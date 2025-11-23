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

include("dashboard.jl")
using .Dashboard

include("database.jl")
using .Database

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

# Global state
const SERVER = Ref{Union{HTTP.Server,Nothing}}(nothing)
const SERVER_PORT = Ref{Int}(3000)
const SERVER_PID_FILE = Ref{String}("")
const JULIA_SESSION_REGISTRY = Dict{String,JuliaSession}()
const JULIA_SESSION_REGISTRY_LOCK = ReentrantLock()
const MCP_SESSION_REGISTRY = Dict{String,MCPSession}()  # Track MCP client sessions
const MCP_SESSION_LOCK = ReentrantLock()
const CLIENT_CONNECTIONS = Dict{String,Channel{Dict}}()  # Track active client notification channels
const CLIENT_CONNECTIONS_LOCK = ReentrantLock()
const VITE_DEV_PROCESS = Ref{Union{Base.Process,Nothing}}(nothing)
const VITE_DEV_PORT = 3001

# ============================================================================
# MCP Notification Support
# ============================================================================

"""
    notify_tools_list_changed()

Send notifications/tools/list_changed to all connected MCP clients.
This tells clients to refresh their tools list after a Julia session registers.
"""
function notify_tools_list_changed()
    @debug "Broadcasting tools/list_changed notification to all connected clients"

    notification = Dict(
        "jsonrpc" => "2.0",
        "method" => "notifications/tools/list_changed",
        "params" => Dict(),
    )

    # Send notification to all active client connections
    lock(CLIENT_CONNECTIONS_LOCK) do
        for (session_id, channel) in CLIENT_CONNECTIONS
            try
                # Non-blocking put - if channel is full, skip this client
                if isopen(channel) && length(channel.data) < 10
                    put!(channel, notification)
                    @debug "Sent notification to client" session_id = session_id
                end
            catch e
                @debug "Failed to send notification to client" session_id = session_id error =
                    e
            end
        end
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
            julia_session_ids = join([s.id for s in julia_sessions], ", ")
            send_jsonrpc_error(
                http,
                get(request, "id", nothing),
                -32001,
                "No target Julia session specified. Available ids: $julia_session_ids. Re-initialize with X-MCPRepl-Target header to specify a target.";
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

        # Redirect /dashboard to /dashboard/ (Vite expects trailing slash)
        if path == "/dashboard"
            send_empty_response(http, 301, ["Location" => "/dashboard/"])
            return nothing
        end

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
        end        # Dashboard API: Get proxy server info
        if path == "/dashboard/api/proxy-info"
            proxy_info = Dict(
                "pid" => getpid(),
                "port" => begin
                    local port = 3000
                    if SERVER[] !== nothing
                        try
                            port_match = match(r":(\d+)", string(SERVER[].listener))
                            if port_match !== nothing
                                port = parse(Int, port_match[1])
                            end
                        catch
                            port = 3000
                        end
                    end
                    port
                end,
                "version" => "v0.4.0",
            )
            send_json_response(http, proxy_info)
            return nothing
        end

        # Dashboard API: Get all sessions
        if path == "/dashboard/api/sessions"
            start_time = time()
            sessions = lock(JULIA_SESSION_REGISTRY_LOCK) do
                result = Dict{String,Any}()
                for (id, conn) in JULIA_SESSION_REGISTRY
                    result[id] = Dict(
                        "id" => id,
                        "port" => conn.port,
                        "pid" => conn.pid,
                        "status" => string(conn.status),
                        "last_heartbeat" => Dates.format(
                            conn.last_heartbeat,
                            "yyyy-mm-dd HH:MM:SS",
                        ),
                    )
                end
                result
            end
            elapsed = (time() - start_time) * 1000
            if elapsed > 100
                @warn "Slow sessions API call" elapsed_ms = elapsed
            end
            send_json_response(http, sessions)
            return nothing
        end

        # Dashboard API: Restart a specific session
        if startswith(path, "/dashboard/api/session/") &&
           endswith(path, "/restart") &&
           req.method == "POST"
            session_id =
                replace(path, r"^/dashboard/api/session/" => "", r"/restart$" => "")

            success = lock(JULIA_SESSION_REGISTRY_LOCK) do
                if haskey(JULIA_SESSION_REGISTRY, session_id)
                    conn = JULIA_SESSION_REGISTRY[session_id]

                    # Send restart request via exit tool
                    try
                        restart_req = Dict(
                            "jsonrpc" => "2.0",
                            "id" => rand(1:999999),
                            "method" => "tools/call",
                            "params" => Dict(
                                "name" => "exit",
                                "arguments" => Dict("restart" => true),
                            ),
                        )
                        write(conn.socket, JSON.json(restart_req) * "\n")
                        @info "Session restart requested" session_id
                        return true
                    catch e
                        @error "Failed to restart session" session_id error = e
                        return false
                    end
                else
                    @warn "Session not found for restart" session_id
                    return false
                end
            end

            send_json_response(
                http,
                Dict("success" => success, "session_id" => session_id);
                status = success ? 200 : 404,
            )
            return nothing
        end

        # Dashboard API: Shutdown a specific session
        if startswith(path, "/dashboard/api/session/") &&
           endswith(path, "/shutdown") &&
           req.method == "POST"
            session_id =
                replace(path, r"^/dashboard/api/session/" => "", r"/shutdown$" => "")

            success = lock(JULIA_SESSION_REGISTRY_LOCK) do
                if haskey(JULIA_SESSION_REGISTRY, session_id)
                    conn = JULIA_SESSION_REGISTRY[session_id]

                    # If disconnected, just unregister it
                    if conn.status == :disconnected
                        delete!(JULIA_SESSION_REGISTRY, session_id)
                        @info "Unregistered disconnected session" session_id
                        return true
                    end

                    # Otherwise, try to send shutdown request
                    try
                        shutdown_req = Dict(
                            "jsonrpc" => "2.0",
                            "id" => rand(1:999999),
                            "method" => "shutdown",
                            "params" => Dict(),
                        )
                        write(conn.socket, JSON.json(shutdown_req) * "\n")

                        # Remove from registry
                        delete!(JULIA_SESSION_REGISTRY, session_id)
                        @info "Session shutdown requested" session_id
                        return true
                    catch e
                        # If write fails, just unregister anyway
                        delete!(JULIA_SESSION_REGISTRY, session_id)
                        @warn "Failed to send shutdown request, unregistered anyway" session_id error =
                            e
                        return true
                    end
                else
                    @warn "Session not found for shutdown" session_id
                    return false
                end
            end

            send_json_response(
                http,
                Dict("success" => success, "session_id" => session_id);
                status = success ? 200 : 404,
            )
            return nothing
        end

        # Dashboard API: Get tools (proxy + selected agent)
        if path == "/dashboard/api/tools"
            agent_id = nothing
            for (k, v) in req.headers
                if lowercase(k) == "x-agent-id"
                    agent_id = v
                    break
                end
            end

            result = Dict{String,Any}(
                "proxy_tools" => get_proxy_tool_schemas(),
                "agent_tools" => Dict{String,Any}(),
            )

            # If agent_id specified, fetch tools from that agent
            if agent_id !== nothing && haskey(JULIA_SESSION_REGISTRY, agent_id)
                conn = JULIA_SESSION_REGISTRY[agent_id]
                if conn.status == :ready
                    try
                        # Make tools/list request to agent
                        agent_req = Dict(
                            "jsonrpc" => "2.0",
                            "id" => 1,
                            "method" => "tools/list",
                            "params" => Dict(),
                        )

                        agent_resp = HTTP.post(
                            "http://127.0.0.1:$(conn.port)/",
                            ["Content-Type" => "application/json"],
                            JSON.json(agent_req);
                            readtimeout = 5,
                        )

                        if agent_resp.status == 200
                            agent_data = JSON.parse(String(agent_resp.body))
                            if haskey(agent_data, "result") &&
                               haskey(agent_data["result"], "tools")
                                result["agent_tools"][agent_id] =
                                    agent_data["result"]["tools"]
                            end
                        end
                    catch e
                        @warn "Failed to fetch tools from agent" agent_id = agent_id exception =
                            e
                    end
                end
            end

            send_json_response(http, result)
            return nothing
        end

        # Dashboard API: List directories for path autocomplete
        if path == "/dashboard/api/directories"
            # Get path prefix from query params
            path_prefix = ""

            if !isempty(req.target)
                uri = HTTP.URI(req.target)
                params = HTTP.queryparams(uri.query)
                path_prefix = get(params, "path", "")
            end

            result =
                Dict{String,Any}("directories" => String[], "is_julia_project" => false)

            try
                # Expand ~ to home directory
                expanded_path = expanduser(path_prefix)

                # Check if current path is a Julia project (has Project.toml)
                if isdir(expanded_path)
                    project_toml = joinpath(expanded_path, "Project.toml")
                    result["is_julia_project"] = isfile(project_toml)
                end

                # If path ends with /, list contents of that directory
                # Otherwise, list contents of parent directory and filter
                if isdir(expanded_path)
                    base_dir = expanded_path
                    filter_prefix = ""
                else
                    base_dir = dirname(expanded_path)
                    filter_prefix = basename(expanded_path)
                end

                if isdir(base_dir)
                    entries = readdir(base_dir, join = false)

                    # Filter directories only
                    for entry in entries
                        full_path = joinpath(base_dir, entry)
                        # Include directories and filter by prefix
                        if isdir(full_path) && startswith(entry, filter_prefix)
                            # Return path relative to what user typed
                            if endswith(expanded_path, "/") || isdir(expanded_path)
                                result["directories"] = push!(
                                    result["directories"],
                                    joinpath(path_prefix, entry),
                                )
                            else
                                result["directories"] = push!(
                                    result["directories"],
                                    joinpath(dirname(path_prefix), entry),
                                )
                            end
                        end
                    end

                    # Sort results
                    sort!(result["directories"])

                    # Limit to 20 results
                    if length(result["directories"]) > 20
                        result["directories"] = result["directories"][1:20]
                    end
                end
            catch e
                result["error"] = "Failed to list directories: $(sprint(showerror, e))"
            end

            send_json_response(http, result)
            return nothing
        end

        # Dashboard API: Get logs for a session
        if path == "/dashboard/api/logs"
            # Get session_id from query params
            session_id = nothing
            lines = 500  # default number of lines

            if !isempty(req.target)
                uri = HTTP.URI(req.target)
                params = HTTP.queryparams(uri.query)
                session_id = get(params, "session_id", nothing)
                lines_str = get(params, "lines", "500")
                lines = tryparse(Int, lines_str)
                if lines === nothing
                    lines = 500
                end
            end

            result = Dict{String,Any}()

            if session_id !== nothing
                # Get log file for specific session
                log_dir = joinpath(dirname(@__DIR__), "logs")
                if isdir(log_dir)
                    # Find most recent log file for this session
                    log_files = filter(
                        f -> startswith(f, "session_$(session_id)_"),
                        readdir(log_dir),
                    )
                    if !isempty(log_files)
                        latest_log = joinpath(log_dir, sort(log_files)[end])
                        if isfile(latest_log)
                            try
                                content = read(latest_log, String)
                                # Get last N lines
                                all_lines = split(content, '\n')
                                selected_lines =
                                    all_lines[max(1, length(all_lines) - lines + 1):end]
                                result["content"] = join(selected_lines, '\n')
                                result["file"] = latest_log
                                result["total_lines"] = length(all_lines)
                            catch e
                                result["error"] = "Failed to read log file: $(sprint(showerror, e))"
                            end
                        else
                            result["error"] = "Log file not found"
                        end
                    else
                        result["error"] = "No log files found for session: $session_id"
                    end
                else
                    result["error"] = "Logs directory does not exist"
                end
            else
                # List all available log files
                log_dir = joinpath(dirname(@__DIR__), "logs")
                if isdir(log_dir)
                    files = readdir(log_dir)
                    result["files"] = map(files) do f
                        path = joinpath(log_dir, f)
                        Dict(
                            "name" => f,
                            "size" => filesize(path),
                            "modified" => string(Dates.unix2datetime(mtime(path))),
                        )
                    end
                else
                    result["files"] = []
                end
            end

            send_json_response(http, result)
            return nothing
            # Dashboard API: Clear log file for a session
            if path == "/dashboard/api/clear-logs" && req.method == "POST"
                # Get session_id from query params or body
                session_id = nothing

                if !isempty(req.target)
                    uri = HTTP.URI(req.target)
                    params = HTTP.queryparams(uri.query)
                    session_id = get(params, "session_id", nothing)
                end

                if session_id === nothing && !isempty(body)
                    try
                        body_params = JSON.parse(body)
                        session_id = get(body_params, "session_id", nothing)
                    catch
                    end
                end

                result = Dict{String,Any}()

                if session_id !== nothing
                    # Clear log file for specific session
                    log_dir = joinpath(dirname(@__DIR__), "logs")
                    if isdir(log_dir)
                        # Find log files for this session
                        log_files = filter(
                            f -> startswith(f, "session_$(session_id)_"),
                            readdir(log_dir),
                        )

                        if !isempty(log_files)
                            cleared_files = String[]
                            for log_file in log_files
                                full_path = joinpath(log_dir, log_file)
                                try
                                    # Truncate the file instead of deleting (keeps file handle valid)
                                    open(full_path, "w") do io
                                        # Write a header indicating when it was cleared
                                        write(
                                            io,
                                            "# Log cleared at $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))\n",
                                        )
                                    end
                                    push!(cleared_files, log_file)
                                    @info "Cleared log file" file = log_file
                                catch e
                                    @warn "Failed to clear log file" file = log_file exception =
                                        e
                                end
                            end

                            if !isempty(cleared_files)
                                result["success"] = true
                                result["message"] = "Cleared $(length(cleared_files)) log file(s)"
                                result["files"] = cleared_files
                            else
                                result["success"] = false
                                result["error"] = "Failed to clear any log files"
                            end
                        else
                            result["success"] = false
                            result["error"] = "No log files found for session: $session_id"
                        end
                    else
                        result["success"] = false
                        result["error"] = "Logs directory does not exist"
                    end
                else
                    result["success"] = false
                    result["error"] = "session_id parameter is required"
                end

                send_json_response(http, result; status = result["success"] ? 200 : 400)
                return nothing
            end

        end

        # Dashboard API: Restart proxy server
        if path == "/dashboard/api/restart" && req.method == "POST"
            @info "Restart endpoint called" pid = getpid()

            send_json_response(
                http,
                Dict("status" => "ok", "message" => "Restarting proxy server"),
            )

            @info "Response sent, scheduling restart"

            # Schedule restart after response is sent
            @async begin
                try
                    sleep(0.5)
                    @info "Restarting proxy server via dashboard"

                    # Get port before closing
                    local port = 3000
                    if SERVER[] !== nothing
                        try
                            port_match = match(r":(\d+)", string(SERVER[].listener))
                            if port_match !== nothing
                                port = parse(Int, port_match[1])
                            end
                        catch
                            port = 3000
                        end

                        # Spawn new proxy with delay, then exit immediately
                        # Let the OS clean up the server on process exit
                        script_dir = dirname(@__FILE__)
                        proxy_script = joinpath(dirname(script_dir), "proxy.jl")

                        # Use shell to wait for port to be free, then start new proxy
                        restart_cmd = """
                        sleep 2
                        while lsof -i :$port >/dev/null 2>&1; do
                            sleep 0.5
                        done
                        julia $proxy_script start --background
                        """

                        @info "Spawning restart process (will wait for port to clear)..."
                        run(`sh -c $restart_cmd`, wait = false)

                        @info "Removing PID file..."
                        remove_pid_file(port)
                    end

                    # Flush logs before exit
                    @info "Exiting current process..."
                    flush(stderr)
                    flush(stdout)
                    sleep(0.1)

                    # Exit current process
                    exit(0)
                catch e
                    @error "Error during restart" exception = (e, catch_backtrace())
                    exit(1)
                end
            end
            return nothing
        end

        # Dashboard API: Shutdown proxy server
        if path == "/dashboard/api/shutdown" && req.method == "POST"
            @info "Shutdown endpoint called" pid = getpid()

            send_json_response(
                http,
                JSON.json(
                    Dict("status" => "ok", "message" => "Shutting down proxy server"),
                ),
            )

            @info "Response sent, scheduling shutdown"

            # Schedule shutdown after response is sent
            @async begin
                @info "Shutdown task started"
                sleep(0.5)  # Give time for response to be sent
                @info "Proxy server shutdown requested via dashboard" pid = getpid()

                # Get port from SERVER before closing
                local port = 3000
                if SERVER[] !== nothing
                    try
                        port_match = match(r":(\d+)", string(SERVER[].listener))
                        if port_match !== nothing
                            port = parse(Int, port_match[1])
                        end
                    catch
                        port = 3000
                    end

                    @info "Shutting down proxy server" port = port

                    # Proper shutdown sequence
                    stop_vite_dev_server()
                    close(SERVER[])
                    SERVER[] = nothing
                    remove_pid_file(port)

                    @info "Server closed, exiting process"
                end

                # Force exit the Julia process
                @info "Calling exit(0)"
                sleep(0.1)
                exit(0)
            end
            return nothing
        end        # Dashboard API: Get events
        if path == "/dashboard/api/events"
            query_params = HTTP.queryparams(uri)
            id = get(query_params, "id", nothing)
            limit = parse(Int, get(query_params, "limit", "100"))

            events = Dashboard.get_events(id = id, limit = limit)
            events_json = [
                Dict(
                    "id" => e.id,
                    "type" => string(e.event_type),
                    "timestamp" => Dates.format(e.timestamp, "yyyy-mm-dd HH:MM:SS.sss"),
                    "data" => e.data,
                    "duration_ms" => e.duration_ms,
                ) for e in events
            ]

            send_json_response(http, events_json)
            return nothing
        end

        # Dashboard API: Server-Sent Events stream
        if path == "/dashboard/api/events/stream"
            query_params = HTTP.queryparams(uri)
            id = get(query_params, "id", nothing)

            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "text/event-stream")
            HTTP.setheader(http, "Cache-Control" => "no-cache")
            HTTP.setheader(http, "Connection" => "keep-alive")
            HTTP.startwrite(http)

            # Send initial connection event
            write(http, "event: connected\n")
            write(http, "data: {\"status\":\"connected\"}\n\n")
            flush(http)

            # Track last seen event ID to only send new events
            last_event_time = now()

            try
                while isopen(http)
                    # Get events since last check
                    events = Dashboard.get_events(id = id, limit = 50)
                    new_events = filter(e -> e.timestamp > last_event_time, events)

                    for event in new_events
                        event_data = Dict(
                            "id" => event.id,
                            "type" => string(event.event_type),
                            "timestamp" => Dates.format(
                                event.timestamp,
                                "yyyy-mm-dd HH:MM:SS.sss",
                            ),
                            "data" => event.data,
                            "duration_ms" => event.duration_ms,
                        )

                        write(http, "event: update\n")
                        write(http, "data: $(JSON.json(event_data))\n\n")
                        flush(http)

                        last_event_time = max(last_event_time, event.timestamp)
                    end

                    # Wait before next poll
                    sleep(0.5)
                end
            catch e
                if !(e isa Base.IOError)
                    @debug "SSE stream error" exception = e
                end
            end

            return nothing
        end

        # Dashboard API: Get interactions for a session
        if path == "/dashboard/api/interactions"
            query_params = HTTP.queryparams(uri)
            session_id = get(query_params, "session_id", nothing)
            request_id = get(query_params, "request_id", nothing)
            direction = get(query_params, "direction", nothing)
            limit = parse(Int, get(query_params, "limit", "100"))

            try
                interactions = Database.get_interactions(
                    session_id = session_id,
                    request_id = request_id,
                    direction = direction,
                    limit = limit,
                )

                # Convert DataFrame to JSON array
                interactions_json = [
                    Dict(
                        "id" => row.id,
                        "session_id" => row.session_id,
                        "timestamp" => row.timestamp,
                        "direction" => row.direction,
                        "message_type" => row.message_type,
                        "request_id" => row.request_id,
                        "method" => row.method,
                        "content" => row.content,
                        "content_size" => row.content_size,
                    ) for row in eachrow(interactions)
                ]

                send_json_response(http, interactions_json)
            catch e
                @error "Failed to get interactions" exception = e
                send_json_response(http, Dict("error" => string(e)), status = 500)
            end
            return nothing
        end

        # Dashboard API: Reconstruct session timeline
        if path == "/dashboard/api/session-timeline"
            query_params = HTTP.queryparams(uri)
            session_id = get(query_params, "session_id", nothing)
            limit = parse(Int, get(query_params, "limit", "1000"))

            if session_id === nothing
                send_json_response(
                    http,
                    Dict("error" => "session_id parameter required"),
                    status = 400,
                )
                return nothing
            end

            try
                timeline = Database.reconstruct_session(session_id, limit = limit)

                # Convert DataFrame to JSON array
                timeline_json = [
                    Dict(
                        "timestamp" => row.timestamp,
                        "type" => row.type,
                        "direction" =>
                            ismissing(row.direction) ? nothing : row.direction,
                        "message_type" =>
                            ismissing(row.message_type) ? nothing : row.message_type,
                        "content" => row.content,
                        "request_id" =>
                            ismissing(row.request_id) ? nothing : row.request_id,
                        "method" => ismissing(row.method) ? nothing : row.method,
                        "event_type" =>
                            ismissing(row.event_type) ? nothing : row.event_type,
                        "duration_ms" =>
                            ismissing(row.duration_ms) ? nothing : row.duration_ms,
                    ) for row in eachrow(timeline)
                ]

                send_json_response(http, timeline_json)
            catch e
                @error "Failed to reconstruct session" exception = e
                send_json_response(http, Dict("error" => string(e)), status = 500)
            end
            return nothing
        end

        # Dashboard API: Get session summary
        if path == "/dashboard/api/session-summary"
            query_params = HTTP.queryparams(uri)
            session_id = get(query_params, "session_id", nothing)

            if session_id === nothing
                send_json_response(
                    http,
                    Dict("error" => "session_id parameter required"),
                    status = 400,
                )
                return nothing
            end

            try
                summary = Database.get_session_summary(session_id)
                send_json_response(http, summary)
            catch e
                @error "Failed to get session summary" exception = e
                send_json_response(http, Dict("error" => string(e)), status = 500)
            end
            return nothing
        end

        # Dashboard API: Get all sessions from database
        if path == "/dashboard/api/db-sessions"
            query_params = HTTP.queryparams(uri)
            limit = parse(Int, get(query_params, "limit", "100"))

            try
                sessions = Database.get_all_sessions(limit = limit)

                # Convert DataFrame to JSON array
                sessions_json = [
                    Dict(
                        "session_id" => row.session_id,
                        "start_time" => row.start_time,
                        "last_activity" => row.last_activity,
                        "status" => row.status,
                        "metadata" => row.metadata,
                    ) for row in eachrow(sessions)
                ]

                send_json_response(http, sessions_json)
            catch e
                @error "Failed to get sessions from database" exception = e
                send_json_response(http, Dict("error" => string(e)), status = 500)
            end
            return nothing
        end

        # Dashboard API: Generate test events
        if path == "/dashboard/api/test-events"
            # Use first available session, or "test-agent" if none
            test_agent =
                isempty(JULIA_SESSION_REGISTRY) ? "test-agent" :
                first(keys(JULIA_SESSION_REGISTRY))

            # Generate sample events of all types
            Dashboard.log_event(test_agent, Dashboard.HEARTBEAT, Dict("status" => "ok"))

            Dashboard.log_event(
                test_agent,
                Dashboard.TOOL_CALL,
                Dict(
                    "tool" => "ex",
                    "arguments" => Dict("e" => "println(\"Hello, World!\")"),
                ),
                duration_ms = 12.5,
            )

            Dashboard.log_event(
                test_agent,
                Dashboard.CODE_EXECUTION,
                Dict("expression" => "2 + 2", "result" => "4"),
                duration_ms = 0.8,
            )

            Dashboard.log_event(
                test_agent,
                Dashboard.OUTPUT,
                Dict("text" => "Hello, World!"),
            )

            Dashboard.log_event(
                test_agent,
                Dashboard.ERROR,
                Dict("message" => "UndefVarError: x not defined", "stacktrace" => "..."),
            )

            Dashboard.log_event(
                test_agent,
                Dashboard.AGENT_START,
                Dict("port" => 3000, "pid" => getpid()),
            )

            Dashboard.log_event(
                test_agent,
                Dashboard.AGENT_STOP,
                Dict("reason" => "shutdown"),
            )

            # Spawn async task to generate progress notifications
            # This way we return immediately but events continue to emit
            @async begin
                sleep(1)  # Wait a bit after initial events

                # Test indeterminate progress (no total) - simulate package loading
                for i = 1:5
                    Dashboard.emit_progress(
                        test_agent,
                        "pkg-load",
                        i,
                        message = "📦 Loading package dependencies ($i)...",
                    )
                    sleep(0.5)
                end

                # Test determinate progress (with total) - simulate file processing
                for i = 1:10
                    Dashboard.emit_progress(
                        test_agent,
                        "file-process",
                        i,
                        total = 10,
                        message = "📄 Processing files: $(i)/10",
                    )
                    sleep(0.3)
                end
            end

            # Return response immediately
            send_json_response(
                http,
                Dict(
                    "status" => "ok",
                    "message" => "Test events queued, progress will emit over next few seconds",
                ),
            )
            return nothing
        end

        # ============================================================================
        # Analytics API Endpoints - Structured analytics from ETL
        # ============================================================================

        # Get tool execution analytics
        if path == "/dashboard/api/analytics/tool-executions"
            query_params = HTTP.queryparams(uri)
            session_id = get(query_params, "session_id", nothing)
            tool_name = get(query_params, "tool_name", nothing)
            status = get(query_params, "status", nothing)
            limit = parse(Int, get(query_params, "limit", "100"))

            try
                db = Database.DB[]
                if db === nothing
                    send_json_response(
                        http,
                        Dict("error" => "Database not initialized"),
                        status = 500,
                    )
                    return nothing
                end

                # Build query with filters
                where_clauses = String[]
                params = Any[]

                if session_id !== nothing
                    push!(where_clauses, "session_id = ?")
                    push!(params, session_id)
                end

                if tool_name !== nothing
                    push!(where_clauses, "tool_name = ?")
                    push!(params, tool_name)
                end

                if status !== nothing
                    push!(where_clauses, "status = ?")
                    push!(params, status)
                end

                where_clause =
                    isempty(where_clauses) ? "" : "WHERE " * join(where_clauses, " AND ")

                query = """
                    SELECT * FROM tool_executions
                    $where_clause
                    ORDER BY request_time DESC
                    LIMIT ?
                """
                push!(params, limit)

                result = DBInterface.execute(db, query, params) |> DataFrame

                # Convert to JSON
                executions = [
                    Dict(
                        "id" => row.id,
                        "session_id" => row.session_id,
                        "request_id" => row.request_id,
                        "tool_name" => row.tool_name,
                        "tool_method" => row.tool_method,
                        "request_time" => row.request_time,
                        "response_time" =>
                            ismissing(row.response_time) ? nothing : row.response_time,
                        "duration_ms" =>
                            ismissing(row.duration_ms) ? nothing : row.duration_ms,
                        "input_size" => row.input_size,
                        "output_size" => row.output_size,
                        "argument_count" => row.argument_count,
                        "status" => row.status,
                        "result_type" =>
                            ismissing(row.result_type) ? nothing : row.result_type,
                        "result_summary" =>
                            ismissing(row.result_summary) ? nothing : row.result_summary,
                    ) for row in eachrow(result)
                ]

                send_json_response(http, executions)
            catch e
                @error "Failed to get tool executions" exception = e
                send_json_response(http, Dict("error" => string(e)), status = 500)
            end
            return nothing
        end

        # Get error analytics
        if path == "/dashboard/api/analytics/errors"
            query_params = HTTP.queryparams(uri)
            session_id = get(query_params, "session_id", nothing)
            tool_name = get(query_params, "tool_name", nothing)
            error_type = get(query_params, "error_type", nothing)
            resolved = get(query_params, "resolved", nothing)
            limit = parse(Int, get(query_params, "limit", "100"))

            try
                db = Database.DB[]
                if db === nothing
                    send_json_response(
                        http,
                        Dict("error" => "Database not initialized"),
                        status = 500,
                    )
                    return nothing
                end

                # Build query with filters
                where_clauses = String[]
                params = Any[]

                if session_id !== nothing
                    push!(where_clauses, "session_id = ?")
                    push!(params, session_id)
                end

                if tool_name !== nothing
                    push!(where_clauses, "tool_name = ?")
                    push!(params, tool_name)
                end

                if error_type !== nothing
                    push!(where_clauses, "error_type = ?")
                    push!(params, error_type)
                end

                if resolved !== nothing
                    push!(where_clauses, "resolved = ?")
                    push!(params, resolved == "true" ? 1 : 0)
                end

                where_clause =
                    isempty(where_clauses) ? "" : "WHERE " * join(where_clauses, " AND ")

                query = """
                    SELECT * FROM errors
                    $where_clause
                    ORDER BY timestamp DESC
                    LIMIT ?
                """
                push!(params, limit)

                result = DBInterface.execute(db, query, params) |> DataFrame

                # Convert to JSON
                errors = [
                    Dict(
                        "id" => row.id,
                        "session_id" => row.session_id,
                        "timestamp" => row.timestamp,
                        "error_type" => row.error_type,
                        "error_code" =>
                            ismissing(row.error_code) ? nothing : row.error_code,
                        "error_category" =>
                            ismissing(row.error_category) ? nothing : row.error_category,
                        "tool_name" =>
                            ismissing(row.tool_name) ? nothing : row.tool_name,
                        "method" => ismissing(row.method) ? nothing : row.method,
                        "request_id" =>
                            ismissing(row.request_id) ? nothing : row.request_id,
                        "message" => row.message,
                        "stack_trace" =>
                            ismissing(row.stack_trace) ? nothing : row.stack_trace,
                        "resolved" => row.resolved,
                    ) for row in eachrow(result)
                ]

                send_json_response(http, errors)
            catch e
                @error "Failed to get errors" exception = e
                send_json_response(http, Dict("error" => string(e)), status = 500)
            end
            return nothing
        end

        # Get tool usage summary
        if path == "/dashboard/api/analytics/tool-summary"
            query_params = HTTP.queryparams(uri)
            session_id = get(query_params, "session_id", nothing)
            days = parse(Int, get(query_params, "days", "7"))

            try
                db = Database.DB[]
                if db === nothing
                    send_json_response(
                        http,
                        Dict("error" => "Database not initialized"),
                        status = 500,
                    )
                    return nothing
                end

                # Query daily tool usage view
                where_clause =
                    session_id !== nothing ? "WHERE session_id = ?" :
                    "WHERE date >= date('now', '-$days days')"
                params = session_id !== nothing ? [session_id] : []

                query = """
                    SELECT 
                        tool_name,
                        SUM(execution_count) as total_executions,
                        AVG(avg_duration_ms) as avg_duration_ms,
                        MIN(min_duration_ms) as min_duration_ms,
                        MAX(max_duration_ms) as max_duration_ms,
                        SUM(error_count) as total_errors,
                        ROUND(AVG(error_rate_pct), 2) as avg_error_rate_pct
                    FROM v_daily_tool_usage
                    $where_clause
                    GROUP BY tool_name
                    ORDER BY total_executions DESC
                """

                result = DBInterface.execute(db, query, params) |> DataFrame

                # Convert to JSON
                summary = [
                    Dict(
                        "tool_name" => row.tool_name,
                        "total_executions" => row.total_executions,
                        "avg_duration_ms" =>
                            ismissing(row.avg_duration_ms) ? nothing : row.avg_duration_ms,
                        "min_duration_ms" =>
                            ismissing(row.min_duration_ms) ? nothing : row.min_duration_ms,
                        "max_duration_ms" =>
                            ismissing(row.max_duration_ms) ? nothing : row.max_duration_ms,
                        "total_errors" => row.total_errors,
                        "avg_error_rate_pct" =>
                            ismissing(row.avg_error_rate_pct) ? nothing :
                            row.avg_error_rate_pct,
                    ) for row in eachrow(result)
                ]

                send_json_response(http, summary)
            catch e
                @error "Failed to get tool summary" exception = e
                send_json_response(http, Dict("error" => string(e)), status = 500)
            end
            return nothing
        end

        # Get error hotspots
        if path == "/dashboard/api/analytics/error-hotspots"
            try
                db = Database.DB[]
                if db === nothing
                    send_json_response(
                        http,
                        Dict("error" => "Database not initialized"),
                        status = 500,
                    )
                    return nothing
                end

                query = "SELECT * FROM v_error_hotspots LIMIT 50"
                result = DBInterface.execute(db, query) |> DataFrame

                # Convert to JSON
                hotspots = [
                    Dict(
                        "tool_name" =>
                            ismissing(row.tool_name) ? "unknown" : row.tool_name,
                        "error_type" => row.error_type,
                        "error_category" => row.error_category,
                        "error_count" => row.error_count,
                        "affected_sessions" => row.affected_sessions,
                        "last_occurrence" => row.last_occurrence,
                    ) for row in eachrow(result)
                ]

                send_json_response(http, hotspots)
            catch e
                @error "Failed to get error hotspots" exception = e
                send_json_response(http, Dict("error" => string(e)), status = 500)
            end
            return nothing
        end

        # Run ETL manually
        if path == "/dashboard/api/analytics/run-etl"
            try
                db = Database.DB[]
                if db === nothing
                    send_json_response(
                        http,
                        Dict("error" => "Database not initialized"),
                        status = 500,
                    )
                    return nothing
                end

                result = Database.run_etl_pipeline(db; mode = :incremental)

                send_json_response(http, result)
            catch e
                @error "Failed to run ETL" exception = e
                send_json_response(http, Dict("error" => string(e)), status = 500)
            end
            return nothing
        end

        # Get ETL status
        if path == "/dashboard/api/analytics/etl-status"
            try
                db = Database.DB[]
                if db === nothing
                    send_json_response(
                        http,
                        Dict("error" => "Database not initialized"),
                        status = 500,
                    )
                    return nothing
                end

                result =
                    DBInterface.execute(db, "SELECT * FROM etl_metadata WHERE id = 1") |>
                    DataFrame

                if nrow(result) > 0
                    row = result[1, :]
                    status = Dict(
                        "last_processed_interaction_id" =>
                            row.last_processed_interaction_id,
                        "last_processed_event_id" => row.last_processed_event_id,
                        "last_run_time" =>
                            ismissing(row.last_run_time) ? nothing : row.last_run_time,
                        "last_run_status" =>
                            ismissing(row.last_run_status) ? nothing : row.last_run_status,
                        "last_error" =>
                            ismissing(row.last_error) ? nothing : row.last_error,
                    )
                    send_json_response(http, status)
                else
                    send_json_response(http, Dict("error" => "No ETL metadata found"))
                end
            catch e
                @error "Failed to get ETL status" exception = e
                send_json_response(http, Dict("error" => string(e)), status = 500)
            end
            return nothing
        end

        # Dashboard WebSocket (for future implementation)
        if path == "/dashboard/ws"
            send_json_response(http, "WebSocket not yet implemented", 501, "text/plain")
            return nothing
        end

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
                            "id" => s.id,
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
            id = get(params, "id", nothing)
            port = get(params, "port", nothing)
            pid = get(params, "pid", nothing)
            metadata_raw = get(params, "metadata", Dict())

            # Convert JSON.Object to Dict if needed
            metadata =
                metadata_raw isa Dict ? metadata_raw :
                Dict(String(k) => v for (k, v) in pairs(metadata_raw))

            if id === nothing || port === nothing
                send_jsonrpc_error(
                    http,
                    get(request, "id", nothing),
                    -32602,
                    "Invalid params: 'id' and 'port' are required";
                    status = 400,
                )
                return nothing
            end

            # Check if a session with this ID already exists
            existing_session = lock(JULIA_SESSION_REGISTRY_LOCK) do
                get(JULIA_SESSION_REGISTRY, id, nothing)
            end

            if existing_session !== nothing
                # Session already exists - check if it's the same process or a duplicate
                if existing_session.pid == pid
                    @warn "Re-registration from same process - updating" id = id port = port pid =
                        pid
                    # Allow re-registration from same PID (process restart case)
                else
                    @error "Duplicate registration attempted" id = id existing_pid =
                        existing_session.pid new_pid = pid existing_port =
                        existing_session.port new_port = port
                    send_jsonrpc_error(
                        http,
                        get(request, "id", nothing),
                        -32000,
                        "Session ID '$id' is already registered by another process (PID $(existing_session.pid) on port $(existing_session.port)). Choose a different session name or stop the existing session first.";
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

            register_julia_session(id, port; pid = pid, metadata = metadata)

            send_jsonrpc_result(
                http,
                get(request, "id", nothing),
                Dict("status" => "registered", "id" => id),
            )
            return nothing
        elseif method == "proxy/unregister"
            # Unregister a Julia session
            params = get(request, "params", Dict())
            id = get(params, "id", nothing)

            if id === nothing
                send_jsonrpc_error(
                    http,
                    get(request, "id", nothing),
                    -32602,
                    "Invalid params: 'id' is required";
                    status = 400,
                )
                return nothing
            end

            unregister_julia_session(id)

            send_jsonrpc_result(
                http,
                get(request, "id", nothing),
                Dict("status" => "unregistered", "id" => id),
            )
            return nothing
        elseif method == "proxy/heartbeat"
            # Julia session sends heartbeat to indicate it's alive
            params = get(request, "params", Dict())
            id = get(params, "id", nothing)

            if id === nothing
                send_jsonrpc_error(
                    http,
                    get(request, "id", nothing),
                    -32602,
                    "Invalid params: 'id' is required";
                    status = 400,
                )
                return nothing
            end

            # Update heartbeat and recover from disconnected/stopped state
            lock(JULIA_SESSION_REGISTRY_LOCK) do
                if haskey(JULIA_SESSION_REGISTRY, id)
                    existing_session = JULIA_SESSION_REGISTRY[id]
                    heartbeat_pid = get(params, "pid", nothing)

                    # Check if this heartbeat is from the registered process
                    if heartbeat_pid !== nothing && existing_session.pid != heartbeat_pid
                        @error "Duplicate heartbeat detected - different PID for same session ID" id =
                            id registered_pid = existing_session.pid heartbeat_pid =
                            heartbeat_pid
                        # Reject this heartbeat - don't update the legitimate session
                        # The duplicate process will not be registered
                        return nothing
                    end

                    JULIA_SESSION_REGISTRY[id].last_heartbeat = now()
                    JULIA_SESSION_REGISTRY[id].missed_heartbeats = 0  # Reset counter on successful heartbeat
                    # Automatically recover from disconnected or stopped state on heartbeat
                    if JULIA_SESSION_REGISTRY[id].status in
                       (:stopped, :disconnected, :reconnecting)
                        old_status = JULIA_SESSION_REGISTRY[id].status
                        JULIA_SESSION_REGISTRY[id].status = :ready
                        JULIA_SESSION_REGISTRY[id].last_error = nothing
                        JULIA_SESSION_REGISTRY[id].disconnect_time = nothing
                        @info "Julia session recovered via heartbeat" id = id old_status =
                            old_status
                    end

                    # Log heartbeat event (don't spam - could be rate limited in Dashboard module)
                    Dashboard.log_event(id, Dashboard.HEARTBEAT, Dict("status" => "ok"))
                else
                    # Session not in registry - proxy may have restarted
                    # Try to re-register by extracting info from heartbeat params
                    port = get(params, "port", nothing)
                    pid = get(params, "pid", nothing)
                    metadata_raw = get(params, "metadata", Dict())

                    if port !== nothing && pid !== nothing
                        @info "Re-registering session from heartbeat (proxy restart detected)" id =
                            id port = port pid = pid
                        metadata =
                            metadata_raw isa Dict ? metadata_raw :
                            Dict(String(k) => v for (k, v) in pairs(metadata_raw))

                        # Register the session
                        JULIA_SESSION_REGISTRY[id] = JuliaSession(
                            id,
                            port,
                            pid,
                            :ready,
                            now(),
                            metadata,
                            nothing,
                            0,
                            Tuple{Dict,HTTP.Stream}[],
                            nothing,
                        )

                        # Log registration event
                        Dashboard.log_event(
                            id,
                            Dashboard.AGENT_START,
                            Dict(
                                "port" => port,
                                "pid" => pid,
                                "metadata" => metadata,
                                "reason" => "reregistered_from_heartbeat",
                            ),
                        )
                    else
                        @warn "Heartbeat from unknown session without port/pid info - cannot re-register" id =
                            id has_port = (port !== nothing) has_pid = (pid !== nothing)
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
                existing = findfirst(s -> s.id == session_name, julia_sessions)
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
                    ccall(:setvbuf, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Cint, Csize_t), Base.stdout.io, C_NULL, 0, 0)
                    ccall(:setvbuf, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Cint, Csize_t), Base.stderr.io, C_NULL, 0, 0)
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

                    # Wait for Julia session to register (max 30 seconds to allow for precompilation)
                    # When agent_name is provided, MCPRepl registers using that name directly
                    registered = false
                    expected_id = session_name
                    for i = 1:300  # 30 seconds with 0.1s sleep
                        sleep(0.1)
                        current_sessions = list_julia_sessions()
                        # Check for the expected registration ID
                        idx = findfirst(s -> s.id == expected_id, current_sessions)
                        if idx !== nothing
                            registered = true
                            new_session = current_sessions[idx]
                            send_mcp_tool_result(
                                http,
                                get(request, "id", nothing),
                                "✅ Successfully started Julia session '$(new_session.id)' on port $(new_session.port)\n\nProject: $project_path\nPID: $(new_session.pid)\nStatus: $(new_session.status)\nLog: $log_file",
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
                        "Julia session process started but did not register within 30 seconds.\n\nLog file: $log_file\n\nRecent output:\n$log_contents",
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

    # Initialize database for persistent event storage
    db_path = joinpath(dirname(@__DIR__), ".mcprepl", "events.db")
    db = Database.init_db!(db_path)
    @info "Database initialized for event storage" db_path = db_path

    # Start ETL scheduler for analytics
    etl_task = Database.start_etl_scheduler(db; interval_seconds = 30)
    @info "ETL scheduler started for analytics processing" interval_seconds = 30

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
