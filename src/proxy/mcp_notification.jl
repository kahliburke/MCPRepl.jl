# ============================================================================
# MCP Notification Support
# ============================================================================

"""
    notify_client_tools_changed(mcp_session_id::String)

Send notifications/tools/list_changed to a specific MCP client.
This tells the client to refresh its tools list after its target Julia session changes.
"""
function notify_client_tools_changed(mcp_session_id::String)
    notification = Dict(
        "jsonrpc" => "2.0",
        "method" => "notifications/tools/list_changed",
        "params" => Dict(),
    )

    lock(CLIENT_CONNECTIONS_LOCK) do
        channel = get(CLIENT_CONNECTIONS, mcp_session_id, nothing)
        if channel !== nothing
            try
                # Non-blocking put - if channel is full, skip
                if isopen(channel) && length(channel.data) < 10
                    put!(channel, notification)
                    @info "Sent tools/list_changed notification to client" mcp_session_id =
                        mcp_session_id
                end
            catch e
                @warn "Failed to send notification to client" mcp_session_id =
                    mcp_session_id error = e
            end
        else
            @debug "No active connection for MCP session" mcp_session_id = mcp_session_id
        end
    end
end

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