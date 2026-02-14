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
    req_socket::Union{ZMQ.Socket,Nothing}
    status::Symbol               # :connected, :disconnected, :connecting
    project_path::String
    julia_version::String
    pid::Int
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
    project_path::String = "",
    julia_version::String = "",
    pid::Int = 0,
)
    REPLConnection(
        session_id,
        name,
        socket_path,
        endpoint,
        nothing,
        :disconnected,
        project_path,
        julia_version,
        pid,
        now(),
        now(),
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

# ── Socket Discovery ─────────────────────────────────────────────────────────

function discover_sessions(mgr::ConnectionManager)
    isdir(mgr.sock_dir) || return REPLConnection[]
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

        conn = REPLConnection(
            session_id = session_id,
            name = get(meta, "name", "julia"),
            socket_path = joinpath(mgr.sock_dir, "$(session_id).sock"),
            endpoint = get(
                meta,
                "endpoint",
                "ipc://$(joinpath(mgr.sock_dir, "$(session_id).sock"))",
            ),
            project_path = get(meta, "project_path", ""),
            julia_version = get(meta, "julia_version", ""),
            pid = parse(Int, get(meta, "pid", "0")),
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
        connect(socket, conn.endpoint)
        conn.req_socket = socket
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
    conn.status = :disconnected
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
    catch
        conn.status = :disconnected
        return nothing
    end
end

# ── Background Tasks ──────────────────────────────────────────────────────────

function start!(mgr::ConnectionManager)
    mgr.running = true
    mkpath(mgr.sock_dir)

    # Socket directory watcher — discovers new bridge sessions
    mgr.watcher_task = @async begin
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

    # Health checker — pings connected sessions, removes stale ones
    mgr.health_task = @async begin
        while mgr.running
            try
                lock(mgr.lock) do
                    to_remove = Int[]
                    for (i, conn) in enumerate(mgr.connections)
                        if conn.status == :connected
                            result = ping(conn)
                            if result === nothing
                                @debug "Bridge unresponsive, disconnecting" name = conn.name
                                disconnect!(conn)
                                # Check if socket file still exists
                                if !isfile(conn.socket_path)
                                    push!(to_remove, i)
                                end
                            end
                        elseif conn.status == :disconnected
                            # Try reconnect if socket file exists
                            if isfile(conn.socket_path)
                                connect!(mgr, conn)
                            else
                                push!(to_remove, i)
                            end
                        end
                    end
                    # Remove dead sessions (reverse order to preserve indices)
                    for i in reverse(to_remove)
                        disconnect!(mgr.connections[i])
                        deleteat!(mgr.connections, i)
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

    # Disconnect all
    lock(mgr.lock) do
        for conn in mgr.connections
            disconnect!(conn)
        end
    end

    # Wait for tasks
    for task in [mgr.watcher_task, mgr.health_task]
        if task !== nothing && !istaskdone(task)
            try
                wait(task)
            catch
            end
        end
    end

    # Close ZMQ context
    try
        close(mgr.zmq_context)
    catch
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
