# ═══════════════════════════════════════════════════════════════════════════════
# Bridge Client — TUI-side connection manager for REPL bridge sockets
#
# Discovers bridge sockets in ~/.cache/mcprepl/sock/, connects via ZMQ REQ,
# sends eval requests, handles reconnection and health checks.
# ═══════════════════════════════════════════════════════════════════════════════

# ZMQ, Serialization, Dates, JSON are available from the MCPRepl module scope.

# ── Types ─────────────────────────────────────────────────────────────────────

mutable struct REPLConnection
    session_id::String
    name::String
    socket_path::String          # filesystem path to .sock
    endpoint::String             # ipc:// endpoint
    stream_endpoint::String      # ipc:// endpoint for PUB/SUB streaming
    req_socket::Union{ZMQ.Socket,Nothing}
    sub_socket::Union{ZMQ.Socket,Nothing}   # SUB for streaming stdout/stderr
    status::Symbol               # :connected, :disconnected, :connecting
    project_path::String
    julia_version::String
    pid::Int
    connected_at::DateTime
    last_seen::DateTime
    last_ping::DateTime
    tool_call_count::Int
    pending_queue::Vector{Any}
end

function REPLConnection(;
    session_id::String,
    name::String = "julia",
    socket_path::String = "",
    endpoint::String = "",
    stream_endpoint::String = "",
    project_path::String = "",
    julia_version::String = "",
    pid::Int = 0,
)
    t = now()
    REPLConnection(
        session_id,
        name,
        socket_path,
        endpoint,
        stream_endpoint,
        nothing,
        nothing,
        :disconnected,
        project_path,
        julia_version,
        pid,
        t,
        t,
        t,
        0,
        [],
    )
end

# ── Connection Manager ────────────────────────────────────────────────────────

mutable struct ConnectionManager
    connections::Vector{REPLConnection}
    zmq_context::ZMQ.Context
    sock_dir::String
    running::Bool
    watcher_task::Union{Task,Nothing}
    health_task::Union{Task,Nothing}
    lock::ReentrantLock
end

function ConnectionManager(;
    sock_dir::String = joinpath(homedir(), ".cache", "mcprepl", "sock"),
)
    ConnectionManager(
        REPLConnection[],
        Context(),
        sock_dir,
        false,
        nothing,
        nothing,
        ReentrantLock(),
    )
end

# ── PID & Stale Session Helpers ──────────────────────────────────────────────

"""
    _is_pid_alive(pid::Int) -> Bool

Cross-platform check whether a process with the given PID exists.
Uses signal 0 (no actual signal sent) via libuv.
"""
function _is_pid_alive(pid::Int)
    pid > 0 || return false
    ccall(:uv_kill, Cint, (Cint, Cint), pid, 0) == 0
end

"""
    _remove_session_files(sock_dir, session_id)

Delete .json, .sock, and -stream.sock files for a session.
"""
function _remove_session_files(sock_dir::String, session_id::String)
    for suffix in (".json", ".sock", "-stream.sock")
        f = joinpath(sock_dir, session_id * suffix)
        isfile(f) && try
            rm(f)
        catch
        end
    end
end

const _cleanup_done = Ref(false)
const _orphan_contexts = ZMQ.Context[]

"""
    cleanup_stale_sessions!(sock_dir)

Scan the sock directory and remove files belonging to dead PIDs.
Also removes orphan `.sock` files with no corresponding `.json`.
"""
function cleanup_stale_sessions!(sock_dir::String)
    isdir(sock_dir) || return

    # Collect known session IDs from .json files
    json_sessions = Set{String}()

    for f in readdir(sock_dir)
        endswith(f, ".json") || continue
        session_id = replace(f, ".json" => "")
        push!(json_sessions, session_id)

        meta = try
            JSON.parsefile(joinpath(sock_dir, f))
        catch
            # Corrupt/unreadable JSON — remove it
            _remove_session_files(sock_dir, session_id)
            continue
        end

        pid = try
            parse(Int, string(get(meta, "pid", "0")))
        catch
            0
        end

        if !_is_pid_alive(pid)
            @debug "Cleaning stale session" session_id pid
            _remove_session_files(sock_dir, session_id)
            delete!(json_sessions, session_id)
        end
    end

    # Sweep orphan .sock files with no corresponding .json
    for f in readdir(sock_dir)
        endswith(f, ".sock") || continue
        # Derive session_id: strip both "-stream.sock" and ".sock"
        session_id = if endswith(f, "-stream.sock")
            replace(f, "-stream.sock" => "")
        else
            replace(f, ".sock" => "")
        end
        if session_id ∉ json_sessions
            @debug "Removing orphan socket" f
            try
                rm(joinpath(sock_dir, f))
            catch
            end
        end
    end
end

# ── Socket Discovery ─────────────────────────────────────────────────────────

function discover_sessions(mgr::ConnectionManager)
    isdir(mgr.sock_dir) || return REPLConnection[]

    # One-time cleanup of stale sessions from previous crashes
    if !_cleanup_done[]
        _cleanup_done[] = true
        cleanup_stale_sessions!(mgr.sock_dir)
    end

    new_connections = REPLConnection[]

    known_ids = lock(mgr.lock) do
        Set(c.session_id for c in mgr.connections)
    end

    for f in readdir(mgr.sock_dir)
        endswith(f, ".json") || continue
        session_id = replace(f, ".json" => "")

        # Skip already-known sessions
        session_id in known_ids && continue

        meta = try
            JSON.parsefile(joinpath(mgr.sock_dir, f))
        catch
            continue
        end

        pid = try
            parse(Int, string(get(meta, "pid", "0")))
        catch
            0
        end

        # Skip and clean up sessions whose PID is no longer alive
        if !_is_pid_alive(pid)
            _remove_session_files(mgr.sock_dir, session_id)
            continue
        end

        conn = REPLConnection(
            session_id = session_id,
            name = get(meta, "name", "julia"),
            socket_path = joinpath(mgr.sock_dir, "$(session_id).sock"),
            endpoint = get(
                meta,
                "endpoint",
                "ipc://$(joinpath(mgr.sock_dir, "$(session_id).sock"))",
            ),
            stream_endpoint = get(meta, "stream_endpoint", ""),
            project_path = get(meta, "project_path", ""),
            julia_version = get(meta, "julia_version", ""),
            pid = pid,
        )
        push!(new_connections, conn)
    end

    return new_connections
end

function connect!(mgr::ConnectionManager, conn::REPLConnection)
    conn.status = :connecting
    try
        socket = Socket(mgr.zmq_context, REQ)
        socket.rcvtimeo = 5000   # 5s timeout for responses
        socket.sndtimeo = 2000   # 2s timeout for sends
        socket.linger = 0        # don't block on close
        connect(socket, conn.endpoint)
        conn.req_socket = socket

        # Connect SUB socket for streaming output (non-blocking)
        if !isempty(conn.stream_endpoint)
            try
                sub = Socket(mgr.zmq_context, SUB)
                sub.rcvtimeo = 0  # non-blocking recv
                sub.linger = 0    # don't block on close
                subscribe(sub, "")  # receive all messages
                connect(sub, conn.stream_endpoint)
                conn.sub_socket = sub
            catch e
                @debug "Failed to connect stream socket" exception = e
            end
        end

        conn.status = :connected
        conn.last_seen = now()
        return true
    catch e
        @debug "Failed to connect to bridge" session_id = conn.session_id exception = e
        conn.status = :disconnected
        conn.req_socket = nothing
        return false
    end
end

function disconnect!(conn::REPLConnection)
    if conn.req_socket !== nothing
        try
            close(conn.req_socket)
        catch
        end
        conn.req_socket = nothing
    end
    if conn.sub_socket !== nothing
        try
            close(conn.sub_socket)
        catch
        end
        conn.sub_socket = nothing
    end
    conn.status = :disconnected
end

"""
Reset a poisoned REQ socket after a ZMQ timeout. REQ sockets enter
an invalid state when a send completes but recv times out — they can
never send again. The only fix is to close and reconnect.
"""
function _reconnect_req!(conn::REPLConnection)
    old = conn.req_socket
    try
        old.linger = 0
        close(old)
    catch
    end
    try
        ctx = Context()
        push!(_orphan_contexts, ctx)
        socket = Socket(ctx, REQ)
        socket.rcvtimeo = 5000
        socket.sndtimeo = 2000
        socket.linger = 0
        connect(socket, conn.endpoint)
        conn.req_socket = socket
    catch
        conn.req_socket = nothing
        conn.status = :disconnected
    end
end

# ── Eval / Communication ─────────────────────────────────────────────────────

function eval_remote(conn::REPLConnection, code::String; timeout_ms::Int = 30000)
    if conn.status != :connected || conn.req_socket === nothing
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = "Bridge not connected (session=$(conn.session_id), status=$(conn.status))",
            backtrace = nothing,
        )
    end

    request = (type = :eval, code = code)
    try
        # Serialize and send
        io = IOBuffer()
        serialize(io, request)
        send(conn.req_socket, Message(take!(io)))

        # Receive response
        raw = recv(conn.req_socket)
        response = deserialize(IOBuffer(raw))
        conn.last_seen = now()
        conn.tool_call_count += 1
        return response
    catch e
        if e isa ZMQ.TimeoutError
            # REQ socket is now in a broken state (sent request, never got
            # reply). We must close and reconnect or all future calls fail.
            _reconnect_req!(conn)
            return (
                stdout = "",
                stderr = "",
                value_repr = "",
                exception = "Bridge eval timed out after $(timeout_ms)ms",
                backtrace = nothing,
            )
        end
        # Connection likely broken — mark disconnected
        conn.status = :disconnected
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = "Bridge communication error: $(sprint(showerror, e))",
            backtrace = nothing,
        )
    end
end

function ping(conn::REPLConnection)
    if conn.status != :connected || conn.req_socket === nothing
        return nothing
    end

    try
        io = IOBuffer()
        serialize(io, (type = :ping,))
        send(conn.req_socket, Message(take!(io)))

        raw = recv(conn.req_socket)
        response = deserialize(IOBuffer(raw))
        conn.last_seen = now()
        conn.last_ping = now()
        return response
    catch e
        if e isa ZMQ.TimeoutError
            # REQ socket is poisoned after timeout — must reconnect
            _reconnect_req!(conn)
        else
            conn.status = :disconnected
        end
        return nothing
    end
end

"""
    drain_stream_messages!(mgr::ConnectionManager) -> Vector{NamedTuple}

Non-blocking drain of all pending streaming messages from connected bridges.
Returns a vector of `(channel, data, session_name)` tuples.
"""
function drain_stream_messages!(mgr::ConnectionManager)
    messages = NamedTuple{(:channel, :data, :session_name),Tuple{String,String,String}}[]
    lock(mgr.lock) do
        for conn in mgr.connections
            conn.sub_socket === nothing && continue
            # Drain all pending messages (non-blocking due to rcvtimeo=0)
            while true
                raw = try
                    recv(conn.sub_socket)
                catch
                    break  # timeout or error — no more messages
                end
                msg = try
                    deserialize(IOBuffer(raw))
                catch
                    continue
                end
                ch = string(get(msg, :channel, "stdout"))
                data = string(get(msg, :data, ""))
                push!(messages, (channel = ch, data = data, session_name = conn.name))
            end
        end
    end
    return messages
end

# ── Background Tasks ──────────────────────────────────────────────────────────

function start!(mgr::ConnectionManager)
    mgr.running = true
    mkpath(mgr.sock_dir)

    # Socket directory watcher — discovers new bridge sessions
    mgr.watcher_task = Threads.@spawn begin
        while mgr.running
            try
                new_conns = discover_sessions(mgr)
                for conn in new_conns
                    if connect!(mgr, conn)
                        lock(mgr.lock) do
                            push!(mgr.connections, conn)
                        end
                        @debug "Connected to bridge" name = conn.name session_id =
                            conn.session_id
                    end
                end
            catch e
                @debug "Watcher error" exception = e
            end
            sleep(2)  # Poll every 2 seconds
        end
    end

    # Health checker — pings connected sessions, removes stale ones.
    # IMPORTANT: We snapshot connections under the lock, then ping WITHOUT
    # holding the lock so we don't block the TUI render loop or stream drain.
    mgr.health_task = Threads.@spawn begin
        while mgr.running
            try
                # Snapshot current connections (cheap copy of references)
                conns = lock(mgr.lock) do
                    copy(mgr.connections)
                end

                to_remove = REPLConnection[]
                for conn in conns
                    if conn.status == :connected
                        result = ping(conn)
                        if result === nothing
                            @debug "Bridge unresponsive, disconnecting" name = conn.name
                            disconnect!(conn)
                            if !isfile(conn.socket_path)
                                push!(to_remove, conn)
                            end
                        end
                    elseif conn.status == :disconnected
                        if isfile(conn.socket_path)
                            connect!(mgr, conn)
                        else
                            push!(to_remove, conn)
                        end
                    end
                end

                # Remove dead sessions under the lock
                if !isempty(to_remove)
                    lock(mgr.lock) do
                        for conn in to_remove
                            idx = findfirst(c -> c === conn, mgr.connections)
                            if idx !== nothing
                                disconnect!(conn)
                                _remove_session_files(mgr.sock_dir, conn.session_id)
                                deleteat!(mgr.connections, idx)
                            end
                        end
                    end
                end
            catch e
                @debug "Health check error" exception = e
            end
            sleep(5)  # Health check every 5 seconds
        end
    end

    return mgr
end

function stop!(mgr::ConnectionManager)
    mgr.running = false

    # Disconnect all sockets immediately (linger=0 ensures close doesn't block)
    lock(mgr.lock) do
        for conn in mgr.connections
            disconnect!(conn)
        end
    end

    # Close the main ZMQ context and any orphans from _reconnect_req!.
    # All sockets have linger=0 so this should return promptly.
    try
        close(mgr.zmq_context)
    catch
    end
    for ctx in _orphan_contexts
        try
            close(ctx)
        catch
        end
    end
    empty!(_orphan_contexts)

    # Let background tasks finish (they'll exit on next loop since running=false)
    Threads.@spawn begin
        for task in [mgr.watcher_task, mgr.health_task]
            if task !== nothing && !istaskdone(task)
                try
                    wait(task)
                catch
                end
            end
        end
    end
end

# ── Convenience ───────────────────────────────────────────────────────────────

"""
    get_connection(mgr, name_or_id) -> Union{REPLConnection, Nothing}

Find a connection by name or session ID.
"""
function get_connection(mgr::ConnectionManager, name_or_id::String)
    lock(mgr.lock) do
        for conn in mgr.connections
            if conn.name == name_or_id || conn.session_id == name_or_id
                return conn
            end
        end
        return nothing
    end
end

"""
    get_default_connection(mgr) -> Union{REPLConnection, Nothing}

Get the first connected REPL, or nothing if none available.
"""
function get_default_connection(mgr::ConnectionManager)
    lock(mgr.lock) do
        for conn in mgr.connections
            if conn.status == :connected
                return conn
            end
        end
        return nothing
    end
end

"""
    connected_sessions(mgr) -> Vector{REPLConnection}

List all currently connected sessions.
"""
function connected_sessions(mgr::ConnectionManager)
    lock(mgr.lock) do
        filter(c -> c.status == :connected, mgr.connections)
    end
end

"""First 8 chars of the session UUID — short, unique, token-efficient."""
short_key(conn::REPLConnection) = first(conn.session_id, 8)

"""Look up a connection by its 8-char short key. Returns nothing if not found."""
function get_connection_by_key(mgr::ConnectionManager, key::String)
    lock(mgr.lock) do
        for conn in mgr.connections
            if conn.status == :connected && startswith(conn.session_id, key)
                return conn
            end
        end
        return nothing
    end
end
