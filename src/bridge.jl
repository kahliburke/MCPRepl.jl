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

const SOCK_DIR = joinpath(homedir(), ".cache", "mcprepl", "sock")
const BRIDGE_LOCK = ReentrantLock()

# Global state for the running bridge
const _BRIDGE_TASK = Ref{Union{Task,Nothing}}(nothing)
const _BRIDGE_CONTEXT = Ref{Union{ZMQ.Context,Nothing}}(nothing)
const _BRIDGE_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)
const _STREAM_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)  # PUB for streaming output
const _SESSION_ID = Ref{String}("")
const _RUNNING = Ref{Bool}(false)
const _START_TIME = Ref{Float64}(0.0)

# ── Core eval logic ──────────────────────────────────────────────────────────
# Extracted from MCPRepl's execute_repllike, stripped of MCP-specific concerns
# (truncation, println stripping, prompt display). Those stay on the server side.

function bridge_eval(code::String; _mod::Module = Main)
    lock(BRIDGE_LOCK)
    try
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
            return val
        else
            return _eval_with_capture(expr)
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

function _publish_stream(channel::String, data::String)
    pub = _STREAM_SOCKET[]
    pub === nothing && return
    try
        io = IOBuffer()
        serialize(io, (channel = channel, data = data))
        send(pub, Message(take!(io)))
    catch
        # Non-critical — subscriber may not be connected
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

function handle_message(request::NamedTuple)
    msg_type = get(request, :type, :unknown)

    if msg_type == :eval
        code = get(request, :code, "")
        result = bridge_eval(code)
        return result
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
    serve(; name="julia", port=nothing)

Start the eval bridge. Binds a ZMQ REP socket on an IPC endpoint and
listens for eval requests from the MCPRepl TUI server.

Non-blocking — returns immediately. The bridge runs in a background task.

# Arguments
- `name::String`: Human-readable session name (shown in TUI)
- `port::Union{Int,Nothing}`: If given, also bind TCP on this port (for remote)

# Example
```julia
using MCPRepl
MCPReplBridge.serve(name="myproject")
```
"""
function serve(; name::String = "julia", port::Union{Int,Nothing} = nothing)
    if _RUNNING[]
        @warn "Bridge already running (session=$(_SESSION_ID[])). Call stop() first."
        return _SESSION_ID[]
    end

    # Ensure socket directory exists
    mkpath(SOCK_DIR)

    # Generate session ID
    session_id = string(Base.UUID(rand(UInt128)))
    _SESSION_ID[] = session_id
    _START_TIME[] = time()

    # Create ZMQ context and sockets
    ctx = Context()
    socket = Socket(ctx, REP)
    _BRIDGE_CONTEXT[] = ctx
    _BRIDGE_SOCKET[] = socket

    # Set receive timeout (1 second) so message loop can check _RUNNING
    socket.rcvtimeo = 1000

    # Bind IPC endpoint
    sock_path = joinpath(SOCK_DIR, "$(session_id).sock")
    endpoint = "ipc://$(sock_path)"
    bind(socket, endpoint)

    # Create PUB socket for streaming stdout/stderr to TUI
    pub_socket = Socket(ctx, PUB)
    stream_path = joinpath(SOCK_DIR, "$(session_id)-stream.sock")
    stream_endpoint = "ipc://$(stream_path)"
    bind(pub_socket, stream_endpoint)
    _STREAM_SOCKET[] = pub_socket

    # Optionally bind TCP
    if port !== nothing
        bind(socket, "tcp://127.0.0.1:$port")
    end

    # Write metadata file
    write_metadata(session_id, name, endpoint, stream_endpoint)

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

    emoticon = try
        parentmodule(@__MODULE__).load_personality()
    catch
        "⚡"
    end
    printstyled("  $emoticon MCPRepl bridge "; color = :green, bold = true)
    printstyled("connected"; color = :green)
    printstyled(" ($name)\n"; color = :light_black)
    return session_id
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
    else
        println("Bridge: not running")
    end
end

end # module MCPReplBridge
