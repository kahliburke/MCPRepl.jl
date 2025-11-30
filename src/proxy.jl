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
using DBInterface

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
include("proxy/request_buffering.jl")

# Global state (simple Refs that can be precompiled)
const SERVER = Ref{Union{HTTP.Server,Nothing}}(nothing)
const SERVER_PORT = Ref{Int}(3000)
const SERVER_PID_FILE = Ref{String}("")
const VITE_DEV_PROCESS = Ref{Union{Base.Process,Nothing}}(nothing)
const VITE_DEV_PORT = 3001

# Proxy's own MCP session ID for tool calls it makes on its own behalf
# (e.g., dashboard Quick Start, internal operations)
const PROXY_MCP_SESSION_ID = "proxy-system"

# CLIENT_CONNECTIONS initialized in __init__() (can't be precompiled)
CLIENT_CONNECTIONS = Dict{String,Channel{Dict}}()
CLIENT_CONNECTIONS_LOCK = ReentrantLock()

# Initialize global state at runtime (after precompilation)
# Note: Session data is stored in the database. Only non-serializable runtime data
# (pending HTTP streams) is kept in memory in session_registry.jl
function __init__()
    # Re-initialize pending requests buffer (defined in session_registry.jl)
    global PENDING_REQUESTS = Dict{String,Vector{Tuple{Dict,HTTP.Stream}}}()
    global PENDING_REQUESTS_LOCK = ReentrantLock()
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

            # Query all active Julia sessions from database
            julia_sessions = list_julia_sessions()

            for session in julia_sessions
                # Skip if already disconnected/reconnecting/stopped
                # Handle missing status from database
                session_status = ismissing(session.status) ? "unknown" : session.status
                if session_status != "ready"
                    continue
                end

                # Check if heartbeat is stale (>30 seconds old)
                last_heartbeat = Dates.DateTime(session.last_activity)
                time_since_heartbeat = now() - last_heartbeat
                if time_since_heartbeat > Second(30)
                    @warn "Julia session heartbeat timeout, marking as disconnected" id =
                        session.id last_heartbeat = last_heartbeat time_since =
                        time_since_heartbeat status_before = session_status

                    # Mark as disconnected in database
                    update_julia_session_status(
                        session.id,
                        "disconnected";
                        error = "Heartbeat timeout after $time_since_heartbeat",
                    )

                    # Log disconnection event
                    Dashboard.log_event(
                        session.id,
                        Dashboard.ERROR,
                        Dict("message" => "Heartbeat timeout after $time_since_heartbeat"),
                    )
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
            save_mcp_session!(session)
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

    # Check for per-request target override in params (highest priority)
    params = get(request, "params", Dict())
    target_override = get(params, "target", nothing)
    if target_override !== nothing
        target_id = String(target_override)
        @debug "Target overridden by request params" target_id = target_id
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
            # Sessions exist but no target specified
            julia_session_ids = join(["$(s.name) ($(s.id))" for s in sessions], ", ")
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

    # Get the Julia session connection by UUID
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

    # Validate session has required fields
    if ismissing(session.port) || session.port === nothing
        send_jsonrpc_error(
            http,
            get(request, "id", nothing),
            -32003,
            "Julia session $target_id has no port registered";
            status = 500,
        )
        return nothing
    end

    # Handle Julia session status
    # Handle missing status from database
    session_status = ismissing(session.status) ? "unknown" : session.status

    if session_status in ("disconnected", "reconnecting")
        # Buffer the request for replay when session reconnects
        buffer_request!(target_id, request, http)

        # Mark as reconnecting if not already
        if session_status == "disconnected"
            update_julia_session_status(target_id, "reconnecting")
            @info "Julia session disconnected, buffering requests for automatic replay on reconnection" id =
                target_id
        end

        # Start async task to send status updates while waiting for reconnection
        @async send_reconnection_updates(target_id, request, http)
        return nothing

    elseif session_status == "stopped"
        # Julia session is permanently stopped, return error
        send_jsonrpc_error(
            http,
            get(request, "id", nothing),
            -32003,
            "Julia session permanently stopped: $target_id. Restart required.";
            status = 503,
        )
        return nothing

    elseif session_status != "ready"
        send_jsonrpc_error(
            http,
            get(request, "id", nothing),
            -32003,
            "Julia session not ready: $(session_status)";
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
        request_id_raw = get(request, "id", nothing)
        request_id_val = request_id_raw === nothing ? nothing : string(request_id_raw)
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

        # Note: Error is already logged via Dashboard.log_event as ERROR event below
        # No need to duplicate as a separate event here

        # Store the error and mark as disconnected
        error_summary = length(error_msg) > 500 ? error_msg[1:500] * "..." : error_msg

        # Check current session status from database
        current_session = get_julia_session(target_id)
        if current_session !== nothing
            # Buffer this request for replay when session reconnects
            buffer_request!(target_id, request, http)

            # Mark as disconnected/reconnecting
            # Handle missing status from database
            current_status =
                ismissing(current_session.status) ? "unknown" : current_session.status
            if current_status == "ready"
                update_julia_session_status(
                    target_id,
                    "disconnected";
                    error = error_summary,
                )
                @info "Julia session disconnected, buffering requests for replay on reconnection" id =
                    target_id
            elseif current_status == "disconnected"
                update_julia_session_status(
                    target_id,
                    "reconnecting";
                    error = error_summary,
                )
                @info "Request buffered, will replay when session reconnects" id = target_id
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
                request_id_raw = get(request_parsed, "id", nothing)
                request_id = request_id_raw === nothing ? nothing : string(request_id_raw)
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
        # If no MCP client session header, use the proxy's own session ID
        session_id_header = HTTP.header(req, "Mcp-Session-Id")
        log_session_id =
            !isempty(session_id_header) ? String(session_id_header) : PROXY_MCP_SESSION_ID

        # Note: Request is already logged as an interaction via log_db_interaction earlier
        # No need to duplicate it as an event

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
                            "uuid" => s.id,
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
            existing_session = get_julia_session(uuid)

            if existing_session !== nothing
                # Session already exists - check if it's the same process or a duplicate
                # Handle missing/NULL pid values from database
                registered_pid =
                    ismissing(existing_session.pid) ? nothing : existing_session.pid
                if registered_pid == pid
                    @warn "Re-registration from same process - updating" uuid = uuid name =
                        name port = port pid = pid
                    # Allow re-registration from same PID (process restart case)
                elseif registered_pid !== nothing && !process_running(registered_pid)
                    @warn "Cleaning up stale registration - process no longer running" uuid =
                        uuid stale_pid = registered_pid new_pid = pid
                    # Process is dead, allow re-registration by marking as inactive
                    Database.update_session_status!(uuid, "replaced")
                else
                    existing_port =
                        ismissing(existing_session.port) ? nothing : existing_session.port
                    @error "Duplicate registration attempted" uuid = uuid existing_pid =
                        registered_pid new_pid = pid existing_port = existing_port new_port =
                        port
                    send_jsonrpc_error(
                        http,
                        get(request, "id", nothing),
                        -32000,
                        "Session UUID '$uuid' is already registered by another process (PID $registered_pid on port $existing_port). This should not happen - UUIDs are unique per session.";
                        status = 409,
                        data = Dict(
                            "existing_pid" => registered_pid,
                            "existing_port" => existing_port,
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
            existing_session = get_julia_session(uuid)

            if existing_session !== nothing
                heartbeat_pid = get(params, "pid", nothing)

                # Check if this heartbeat is from the registered process
                # Handle missing/NULL pid values from database
                registered_pid =
                    ismissing(existing_session.pid) ? nothing : existing_session.pid
                if heartbeat_pid !== nothing &&
                   registered_pid !== nothing &&
                   registered_pid != heartbeat_pid
                    @error "Duplicate heartbeat detected - different PID for same session UUID" uuid =
                        uuid registered_pid = registered_pid heartbeat_pid = heartbeat_pid
                    # Reject this heartbeat - don't update the legitimate session
                    send_jsonrpc_error(
                        http,
                        get(request, "id", nothing),
                        -32000,
                        "Duplicate session detected with different PID";
                        status = 409,
                    )
                    return nothing
                end

                # Update heartbeat timestamp
                Database.update_session_status!(uuid, "ready")

                # Automatically recover from disconnected or stopped state on heartbeat
                # Handle missing status from database
                session_status =
                    ismissing(existing_session.status) ? "unknown" : existing_session.status
                if session_status in ("stopped", "disconnected", "reconnecting")
                    update_julia_session_status(uuid, "ready")
                    @info "Julia session recovered via heartbeat" uuid = uuid old_status =
                        session_status
                end

                # Log heartbeat event (don't spam - could be rate limited in Dashboard module)
                Dashboard.log_event(uuid, Dashboard.HEARTBEAT, Dict("status" => "ok"))
            else
                # Session not in database - proxy may have restarted
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

                    # Register the session using the standard registration function
                    register_julia_session(uuid, name, port; pid = pid, metadata = metadata)

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

            send_jsonrpc_result(http, get(request, "id", nothing), Dict("status" => "ok"))
            return nothing
        elseif method == "initialize"
            # Handle MCP initialize request according to spec
            # Check for X-MCPRepl-Target header to determine routing
            header_value = HTTP.header(req, "X-MCPRepl-Target")
            target_julia_session_id = isempty(header_value) ? nothing : String(header_value)

            # Auto-detect: if no target specified but exactly one Julia session exists, use it
            auto_targeted = false
            if target_julia_session_id === nothing
                sessions = list_julia_sessions()
                if length(sessions) == 1
                    target_julia_session_id = sessions[1].id
                    auto_targeted = true
                    @info "Auto-targeting single Julia session" target =
                        target_julia_session_id name = sessions[1].name
                end
            end

            # Get initialization parameters
            params = get(request, "params", Dict())
            client_info = get(params, "clientInfo", Dict())
            client_name = get(client_info, "name", "unknown")

            @info "MCP initialize request" target_julia_session_id = target_julia_session_id client_name =
                client_name

            # Check if client is providing an existing session ID (e.g., after proxy restart)
            # This allows clients to reconnect with their previous session and maintain Julia backend routing
            existing_session_id = HTTP.header(req, "Mcp-Session-Id")
            session = nothing

            if !isempty(existing_session_id)
                # Try to restore session from database
                session = get_mcp_session(existing_session_id)

                if session !== nothing
                    @info "Restoring MCP session from database" session_id =
                        existing_session_id target = session.target_julia_session_id state =
                        session.state
                    # Use the restored target (may override auto-detection from header)
                    if session.target_julia_session_id !== nothing
                        target_julia_session_id = session.target_julia_session_id
                    end
                end
            end

            # X-MCPRepl-Target header is optional
            # If specified, MCP session will route to that Julia session
            # If not specified and multiple sessions exist, session can use proxy tools to list/select
            # If exactly one Julia session exists, auto-target it for convenience
            # Session is always created as per MCP spec

            # Create MCP session if not restored from database
            if session === nothing
                session = create_mcp_session(target_julia_session_id)
                @info "Created new MCP session" session_id = session.id
            end

            # If we have a target (explicit or auto-detected), notify client about available tools
            if target_julia_session_id !== nothing
                # Delay notification slightly to ensure client connection is registered
                @async begin
                    sleep(0.1)  # Give time for connection to be established
                    notify_client_tools_changed(session.id)
                end
            end

            # Initialize the session using the Session module for proper capability negotiation
            # Convert JSON.Object to Dict if necessary
            params_dict =
                params isa Dict ? params : Dict(String(k) => v for (k, v) in pairs(params))

            # Check if session is already initialized (restored from database)
            if session.state == Session.INITIALIZED
                @info "Session already initialized, reusing existing initialization" session_id =
                    session.id
                # Return the existing initialization result
                result = Dict{String,Any}(
                    "protocolVersion" => session.protocol_version,
                    "capabilities" => session.server_capabilities,
                    "serverInfo" => Dict{String,Any}(
                        "name" => "MCPRepl",
                        "version" => Session.get_version(),
                    ),
                )
            else
                # Initialize the session
                result = initialize_session!(session, params_dict)
                # Save the updated session state to database
                save_mcp_session!(session)
            end

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
                    save_mcp_session!(session)
                    target_julia_session_id = session.target_julia_session_id
                    @debug "tools/list for session" session_id = session_id target_julia_session_id =
                        target_julia_session_id
                end
            end

            # Check for per-request target override in params (highest priority)
            params = get(request, "params", Dict())
            target_override = get(params, "target", nothing)
            if target_override !== nothing
                target_julia_session_id = String(target_override)
                @debug "tools/list target overridden by request params" target_julia_session_id =
                    target_julia_session_id
            end

            # If no session or no target Julia session, check for auto-targeting
            if target_julia_session_id === nothing
                sessions = list_julia_sessions()

                # Auto-target if exactly one Julia session exists
                if length(sessions) == 1
                    target_julia_session_id = sessions[1].id
                    @debug "tools/list - auto-targeting single session" target =
                        target_julia_session_id name = sessions[1].name

                    # Update the MCP session's target if we have a session ID
                    if !isempty(session_id_header)
                        session_id = String(session_id_header)
                        session = get_mcp_session(session_id)
                        if session !== nothing &&
                           session.target_julia_session_id === nothing
                            # Associate this MCP session with the Julia session
                            session.target_julia_session_id = target_julia_session_id
                            save_mcp_session!(session)
                            @info "Associated MCP session with Julia session" mcp_session =
                                session_id julia_session = target_julia_session_id

                            # Notify client that tools have changed
                            @async notify_client_tools_changed(session_id)
                        end
                    end
                else
                    @debug "tools/list - no target session" num_sessions = length(sessions) returning = "proxy tools only"

                    send_jsonrpc_result(
                        http,
                        get(request, "id", nothing),
                        Dict("tools" => proxy_tools),
                    )
                    return nothing
                end
            end

            # Fetch tools from the target Julia session and combine with proxy tools
            session = get_julia_session(target_julia_session_id)
            all_tools = copy(proxy_tools)

            if session !== nothing &&
               session.status == "ready" &&
               !ismissing(session.port) &&
               session.port !== nothing
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

            # Track timing for tool calls
            start_time = time()

            # Log proxy tool calls as events (these are meaningful user actions)
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
                elseif tool_name in ["start_julia_session", "connect_to_session"]
                    # Special handling - continue to existing implementation below
                    nothing
                else
                    tool.handler(args)
                end

                # If start_julia_session or connect_to_session, continue to existing code
                if tool_name in ["start_julia_session", "connect_to_session"] &&
                   result_text === nothing
                    # Fall through to existing implementation
                elseif result_text !== nothing
                    # Log successful proxy tool completion
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

            # Handle connect_to_session - associates MCP session with a Julia session
            if tool_name == "connect_to_session"
                args = get(params, "arguments", Dict())
                session_id_arg = get(args, "session_id", "")

                # Get the MCP session ID from the header
                session_id_header = HTTP.header(req, "Mcp-Session-Id")
                if isempty(session_id_header)
                    send_mcp_tool_result(
                        http,
                        get(request, "id", nothing),
                        "❌ Error: No MCP session ID found. This tool must be called from an MCP client.",
                    )
                    return nothing
                end

                mcp_session_id = String(session_id_header)
                mcp_session = get_mcp_session(mcp_session_id)

                # If MCP session doesn't exist (e.g., after proxy restart), create it
                if mcp_session === nothing
                    @info "MCP session not found, creating new session on the fly" session_id =
                        mcp_session_id
                    # Create session with the client's session ID
                    mcp_session = create_mcp_session(nothing; session_id = mcp_session_id)
                    @info "Created MCP session on demand" session_id = mcp_session_id
                end

                # Find the Julia session by UUID
                julia_session = get_julia_session(session_id_arg)

                if julia_session === nothing
                    available = list_julia_sessions()
                    sessions_list =
                        join(["  - $(s.name) ($(s.id))" for s in available], "\n")
                    send_mcp_tool_result(
                        http,
                        get(request, "id", nothing),
                        "❌ Error: Julia session not found: $session_id_arg\n\nAvailable sessions:\n$sessions_list",
                    )
                    return nothing
                end

                # Persist the association to database so it survives proxy restarts
                try
                    Database.update_mcp_session_target!(mcp_session_id, julia_session.id)
                catch e
                    @warn "Failed to persist MCP session target to database" exception = e
                end

                @info "Manually connected MCP session to Julia session" mcp_session =
                    mcp_session_id julia_session = julia_session.id julia_name =
                    julia_session.name

                # Notify the client that tools have changed
                notify_client_tools_changed(mcp_session_id)

                port_str =
                    ismissing(julia_session.port) ? "N/A" : string(julia_session.port)
                result_text = """
                ✅ Successfully connected to Julia session: $(julia_session.name)
                   UUID: $(julia_session.id)
                   Port: $port_str

                Your MCP client now has access to this session's tools. Refreshing tools list...
                """

                send_mcp_tool_result(http, get(request, "id", nothing), result_text)
                return nothing
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
                        # Fast approach: only check disconnected sessions from database
                        # Avoid any process scanning which is slow
                        stale_processes = []

                        # Query all Julia sessions from database
                        all_sessions = list_julia_sessions()
                        for session in all_sessions
                            # Handle missing/NULL values from database
                            pid = ismissing(session.pid) ? nothing : session.pid
                            port = ismissing(session.port) ? nothing : session.port
                            session_status =
                                ismissing(session.status) ? "unknown" : session.status

                            # Skip if pid is missing (can't kill it)
                            if pid === nothing
                                continue
                            end

                            # Check proxy port filter if specified
                            if proxy_port_filter !== nothing &&
                               port !== nothing &&
                               string(port) != string(proxy_port_filter)
                                continue
                            end

                            # Only flag disconnected sessions as stale
                            if session_status == "disconnected"
                                is_stale = true
                                if force || is_stale
                                    push!(stale_processes, (pid, session.name, is_stale))
                                end
                            elseif force
                                # Force mode - include all active sessions too
                                is_stale = false
                                push!(stale_processes, (pid, session.name, is_stale))
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
                                        # Mark as stopped in database
                                        # Find session ID by name and pid
                                        for s in all_sessions
                                            if s.name == session_name && s.pid == pid
                                                Database.update_session_status!(
                                                    s.id,
                                                    "stopped",
                                                )
                                                break
                                            end
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
                    # Generate UUID for this session
                    session_uuid = string(UUIDs.uuid4())

                    @info "Starting Julia session" project_path = project_path session_id =
                        session_name uuid = session_uuid

                    # Create log file for session output (using UUID for consistent identification)
                    log_dir = joinpath(dirname(@__DIR__), "logs")
                    mkpath(log_dir)
                    log_file = joinpath(log_dir, "session_$(session_uuid).log")

                    # Build Julia command - inherit security config from the project itself
                    # Pass workspace_dir=project_path so it checks for .mcprepl/security.json in the project
                    # Use wait() to keep the process alive until the server is stopped
                    # Set stdout/stderr to unbuffered mode for real-time log updates

                    startup_code = """
                    Base.stderr = Base.IOContext(Base.stderr, :color => false)
                    Base.stdout = Base.IOContext(Base.stdout, :color => false)
                    using MCPRepl; MCPRepl.start!(julia_session_name=$(repr(session_name)), workspace_dir=$(repr(project_path)), session_uuid=$(repr(session_uuid))); wait()
                    """
                    julia_cmd = `julia --project=$project_path -e $startup_code`

                    # Add environment variable tag for easy identification
                    env = copy(ENV)
                    env["MCPREPL_SESSION"] = session_name
                    env["MCPREPL_SESSION_UUID"] = session_uuid
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
                    # MCPRepl registers using the julia_session_name directly
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
                            port_str =
                                ismissing(new_session.port) ? "N/A" :
                                string(new_session.port)
                            pid_str =
                                ismissing(new_session.pid) ? "N/A" : string(new_session.pid)
                            status_str =
                                ismissing(new_session.status) ? "unknown" :
                                string(new_session.status)
                            send_mcp_tool_result(
                                http,
                                get(request, "id", nothing),
                                "✅ Successfully started Julia session '$(new_session.name)' on port $port_str\n\nProject: $project_path\nPID: $pid_str\nStatus: $status_str\nLog: $log_file",
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

    # Register the proxy's own MCP session for tool calls it makes on its own behalf
    # (e.g., dashboard Quick Start, internal operations)
    try
        Database.register_mcp_session!(
            PROXY_MCP_SESSION_ID;
            metadata = Dict("type" => "proxy-system", "created_at" => string(now())),
        )
        @info "Registered proxy system MCP session" session_id = PROXY_MCP_SESSION_ID
    catch e
        # Session may already exist from previous run
        @debug "Proxy MCP session already registered" session_id = PROXY_MCP_SESSION_ID
    end

    # Note: Client MCP sessions are restored on-demand when clients reconnect and include
    # their Mcp-Session-Id header in the initialize request. This allows clients
    # to maintain their Julia backend routing across proxy restarts.

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
    clean_proxy_data(port::Int=3000; verbose::Bool=true)

Clean all proxy logs and database files for a fresh start.

Removes:
- Proxy log files (proxy-PORT.log, proxy-PORT-info.log)
- Session log files (session_*.log)
- Database file (mcprepl.db)

# Arguments
- `port::Int=3000`: Port number (used for log file names)
- `verbose::Bool=true`: Print status messages
"""
function clean_proxy_data(port::Int = 3000; verbose::Bool = true)
    cache_dir = get(ENV, "XDG_CACHE_HOME") do
        if Sys.iswindows()
            joinpath(ENV["LOCALAPPDATA"], "MCPRepl")
        else
            joinpath(homedir(), ".cache", "mcprepl")
        end
    end

    files_removed = String[]

    # Remove proxy log files
    for log_file in ["proxy-$port.log", "proxy-$port-info.log"]
        path = joinpath(cache_dir, log_file)
        if isfile(path)
            rm(path)
            push!(files_removed, log_file)
        end
    end

    # Remove session log files
    logs_dir = joinpath(dirname(@__DIR__), "logs")
    if isdir(logs_dir)
        for file in readdir(logs_dir)
            if startswith(file, "session_") && endswith(file, ".log")
                path = joinpath(logs_dir, file)
                rm(path)
                push!(files_removed, "logs/$file")
            end
        end
    end

    # Remove database
    db_path = joinpath(cache_dir, "mcprepl.db")
    if isfile(db_path)
        rm(db_path)
        push!(files_removed, "mcprepl.db")
    end

    if verbose
        if isempty(files_removed)
            println("✨ No files to clean (already clean)")
        else
            println("🧹 Cleaned $(length(files_removed)) file(s):")
            for file in files_removed
                println("   ✓ $file")
            end
        end
    end

    return files_removed
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
