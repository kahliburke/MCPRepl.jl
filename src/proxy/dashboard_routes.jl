"""
Dashboard HTTP API Routes

Handles all /dashboard/* HTTP endpoints for the MCPRepl proxy dashboard.
Extracted from the monolithic handle_request function for better maintainability.

This file is included within the Proxy module, so it has direct access to
Proxy module functions like get_julia_session, send_json_response, etc.
"""

# Note: This file is included in proxy.jl, so HTTP, JSON, Dates are already available
# and we have direct access to Proxy module internals

"""
    handle_dashboard_route(http::HTTP.Stream, req::HTTP.Request, body::String, path::AbstractString) -> Union{Bool, Nothing}

Route and handle dashboard HTTP requests.

Returns `nothing` if the route was handled (response sent),
`false` if the route wasn't recognized (caller should continue routing).
"""
function handle_dashboard_route(
    http::HTTP.Stream,
    req::HTTP.Request,
    body::String,
    path::AbstractString,
)
    # Redirect /dashboard to /dashboard/ (Vite expects trailing slash)
    if path == "/dashboard"
        send_empty_response(http, 301, ["Location" => "/dashboard/"])
        return nothing
    end

    # Dashboard API routes
    if !startswith(path, "/dashboard/api/")
        # Not a dashboard API route - let caller handle static files
        return false
    end

    # Proxy info endpoint
    if path == "/dashboard/api/proxy-info"
        return handle_proxy_info(http)
    end

    # Sessions management
    if path == "/dashboard/api/sessions"
        return handle_sessions_list(http)
    end

    # Session restart
    if startswith(path, "/dashboard/api/session/") &&
       endswith(path, "/restart") &&
       req.method == "POST"
        session_id = replace(path, r"^/dashboard/api/session/" => "", r"/restart$" => "")
        return handle_session_restart(http, session_id)
    end

    # Session shutdown
    if startswith(path, "/dashboard/api/session/") &&
       endswith(path, "/shutdown") &&
       req.method == "POST"
        session_id = replace(path, r"^/dashboard/api/session/" => "", r"/shutdown$" => "")
        return handle_session_shutdown(http, session_id)
    end

    # Tools endpoint
    if path == "/dashboard/api/tools"
        agent_id = nothing
        for (k, v) in req.headers
            if lowercase(k) == "x-agent-id"
                agent_id = String(v)
                break
            end
        end
        return handle_tools_list(http, agent_id)
    end

    # Database-backed endpoints
    if path == "/dashboard/api/events"
        return handle_events(http, req)
    end

    # SSE streaming endpoint for events
    if path == "/dashboard/api/events/stream"
        return handle_events_stream(http, req)
    end

    # Sessions stream not yet implemented
    if path == "/dashboard/api/sessions/stream"
        send_json_response(
            http,
            Dict(
                "error" => "Sessions streaming not yet implemented",
                "message" => "Real-time session streaming is not yet available.",
            );
            status = 501,
        )
        return nothing
    end

    if path == "/dashboard/api/interactions"
        return handle_interactions(http, req)
    end

    if path == "/dashboard/api/session-timeline"
        return handle_session_timeline(http, req)
    end

    if path == "/dashboard/api/session-summary"
        return handle_session_summary(http, req)
    end

    if path == "/dashboard/api/db-sessions"
        return handle_db_sessions(http)
    end

    # Logs endpoint
    if path == "/dashboard/api/logs"
        return handle_logs(http, req)
    end

    # Analytics endpoints
    if path == "/dashboard/api/analytics/tool-executions"
        return handle_analytics_tool_executions(http, req)
    end

    if path == "/dashboard/api/analytics/errors"
        return handle_analytics_errors(http, req)
    end

    if path == "/dashboard/api/analytics/tool-summary"
        return handle_analytics_tool_summary(http)
    end

    if path == "/dashboard/api/analytics/error-hotspots"
        return handle_analytics_error_hotspots(http)
    end

    if path == "/dashboard/api/analytics/run-etl" && req.method == "POST"
        return handle_analytics_run_etl(http)
    end

    if path == "/dashboard/api/analytics/etl-status"
        return handle_analytics_etl_status(http)
    end

    # Dashboard WebSocket endpoint
    if path == "/dashboard/ws"
        return handle_dashboard_websocket(http)
    end

    # Not a recognized dashboard API route
    return false
end

# ============================================================================
# Route Handlers
# ============================================================================

function handle_proxy_info(http::HTTP.Stream)
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

function handle_sessions_list(http::HTTP.Stream)
    start_time = time()
    # Query Julia sessions from database
    julia_sessions = list_julia_sessions()

    result = Dict{String,Any}()
    for session in julia_sessions
        # Convert all fields explicitly, handling Missing
        session_id = ismissing(session.id) ? "" : String(session.id)
        session_name = ismissing(session.name) ? "" : String(session.name)
        session_port = ismissing(session.port) ? nothing : session.port
        session_pid = ismissing(session.pid) ? nothing : session.pid
        session_status = ismissing(session.status) ? "unknown" : String(session.status)
        session_last_activity =
            ismissing(session.last_activity) ? "" : String(session.last_activity)
        session_start_time = ismissing(session.start_time) ? "" : String(session.start_time)

        if !isempty(session_id)
            result[session_id] = Dict(
                "uuid" => session_id,
                "name" => session_name,
                "port" => session_port,
                "pid" => session_pid,
                "status" => session_status,
                "last_heartbeat" => session_last_activity,
                "created_at" => session_start_time,
            )
        end
    end

    elapsed = (time() - start_time) * 1000
    if elapsed > 100
        @warn "Slow sessions API call" elapsed_ms = elapsed
    end
    send_json_response(http, result)
    return nothing
end

function handle_session_restart(http::HTTP.Stream, session_id::String)
    return handle_session_control(http, session_id, "restart") do conn, sid
        # Immediately mark session as restarting in database
        Database.update_session_status!(sid, "restarting")
        @info "Marked session as restarting" session_id = sid

        # Send restart request via manage_repl tool
        params = Dict("name" => "manage_repl", "arguments" => Dict("command" => "restart"))
        success = send_jsonrpc_to_session(conn, "tools/call", params)

        if success
            @info "Session restart requested" session_id = sid
        else
            @error "Failed to send restart command" session_id = sid
            # Revert status if restart command failed
            Database.update_session_status!(sid, "ready")
        end

        return (success, false)  # success, don't delete from registry
    end
end

function handle_session_shutdown(http::HTTP.Stream, session_id::String)
    return handle_session_control(http, session_id, "shutdown") do conn, sid
        # If disconnected, just unregister it
        session_status = ismissing(conn.status) ? "unknown" : conn.status
        if session_status == "disconnected"
            @info "Unregistered disconnected session" session_id = sid
            return (true, true)  # success, delete from registry
        end

        # Send shutdown request via manage_repl tool
        params = Dict("name" => "manage_repl", "arguments" => Dict("command" => "shutdown"))
        success = send_jsonrpc_to_session(conn, "tools/call", params)

        if success
            @info "Session shutdown requested" session_id = sid
        else
            @warn "Failed to send shutdown request, unregistering anyway" session_id = sid
        end

        return (true, true)  # always success (unregister even if write fails), always delete
    end
end

function handle_tools_list(http::HTTP.Stream, agent_id::Union{String,Nothing})
    try
        result = Dict{String,Any}(
            "proxy_tools" => get_proxy_tool_schemas(),
            "session_tools" => Dict{String,Any}(),
        )

        # If agent_id specified, fetch tools from that agent
        if agent_id !== nothing
            session = get_julia_session(agent_id)
            if session === nothing
                @warn "Tools requested for non-existent session" agent_id = agent_id
                # Return empty tools for non-existent session, UI will show "No tools available"
            else
                session_status = ismissing(session.status) ? "unknown" : session.status
                session_port = ismissing(session.port) ? nothing : session.port
                if session_status != "ready" || session_port === nothing
                    @warn "Tools requested for non-ready session" agent_id = agent_id status =
                        session_status
                    # Return empty tools for non-ready session, UI will show "No tools available"
                else
                    try
                        # Make tools/list request to agent
                        agent_req = Dict(
                            "jsonrpc" => "2.0",
                            "id" => 1,
                            "method" => "tools/list",
                            "params" => Dict(),
                        )

                        agent_resp = HTTP.post(
                            "http://127.0.0.1:$(session_port)/",
                            ["Content-Type" => "application/json"],
                            JSON.json(agent_req);
                            readtimeout = 5,
                        )

                        if agent_resp.status == 200
                            agent_data = JSON.parse(String(agent_resp.body))
                            if haskey(agent_data, "result") &&
                               haskey(agent_data["result"], "tools")
                                result["session_tools"][agent_id] =
                                    agent_data["result"]["tools"]
                                @info "Fetched tools for session" agent_id = agent_id tool_count =
                                    length(agent_data["result"]["tools"])
                            else
                                @warn "Invalid tools/list response from session" agent_id =
                                    agent_id
                            end
                        else
                            @warn "Failed to fetch tools from session" agent_id = agent_id status =
                                agent_resp.status
                        end
                    catch e
                        @warn "Exception while fetching tools from session" agent_id =
                            agent_id exception = e
                    end
                end
            end
        end

        send_json_response(http, result)
    catch e
        @error "Error in handle_tools_list" exception = (e, catch_backtrace())
        send_json_response(http, Dict("error" => string(e)); status = 500)
    end
    return nothing
end

# Database-backed handlers - these will query the Database module
function handle_events(http::HTTP.Stream, req::HTTP.Request)
    query_params = parse_query_params(req)
    limit = get_int_param(query_params, "limit", "100")
    offset = get_int_param(query_params, "offset", "0")

    # get_events uses keyword arguments
    events = Database.get_events(; limit = limit, offset = offset)

    # Transform events to match frontend expectations
    # Frontend expects: {type, id, timestamp, data, duration_ms}
    # Database has: {event_type, julia_session_id, timestamp, data, duration_ms}
    transformed_events = map(events) do event
        Dict(
            "type" => get(event, "event_type", ""),
            "id" => get(event, "julia_session_id", ""),
            "timestamp" => get(event, "timestamp", ""),
            "data" => try
                # Parse data if it's a JSON string
                data_str = get(event, "data", "{}")
                typeof(data_str) == String ? JSON.parse(data_str) : data_str
            catch
                get(event, "data", Dict())
            end,
            "duration_ms" => get(event, "duration_ms", nothing),
        )
    end

    send_json_response(http, transformed_events)
    return nothing
end

function handle_interactions(http::HTTP.Stream, req::HTTP.Request)
    query_params = parse_query_params(req)
    session_id = get(query_params, "session_id", nothing)
    limit = get_int_param(query_params, "limit", "50")

    # get_interactions uses keyword arguments
    interactions = if session_id !== nothing
        Database.get_interactions(; julia_session_id = session_id, limit = limit)
    else
        Database.get_interactions(; limit = limit)
    end

    send_json_response(http, interactions)
    return nothing
end

function handle_session_timeline(http::HTTP.Stream, req::HTTP.Request)
    query_params = parse_query_params(req)
    session_id = require_session_id(http, query_params)
    if session_id === nothing
        return nothing
    end
    return handle_database_query(http, Database.get_session_timeline, session_id)
end

function handle_session_summary(http::HTTP.Stream, req::HTTP.Request)
    return handle_session_query(http, req, Database.get_session_summary)
end

function handle_db_sessions(http::HTTP.Stream)
    return handle_database_query(http, Database.get_all_sessions)
end

function handle_logs(http::HTTP.Stream, req::HTTP.Request)
    query_params = parse_query_params(req)
    session_id = get(query_params, "session_id", nothing)
    lines = get_int_param(query_params, "lines", "500")

    result = Dict{String,Any}()

    if session_id !== nothing
        # Get log file for specific session (matches original implementation)
        log_dir = joinpath(dirname(dirname(@__DIR__)), "logs")

        if isdir(log_dir)
            # Logs are now named by UUID: session_<uuid>.log
            # session_id parameter should always be a UUID
            session = get_julia_session(session_id)

            # Use UUID for log file lookup (session_id should already be UUID)
            search_uuid = session !== nothing ? session.id : session_id

            # Find log file for this session (UUID-based, no timestamp suffix)
            log_file_name = "session_$(search_uuid).log"
            log_files = filter(f -> f == log_file_name, readdir(log_dir))

            if !isempty(log_files)
                # Sort by modification time and filter out crash dumps (small files)
                log_files_with_info = [(f, stat(joinpath(log_dir, f))) for f in log_files]

                # Filter out likely crash dumps (< 3KB) and very old files (> 24 hours old)
                recent_logs = filter(log_files_with_info) do (f, s)
                    s.size > 3000 && (time() - s.mtime) < 86400  # 24 hours
                end

                if isempty(recent_logs)
                    result["error"] = "No active log files found for session: $session_id\n\nNote: This session may be logging to a parent process (VS Code, terminal, etc.) rather than to a file. Only background-started sessions write to log files."
                    send_json_response(http, result)
                    return nothing
                end

                # Get most recent non-crash log
                latest_file = sort(recent_logs, by = x -> x[2].mtime, rev = true)[1][1]
                latest_log = joinpath(log_dir, latest_file)

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
                result["error"] = "No log files found for session: $session_id\n\nNote: This session may be logging to a parent process (VS Code, terminal, etc.) rather than to a file. Only background-started sessions write to log files."
            end
        else
            result["error"] = "Logs directory does not exist"
        end
    else
        result["error"] = "session_id parameter is required"
    end

    send_json_response(http, result)
    return nothing
end

function handle_analytics_tool_executions(http::HTTP.Stream, req::HTTP.Request)
    query_params = parse_query_params(req)
    days = get_int_param(query_params, "days", "7")
    try
        data = Database.get_tool_executions(; days = days)
        send_json_response(http, data)
    catch e
        @error "Failed to get tool executions" exception = e
        send_json_response(http, Dict("error" => string(e)); status = 500)
    end
    return nothing
end

function handle_analytics_errors(http::HTTP.Stream, req::HTTP.Request)
    query_params = parse_query_params(req)
    days = get_int_param(query_params, "days", "7")
    try
        data = Database.get_error_analytics(; days = days)
        send_json_response(http, data)
    catch e
        @error "Failed to get error analytics" exception = e
        send_json_response(http, Dict("error" => string(e)); status = 500)
    end
    return nothing
end

function handle_analytics_tool_summary(http::HTTP.Stream)
    return handle_database_query(http, Database.get_tool_summary)
end

function handle_analytics_error_hotspots(http::HTTP.Stream)
    return handle_database_query(http, Database.get_error_hotspots)
end

function handle_analytics_run_etl(http::HTTP.Stream)
    try
        db = Database.DB[]
        if db === nothing
            send_json_response(
                http,
                Dict("status" => "error", "message" => "Database not initialized");
                status = 500,
            )
            return nothing
        end

        # Run ETL pipeline
        result = Database.run_etl_pipeline(db; mode = :incremental)

        if result.success
            send_json_response(
                http,
                Dict(
                    "status" => "success",
                    "message" => "ETL pipeline completed",
                    "tool_executions" => result.tool_executions,
                    "errors" => result.errors,
                    "client_sessions" => result.client_sessions,
                    "metrics" => result.metrics,
                    "duration_seconds" => result.duration_seconds,
                ),
            )
        else
            send_json_response(
                http,
                Dict(
                    "status" => "error",
                    "message" => get(result, :error, "Unknown error"),
                );
                status = 500,
            )
        end
    catch e
        @error "ETL pipeline failed" exception = (e, catch_backtrace())
        send_json_response(
            http,
            Dict("status" => "error", "message" => string(e));
            status = 500,
        )
    end
    return nothing
end

function handle_analytics_etl_status(http::HTTP.Stream)
    try
        db = Database.DB[]
        if db === nothing
            send_json_response(
                http,
                Dict("error" => "Database not initialized");
                status = 500,
            )
            return nothing
        end

        # Query ETL metadata using Database module helper
        status_data = Database.get_etl_status()
        send_json_response(http, status_data)
    catch e
        @error "Failed to get ETL status" exception = e
        send_json_response(http, Dict("error" => string(e)); status = 500)
    end
    return nothing
end

function handle_dashboard_websocket(http::HTTP.Stream)
    send_json_response(http, "WebSocket not yet implemented"; status = 501)
    return nothing
end

function handle_events_stream(http::HTTP.Stream, req::HTTP.Request)
    query_params = parse_query_params(req)
    session_id = get(query_params, "id", nothing)

    # Set SSE headers
    HTTP.setstatus(http, 200)
    HTTP.setheader(http, "Content-Type" => "text/event-stream")
    HTTP.setheader(http, "Cache-Control" => "no-cache")
    HTTP.setheader(http, "Connection" => "keep-alive")
    HTTP.setheader(http, "Access-Control-Allow-Origin" => "*")
    HTTP.startwrite(http)

    # Send initial connection event
    write(http, "event: connected\n")
    write(http, "data: {\"status\":\"connected\"}\n\n")
    flush(http)

    # Track last seen event ID to only send new events
    last_event_time = now()

    try
        while isopen(http)
            # Get recent events from database
            events = if session_id !== nothing
                Database.get_events(; julia_session_id = session_id, limit = 50)
            else
                Database.get_events(; limit = 50)
            end

            # Filter to only new events (timestamp > last_event_time)
            for event in events
                # Parse timestamp from event
                event_timestamp = try
                    if haskey(event, "timestamp") && event["timestamp"] !== nothing
                        # Try parsing with milliseconds first, fall back to without
                        try
                            DateTime(event["timestamp"], "yyyy-mm-dd HH:MM:SS.sss")
                        catch
                            DateTime(event["timestamp"], "yyyy-mm-dd HH:MM:SS")
                        end
                    else
                        continue
                    end
                catch e
                    @debug "Failed to parse event timestamp" timestamp =
                        get(event, "timestamp", nothing) exception = e
                    continue
                end

                if event_timestamp > last_event_time
                    # Transform event to match frontend expectations
                    # Frontend expects: {type, id, timestamp, data, duration_ms}
                    # Database has: {event_type, julia_session_id, timestamp, data, duration_ms}
                    frontend_event = Dict(
                        "type" => get(event, "event_type", ""),
                        "id" => get(event, "julia_session_id", ""),
                        "timestamp" => get(event, "timestamp", ""),
                        "data" => get(event, "data", Dict()),
                        "duration_ms" => get(event, "duration_ms", nothing),
                    )

                    # Send event in SSE format
                    write(http, "event: update\n")
                    write(http, "data: $(JSON.json(frontend_event))\n\n")
                    flush(http)

                    last_event_time = max(last_event_time, event_timestamp)
                end
            end

            # Wait before next poll
            sleep(0.5)
        end
    catch e
        if !(e isa Base.IOError)
            @debug "SSE stream error" exception = (e, catch_backtrace())
        end
    end

    return nothing
end
