"""
Request Buffering and Reconnection Logic

Handles buffering requests when Julia sessions are unavailable and replaying them when sessions reconnect.

Note: Julia sessions automatically register themselves with the proxy when they start up,
triggering the reconnection flow. No active polling is needed.
"""

"""
    send_reconnection_updates(target_id::String, request::Dict, http::HTTP.Stream, completion_channel::Channel{Bool}; timeout_seconds::Int=30)

Wait for session reconnection and request replay completion. Blocks until the buffered request
is successfully replayed or timeout expires. This keeps the HTTP stream open for the response.

The request is already buffered when this function is called. This function waits for the
completion_channel to be signaled by flush_pending_requests after writing the response.
"""
function send_reconnection_updates(
    target_id::String,
    request::Dict,
    http::HTTP.Stream,
    completion_channel::Channel{Bool};
    timeout_seconds::Int = 30,
)
    request_id = get(request, "id", nothing)
    @info "Request buffered, waiting for replay completion" target_id = target_id request_id =
        request_id timeout = timeout_seconds

    # Wait for completion channel to be signaled or timeout
    start_time = time()
    while (time() - start_time) < timeout_seconds
        # Check if completion signal is ready (non-blocking)
        if isready(completion_channel)
            success = try
                take!(completion_channel)
            catch
                false
            end

            if success
                @info "Buffered request completed successfully" target_id = target_id request_id =
                    request_id
            else
                @warn "Buffered request failed during replay" target_id = target_id request_id =
                    request_id
            end
            return
        end

        sleep(0.1)  # Check frequently for completion
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

    # Close completion channel
    try
        close(completion_channel)
    catch
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
            Tuple{Dict,HTTP.Stream,Channel{Bool}}[]
        end
    end

    @info "Failing all pending requests with error" target_id = target_id count =
        length(pending) error = error_message

    for (request, http, completion_channel) in pending
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

        # Signal completion and close channel
        try
            put!(completion_channel, false)
            close(completion_channel)
        catch
        end
    end
end
