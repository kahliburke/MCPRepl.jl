"""
Dashboard HTTP API Routes

Handles all /dashboard/* HTTP endpoints for the MCPRepl proxy dashboard.
Extracted from the monolithic handle_request function for better maintainability.

This file is included within the Proxy module, so it has direct access to
Proxy module globals like JULIA_SESSION_REGISTRY, send_json_response, etc.
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
                agent_id = v
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
    sessions = lock(JULIA_SESSION_REGISTRY_LOCK) do
        result = Dict{String,Any}()
        for (id, conn) in JULIA_SESSION_REGISTRY
            result[id] = Dict(
                "id" => id,
                "port" => conn.port,
                "pid" => conn.pid,
                "status" => string(conn.status),
                "last_heartbeat" =>
                    Dates.format(conn.last_heartbeat, "yyyy-mm-dd HH:MM:SS"),
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

function handle_session_restart(http::HTTP.Stream, session_id::String)
    return handle_session_control(http, session_id, "restart") do conn, sid
        # Send restart request via exit tool
        params = Dict("name" => "exit", "arguments" => Dict("restart" => true))
        success = send_jsonrpc_to_session(conn, "tools/call", params)

        if success
            @info "Session restart requested" session_id = sid
        else
            @error "Failed to restart session" session_id = sid
        end

        return (success, false)  # success, don't delete from registry
    end
end

function handle_session_shutdown(http::HTTP.Stream, session_id::String)
    return handle_session_control(http, session_id, "shutdown") do conn, sid
        # If disconnected, just unregister it
        if conn.status == :disconnected
            @info "Unregistered disconnected session" session_id = sid
            return (true, true)  # success, delete from registry
        end

        # Otherwise, try to send shutdown request
        success = send_jsonrpc_to_session(conn, "shutdown", Dict())

        if success
            @info "Session shutdown requested" session_id = sid
        else
            @warn "Failed to send shutdown request, unregistering anyway" session_id = sid
        end

        return (true, true)  # always success (unregister even if write fails), always delete
    end
end

function handle_tools_list(http::HTTP.Stream, agent_id::Union{String,Nothing})
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
                    if haskey(agent_data, "result") && haskey(agent_data["result"], "tools")
                        result["agent_tools"][agent_id] = agent_data["result"]["tools"]
                    end
                end
            catch e
                @warn "Failed to fetch tools from agent" agent_id = agent_id exception = e
            end
        end
    end

    send_json_response(http, result)
    return nothing
end

# Database-backed handlers - these will query the Database module
function handle_events(http::HTTP.Stream, req::HTTP.Request)
    query_params = parse_query_params(req)
    limit = get_int_param(query_params, "limit", "100")
    offset = get_int_param(query_params, "offset", "0")

    # get_events uses keyword arguments
    events = Database.get_events(; limit = limit, offset = offset)
    send_json_response(http, events)
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
        # Import ETL module and run transformation
        include(joinpath(@__DIR__, "..", "database_etl.jl"))
        DatabaseETL.run_etl_pipeline()
        send_json_response(
            http,
            Dict("status" => "success", "message" => "ETL pipeline completed"),
        )
    catch e
        @error "ETL pipeline failed" exception = e
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
                        DateTime(event["timestamp"], "yyyy-mm-dd HH:MM:SS")
                    else
                        continue
                    end
                catch
                    continue
                end

                if event_timestamp > last_event_time
                    # Send event in SSE format
                    write(http, "event: update\n")
                    write(http, "data: $(JSON.json(event))\n\n")
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
