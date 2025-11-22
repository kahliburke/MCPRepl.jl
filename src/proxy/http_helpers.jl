"""
HTTP Response Helpers

Common functions to reduce duplication in HTTP response handling.
"""

"""
    send_json_response(http::HTTP.Stream, data; status::Int=200)

Send a JSON response with proper headers.
"""
function send_json_response(http::HTTP.Stream, data; status::Int=200)
    HTTP.setstatus(http, status)
    HTTP.setheader(http, "Content-Type" => "application/json")
    HTTP.startwrite(http)
    write(http, JSON.json(data))
    return nothing
end

"""
    send_jsonrpc_result(http::HTTP.Stream, id, result; status::Int=200)

Send a JSON-RPC success response.
"""
function send_jsonrpc_result(http::HTTP.Stream, id, result; status::Int=200)
    send_json_response(
        http,
        Dict("jsonrpc" => "2.0", "id" => id, "result" => result);
        status=status,
    )
end

"""
    send_jsonrpc_error(http::HTTP.Stream, id, code::Int, message::String; status::Int=200, data=nothing)

Send a JSON-RPC error response.
"""
function send_jsonrpc_error(
    http::HTTP.Stream,
    id,
    code::Int,
    message::String;
    status::Int=200,
    data=nothing,
)
    error_dict = Dict("code" => code, "message" => message)
    if data !== nothing
        error_dict["data"] = data
    end
    send_json_response(
        http,
        Dict("jsonrpc" => "2.0", "id" => id, "error" => error_dict);
        status=status,
    )
end

"""
    send_mcp_tool_result(http::HTTP.Stream, id, text::String; status::Int=200)

Send an MCP tool call result with text content.
"""
function send_mcp_tool_result(http::HTTP.Stream, id, text::String; status::Int=200)
    send_jsonrpc_result(
        http,
        id,
        Dict("content" => [Dict("type" => "text", "text" => text)]);
        status=status,
    )
end

"""
    send_empty_response(http::HTTP.Stream; status::Int=200)

Send an empty response with just status code.
"""
function send_empty_response(http::HTTP.Stream; status::Int=200)
    HTTP.setstatus(http, status)
    HTTP.setheader(http, "Content-Length" => "0")
    HTTP.startwrite(http)
    return nothing
end
