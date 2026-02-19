# ═══════════════════════════════════════════════════════════════════════════════
# MCPReplBridge — Thin eval bridge for the user's REPL
#
# Runs inside the user's Julia session. Binds a ZMQ REP socket on an IPC
# endpoint so the persistent TUI server can send eval requests without living
# inside this process. Dependencies: ZMQ.jl + Serialization (stdlib).
# ═══════════════════════════════════════════════════════════════════════════════

module MCPReplBridge

using ZMQ
using REPL
using Serialization
using Dates

# ── Constants ─────────────────────────────────────────────────────────────────

const _BRIDGE_CACHE_DIR = let
    d = get(ENV, "XDG_CACHE_HOME") do
        Sys.iswindows() ?
        joinpath(
            get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local")),
            "MCPRepl",
        ) : joinpath(homedir(), ".cache", "mcprepl")
    end
    mkpath(d)
    d
end
const SOCK_DIR = joinpath(_BRIDGE_CACHE_DIR, "sock")
const BRIDGE_LOCK = ReentrantLock()
const _PUB_LOCK = ReentrantLock()

# Global state for the running bridge
const _BRIDGE_TASK = Ref{Union{Task,Nothing}}(nothing)
const _BRIDGE_CONTEXT = Ref{Union{ZMQ.Context,Nothing}}(nothing)
const _BRIDGE_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)
const _STREAM_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)  # PUB for streaming output
const _SESSION_ID = Ref{String}("")
const _RUNNING = Ref{Bool}(false)
const _START_TIME = Ref{Float64}(0.0)
const _MIRROR_REPL = Ref{Bool}(false)
const _REVISE_WATCHER_TASK = Ref{Union{Task,Nothing}}(nothing)

# ── Core eval logic ──────────────────────────────────────────────────────────
# Extracted from MCPRepl's execute_repllike, stripped of MCP-specific concerns
# (truncation, println stripping, prompt display). Those stay on the server side.

function bridge_eval(code::String; _mod::Module = Main, display_code::String = code)
    lock(BRIDGE_LOCK)
    try
        if _MIRROR_REPL[]
            printstyled("\nagent> ", color = :red, bold = true)
            print(display_code, "\n")
        end

        # Check REPL availability
        repl =
            (isdefined(Base, :active_repl) && Base.active_repl !== nothing) ?
            Base.active_repl : nothing
        backend =
            repl !== nothing && hasproperty(repl, :backendref) ? repl.backendref : nothing
        has_repl =
            repl !== nothing &&
            backend !== nothing &&
            hasproperty(backend, :repl_channel) &&
            hasproperty(backend, :response_channel) &&
            isopen(backend.repl_channel) &&
            isopen(backend.response_channel)

        expr = Base.parse_input_line(code)

        if has_repl
            result = REPL.call_on_backend(() -> _eval_with_capture(expr), backend)
            # call_on_backend returns (value, iserr) Pair or NamedTuple
            val = if result isa Pair
                result.first
            elseif result isa Tuple && length(result) == 2
                result[1]
            else
                result
            end
            _maybe_echo_result(val)
            return val
        else
            val = _eval_with_capture(expr)
            _maybe_echo_result(val)
            return val
        end
    catch e
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = sprint(showerror, e, catch_backtrace()),
            backtrace = sprint(Base.show_backtrace, catch_backtrace()),
        )
    finally
        unlock(BRIDGE_LOCK)
    end
end

function _maybe_echo_result(result)
    _MIRROR_REPL[] || return

    has_exc = hasproperty(result, :exception) && result.exception !== nothing
    if has_exc
        printstyled("ERROR: ", color = :red, bold = true)
        println(string(result.exception))
        return
    end

    # stdout/stderr are mirrored live while reading redirected streams.
    if hasproperty(result, :value_repr)
        val = string(result.value_repr)
        isempty(val) || println(val)
    end
end

function _set_option!(key::String, value)
    if key == "mirror_repl"
        _MIRROR_REPL[] = value === true
        return (type = :ok, key = key, value = _MIRROR_REPL[])
    end
    return (type = :error, message = "unknown option: $key")
end

function _current_options()
    return (type = :options, mirror_repl = _MIRROR_REPL[])
end

function _publish_stream(channel::String, data; request_id::String = "")
    pub = _STREAM_SOCKET[]
    pub === nothing && return
    lock(_PUB_LOCK) do
        try
            io = IOBuffer()
            msg =
                isempty(request_id) ? (channel = channel, data = data) :
                (channel = channel, data = data, request_id = request_id)
            serialize(io, msg)
            send(pub, Message(take!(io)))
        catch
            # Non-critical — subscriber may not be connected
        end
    end
end

function _start_revise_watcher()
    isdefined(Main, :Revise) || return
    isdefined(Main.Revise, :revision_event) || return
    _REVISE_WATCHER_TASK[] = @async begin
        try
            while _RUNNING[]
                wait(Main.Revise.revision_event)
                _RUNNING[] || break
                Base.reset(Main.Revise.revision_event)
                project_path = dirname(Base.active_project())
                _publish_stream("files_changed", project_path)
            end
        catch e
            e isa InterruptException && return
            @debug "Revise watcher exited" exception = e
        end
    end
end

function _eval_with_capture(expr)
    orig_stdout = stdout
    orig_stderr = stderr

    stdout_read, stdout_write = redirect_stdout()
    stderr_read, stderr_write = redirect_stderr()

    stdout_content = String[]
    stderr_content = String[]

    stdout_task = @async begin
        try
            while !eof(stdout_read)
                line = readline(stdout_read; keep = true)
                push!(stdout_content, line)
                # Echo to original stdout for REPL visibility
                write(orig_stdout, line)
                flush(orig_stdout)
                # Publish to TUI stream
                _publish_stream("stdout", line)
            end
        catch e
            e isa EOFError || @debug "stdout read error" exception = e
        end
    end

    stderr_task = @async begin
        try
            while !eof(stderr_read)
                line = readline(stderr_read; keep = true)
                push!(stderr_content, line)
                write(orig_stderr, line)
                flush(orig_stderr)
                _publish_stream("stderr", line)
            end
        catch e
            e isa EOFError || @debug "stderr read error" exception = e
        end
    end

    value = nothing
    caught = nothing
    bt = nothing
    try
        # Apply REPL ast_transforms (Revise, softscope, etc.)
        if isdefined(Base, :active_repl_backend) && Base.active_repl_backend !== nothing
            for xf in Base.active_repl_backend.ast_transforms
                expr = Base.invokelatest(xf, expr)
            end
        end
        value = Core.eval(Main, expr)
    catch e
        caught = e
        bt = catch_backtrace()
    finally
        redirect_stdout(orig_stdout)
        redirect_stderr(orig_stderr)
        close(stdout_write)
        close(stderr_write)
        wait(stdout_task)
        wait(stderr_task)
        close(stdout_read)
        close(stderr_read)
    end

    # Format value representation
    value_repr = ""
    if value !== nothing
        io = IOBuffer()
        try
            show(io, MIME("text/plain"), value)
            value_repr = String(take!(io))
        catch
            value_repr = repr(value)
        end
    end

    exception_str = if caught !== nothing
        io = IOBuffer()
        try
            showerror(io, caught, bt)
        catch
            showerror(io, caught)
        end
        String(take!(io))
    else
        nothing
    end

    return (
        stdout = join(stdout_content),
        stderr = join(stderr_content),
        value_repr = value_repr,
        exception = exception_str,
        backtrace = nothing,
    )
end

# ── Metadata ──────────────────────────────────────────────────────────────────

function write_metadata(
    session_id::String,
    name::String,
    endpoint::String,
    stream_endpoint::String = "",
)
    meta_path = joinpath(SOCK_DIR, "$(session_id).json")
    meta = Dict(
        "session_id" => session_id,
        "name" => name,
        "pid" => getpid(),
        "julia_version" => string(VERSION),
        "project_path" => dirname(Base.active_project()),
        "endpoint" => endpoint,
        "stream_endpoint" => stream_endpoint,
        "started_at" => string(now()),
    )
    open(meta_path, "w") do io
        # Simple JSON without dependency — just key-value pairs
        print(io, "{\n")
        pairs = collect(meta)
        for (i, (k, v)) in enumerate(pairs)
            print(io, "  \"$k\": \"$v\"")
            i < length(pairs) && print(io, ",")
            print(io, "\n")
        end
        print(io, "}\n")
    end
    return meta_path
end

function cleanup_files(session_id::String)
    for ext in [".sock", "-stream.sock", ".json"]
        path = joinpath(SOCK_DIR, "$(session_id)$(ext)")
        isfile(path) && rm(path; force = true)
    end
end

# ── Message loop ──────────────────────────────────────────────────────────────

"""
Serialize a result NamedTuple to bytes for PUB transport.
"""
function _serialize_result(result)::String
    io = IOBuffer()
    serialize(io, result)
    return String(take!(io))
end

"""
    _exec_restart(name, session_id, project_path)

Replace the current process with a fresh Julia via `execvp`. Same PID, same
terminal, fresh Julia state. The `-i` flag keeps the REPL interactive.
"""
function _exec_restart(name::String, session_id::String, project_path::String)
    julia_args = Base.julia_cmd().exec  # e.g. ["julia", "-Cnative", "-J..."]
    serve_code = """
    try; using Revise; catch; end
    using MCPRepl
    MCPReplBridge.serve(session_id=$(repr(session_id)))
    """
    args = vcat(julia_args, ["--project=$project_path", "-i", "-e", serve_code])

    # execvp replaces the process image — same PID, same terminal
    argv = map(String, args)
    ptrs = Ptr{UInt8}[pointer(s) for s in argv]
    push!(ptrs, Ptr{UInt8}(0))  # NULL terminator
    GC.@preserve argv ccall(:execvp, Cint, (Cstring, Ptr{Ptr{UInt8}}), argv[1], ptrs)

    # If we reach here, execvp failed — fall back to exit
    @error "execvp failed, falling back to exit" errno = Base.Libc.errno()
    exit(1)
end

function handle_message(request::NamedTuple)
    msg_type = get(request, :type, :unknown)

    if msg_type == :eval
        code = get(request, :code, "")
        display_code = get(request, :display_code, code)
        result = bridge_eval(code; display_code = display_code)
        return result
    elseif msg_type == :eval_async
        code = get(request, :code, "")
        display_code = get(request, :display_code, code)
        request_id = get(request, :request_id, "")
        # Run eval in background, return :accepted immediately
        @async begin
            try
                result = bridge_eval(code; display_code = display_code)
                _publish_stream("eval_complete", _serialize_result(result); request_id)
            catch e
                error_result = (
                    stdout = "",
                    stderr = "",
                    value_repr = "",
                    exception = sprint(showerror, e, catch_backtrace()),
                    backtrace = nothing,
                )
                _publish_stream("eval_error", _serialize_result(error_result); request_id)
            end
        end
        return (type = :accepted, request_id = request_id)
    elseif msg_type == :set_option
        key = string(get(request, :key, ""))
        value = get(request, :value, nothing)
        return _set_option!(key, value)
    elseif msg_type == :get_options
        return _current_options()
    elseif msg_type == :ping
        return (
            type = :pong,
            pid = getpid(),
            uptime = time() - _START_TIME[],
            julia_version = string(VERSION),
            project_path = dirname(Base.active_project()),
        )
    elseif msg_type == :shutdown
        _RUNNING[] = false
        return (type = :ok, message = "shutting down")
    elseif msg_type == :restart
        # Save metadata before cleanup
        old_name = string(get(request, :name, "julia"))
        old_session_id = _SESSION_ID[]
        old_project = dirname(Base.active_project())

        _RUNNING[] = false

        @async begin
            try
                sleep(0.3)  # Let ZMQ reply go through
                _cleanup()  # Close sockets, remove metadata files
                _exec_restart(old_name, old_session_id, old_project)
            catch e
                @error "Restart failed" exception = (e, catch_backtrace())
                exit(1)
            end
        end

        return (type = :ok, message = "restarting via exec")
    else
        return (type = :error, message = "unknown request type: $msg_type")
    end
end

function message_loop(socket::ZMQ.Socket)
    while _RUNNING[]
        try
            # recv with timeout — throws TimeoutError on timeout
            raw = recv(socket)
            request = deserialize(IOBuffer(raw))

            response = handle_message(request)

            # Serialize and send response
            io = IOBuffer()
            serialize(io, response)
            send(socket, Message(take!(io)))
        catch e
            if !_RUNNING[]
                break  # Clean shutdown
            end
            # Timeout is expected — just loop to check _RUNNING
            if e isa ZMQ.TimeoutError
                continue
            end
            if e isa ZMQ.StateError || e isa EOFError
                break
            end
            @debug "Bridge message loop error" exception = e
            # Try to send error response
            try
                io = IOBuffer()
                serialize(io, (type = :error, message = sprint(showerror, e)))
                send(socket, Message(take!(io)))
            catch
                # If we can't even send the error, just continue
            end
        end
    end
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    serve(; session_id=nothing)

Start the eval bridge. Binds a ZMQ REP socket on an IPC endpoint and
listens for eval requests from the MCPRepl TUI server.

Non-blocking — returns immediately. The bridge runs in a background task.
The session name is derived automatically from the active project path.

# Arguments
- `session_id::Union{String,Nothing}`: Reuse a session ID (e.g. after exec restart)

# Example
```julia
using MCPRepl
MCPReplBridge.serve()
```
"""
function serve(;
    name::Union{String,Nothing} = nothing,
    port::Union{Int,Nothing} = nothing,
    session_id::Union{String,Nothing} = nothing,
)
    if name !== nothing
        Base.depwarn(
            "serve(name=...) is deprecated. The session name is now derived from the active project automatically.",
            :serve,
        )
    end
    if port !== nothing
        Base.depwarn(
            "serve(port=...) is deprecated. The TCP port binding has been removed; bridges use IPC only.",
            :serve,
        )
    end
    _serve(;
        name = something(
            name,
            basename(dirname(something(Base.active_project(), "julia"))),
        ),
        session_id,
    )
end

function _serve(; name::String, session_id::Union{String,Nothing})
    if _RUNNING[]
        @warn "Bridge already running (session=$(_SESSION_ID[])). Call stop() first."
        return _SESSION_ID[]
    end

    # Ensure socket directory exists
    mkpath(SOCK_DIR)

    # Generate or reuse session ID
    sid = session_id !== nothing ? session_id : string(Base.UUID(rand(UInt128)))
    _SESSION_ID[] = sid
    _START_TIME[] = time()
    _MIRROR_REPL[] = try
        parentmodule(@__MODULE__).get_bridge_mirror_repl_preference()
    catch
        false
    end

    # Create ZMQ context and sockets
    ctx = Context()
    socket = Socket(ctx, REP)
    _BRIDGE_CONTEXT[] = ctx
    _BRIDGE_SOCKET[] = socket

    # Set receive timeout (1 second) so message loop can check _RUNNING
    socket.rcvtimeo = 1000

    # Bind IPC endpoint
    sock_path = joinpath(SOCK_DIR, "$(sid).sock")
    endpoint = "ipc://$(sock_path)"
    bind(socket, endpoint)

    # Create PUB socket for streaming stdout/stderr to TUI
    pub_socket = Socket(ctx, PUB)
    stream_path = joinpath(SOCK_DIR, "$(sid)-stream.sock")
    stream_endpoint = "ipc://$(stream_path)"
    bind(pub_socket, stream_endpoint)
    _STREAM_SOCKET[] = pub_socket

    # Write metadata file
    write_metadata(sid, name, endpoint, stream_endpoint)

    # Register cleanup
    atexit(() -> stop())

    # Start message loop in background
    _RUNNING[] = true
    _BRIDGE_TASK[] = @async begin
        try
            message_loop(socket)
        catch e
            @debug "Bridge task exited" exception = e
        finally
            _cleanup()
        end
    end

    _start_revise_watcher()

    emoticon = try
        parentmodule(@__MODULE__).load_personality()
    catch
        "⚡"
    end
    printstyled("  $emoticon MCPRepl bridge "; color = :green, bold = true)
    printstyled("connected"; color = :green)
    printstyled(" ($name)\n"; color = :light_black)
    if _MIRROR_REPL[]
        printstyled("  host REPL mirroring enabled\n"; color = :light_black)
    end
    return sid
end

"""
    stop()

Stop the eval bridge, clean up socket and metadata files.
"""
function stop()
    if !_RUNNING[]
        return
    end

    _RUNNING[] = false

    # Wait for task to finish
    task = _BRIDGE_TASK[]
    if task !== nothing && !istaskdone(task)
        try
            wait(task)
        catch
        end
    end

    _cleanup()
    printstyled("  MCPRepl bridge "; color = :yellow, bold = true)
    printstyled("disconnected\n"; color = :yellow)
end

function _cleanup()
    # Stop Revise watcher
    watcher = _REVISE_WATCHER_TASK[]
    if watcher !== nothing && !istaskdone(watcher)
        try
            # Wake the blocked wait so the task can exit
            if isdefined(Main, :Revise)
                Base.notify(Main.Revise.revision_event)
            end
        catch
        end
    end
    _REVISE_WATCHER_TASK[] = nothing

    # Close REP socket
    socket = _BRIDGE_SOCKET[]
    if socket !== nothing
        try
            close(socket)
        catch
        end
        _BRIDGE_SOCKET[] = nothing
    end

    # Close PUB socket
    pub = _STREAM_SOCKET[]
    if pub !== nothing
        try
            close(pub)
        catch
        end
        _STREAM_SOCKET[] = nothing
    end

    # Close context
    ctx = _BRIDGE_CONTEXT[]
    if ctx !== nothing
        try
            close(ctx)
        catch
        end
        _BRIDGE_CONTEXT[] = nothing
    end

    # Remove files
    cleanup_files(_SESSION_ID[])

    _BRIDGE_TASK[] = nothing
    _RUNNING[] = false
    _MIRROR_REPL[] = false
end

"""
    status()

Print current bridge status.
"""
function status()
    if _RUNNING[]
        uptime = time() - _START_TIME[]
        mins = round(Int, uptime / 60)
        println("Bridge: running")
        println("  Session: $(_SESSION_ID[])")
        println("  Uptime:  $(mins)m")
        println("  PID:     $(getpid())")
        println("  Mirror:  $(_MIRROR_REPL[])")
    else
        println("Bridge: not running")
    end
end

end # module MCPReplBridge
