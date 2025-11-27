"""
Dashboard Route Helper Functions

Reusable patterns for dashboard API handlers to reduce code duplication.
"""

"""
    parse_query_params(req::HTTP.Request) -> Dict

Extract and parse query parameters from an HTTP request.
"""
function parse_query_params(req::HTTP.Request)
    uri = HTTP.URI(req.target)
    return HTTP.queryparams(uri.query)
end

"""
    get_int_param(query_params::Dict, key::String, default::String) -> Int

Parse an integer parameter from query params with a default value.
"""
function get_int_param(query_params::Dict, key::String, default::String)
    return parse(Int, get(query_params, key, default))
end

"""
    require_session_id(http::HTTP.Stream, query_params::Dict) -> Union{String, Nothing}

Validate that session_id parameter is present and non-empty.
Returns the session_id if valid, or sends error response and returns nothing.
"""
function require_session_id(http::HTTP.Stream, query_params::Dict)
    session_id = get(query_params, "session_id", "")
    if isempty(session_id)
        send_json_response(http, Dict("error" => "session_id required"); status = 400)
        return nothing
    end
    return session_id
end

"""
    handle_database_query(http::HTTP.Stream, database_func::Function, args...)

Generic handler for database query endpoints.
Calls the database function, sends JSON response, and handles errors uniformly.
"""
function handle_database_query(http::HTTP.Stream, database_func::Function, args...)
    try
        data = database_func(args...)
        send_json_response(http, data)
    catch e
        @error "Database query failed" exception = e
        send_json_response(http, Dict("error" => string(e)); status = 500)
    end
    return nothing
end

"""
    handle_analytics_with_days(http::HTTP.Stream, req::HTTP.Request, database_func::Function; default_days::Int=7)

Generic handler for analytics endpoints that accept a 'days' parameter.
"""
function handle_analytics_with_days(
    http::HTTP.Stream,
    req::HTTP.Request,
    database_func::Function;
    default_days::Int = 7,
)
    query_params = parse_query_params(req)
    days = get_int_param(query_params, "days", string(default_days))
    return handle_database_query(http, database_func, days)
end

"""
    handle_session_query(http::HTTP.Stream, req::HTTP.Request, database_func::Function)

Generic handler for session-specific database queries.
Validates session_id parameter and calls the database function.
"""
function handle_session_query(http::HTTP.Stream, req::HTTP.Request, database_func::Function)
    query_params = parse_query_params(req)
    session_id = require_session_id(http, query_params)
    if session_id === nothing
        return nothing
    end
    return handle_database_query(http, database_func, session_id)
end

"""
    send_jsonrpc_to_session(conn, method::String, params::Dict) -> Bool

Send a JSON-RPC request to a Julia session via HTTP.
Returns true on success, false on failure.
"""
function send_jsonrpc_to_session(conn, method::String, params::Dict)
    try
        request = Dict(
            "jsonrpc" => "2.0",
            "id" => rand(1:999999),
            "method" => method,
            "params" => params,
        )
        backend_url = "http://127.0.0.1:$(conn.port)/"
        response = HTTP.post(
            backend_url,
            ["Content-Type" => "application/json"],
            JSON.json(request);
            readtimeout = 5,
            connect_timeout = 2,
            status_exception = false,
        )
        return response.status == 200
    catch e
        @warn "Failed to send JSON-RPC to session" session_uuid = conn.uuid session_name =
            conn.name error = e
        return false
    end
end

"""
    handle_session_control(action_func::Function, http::HTTP.Stream, session_id::String, action_name::String)

Generic handler for session control operations (restart, shutdown, etc.).

The action_func is called with (session, session_id) and should return (success::Bool, should_delete::Bool).
Note: action_func is first to support do-block syntax.
"""
function handle_session_control(
    action_func::Function,
    http::HTTP.Stream,
    session_id::String,
    action_name::String,
)
    # Get session from database
    session = get_julia_session(session_id)

    if session === nothing
        @warn "Session not found for $action_name" session_id
        send_json_response(
            http,
            Dict("success" => false, "session_id" => session_id);
            status = 404,
        )
        return nothing
    end

    # Execute action and determine if we should unregister
    success, should_delete = action_func(session, session_id)

    # Properly unregister the session if requested
    if should_delete && success
        unregister_julia_session(session_id)
    end

    send_json_response(
        http,
        Dict("success" => success, "session_id" => session_id);
        status = success ? 200 : 404,
    )
    return nothing
end
