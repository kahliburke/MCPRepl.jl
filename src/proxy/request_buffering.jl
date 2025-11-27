"""
Request Buffering and Reconnection Logic

Handles buffering requests when Julia sessions are unavailable and replaying them when sessions reconnect.

Note: Julia sessions automatically register themselves with the proxy when they start up,
triggering the reconnection flow. No active polling is needed.
"""

"""
    send_reconnection_updates(target_id::String, request::Dict, http::HTTP.Stream)

Placeholder for sending status updates to the client while waiting for reconnection.
Currently just logs the buffering. The HTTP stream is kept open and will receive
the response when the Julia session reconnects and the request is replayed.
"""
function send_reconnection_updates(target_id::String, request::Dict, http::HTTP.Stream)
    # The request is already buffered and the HTTP stream is stored
    # When the session reconnects and re-registers, flush_pending_requests() will
    # replay the request and send the response through this stream
    @debug "Request buffered, waiting for automatic reconnection" target_id = target_id request_id =
        get(request, "id", nothing)
end

"""
    flush_pending_requests_with_error(target_id::String, error_message::String)

Send error responses for all pending requests when a session permanently fails.
"""
function flush_pending_requests_with_error(target_id::String, error_message::String)
    pending = lock(PENDING_REQUESTS_LOCK) do
        if haskey(PENDING_REQUESTS, target_id)
            reqs = PENDING_REQUESTS[target_id]
            delete!(PENDING_REQUESTS, target_id)
            reqs
        else
            Tuple{Dict,HTTP.Stream}[]
        end
    end

    @info "Failing all pending requests with error" target_id = target_id count =
        length(pending) error = error_message

    for (request, http) in pending
        try
            send_jsonrpc_error(
                http,
                get(request, "id", nothing),
                -32003,
                error_message;
                status = 503,
            )
        catch e
            @error "Failed to send error response for buffered request" exception = e
        end
    end
end
