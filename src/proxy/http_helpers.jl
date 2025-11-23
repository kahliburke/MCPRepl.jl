"""
HTTP Response Helpers

Common functions for HTTP response handling with database logging support.
These functions integrate with the Database module to log all interactions.
"""

"""
    send_json_response(http::HTTP.Stream, data; status::Int=200, mcp_session_id=nothing, julia_session_id=nothing, request_id=nothing)

Send a JSON response with proper headers and log to database.

# Arguments
- `http::HTTP.Stream`: The HTTP stream to write to
- `data`: The data to serialize as JSON
- `status::Int=200`: HTTP status code
- `mcp_session_id::Union{String,Nothing}=nothing`: MCP client session ID for logging
- `julia_session_id::Union{String,Nothing}=nothing`: Julia REPL session ID for logging  
- `request_id=nothing`: Request ID for correlation

# Example
```julia
send_json_response(http, Dict("result" => "ok"); status=200, mcp_session_id="client-123")
```
"""
function send_json_response(
    http::HTTP.Stream,
    data;
    status::Int = 200,
    mcp_session_id::Union{String,Nothing} = nothing,
    julia_session_id::Union{String,Nothing} = nothing,
    request_id = nothing,
)
    json_str = JSON.json(data)

    # Log outbound response (function must be defined in parent scope)
    try
        log_db_interaction(
            "outbound",
            "response",
            json_str;
            mcp_session_id = mcp_session_id,
            julia_session_id = julia_session_id,
            request_id = request_id,
            method = nothing,
            http_status_code = status,
        )
    catch e
        # Don't fail the response if logging fails
        @debug "Failed to log response to database" exception = e
    end

    HTTP.setstatus(http, status)
    HTTP.setheader(http, "Content-Type" => "application/json")
    HTTP.startwrite(http)
    write(http, json_str)
    return nothing
end

"""
    send_jsonrpc_result(http::HTTP.Stream, id, result; status::Int=200, session_id::String="proxy")

Send a JSON-RPC success response and log to database.

# Arguments
- `http::HTTP.Stream`: The HTTP stream to write to
- `id`: Request ID from the JSON-RPC request
- `result`: The result data to return
- `status::Int=200`: HTTP status code
- `session_id::String="proxy"`: Session ID for logging (deprecated, use mcp_session_id)

# Example
```julia
send_jsonrpc_result(http, 123, Dict("value" => 42))
```
"""
function send_jsonrpc_result(
    http::HTTP.Stream,
    id,
    result;
    status::Int = 200,
    session_id::String = "proxy",
)
    send_json_response(
        http,
        Dict("jsonrpc" => "2.0", "id" => id, "result" => result);
        status = status,
        mcp_session_id = session_id,
        request_id = id,
    )
end

"""
    send_jsonrpc_error(http::HTTP.Stream, id, code::Int, message::String; status::Int=200, data=nothing, session_id::String="proxy")

Send a JSON-RPC error response and log to database.

# Arguments
- `http::HTTP.Stream`: The HTTP stream to write to
- `id`: Request ID from the JSON-RPC request
- `code::Int`: JSON-RPC error code (e.g., -32600 for invalid request)
- `message::String`: Human-readable error message
- `status::Int=200`: HTTP status code (200 for JSON-RPC errors, 400+ for HTTP errors)
- `data=nothing`: Optional additional error data
- `session_id::String="proxy"`: Session ID for logging

# Standard JSON-RPC Error Codes
- `-32700`: Parse error
- `-32600`: Invalid request
- `-32601`: Method not found
- `-32602`: Invalid params
- `-32603`: Internal error
- `-32000` to `-32099`: Server error (application-defined)

# Example
```julia
send_jsonrpc_error(http, 123, -32602, "Invalid params"; data=Dict("missing" => ["id"]))
```
"""
function send_jsonrpc_error(
    http::HTTP.Stream,
    id,
    code::Int,
    message::String;
    status::Int = 200,
    data = nothing,
    session_id::String = "proxy",
)
    error_dict = Dict("code" => code, "message" => message)
    if data !== nothing
        error_dict["data"] = data
    end
    send_json_response(
        http,
        Dict("jsonrpc" => "2.0", "id" => id, "error" => error_dict);
        status = status,
        mcp_session_id = session_id,
        request_id = id,
    )
end

"""
    send_mcp_tool_result(http::HTTP.Stream, id, text::String; status::Int=200, session_id::String="proxy")

Send an MCP tool call result with text content and log to database.

This is a convenience function for the common case of returning text content from a tool execution.

# Arguments
- `http::HTTP.Stream`: The HTTP stream to write to
- `id`: Request ID from the tool call
- `text::String`: The text content to return
- `status::Int=200`: HTTP status code
- `session_id::String="proxy"`: Session ID for logging

# Example
```julia
send_mcp_tool_result(http, 123, "Command executed successfully")
```
"""
function send_mcp_tool_result(
    http::HTTP.Stream,
    id,
    text::String;
    status::Int = 200,
    session_id::String = "proxy",
)
    send_jsonrpc_result(
        http,
        id,
        Dict("content" => [Dict("type" => "text", "text" => text)]);
        status = status,
        session_id = session_id,
    )
end

"""
    send_empty_response(http::HTTP.Stream; status::Int=200)

Send an empty response with just status code.

Used for endpoints that don't need to return data (e.g., successful DELETE requests).

# Arguments
- `http::HTTP.Stream`: The HTTP stream to write to
- `status::Int=200`: HTTP status code

# Example
```julia
send_empty_response(http; status=204)  # No Content
```
"""
function send_empty_response(http::HTTP.Stream; status::Int = 200)
    HTTP.setstatus(http, status)
    HTTP.setheader(http, "Content-Length" => "0")
    HTTP.startwrite(http)
    return nothing
end
