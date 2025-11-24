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