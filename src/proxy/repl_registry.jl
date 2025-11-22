"""
REPL Registry Management

Manages the registry of connected Julia REPL sessions and MCP client sessions.
"""

# REPL Connection tracking
mutable struct REPLConnection
    id::String                          # Unique identifier (project name, agent name)
    port::Int                           # REPL's MCP server port
    pid::Union{Int,Nothing}            # REPL process ID
    status::Symbol                      # :ready, :disconnected, :reconnecting, :stopped
    last_heartbeat::DateTime            # Last time we heard from this REPL
    metadata::Dict{String,Any}         # Additional info (project path, etc.)
    last_error::Union{String,Nothing}  # Last error message if any
    missed_heartbeats::Int             # Counter for consecutive missed heartbeats
    pending_requests::Vector{Tuple{Dict,HTTP.Stream}}  # Buffered requests during reconnection
    disconnect_time::Union{DateTime,Nothing}  # When REPL disconnected
end

# Global registries
const REPL_REGISTRY = Dict{String,REPLConnection}()
const REPL_REGISTRY_LOCK = ReentrantLock()
const SESSION_REGISTRY = Dict{String,MCPSession}()  # Track MCP client sessions
const SESSION_LOCK = ReentrantLock()

"""
    register_repl(id::String, port::Int; pid::Union{Int,Nothing}=nothing, metadata::Dict=Dict())

Register a REPL with the proxy server so it can route requests to it.
"""
function register_repl(
    id::String,
    port::Int;
    pid::Union{Int,Nothing}=nothing,
    metadata::Dict=Dict(),
    flush_pending_fn=nothing,
    notify_fn=nothing,
)
    # Check for pending requests and copy them outside the lock
    pending = lock(REPL_REGISTRY_LOCK) do
        # Check if this is a re-registration (reconnection)
        existing = get(REPL_REGISTRY, id, nothing)
        pending_requests =
            existing !== nothing ? existing.pending_requests : Tuple{Dict,HTTP.Stream}[]

        if existing !== nothing && !isempty(pending_requests)
            @info "REPL re-registering with buffered requests" id = id port = port pid = pid buffer_size = length(pending_requests)
        end

        REPL_REGISTRY[id] = REPLConnection(
            id,
            port,
            pid,
            :ready,
            now(),
            metadata,
            nothing,
            0,
            Tuple{Dict,HTTP.Stream}[],  # Start with empty buffer
            nothing,
        )
        @info "REPL registered with proxy" id = id port = port pid = pid

        # Register session in database
        try
            Database.register_session!(id, "active"; metadata=metadata)
        catch e
            @warn "Failed to register session in database" id = id exception = e
        end

        # Log registration event to dashboard
        Dashboard.log_event(
            id,
            Dashboard.AGENT_START,
            Dict("port" => port, "pid" => pid, "metadata" => metadata),
        )

        # Return pending requests to process outside the lock
        pending_requests
    end

    # If there were pending requests, flush them to the newly connected REPL
    if !isempty(pending) && flush_pending_fn !== nothing
        @async flush_pending_fn(id, pending)
    end

    # Notify all connected MCP clients that tools list has changed
    if notify_fn !== nothing
        notify_fn()
    end
end

"""
    unregister_repl(id::String)

Remove a REPL from the proxy registry.
"""
function unregister_repl(id::String)
    lock(REPL_REGISTRY_LOCK) do
        if haskey(REPL_REGISTRY, id)
            delete!(REPL_REGISTRY, id)
            Dashboard.log_event(id, Dashboard.AGENT_STOP, Dict())
            @info "REPL unregistered from proxy" id = id
        end
    end
end

"""
    get_repl(id::String) -> Union{REPLConnection, Nothing}

Get a REPL connection by ID.
"""
function get_repl(id::String)
    lock(REPL_REGISTRY_LOCK) do
        get(REPL_REGISTRY, id, nothing)
    end
end

"""
    list_repls() -> Vector{REPLConnection}

List all registered REPLs.
"""
function list_repls()
    lock(REPL_REGISTRY_LOCK) do
        collect(values(REPL_REGISTRY))
    end
end

"""  
    update_repl_status(id::String, status::Symbol; error::Union{String,Nothing}=nothing)

Update the status of a registered REPL, optionally storing error information.
"""
function update_repl_status(
    id::String,
    status::Symbol;
    error::Union{String,Nothing}=nothing,
    process_pending_fn=nothing,
)
    lock(REPL_REGISTRY_LOCK) do
        if haskey(REPL_REGISTRY, id)
            REPL_REGISTRY[id].status = status
            REPL_REGISTRY[id].last_heartbeat = now()
            if error !== nothing
                REPL_REGISTRY[id].last_error = error
                REPL_REGISTRY[id].missed_heartbeats += 1
            elseif status == :ready
                # Clear error and reset counter when back to ready
                REPL_REGISTRY[id].last_error = nothing
                REPL_REGISTRY[id].missed_heartbeats = 0
                REPL_REGISTRY[id].disconnect_time = nothing

                # Process any pending requests if we just reconnected
                if !isempty(REPL_REGISTRY[id].pending_requests) &&
                   process_pending_fn !== nothing
                    @info "REPL reconnected, processing buffered requests" id = id buffer_size =
                        length(REPL_REGISTRY[id].pending_requests)
                    @async process_pending_fn(id)
                end
            end
        end
    end
end

# ============================================================================
# MCP Session Management
# ============================================================================

"""
    create_mcp_session(target_repl_id::Union{String,Nothing}) -> MCPSession

Create a new MCP session for a client connection.
"""
function create_mcp_session(target_repl_id::Union{String,Nothing})
    session = MCPSession(target_repl_id=target_repl_id)

    lock(SESSION_LOCK) do
        SESSION_REGISTRY[session.id] = session
    end

    @info "Created MCP session" session_id = session.id target_repl_id = target_repl_id
    return session
end

"""
    get_mcp_session(session_id::String) -> Union{MCPSession, Nothing}

Get an MCP session by its ID.
"""
function get_mcp_session(session_id::String)
    lock(SESSION_LOCK) do
        return get(SESSION_REGISTRY, session_id, nothing)
    end
end

"""
    delete_mcp_session!(session_id::String)

Delete an MCP session.
"""
function delete_mcp_session!(session_id::String)
    lock(SESSION_LOCK) do
        if haskey(SESSION_REGISTRY, session_id)
            session = SESSION_REGISTRY[session_id]
            close_session!(session)
            delete!(SESSION_REGISTRY, session_id)
            @info "Deleted MCP session" session_id = session_id
        end
    end
end

"""
    cleanup_inactive_sessions!(max_age::Dates.Period=Dates.Hour(1))

Remove sessions that haven't been active for longer than max_age.
"""
function cleanup_inactive_sessions!(max_age::Dates.Period=Dates.Hour(1))
    cutoff = now() - max_age
    lock(SESSION_LOCK) do
        inactive =
            [id for (id, session) in SESSION_REGISTRY if session.last_activity < cutoff]
        for id in inactive
            session = SESSION_REGISTRY[id]
            close_session!(session)
            delete!(SESSION_REGISTRY, id)
            @info "Cleaned up inactive session" session_id = id
        end
    end
end
