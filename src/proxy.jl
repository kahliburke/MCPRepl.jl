"""
Persistent MCP Proxy Server

Provides a stable MCP interface that routes requests to backend Julia session processes.
The proxy server runs independently and stays up even when backend julia_sessions restart.
"""
module Proxy

using HTTP
using JSON
using Sockets
using Dates
using Dates: Minute, Second
using Logging
using LoggingExtras
using UUIDs

# Access Dashboard and Database from parent MCPRepl module
using ..Dashboard
using ..Database

include("session.jl")
using .Session

include("proxy_tools.jl")

# Include proxy sub-modules
include("proxy/validation.jl")
include("proxy/http_helpers.jl")
include("proxy/session_registry.jl")
include("proxy/process_management.jl")
include("proxy/logging.jl")
include("proxy/vite.jl")
include("proxy/mcp_notification.jl")
include("proxy/dashboard_helpers.jl")
include("proxy/dashboard_routes.jl")

# Global state (simple Refs that can be precompiled)
const SERVER = Ref{Union{HTTP.Server,Nothing}}(nothing)
const SERVER_PORT = Ref{Int}(3000)
const SERVER_PID_FILE = Ref{String}("")
const VITE_DEV_PROCESS = Ref{Union{Base.Process,Nothing}}(nothing)
const VITE_DEV_PORT = 3001

# CLIENT_CONNECTIONS initialized in __init__() (can't be precompiled)
CLIENT_CONNECTIONS = Dict{String,Channel{Dict}}()
CLIENT_CONNECTIONS_LOCK = ReentrantLock()

# Initialize global state at runtime (after precompilation)
# Note: JULIA_SESSION_REGISTRY, MCP_SESSION_REGISTRY and their locks
# are defined in proxy/session_registry.jl and re-initialized here
function __init__()
    # Re-initialize session registries (defined in session_registry.jl)
    global JULIA_SESSION_REGISTRY = Dict{String,JuliaSession}()
    global JULIA_SESSION_REGISTRY_LOCK = ReentrantLock()
    global MCP_SESSION_REGISTRY = Dict{String,MCPSession}()
    global MCP_SESSION_LOCK = ReentrantLock()
    # Initialize client connections
    global CLIENT_CONNECTIONS = Dict{String,Channel{Dict}}()
    global CLIENT_CONNECTIONS_LOCK = ReentrantLock()
end

# Database initialization - called explicitly when needed (not on module load)
function init_database!(db_path::String)
    try
        Database.init_db!(db_path)
        @debug "Proxy database initialized" db_path = db_path pid = getpid()
        return true
    catch e
        @warn "Failed to initialize proxy database" exception = (e, catch_backtrace())
        return false
    end
end

"""
    register_client_connection(session_id::String) -> Channel{Dict}

Register a new client connection and return a channel for sending notifications.
"""
function register_client_connection(session_id::String)
    channel = Channel{Dict}(32)  # Buffer up to 32 notifications

    lock(CLIENT_CONNECTIONS_LOCK) do
        CLIENT_CONNECTIONS[session_id] = channel
    end

    @debug "Registered client connection" session_id = session_id
    return channel
end

"""
    unregister_client_connection(session_id::String)

Remove a client connection when the session ends.
"""
function unregister_client_connection(session_id::String)
    lock(CLIENT_CONNECTIONS_LOCK) do
        if haskey(CLIENT_CONNECTIONS, session_id)
            channel = CLIENT_CONNECTIONS[session_id]
            close(channel)
            delete!(CLIENT_CONNECTIONS, session_id)
            @debug "Unregistered client connection" session_id = session_id
        end
    end
end

"""
    monitor_heartbeats()

Background task that monitors Julia session heartbeats and marks Julia sessions as disconnected if they stop responding.
Runs every 1 second and checks for Julia sessions that haven't sent a heartbeat in 30 seconds.
"""
function monitor_heartbeats()
    while SERVER[] !== nothing
        try
            sleep(1)  # Check every 1 second

            if SERVER[] === nothing
                break
            end

            julia_session_ids_to_check = String[]
            lock(JULIA_SESSION_REGISTRY_LOCK) do
                julia_session_ids_to_check = collect(keys(JULIA_SESSION_REGISTRY))
            end

            for julia_session_id in julia_session_ids_to_check
                # Do all checks inside lock to avoid race conditions
                lock(JULIA_SESSION_REGISTRY_LOCK) do
                    if !haskey(JULIA_SESSION_REGISTRY, julia_session_id)
                        return
                    end

                    session = JULIA_SESSION_REGISTRY[julia_session_id]
                    # Skip if already disconnected/reconnecting/stopped
                    if session.status != :ready
                        return
                    end

                    # Check if heartbeat is stale (>30 seconds old)
                    time_since_heartbeat = now() - session.last_heartbeat
                    if time_since_heartbeat > Second(30)
                        @warn "Julia session heartbeat timeout, marking as disconnected" id =
                            julia_session_id last_heartbeat = session.last_heartbeat time_since =
                            time_since_heartbeat status_before = session.status
                        JULIA_SESSION_REGISTRY[julia_session_id].status = :disconnected
                        JULIA_SESSION_REGISTRY[julia_session_id].disconnect_time = now()
                        JULIA_SESSION_REGISTRY[julia_session_id].missed_heartbeats += 1

                        # Log disconnection event
                        Dashboard.log_event(
                            julia_session_id,
                            Dashboard.ERROR,
                            Dict(
                                "message" => "Heartbeat timeout after $time_since_heartbeat",
                            ),
                        )
                    end
                end
            end
        catch e
            @error "Error in heartbeat monitor" exception = (e, catch_backtrace())
        end
    end

    @info "Heartbeat monitor stopped"
end

"""
    route_to_session_streaming(request::Dict, original_req::HTTP.Request, http::HTTP.Stream) -> Nothing

Route a request to the appropriate backend Julia session with streaming support.

Routing priority:
1. Mcp-Session-Id header (standard MCP session)
2. X-MCPRepl-Target header (explicit target specification)
3. Smart routing (prefer MCPRepl agent, or first available)
"""
function route_to_session_streaming(
    request::Dict,
    original_req::HTTP.Request,
    http::HTTP.Stream,
)
    # Check for MCP session ID first (standard MCP mechanism)
    session_id_header = HTTP.header(original_req, "Mcp-Session-Id")
    target_id = nothing

    if !isempty(session_id_header)
        session_id = String(session_id_header)
        session = get_mcp_session(session_id)

        if session !== nothing
            # Update session activity
            update_activity!(session)
            target_id = session.target_julia_session_id
            @debug "Routing via session" session_id = session_id target_id = target_id
        else
            # Session not found - client needs to re-initialize
            send_jsonrpc_error(
                http,
                get(request, "id", nothing),
                -32001,
                "Session not found. Please send a new initialize request.";
                status = 404,
            )
            return nothing
        end
    end

    # Fall back to X-MCPRepl-Target header if no session
    if target_id === nothing
        header_value = HTTP.header(original_req, "X-MCPRepl-Target")
        target_id = isempty(header_value) ? nothing : String(header_value)
    end

    # If still no target, this request requires a backend Julia session but none is available
    if target_id === nothing
        sessions = list_julia_sessions()
        if isempty(sessions)
            send_jsonrpc_error(
                http,
                get(request, "id", nothing),
                -32001,
                "No Julia sessions available. Use proxy tools to list or start sessions: list_julia_sessions, start_julia_session.";
                status = 503,
            )
            return nothing
        else
            # julia_sessions exist but session doesn't have a target
            julia_session_ids =
                join(["$(s.name) ($(s.uuid))" for s in julia_sessions], ", ")
            send_jsonrpc_error(
                http,
                get(request, "id", nothing),
                -32001,
                "No target Julia session specified. Available sessions: $julia_session_ids. Re-initialize with X-MCPRepl-Target header to specify a target.";
                status = 400,
            )
            return nothing
        end
    end

    # Get the Julia session connection
    session = get_julia_session(target_id)

    if session === nothing
        send_jsonrpc_error(
            http,
            get(request, "id", nothing),
            -32002,
            "Julia session not found: $target_id";
            status = 404,
        )
        return nothing
    end

    # Handle Julia session status
    if session.status == :disconnected || session.status == :reconnecting
        # Buffer the request and keep stream open with status updates
        lock(JULIA_SESSION_REGISTRY_LOCK) do
            if haskey(JULIA_SESSION_REGISTRY, target_id)
                # Add request to buffer
                push!(JULIA_SESSION_REGISTRY[target_id].pending_requests, (request, http))

                # Mark as reconnecting if not already
                if JULIA_SESSION_REGISTRY[target_id].status == :disconnected
                    JULIA_SESSION_REGISTRY[target_id].status = :reconnecting
                    @info "Julia session disconnected, buffering requests and attempting reconnection" id =
                        target_id buffer_size =
                        length(JULIA_SESSION_REGISTRY[target_id].pending_requests)

                    # Start async reconnection task
                    @async try_reconnect(target_id)
                end
            end
        end

        # Start async task to send status updates while waiting for reconnection
        @async send_reconnection_updates(target_id, request, http)
        return nothing

    elseif session.status == :stopped
        # Julia session is permanently stopped, return error
        send_jsonrpc_error(
            http,
            get(request, "id", nothing),
            -32003,
            "Julia session permanently stopped: $target_id. Restart required.";
            status = 503,
        )
        return nothing

    elseif session.status != :ready
        send_jsonrpc_error(
            http,
            get(request, "id", nothing),
            -32003,
            "Julia session not ready: $(session.status)";
            status = 503,
        )
        return nothing
    end

    # Forward request to backend Julia session with streaming support
    try
        backend_url = "http://127.0.0.1:$(session.port)/"
        body_str = JSON.json(request)

        @debug "Forwarding to backend" url = backend_url body_length = length(body_str)

        # Log tool call event to dashboard
        method = get(request, "method", "")
        if method == "tools/call"
            params = get(request, "params", Dict())
            tool_name = get(params, "name", "unknown")
            tool_args = get(params, "arguments", Dict())
            Dashboard.log_event(
                target_id,
                Dashboard.TOOL_CALL,
                Dict("tool" => tool_name, "method" => method, "arguments" => tool_args),
            )
        elseif !isempty(method)
            # Log other methods as code execution
            Dashboard.log_event(
                target_id,
                Dashboard.CODE_EXECUTION,
                Dict("method" => method),
            )
        end

        start_time = time()

        # Emit progress notification at start of tool execution
        if method == "tools/call" && !isempty(tool_name)
            progress_token = "tool-$(tool_name)-$(round(Int, start_time))"
            Dashboard.emit_progress(
                target_id,
                progress_token,
                1,
                message = "🔧 $(tool_name): Executing...",
            )
        end

        # Make request to backend - use simple HTTP.request with response streaming disabled
        backend_response = HTTP.request(
            "POST",
            backend_url,
            ["Content-Type" => "application/json"],
            body_str;
            readtimeout = 30,
            connect_timeout = 5,
            status_exception = false,
        )

        duration_ms = (time() - start_time) * 1000

        # Complete progress notification after tool execution
        if method == "tools/call" && !isempty(tool_name)
            progress_token = "tool-$(tool_name)-$(round(Int, start_time))"
            Dashboard.emit_progress(
                target_id,
                progress_token,
                2,
                total = 2,
                message = "✅ $(tool_name): Complete",
            )
        end
        response_body = String(backend_response.body)
        response_status = backend_response.status
        response_headers = Dict{String,String}()
        for (name, value) in backend_response.headers
            response_headers[name] = value
        end

        # Parse response to extract result/error for dashboard
        response_data = Dict("status" => response_status[], "method" => method)
        try
            response_json = JSON.parse(response_body)
            # Include the actual result or error in the event log
            if haskey(response_json, "result")
                response_data["result"] = response_json["result"]
            elseif haskey(response_json, "error")
                response_data["error"] = response_json["error"]
            end
        catch parse_err
            # If we can't parse the response, just log the status
            @debug "Could not parse response for logging" exception = parse_err
        end

        # Log successful execution with result
        Dashboard.log_event(
            target_id,
            Dashboard.OUTPUT,
            response_data;
            duration_ms = duration_ms,
        )

        # Update last heartbeat
        update_julia_session_status(target_id, :ready)

        # Forward response to client with proper headers
        HTTP.setstatus(http, response_status)

        # Forward all headers from backend, ensuring Content-Type is set
        for (name, value) in response_headers
            HTTP.setheader(http, name => value)
        end
        # Ensure Content-Type is set if not already present
        if !haskey(response_headers, "Content-Type")
            HTTP.setheader(http, "Content-Type" => "application/json")
        end

        # Log the backend response before sending to client
        request_id_val = get(request, "id", nothing)
        log_db_interaction(
            "outbound",
            "response",
            response_body;
            julia_session_id = target_id,
            request_id = request_id_val,
            method = method,
        )

        HTTP.startwrite(http)
        write(http, response_body)
        return nothing
    catch e
        # Capture full error with stack trace
        io = IOBuffer()
        showerror(io, e, catch_backtrace())
        error_msg = String(take!(io))
        @error "Error forwarding request to Julia session" target = target_id exception = e

        # Log error to database
        log_db_event(
            "request.error",
            Dict(
                "error_type" => string(typeof(e)),
                "error_message" => error_msg,
                "method" => get(request, "method", "unknown"),
            );
            julia_session_id = target_id,
        )

        # Store the error and mark as disconnected
        error_summary = length(error_msg) > 500 ? error_msg[1:500] * "..." : error_msg

        # Mark as disconnected and buffer this request
        lock(JULIA_SESSION_REGISTRY_LOCK) do
            if haskey(JULIA_SESSION_REGISTRY, target_id)
                JULIA_SESSION_REGISTRY[target_id].last_error = error_summary
                JULIA_SESSION_REGISTRY[target_id].missed_heartbeats += 1

                # Only permanently stop after extended disconnect (2 minutes)
                if JULIA_SESSION_REGISTRY[target_id].status == :disconnected &&
                   JULIA_SESSION_REGISTRY[target_id].disconnect_time !== nothing &&
                   (now() - JULIA_SESSION_REGISTRY[target_id].disconnect_time) > Minute(2)
                    JULIA_SESSION_REGISTRY[target_id].status = :stopped
                    @warn "Julia session permanently stopped after 2 minutes disconnected" id =
                        target_id

                    # Fail all pending requests
                    flush_pending_requests_with_error(
                        target_id,
                        "Julia session permanently stopped",
                    )
                else
                    # First failure - mark as disconnected
                    if JULIA_SESSION_REGISTRY[target_id].status == :ready
                        JULIA_SESSION_REGISTRY[target_id].status = :disconnected
                        JULIA_SESSION_REGISTRY[target_id].disconnect_time = now()
                        @info "Julia session disconnected, will buffer requests and retry" id =
                            target_id
                    end

                    # Buffer this request
                    push!(
                        JULIA_SESSION_REGISTRY[target_id].pending_requests,
                        (request, http),
                    )
                    @info "Request buffered" id = target_id buffer_size =
                        length(JULIA_SESSION_REGISTRY[target_id].pending_requests)

                    # Start reconnection attempts
                    if JULIA_SESSION_REGISTRY[target_id].status == :disconnected
                        JULIA_SESSION_REGISTRY[target_id].status = :reconnecting
                        @async try_reconnect(target_id)
                    end
                end
            end
        end

        # Log error event
        Dashboard.log_event(
            target_id,
            Dashboard.ERROR,
            Dict("message" => sprint(showerror, e), "method" => get(request, "method", "")),
        )

        # Don't send response - will be handled by reconnection logic
        return nothing
    end
end

"""
    handle_request(http::HTTP.Stream) -> Nothing

Handle incoming MCP requests with streaming support. Routes to appropriate backend Julia session or handles proxy commands.
"""
function handle_request(http::HTTP.Stream)
    req = http.message

    try
        # Read the full request body FIRST (required by HTTP.jl before writing response)
        body = String(read(http))

        # Handle CORS preflight requests
        if req.method == "OPTIONS"
            send_empty_response(http; status = 204)
            return nothing
        end

        # Log incoming requests at debug level
        @debug "Incoming request" method = req.method target = req.target content_length =
            length(body)

        # Log all incoming requests to database for complete session reconstruction
        # Parse request to extract session IDs and HTTP metadata
        request_parsed = nothing
        request_id = nothing
        request_method = nothing
        mcp_session_id = nothing  # MCP client session ID
        julia_session_id = nothing  # Target Julia session ID

        # Extract HTTP metadata
        remote_addr = string(get(req.context, :client_host, ""))
        user_agent_raw = HTTP.header(req, "User-Agent")
        user_agent = isempty(user_agent_raw) ? nothing : String(user_agent_raw)
        content_type_raw = HTTP.header(req, "Content-Type")
        content_type = isempty(content_type_raw) ? nothing : String(content_type_raw)
        content_encoding_raw = HTTP.header(req, "Content-Encoding")
        content_encoding =
            isempty(content_encoding_raw) ? nothing : String(content_encoding_raw)
        http_headers = JSON.json(Dict(req.headers))

        try
            # Extract MCP session ID from standard header
            mcp_session_header = HTTP.header(req, "Mcp-Session-Id")
            if !isempty(mcp_session_header)
                mcp_session_id = String(mcp_session_header)
            end

            # Extract Julia target session ID from custom header
            target_header = HTTP.header(req, "X-MCPRepl-Target")
            if !isempty(target_header)
                julia_session_id = String(target_header)
            end

            if !isempty(body) && req.method == "POST"
                request_parsed = JSON.parse(body)
                request_id = get(request_parsed, "id", nothing)
                request_method = get(request_parsed, "method", nothing)
            end

            # Log the inbound request with full HTTP details
            log_db_interaction(
                "inbound",
                "request",
                body;
                mcp_session_id = mcp_session_id,
                julia_session_id = julia_session_id,
                request_id = request_id,
                method = request_method,
                http_method = req.method,
                http_path = req.target,
                http_headers = http_headers,
                remote_addr = remote_addr,
                user_agent = user_agent,
                content_type = content_type,
                content_encoding = content_encoding,
            )
        catch e
            @debug "Failed to parse request for logging" exception = e
        end

        # Handle dashboard HTTP routes
        uri = HTTP.URI(req.target)
        path = uri.path

        # Try dashboard API routes first (handles /dashboard redirect and all /dashboard/api/* endpoints)
        dashboard_result = handle_dashboard_route(http, req, body, path)
        if dashboard_result === nothing
            # Dashboard route was handled, response already sent
            return nothing
        end
        # dashboard_result == false means route not recognized, continue with static files

        # Dashboard HTML page and static assets (React build or Vite dev server)
        if (path == "/dashboard/" || startswith(path, "/dashboard/")) &&
           !startswith(path, "/dashboard/api/")
            # Try to proxy to Vite dev server first (for HMR during development)
            vite_port = 3001
            try
                # Quick check if Vite dev server is running
                test_conn = Sockets.connect("localhost", vite_port)
                close(test_conn)

                # Vite is running - proxy the request to it
                # Keep the full path including /dashboard since Vite is configured with base: '/dashboard/'
                vite_url = "http://localhost:$(vite_port)$(path)"
                vite_response = HTTP.get(vite_url, status_exception = false)

                HTTP.setstatus(http, vite_response.status)
                for (name, value) in vite_response.headers
                    # Skip transfer-encoding headers that HTTP.jl handles
                    if lowercase(name) ∉ ["transfer-encoding", "connection"]
                        HTTP.setheader(http, name => value)
                    end
                end
                HTTP.startwrite(http)
                write(http, vite_response.body)
                return nothing
            catch e
                # Vite not running - fall back to serving built static files
            end

            # Vite not running or failed - serve built static files
            asset_path = replace(path, r"^/dashboard/" => "")
            response = Dashboard.serve_static_file(asset_path)
            HTTP.setstatus(http, response.status)
            for (name, value) in response.headers
                HTTP.setheader(http, name => value)
            end
            HTTP.startwrite(http)
            write(http, response.body)
            return nothing
        end

        # All dashboard routes handled above - continue with MCP JSON-RPC protocol

        if isempty(body)
            # Handle OPTIONS requests (CORS preflight for streamable-http)
            if req.method == "OPTIONS"
                send_empty_response(
                    http,
                    200,
                    [
                        "Access-Control-Allow-Origin" => "*",
                        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
                        "Access-Control-Allow-Headers" => "Content-Type, Authorization",
                        "Access-Control-Max-Age" => "86400",
                        "Content-Length" => "0",
                    ],
                )
                return nothing
            end

            # Handle DELETE requests - session cleanup
            if req.method == "DELETE"
                # VS Code sends DELETE to clean up sessions before reconnecting
                @debug "Handling DELETE request" target = req.target
                response = JSON.json(Dict("status" => "ok"))
                send_json_response(
                    http,
                    response,
                    200,
                    "application/json",
                    ["Content-Length" => string(length(response))],
                )
                return nothing
            end

            # Handle GET requests - SSE not supported
            # Per MCP spec 2.2: "The server MUST either return Content-Type: text/event-stream
            # in response to this HTTP GET, or else return HTTP 405 Method Not Allowed"
            if req.method == "GET"
                # Return a valid JSON-RPC error message
                error_body = JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "error" => Dict(
                            "code" => -32601,
                            "message" => "SSE transport not supported. Use POST for requests.",
                        ),
                        "id" => nothing,
                    ),
                )
                HTTP.setheader(http, "Content-Length" => string(length(error_body)))
                HTTP.startwrite(http)
                write(http, error_body)
                return nothing
            end
            # Empty POST body - invalid request
            send_jsonrpc_error(
                http,
                nothing,
                -32700,
                "Parse error: empty request body";
                status = 400,
            )
            return nothing
        end

        # Parse JSON-RPC request
        request = try
            JSON.parse(body)
        catch e
            @error "Failed to parse JSON request" body = body exception = e
            send_jsonrpc_error(http, nothing, -32700, "Parse error: invalid JSON")
            return nothing
        end

        # Log all incoming requests with full details
        method = get(request, "method", "")
        request_id = get(request, "id", nothing)
        params = get(request, "params", nothing)
        @debug "📨 MCP Request" method = method id = request_id has_params =
            !isnothing(params)

        # Extract session ID for logging
        session_id_header = HTTP.header(req, "Mcp-Session-Id")
        log_session_id = !isempty(session_id_header) ? String(session_id_header) : "proxy"

        # Log request to database
        log_db_event(
            "request.received",
            Dict(
                "method" => method,
                "request_id" => request_id,
                "has_params" => !isnothing(params),
                "path" => req.target,
            );
            mcp_session_id = log_session_id,
        )

        # Handle notifications (methods that start with "notifications/")
        if startswith(method, "notifications/")
            @debug "✉️  Received notification" method = method params = params
            # Notifications don't require a response, just return 200
            send_empty_response(http)
            return nothing
        end

        if method == "proxy/status"
            sessions = list_julia_sessions()
            send_jsonrpc_result(
                http,
                get(request, "id", nothing),
                Dict(
                    "status" => "running",
                    "pid" => getpid(),
                    "port" => SERVER_PORT[],
                    "connected_sessions" => length(sessions),
                    "sessions" => [
                        Dict(
                            "uuid" => s.uuid,
                            "name" => s.name,
                            "port" => s.port,
                            "status" => string(s.status),
                            "pid" => s.pid,
                            "last_error" => s.last_error,
                        ) for s in sessions
                    ],
                    "uptime" => time(),
                ),
            )
            return nothing
        elseif method == "proxy/register"
            # Register a new julia session
            params = get(request, "params", Dict())
            uuid = get(params, "uuid", nothing)
            name = get(params, "name", nothing)
            port = get(params, "port", nothing)
            pid = get(params, "pid", nothing)
            metadata_raw = get(params, "metadata", Dict())

            # Convert JSON.Object to Dict if needed
            metadata =
                metadata_raw isa Dict ? metadata_raw :
                Dict(String(k) => v for (k, v) in pairs(metadata_raw))

            if uuid === nothing || name === nothing || port === nothing
                send_jsonrpc_error(
                    http,
                    get(request, "id", nothing),
                    -32602,
                    "Invalid params: 'uuid', 'name', and 'port' are required";
                    status = 400,
                )
                return nothing
            end

            # Check if a session with this UUID already exists
            existing_session = lock(JULIA_SESSION_REGISTRY_LOCK) do
                get(JULIA_SESSION_REGISTRY, uuid, nothing)
            end

            if existing_session !== nothing
                # Session already exists - check if it's the same process or a duplicate
                if existing_session.pid == pid
                    @warn "Re-registration from same process - updating" uuid = uuid name =
                        name port = port pid = pid
                    # Allow re-registration from same PID (process restart case)
                elseif existing_session.pid !== nothing &&
                       !process_running(existing_session.pid)
                    @warn "Cleaning up stale registration - process no longer running" uuid =
                        uuid stale_pid = existing_session.pid new_pid = pid
                    # Process is dead, allow re-registration by removing stale entry
                    lock(JULIA_SESSION_REGISTRY_LOCK) do
                        delete!(JULIA_SESSION_REGISTRY, uuid)
                    end
                else
                    @error "Duplicate registration attempted" uuid = uuid existing_pid =
                        existing_session.pid new_pid = pid existing_port =
                        existing_session.port new_port = port
                    send_jsonrpc_error(
                        http,
                        get(request, "id", nothing),
                        -32000,
                        "Session UUID '$uuid' is already registered by another process (PID $(existing_session.pid) on port $(existing_session.port)). This should not happen - UUIDs are unique per session.";
                        status = 409,
                        data = Dict(
                            "existing_pid" => existing_session.pid,
                            "existing_port" => existing_session.port,
                            "requested_pid" => pid,
                            "requested_port" => port,
                        ),
                    )
                    return nothing
                end
            end

            success, error_msg =
                register_julia_session(uuid, name, port; pid = pid, metadata = metadata)

            if !success
                send_jsonrpc_error(
                    http,
                    get(request, "id", nothing),
                    -32602,
                    "Registration failed: $error_msg";
                    status = 400,
                )
                return nothing
            end

            send_jsonrpc_result(
                http,
                get(request, "id", nothing),
                Dict("status" => "registered", "uuid" => uuid, "name" => name),
            )
            return nothing
        elseif method == "proxy/unregister"
            # Unregister a Julia session
            params = get(request, "params", Dict())
            uuid = get(params, "uuid", nothing)

            if uuid === nothing
                send_jsonrpc_error(
                    http,
                    get(request, "id", nothing),
                    -32602,
                    "Invalid params: 'uuid' is required";
                    status = 400,
                )
                return nothing
            end

            unregister_julia_session(uuid)

            send_jsonrpc_result(
                http,
                get(request, "id", nothing),
                Dict("status" => "unregistered", "uuid" => uuid),
            )
            return nothing
        elseif method == "proxy/heartbeat"
            # Julia session sends heartbeat to indicate it's alive
            params = get(request, "params", Dict())
            uuid = get(params, "uuid", nothing)

            if uuid === nothing
                send_jsonrpc_error(
                    http,
                    get(request, "id", nothing),
                    -32602,
                    "Invalid params: 'uuid' is required";
                    status = 400,
                )
                return nothing
            end

            # Update heartbeat and recover from disconnected/stopped state
            lock(JULIA_SESSION_REGISTRY_LOCK) do
                if haskey(JULIA_SESSION_REGISTRY, uuid)
                    existing_session = JULIA_SESSION_REGISTRY[uuid]
                    heartbeat_pid = get(params, "pid", nothing)

                    # Check if this heartbeat is from the registered process
                    if heartbeat_pid !== nothing && existing_session.pid != heartbeat_pid
                        @error "Duplicate heartbeat detected - different PID for same session UUID" uuid =
                            uuid registered_pid = existing_session.pid heartbeat_pid =
                            heartbeat_pid
                        # Reject this heartbeat - don't update the legitimate session
                        # The duplicate process will not be registered
                        return nothing
                    end

                    JULIA_SESSION_REGISTRY[uuid].last_heartbeat = now()
                    JULIA_SESSION_REGISTRY[uuid].missed_heartbeats = 0  # Reset counter on successful heartbeat
                    # Automatically recover from disconnected or stopped state on heartbeat
                    if JULIA_SESSION_REGISTRY[uuid].status in
                       (:stopped, :disconnected, :reconnecting)
                        old_status = JULIA_SESSION_REGISTRY[uuid].status
                        JULIA_SESSION_REGISTRY[uuid].status = :ready
                        JULIA_SESSION_REGISTRY[uuid].last_error = nothing
                        JULIA_SESSION_REGISTRY[uuid].disconnect_time = nothing
                        @info "Julia session recovered via heartbeat" uuid = uuid old_status =
                            old_status
                    end

                    # Log heartbeat event (don't spam - could be rate limited in Dashboard module)
                    Dashboard.log_event(uuid, Dashboard.HEARTBEAT, Dict("status" => "ok"))
                else
                    # Session not in registry - proxy may have restarted
                    # Try to re-register by extracting info from heartbeat params
                    name = get(params, "name", nothing)
                    port = get(params, "port", nothing)
                    pid = get(params, "pid", nothing)
                    metadata_raw = get(params, "metadata", Dict())

                    if name !== nothing && port !== nothing && pid !== nothing
                        @info "Re-registering session from heartbeat (proxy restart detected)" uuid =
                            uuid name = name port = port pid = pid
                        metadata =
                            metadata_raw isa Dict ? metadata_raw :
                            Dict(String(k) => v for (k, v) in pairs(metadata_raw))

                        # Register the session
                        JULIA_SESSION_REGISTRY[uuid] = JuliaSession(
                            uuid,
                            name,
                            port,
                            pid,
                            :ready,
                            now(),  # created_at
                            now(),  # last_heartbeat
                            metadata,
                            nothing,
                            0,
                            Tuple{Dict,HTTP.Stream}[],
                            nothing,
                        )

                        # Log registration event
                        Dashboard.log_event(
                            uuid,
                            Dashboard.AGENT_START,
                            Dict(
                                "port" => port,
                                "pid" => pid,
                                "name" => name,
                                "metadata" => metadata,
                                "reason" => "reregistered_from_heartbeat",
                            ),
                        )
                    else
                        @warn "Heartbeat from unknown session without name/port/pid info - cannot re-register" uuid =
                            uuid has_name = (name !== nothing) has_port = (port !== nothing) has_pid =
                            (pid !== nothing)
                    end
                end
            end

            send_jsonrpc_result(http, get(request, "id", nothing), Dict("status" => "ok"))
            return nothing
        elseif method == "initialize"
            # Handle MCP initialize request according to spec
            # Check for X-MCPRepl-Target header to determine routing
            header_value = HTTP.header(req, "X-MCPRepl-Target")
            target_julia_session_id = isempty(header_value) ? nothing : String(header_value)

            # Get initialization parameters
            params = get(request, "params", Dict())
            client_info = get(params, "clientInfo", Dict())
            client_name = get(client_info, "name", "unknown")

            @info "MCP initialize request" target_julia_session_id = target_julia_session_id client_name =
                client_name

            # X-MCPRepl-Target header is optional
            # If specified, MCP session will route to that Julia session
            # If not specified, session can use proxy tools to list/select/start julia_sessions
            # Session is always created as per MCP spec

            # Create MCP session with optional target Julia session mapping
            session = create_mcp_session(target_julia_session_id)

            # Initialize the session using the Session module for proper capability negotiation
            # Convert JSON.Object to Dict if necessary
            params_dict =
                params isa Dict ? params : Dict(String(k) => v for (k, v) in pairs(params))
            result = initialize_session!(session, params_dict)

            # Log session initialization
            log_db_event(
                "session.initialized",
                Dict(
                    "client_name" => client_name,
                    "target_julia_session_id" => target_julia_session_id,
                    "capabilities" => get(params_dict, "capabilities", Dict()),
                );
                mcp_session_id = session.id,
            )

            # Register client connection for notifications
            notification_channel = register_client_connection(session.id)

            # Respond with session ID header as per MCP spec
            # The Mcp-Session-Id header tells the client to include this ID on all subsequent requests
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.setheader(http, "Mcp-Session-Id" => session.id)
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "result" => result,
                    ),
                ),
            )
            return nothing
        elseif method == "logging/setLevel"
            # Handle MCP logging/setLevel request
            params = get(request, "params", Dict())
            level = get(params, "level", nothing)

            # Validate log level according to RFC 5424
            valid_levels = [
                "debug",
                "info",
                "notice",
                "warning",
                "error",
                "critical",
                "alert",
                "emergency",
            ]

            if level === nothing || !(level in valid_levels)
                send_jsonrpc_error(
                    http,
                    get(request, "id", nothing),
                    -32602,
                    "Invalid params: level must be one of $(join(valid_levels, ", "))",
                )
                return nothing
            end

            # Map MCP log levels to Julia Logging levels
            level_map = Dict(
                "debug" => Logging.Debug,
                "info" => Logging.Info,
                "notice" => Logging.Info,
                "warning" => Logging.Warn,
                "error" => Logging.Error,
                "critical" => Logging.Error,
                "alert" => Logging.Error,
                "emergency" => Logging.Error,
            )

            julia_level = level_map[level]

            # Set the global log level
            try
                global_logger(ConsoleLogger(stderr, julia_level))
                @info "Log level set" level = level julia_level = julia_level
            catch e
                send_jsonrpc_error(
                    http,
                    get(request, "id", nothing),
                    -32603,
                    "Internal error: $(string(e))",
                )
                return nothing
            end

            # Success response (empty result as per spec)
            send_jsonrpc_result(http, get(request, "id", nothing), Dict())
            return nothing
        elseif method == "tools/list"
            # Get proxy tools (always available)
            proxy_tools = get_proxy_tool_schemas()

            # Check if this request is from an MCP session with a specific target Julia session
            session_id_header = HTTP.header(req, "Mcp-Session-Id")
            target_julia_session_id = nothing

            if !isempty(session_id_header)
                session_id = String(session_id_header)
                session = get_mcp_session(session_id)
                if session !== nothing
                    update_activity!(session)
                    target_julia_session_id = session.target_julia_session_id
                    @debug "tools/list for session" session_id = session_id target_julia_session_id =
                        target_julia_session_id
                end
            end

            # If no session or no target Julia session, return only proxy tools
            if target_julia_session_id === nothing
                sessions = list_julia_sessions()
                @debug "tools/list - no target session" num_sessions = length(sessions) returning = "proxy tools only"

                send_jsonrpc_result(
                    http,
                    get(request, "id", nothing),
                    Dict("tools" => proxy_tools),
                )
                return nothing
            end

            # Fetch tools from the target Julia session and combine with proxy tools
            session = get_julia_session(target_julia_session_id)
            all_tools = copy(proxy_tools)

            if session !== nothing && session.status == :ready
                try
                    request_dict =
                        request isa Dict ? request :
                        Dict(String(k) => v for (k, v) in pairs(request))

                    backend_url = "http://127.0.0.1:$(session.port)/"
                    body_str = JSON.json(request_dict)
                    backend_response = HTTP.request(
                        "POST",
                        backend_url,
                        ["Content-Type" => "application/json"],
                        body_str;
                        readtimeout = 5,
                        connect_timeout = 2,
                        status_exception = false,
                    )

                    if backend_response.status == 200
                        backend_data = JSON.parse(String(backend_response.body))
                        if haskey(backend_data, "result") &&
                           haskey(backend_data["result"], "tools")
                            backend_tools = backend_data["result"]["tools"]
                            append!(all_tools, backend_tools)
                            @debug "tools/list - combined tools" target_julia_session_id =
                                target_julia_session_id proxy_tools = length(proxy_tools) backend_tools =
                                length(backend_tools) total = length(all_tools)
                        end
                    end
                catch e
                    @warn "Failed to fetch tools from target Julia session, returning proxy tools only" julia_session_id =
                        target_julia_session_id exception = e
                end
            else
                @debug "Target Julia session not ready, returning proxy tools only" target_julia_session_id =
                    target_julia_session_id status =
                    session !== nothing ? session.status : :not_found
            end

            # Return combined tools from proxy + target Julia session
            send_jsonrpc_result(
                http,
                get(request, "id", nothing),
                Dict("tools" => all_tools),
            )
            return nothing
        elseif method == "prompts/list"
            # Return empty prompts list (proxy doesn't provide prompts)
            send_jsonrpc_result(http, get(request, "id", nothing), Dict("prompts" => []))
            return nothing
        elseif method == "resources/list"
            # Return empty resources list (proxy doesn't provide resources)
            send_jsonrpc_result(http, get(request, "id", nothing), Dict("resources" => []))
            return nothing
        elseif method == "tools/call"
            # Handle proxy-level tools (always available)
            params = get(request, "params", Dict())
            tool_name = get(params, "name", "")
            julia_sessions = list_julia_sessions()

            # Log tool call start
            start_time = time()
            log_db_event(
                "tool.call.start",
                Dict(
                    "tool_name" => tool_name,
                    "is_proxy_tool" => haskey(PROXY_TOOLS, tool_name),
                    "arguments" => get(params, "arguments", Dict()),
                );
                mcp_session_id = log_session_id,
            )

            # Check if this is a proxy tool
            if haskey(PROXY_TOOLS, tool_name)
                tool = PROXY_TOOLS[tool_name]
                args = get(params, "arguments", Dict())

                # Call tool handler with appropriate context
                result_text = if tool_name == "help"
                    tool.handler(args)
                elseif tool_name in ["proxy_status", "list_julia_sessions"]
                    tool.handler(args, julia_sessions)
                elseif tool_name == "dashboard_url"
                    tool.handler(args)
                elseif tool_name == "start_julia_session"
                    # Special handling - continue to existing implementation below
                    nothing
                else
                    tool.handler(args)
                end

                # If start_julia_session, continue to existing code
                if tool_name == "start_julia_session" && result_text === nothing
                    # Fall through to existing implementation
                elseif result_text !== nothing
                    # Log successful tool completion
                    duration_ms = (time() - start_time) * 1000
                    log_db_event(
                        "tool.call.complete",
                        Dict(
                            "tool_name" => tool_name,
                            "success" => true,
                            "result_length" => length(result_text),
                        );
                        mcp_session_id = log_session_id,
                        duration_ms = duration_ms,
                    )
                    # Return result for other tools
                    send_mcp_tool_result(http, get(request, "id", nothing), result_text)
                    return nothing
                end
            end

            # Handle kill_stale_sessions with special logic
            if tool_name == "kill_stale_sessions"
                args = get(params, "arguments", Dict())
                dry_run = get(args, "dry_run", true)
                force = get(args, "force", false)
                proxy_port_filter = get(args, "proxy_port", nothing)

                result_text = ""
                try
                    if Sys.iswindows()
                        result_text = "❌ kill_stale_sessions is not yet supported on Windows"
                    else
                        # Fast approach: only check disconnected sessions from registry
                        # Avoid any process scanning which is slow
                        stale_processes = []

                        lock(JULIA_SESSION_REGISTRY_LOCK) do
                            for (session_name, conn) in JULIA_SESSION_REGISTRY
                                pid = conn.pid

                                # Check proxy port filter if specified
                                if proxy_port_filter !== nothing &&
                                   string(conn.port) != string(proxy_port_filter)
                                    continue
                                end

                                # Only flag disconnected sessions as stale
                                if conn.status == :disconnected
                                    is_stale = true
                                    if force || is_stale
                                        push!(
                                            stale_processes,
                                            (pid, session_name, is_stale),
                                        )
                                    end
                                elseif force
                                    # Force mode - include all active sessions too
                                    is_stale = false
                                    push!(stale_processes, (pid, session_name, is_stale))
                                end
                            end
                        end

                        if isempty(stale_processes)
                            result_text = "✅ No stale MCPRepl sessions found"
                        else
                            result_text = "Found $(length(stale_processes)) MCPRepl session(s):\n\n"
                            for (pid, session_name, is_stale) in stale_processes
                                status =
                                    is_stale ? "❌ STALE (not registered)" :
                                    "✅ Active (registered)"
                                result_text *= "  PID $pid: $session_name - $status\n"
                            end

                            if dry_run
                                result_text *= "\n🔍 DRY RUN MODE - No processes killed\n"
                                result_text *= "Set dry_run=false to actually kill these processes"
                            else
                                result_text *= "\n💀 Killing processes...\n\n"
                                for (pid, session_name, is_stale) in stale_processes
                                    try
                                        run(`kill -9 $pid`)
                                        result_text *= "  ✅ Killed PID $pid ($session_name)\n"
                                        # Remove from registry if it was there
                                        lock(JULIA_SESSION_REGISTRY_LOCK) do
                                            delete!(JULIA_SESSION_REGISTRY, session_name)
                                        end
                                    catch e
                                        result_text *= "  ❌ Failed to kill PID $pid: $e\n"
                                    end
                                end
                            end
                        end
                    end
                catch e
                    result_text = "❌ Error scanning for stale sessions: $e"
                end

                send_mcp_tool_result(http, get(request, "id", nothing), result_text)
                return nothing
            end

            # Handle start_julia_session with special logic
            if tool_name == "start_julia_session"
                # Parse arguments
                args = get(params, "arguments", Dict())
                project_path = get(args, "project_path", "")

                # Expand tilde in path and strip trailing slashes
                if startswith(project_path, "~/")
                    project_path = joinpath(homedir(), project_path[3:end])
                end
                project_path = rstrip(project_path, '/')

                session_name = get(args, "session_name", basename(project_path))

                if isempty(project_path)
                    send_jsonrpc_error(
                        http,
                        get(request, "id", nothing),
                        -32602,
                        "project_path is required",
                    )
                    return nothing
                end

                # Check if Julia session already exists
                existing = findfirst(s -> s.name == session_name, julia_sessions)
                if existing !== nothing
                    send_mcp_tool_result(
                        http,
                        get(request, "id", nothing),
                        "Julia session '$session_name' is already running on port $(julia_sessions[existing].port)",
                    )
                    return nothing
                end

                # Spawn new Julia session process
                try
                    @info "Starting Julia session" project_path = project_path session_id =
                        session_name

                    # Create log file for session output
                    log_dir = joinpath(dirname(@__DIR__), "logs")
                    mkpath(log_dir)
                    log_file = joinpath(
                        log_dir,
                        "session_$(session_name)_$(round(Int, time())).log",
                    )

                    # Build Julia command - inherit security config from the project itself
                    # Pass workspace_dir=project_path so it checks for .mcprepl/security.json in the project
                    # If project has .mcprepl/agents.json with this agent name, it uses that
                    # Otherwise falls back to .mcprepl/security.json or lax mode with warning
                    # Use wait() to keep the process alive until the server is stopped
                    # Set stdout/stderr to unbuffered mode for real-time log updates

                    startup_code = """
                    Base.stderr = Base.IOContext(Base.stderr, :color => false)
                    Base.stdout = Base.IOContext(Base.stdout, :color => false)
                    using MCPRepl; MCPRepl.start!(agent_name=$(repr(session_name)), workspace_dir=$(repr(project_path))); wait()
                    """
                    julia_cmd = `julia --project=$project_path -e $startup_code`

                    # Add environment variable tag for easy identification
                    env = copy(ENV)
                    env["MCPREPL_SESSION"] = session_name
                    env["MCPREPL_PROXY_PORT"] =
                        string(get(ENV, "MCPREPL_PROXY_PORT", "3000"))

                    # Run in background, capture output to log file
                    proc = run(
                        pipeline(
                            setenv(julia_cmd, env),
                            stdout = log_file,
                            stderr = log_file,
                        ),
                        wait = false,
                    )

                    # Wait for Julia session to register (max 60 seconds to allow for precompilation)
                    # When agent_name is provided, MCPRepl registers using that name directly
                    registered = false
                    expected_id = session_name
                    for i = 1:600  # 60 seconds with 0.1s sleep
                        sleep(0.1)
                        current_sessions = list_julia_sessions()
                        # Check for the expected registration name
                        idx = findfirst(s -> s.name == expected_id, current_sessions)
                        if idx !== nothing
                            registered = true
                            new_session = current_sessions[idx]
                            send_mcp_tool_result(
                                http,
                                get(request, "id", nothing),
                                "✅ Successfully started Julia session '$(new_session.name)' on port $(new_session.port)\n\nProject: $project_path\nPID: $(new_session.pid)\nStatus: $(new_session.status)\nLog: $log_file",
                            )
                            return nothing
                        end
                    end

                    # Timeout - read log file for diagnostics
                    log_contents = ""
                    try
                        if isfile(log_file)
                            log_contents = read(log_file, String)
                            # Get last 500 characters
                            if length(log_contents) > 500
                                log_contents = "..." * log_contents[end-500:end]
                            end
                        end
                    catch
                        log_contents = "(unable to read log file)"
                    end

                    send_jsonrpc_error(
                        http,
                        get(request, "id", nothing),
                        -32603,
                        "Julia session process started but did not register within 60 seconds.\n\nLog file: $log_file\n\nRecent output:\n$log_contents",
                    )
                    return nothing
                catch e
                    @error "Failed to start Julia session" exception =
                        (e, catch_backtrace())
                    send_jsonrpc_error(
                        http,
                        get(request, "id", nothing),
                        -32603,
                        "Failed to start Julia session backend: $(sprint(showerror, e))",
                    )
                    return nothing
                end
            else
                # Tool requires backend Julia session - check if any are available
                if isempty(julia_sessions)
                    send_mcp_tool_result(
                        http,
                        get(request, "id", nothing),
                        "⚠️ Tool '$tool_name' requires a Julia session.\n\nNo Julia sessions are currently connected to the proxy.\n\nTo enable Julia tools:\n1. Start a Julia session\n2. Run: using MCPRepl; MCPRepl.start!()\n3. The session will automatically register with this proxy\n\nAvailable proxy tools: help, proxy_status, list_julia_sessions, dashboard_url, start_julia_session",
                    )
                    return nothing
                else
                    # Route to backend
                    request_dict =
                        request isa Dict ? request :
                        Dict(String(k) => v for (k, v) in pairs(request))
                    route_to_session_streaming(request_dict, req, http)
                    return nothing
                end
            end
        else
            # Unknown method - route to backend if available
            julia_sessions = list_julia_sessions()
            if isempty(julia_sessions)
                # No backends available - return a friendly message
                @debug "No backends available for method" method = method
                send_jsonrpc_result(
                    http,
                    get(request, "id", nothing),
                    nothing,  # Many MCP methods (like notifications) expect null result
                )
                return nothing
            else
                # Route to backend Julia session
                request_dict =
                    request isa Dict ? request :
                    Dict(String(k) => v for (k, v) in pairs(request))
                route_to_session_streaming(request_dict, req, http)
                return nothing
            end
        end

    catch e
        # Don't log connection reset/broken pipe errors - these are normal when clients disconnect
        if e isa Base.IOError &&
           (occursin("connection reset", e.msg) || occursin("broken pipe", e.msg))
            @debug "Client disconnected during response" exception = e
        else
            @error "Error handling request" exception = (e, catch_backtrace())
        end

        # Try to send error response if stream is still open
        try
            if isopen(http)
                send_jsonrpc_error(
                    http,
                    nothing,
                    -32603,
                    "Internal error: $(sprint(showerror, e))";
                    status = 500,
                )
            end
        catch write_err
            # Ignore errors when trying to write error response
            @debug "Failed to send error response" exception = write_err
        end
        return nothing
    end
end

"""
    start_server(port::Int=3000; background::Bool=false, status_callback=nothing) -> Union{HTTP.Server, Nothing}

Start the persistent MCP proxy server.

# Arguments
- `port::Int=3000`: Port to listen on
- `background::Bool=false`: If true, run in background process
- `status_callback`: Optional function to call with status updates (for background mode)

# Returns
- HTTP.Server if running in foreground
- nothing if started in background
"""
function start_server(port::Int = 3000; background::Bool = false, status_callback = nothing)
    if is_server_running(port)
        existing_pid = get_server_pid(port)
        if existing_pid !== nothing
            @info "Proxy server already running on port $port (PID: $existing_pid)"
            return nothing
        end
    end

    if background
        # Start server in background process
        return start_background_server(port; status_callback = status_callback)
    else
        # Start server in current process
        return start_foreground_server(port)
    end
end

"""
    start_foreground_server(port::Int=3000) -> HTTP.Server

Start the proxy server in the current process.
"""
function start_foreground_server(port::Int = 3000)
    if SERVER[] !== nothing
        @warn "Server already running in this process"
        return SERVER[]
    end

    SERVER_PORT[] = port
    write_pid_file(port)

    # Set up file logging
    log_file = setup_proxy_logging(port)
    println("Proxy log file: $log_file")

    # Initialize database (lazy initialization on server start)
    # Use XDG_CACHE_HOME for persistent storage across proxy restarts
    cache_dir = get(ENV, "XDG_CACHE_HOME") do
        if Sys.iswindows()
            joinpath(ENV["LOCALAPPDATA"], "MCPRepl")
        else
            joinpath(homedir(), ".cache", "mcprepl")
        end
    end
    mkpath(cache_dir)
    db_path = joinpath(cache_dir, "mcprepl.db")
    init_database!(db_path)

    # Start ETL scheduler for analytics
    db = Database.DB[]
    if db !== nothing
        etl_task = Database.start_etl_scheduler(db; interval_seconds = 30)
        @info "ETL scheduler started for analytics processing" interval_seconds = 30
    else
        @warn "Database not initialized, ETL scheduler not started"
    end

    # Set up dashboard to use database for event persistence
    Dashboard.set_db_callback!() do session_id, event_type, timestamp, data, duration_ms
        # Dashboard events are primarily Julia session events
        # The session_id here is the Julia session ID
        # Note: timestamp parameter is ignored since log_event! generates its own
        try
            Database.log_event!(
                event_type,
                data;
                julia_session_id = session_id,
                duration_ms = duration_ms,
            )
        catch e
            @warn "Failed to log dashboard event to database" exception = e
        end
    end
    @info "Dashboard configured to persist events to database"

    @info "Starting MCP Proxy Server" port = port pid = getpid()

    # Start Vite dev server if in development mode
    start_vite_dev_server()

    # Setup cleanup on exit
    atexit(() -> begin
        stop_vite_dev_server()
        remove_pid_file(port)
    end)

    # Start HTTP server with streaming support
    server =
        HTTP.serve!(handle_request, ip"127.0.0.1", port; verbose = false, stream = true)
    SERVER[] = server

    # Start background heartbeat monitor AFTER setting SERVER[]
    @async monitor_heartbeats()

    @info "MCP Proxy Server started successfully" port = port pid = getpid()

    return server
end

"""
    start_background_server(port::Int=3000; status_callback=nothing) -> Nothing

Start the proxy server in a detached background process.

If `status_callback` is provided, it will be called with status updates instead of
printing directly (useful when parent has its own spinner).
"""
function start_background_server(port::Int = 3000; status_callback = nothing)
    # Create a Julia script that starts the server
    script = """
    using Pkg
    Pkg.activate("$(Base.active_project())")

    using MCPRepl

    println("Starting MCP Proxy Server in background...")
    MCPRepl.Proxy.start_foreground_server($port)

    # Keep server running
    println("Press Ctrl+C to stop the server")
    try
        wait(MCPRepl.Proxy.SERVER[])
    catch e
        @warn "Server stopped" exception=e
    end
    """

    script_file = tempname() * ".jl"
    write(script_file, script)

    # Start detached Julia process
    @debug "Launching background proxy server" port = port

    if Sys.iswindows()
        # Windows: use START command
        run(`cmd /c start julia $script_file`, wait = false)
    else
        # Unix: use nohup and discard stdout/stderr (all logs go to proxy-$port.log via FileLogger)
        run(
            pipeline(`nohup julia $script_file`, stdout = devnull, stderr = devnull),
            wait = false,
        )
    end

    # Wait for server to start
    max_wait = 30  # seconds
    elapsed = 0.0
    check_interval = 0.1  # Check every 100ms

    while elapsed < max_wait
        # Update status via callback if provided, otherwise print directly
        if status_callback !== nothing
            elapsed_sec = round(Int, elapsed)
            # Color the number with coral/salmon (203 = coral pink)
            status_callback(
                "Starting MCPRepl (waiting for proxy server... \033[38;5;203m$(elapsed_sec)s\033[0m)",
            )
        end

        if is_server_running(port)
            # Success
            if status_callback !== nothing
                status_callback("Starting MCPRepl (proxy server ready)")
            end
            pid = get_server_pid(port)
            @debug "Background proxy server started" port = port pid = pid elapsed_time =
                elapsed
            return nothing
        end

        sleep(check_interval)
        elapsed += check_interval
    end

    # Server didn't start in time
    @error "Failed to start background proxy server" timeout = max_wait
    @info "Check log file for details" log_file =
        joinpath(dirname(get_pid_file_path(port)), "proxy-$port.log")

    return nothing
end

"""
    stop_server(port::Int=3000)

Stop the proxy server running on the specified port.
"""
function stop_server(port::Int = 3000)
    # Stop Vite dev server first
    stop_vite_dev_server()

    if SERVER[] !== nothing
        # Stop server in current process
        @info "Stopping proxy server"
        close(SERVER[])
        SERVER[] = nothing
        remove_pid_file(port)
    else
        # Try to stop background server by PID file
        pid = get_server_pid(port)
        if pid !== nothing
            @info "Stopping background proxy server" pid = pid
            if Sys.iswindows()
                run(`taskkill /PID $pid /F`, wait = false)
            else
                run(`kill $pid`, wait = false)
            end
            remove_pid_file(port)
        end

        # Also kill any process listening on the port (in case PID file is stale)
        try
            if !Sys.iswindows()
                # Use lsof to find and kill any process on the port
                result = read(`lsof -ti :$port`, String)
                pids = split(strip(result), '\n')
                for pid_str in pids
                    if !isempty(pid_str)
                        pid_num = parse(Int, pid_str)
                        @info "Killing process on port $port" pid = pid_num
                        run(`kill $pid_num`, wait = false)
                    end
                end
            end
        catch e
            # Port might not be in use, that's okay
            @debug "No additional processes found on port $port"
        end

        if pid === nothing && !is_server_running(port)
            @info "No proxy server found on port $port"
        end
    end
end

"""
    restart_server(port::Int=3000; background::Bool=false)

Restart the proxy server (stop existing if running, then start new).

# Arguments
- `port::Int=3000`: Port to listen on
- `background::Bool=false`: If true, run in background process

# Returns
- HTTP.Server if running in foreground
- nothing if started in background
"""
function restart_server(port::Int = 3000; background::Bool = false)
    # Stop existing server if running (won't error if not running)
    if is_server_running(port)
        @info "Stopping existing proxy server on port $port"
        stop_server(port)
        sleep(1)  # Give it time to shutdown
    end

    # Start new server
    @info "Starting proxy server on port $port"
    return start_server(port; background = background)
end

end # module Proxy
