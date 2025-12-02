# ============================================================================
# MCP Notification Support
# ============================================================================

"""
    make_tools_changed_notification() -> Dict

Create a tools/list_changed notification message.
"""
function make_tools_changed_notification()
    return Dict(
        "jsonrpc" => "2.0",
        "method" => "notifications/tools/list_changed",
        "params" => Dict(),
    )
end

"""
    queue_notification(session_id::String, notification::Dict) -> Bool

Queue a notification for a specific MCP session. Returns true if queued successfully.
"""
function queue_notification(session_id::String, notification::Dict)
    lock(CLIENT_CONNECTIONS_LOCK) do
        channel = get(CLIENT_CONNECTIONS, session_id, nothing)
        if channel !== nothing && isopen(channel) && length(channel.data) < 10
            try
                put!(channel, notification)
                return true
            catch e
                @warn "Failed to queue notification" session_id = session_id error = e
            end
        end
        return false
    end
end

"""
    notify_client_tools_changed(mcp_session_id::String)

Send notifications/tools/list_changed to a specific MCP client.
This tells the client to refresh its tools list after its target Julia session changes.
"""
function notify_client_tools_changed(mcp_session_id::String)
    notification = make_tools_changed_notification()
    if queue_notification(mcp_session_id, notification)
        @info "Queued tools/list_changed notification" mcp_session_id = mcp_session_id
    else
        @debug "No active connection for MCP session" mcp_session_id = mcp_session_id
    end
end

"""
    notify_tools_list_changed(julia_session_id::Union{String,Nothing}=nothing)

Send notifications/tools/list_changed to relevant MCP clients.

If `julia_session_id` is provided, only notifies MCP sessions that:
- Target this specific Julia session
- Have no target (proxy-level sessions)

If `julia_session_id` is nothing, notifies all connected MCP clients.
"""
function notify_tools_list_changed(julia_session_id::Union{String,Nothing} = nothing)
    notification = make_tools_changed_notification()

    if julia_session_id === nothing
        # Broadcast to all
        @debug "Broadcasting tools/list_changed notification to all connected clients"
        lock(CLIENT_CONNECTIONS_LOCK) do
            for (session_id, _) in CLIENT_CONNECTIONS
                if queue_notification(session_id, notification)
                    @debug "Queued notification for client" session_id = session_id
                end
            end
        end
    else
        # Only notify MCP sessions targeting this Julia session or with no target
        @debug "Notifying relevant MCP clients about Julia session" julia_session_id =
            julia_session_id

        # Get MCP sessions that target this Julia session
        targeted_sessions = Database.get_mcp_sessions_by_target(julia_session_id)

        # Also get MCP sessions with no target (proxy-level)
        all_active_sessions = Database.get_active_mcp_sessions()
        untargeted_sessions = filter(
            s ->
                ismissing(s.target_julia_session_id) ||
                    s.target_julia_session_id === nothing,
            all_active_sessions,
        )

        # Combine and deduplicate
        sessions_to_notify = Set{String}()
        for s in targeted_sessions
            push!(sessions_to_notify, s.id)
        end
        for s in untargeted_sessions
            push!(sessions_to_notify, s.id)
        end

        for session_id in sessions_to_notify
            if queue_notification(session_id, notification)
                @debug "Queued notification for relevant client" session_id = session_id julia_session_id =
                    julia_session_id
            end
        end
    end
end

"""
    has_pending_notifications(mcp_session_id::String) -> Bool

Check if there are any pending notifications for the given MCP session.
"""
function has_pending_notifications(mcp_session_id::String)
    lock(CLIENT_CONNECTIONS_LOCK) do
        channel = get(CLIENT_CONNECTIONS, mcp_session_id, nothing)
        if channel === nothing || !isopen(channel)
            return false
        end
        return isready(channel)
    end
end

"""
    write_sse_event(http, data::Dict)

Write a single SSE event to the HTTP stream.
Format: event: message\\ndata: <json>\\n\\n
"""
function write_sse_event(http, data::Dict)
    json_str = JSON.json(data)
    write(http, "event: message\n")
    write(http, "data: ")
    write(http, json_str)
    write(http, "\n\n")
end

"""
    flush_pending_notifications_sse(mcp_session_id::String, http) -> Int

Flush any pending notifications from the channel to the HTTP stream using SSE format.
Used for MCP Streamable HTTP transport when response includes notifications.

Returns the number of notifications flushed.
"""
function flush_pending_notifications_sse(mcp_session_id::String, http)
    notifications_sent = 0

    lock(CLIENT_CONNECTIONS_LOCK) do
        channel = get(CLIENT_CONNECTIONS, mcp_session_id, nothing)
        if channel === nothing || !isopen(channel)
            return
        end

        # Drain all pending notifications from the channel
        while isready(channel)
            try
                notification = take!(channel)
                write_sse_event(http, notification)
                notifications_sent += 1
                @debug "Flushed notification as SSE event" mcp_session_id = mcp_session_id method =
                    get(notification, "method", "unknown")
            catch e
                @warn "Error flushing notification" mcp_session_id = mcp_session_id error =
                    e
                break
            end
        end
    end

    if notifications_sent > 0
        @info "Flushed pending notifications to client (SSE)" mcp_session_id =
            mcp_session_id count = notifications_sent
    end

    return notifications_sent
end
