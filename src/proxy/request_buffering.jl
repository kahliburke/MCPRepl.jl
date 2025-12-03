"""
Request Buffering and Reconnection Logic

Handles buffering requests when Julia sessions are unavailable and replaying them when sessions reconnect.

Note: Julia sessions automatically register themselves with the proxy when they start up,
triggering the reconnection flow. No active polling is needed.
"""

"""
    send_reconnection_updates(target_id::String, request::Dict, http::HTTP.Stream; timeout_seconds::Int=30)

Wait for session reconnection with a timeout. If session doesn't reconnect within timeout,
send an error response to the client.

The request is already buffered when this function is called. If the session reconnects,
flush_pending_requests() will replay the request. If timeout expires, we send an error.
"""
function send_reconnection_updates(
    target_id::String,
    request::Dict,
    http::HTTP.Stream;
    timeout_seconds::Int = 30,
)
    request_id = get(request, "id", nothing)
    @info "Request buffered, waiting for reconnection" target_id = target_id request_id =
        request_id timeout = timeout_seconds

    # Wait for reconnection with timeout, checking status periodically
    start_time = time()
    while (time() - start_time) < timeout_seconds
        # Check if session has reconnected
        session = get_julia_session(target_id)
        if session !== nothing && session.status == "ready"
            # Session is back - the buffered request will be replayed by flush_pending_requests
            @debug "Session reconnected, request will be replayed" target_id = target_id request_id =
                request_id
            return
        end

        # Check if request was already handled (removed from buffer)
        still_buffered = lock(PENDING_REQUESTS_LOCK) do
            if haskey(PENDING_REQUESTS, target_id)
                any(r -> get(r[1], "id", nothing) == request_id, PENDING_REQUESTS[target_id])
            else
                false
            end
        end

        if !still_buffered
            # Request was already handled by flush_pending_requests
            @debug "Buffered request was handled" target_id = target_id request_id =
                request_id
            return
        end

        sleep(1)
    end

    # Timeout expired - remove this specific request from buffer and send error
    @warn "Reconnection timeout expired" target_id = target_id request_id = request_id timeout =
        timeout_seconds

    # Remove only this request from the buffer
    lock(PENDING_REQUESTS_LOCK) do
        if haskey(PENDING_REQUESTS, target_id)
            filter!(
                r -> get(r[1], "id", nothing) != request_id,
                PENDING_REQUESTS[target_id],
            )
        end
    end

    # Send error response
    try
        send_jsonrpc_error(
            http,
            request_id,
            -32003,
            "Julia session did not reconnect within $(timeout_seconds) seconds. Please restart the session.";
            status = 503,
        )
    catch e
        @error "Failed to send timeout error response" exception = e
    end
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
