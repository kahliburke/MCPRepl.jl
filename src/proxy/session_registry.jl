"""
REPL Registry Management

Manages the registry of connected Julia REPL sessions and MCP client sessions.
Integrates with Database and Dashboard modules for logging and monitoring.

This module defines the core data structures and functions for tracking active
REPL connections, their status, and associated metadata. It also manages MCP
client sessions that connect to the proxy.
"""

# ============================================================================
# Data Structures
# ============================================================================

"""
    REPLConnection

Represents a connected Julia REPL session.

# Fields
- `id::String`: Unique identifier (project name, agent name)
- `port::Int`: REPL's MCP server port
- `pid::Union{Int,Nothing}`: REPL process ID
- `status::Symbol`: Connection status (:ready, :disconnected, :reconnecting, :stopped)
- `last_heartbeat::DateTime`: Last time we heard from this REPL
- `metadata::Dict{String,Any}`: Additional info (project path, etc.)
- `last_error::Union{String,Nothing}`: Last error message if any
- `missed_heartbeats::Int`: Counter for consecutive missed heartbeats
- `pending_requests::Vector{Tuple{Dict,HTTP.Stream}}`: Buffered requests during reconnection
- `disconnect_time::Union{DateTime,Nothing}`: When REPL disconnected
"""
mutable struct JuliaSession
    id::String
    port::Int
    pid::Union{Int,Nothing}
    status::Symbol
    last_heartbeat::DateTime
    metadata::Dict{String,Any}
    last_error::Union{String,Nothing}
    missed_heartbeats::Int
    pending_requests::Vector{Tuple{Dict,HTTP.Stream}}
    disconnect_time::Union{DateTime,Nothing}
end

# ============================================================================
# Global Registries
# ============================================================================

# Julia session registry - tracks all connected Julia sessions
# Note: These are initialized in the parent Proxy module's __init__() function
# to avoid precompilation issues with Dict and ReentrantLock
JULIA_SESSION_REGISTRY = Dict{String,JuliaSession}()
JULIA_SESSION_REGISTRY_LOCK = ReentrantLock()

# MCP session registry - tracks all connected MCP clients
MCP_SESSION_REGISTRY = Dict{String,MCPSession}()
MCP_SESSION_LOCK = ReentrantLock()

# ============================================================================
# REPL Registration Functions
# ============================================================================

"""
    register_julia_session(id::String, port::Int; pid=nothing, metadata=Dict()) -> (Bool, Union{String,Nothing})

Register a Julia session with the proxy server.

This function:
1. Validates parameters (using validation module)
2. Creates/updates JuliaSession in registry
3. Logs to database (Julia session + event)
4. Logs to dashboard
5. Flushes any pending requests
6. Notifies MCP clients of tool changes

# Arguments
- `id::String`: Unique identifier for this Julia session
- `port::Int`: Port where the Session's MCP server is listening
- `pid::Union{Int,Nothing}=nothing`: Process ID of the Julia session
- `metadata::Dict=Dict()`: Additional metadata (project path, etc.)

# Returns
- `(true, nothing)` on success
- `(false, error_message)` on validation failure

# Example
```julia
success, error = register_julia_session("my-project", 8080; pid=12345)
if success
    println("Julia session registered successfully")
end
```
"""
function register_julia_session(
    id::String,
    port::Int;
    pid::Union{Int,Nothing} = nothing,
    metadata::Dict = Dict(),
)
    # This function needs validate_registration_params, flush_pending_requests,
    # notify_tools_list_changed, log_db_event from parent scope
    # Will be defined when included into proxy.jl

    # Validate input parameters
    valid, error_msg = validate_registration_params(id, port, pid)
    if !valid
        @warn "REPL registration validation failed" id = id port = port pid = pid error =
            error_msg
        return (false, error_msg)
    end

    # Check for pending requests and copy them outside the lock
    pending = lock(JULIA_SESSION_REGISTRY_LOCK) do
        # Check if this is a re-registration (reconnection)
        existing = get(JULIA_SESSION_REGISTRY, id, nothing)
        pending_requests =
            existing !== nothing ? existing.pending_requests : Tuple{Dict,HTTP.Stream}[]

        if existing !== nothing && !isempty(pending_requests)
            @info "Julia session re-registering with buffered requests" id = id port = port pid = pid buffer_size = length(pending_requests)
        end

        JULIA_SESSION_REGISTRY[id] = JuliaSession(
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
        @info "Julia session registered with proxy" id = id port = port pid = pid

        # Register Julia session in database
        try
            Database.register_julia_session!(
                id,
                id,  # Use ID as name (logical name)
                "ready";
                port = port,
                pid = pid,
                metadata = metadata,
            )
            log_db_event(
                "julia_session.registered",
                Dict("port" => port, "pid" => pid, "metadata" => metadata);
                julia_session_id = id,
            )
        catch e
            @warn "Failed to register session in database" id = id exception =
                (e, catch_backtrace())
            # Don't fail registration if database logging fails
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
    # Do this outside the lock to avoid holding it during HTTP requests
    if !isempty(pending)
        @async flush_pending_requests(id, pending)
    end

    # Notify all connected MCP clients that tools list has changed
    notify_tools_list_changed()

    return (true, nothing)
end

"""
    unregister_julia_session(id::String)

Remove a Julia from the proxy registry.

Logs the unregistration to both database and dashboard.
"""
function unregister_julia_session(id::String)
    lock(JULIA_SESSION_REGISTRY_LOCK) do
        if haskey(JULIA_SESSION_REGISTRY, id)
            repl = JULIA_SESSION_REGISTRY[id]
            delete!(JULIA_SESSION_REGISTRY, id)

            # Log stop event to dashboard
            Dashboard.log_event(id, Dashboard.AGENT_STOP, Dict())

            # Log unregistration to database
            log_db_event(
                "julia_session.unregistered",
                Dict(
                    "port" => repl.port,
                    "pid" => repl.pid,
                    "status" => string(repl.status),
                );
                julia_session_id = id,
            )

            @info "Julia session unregistered from proxy" id = id
        end
    end
end

"""
    get_julia_session(id::String) -> Union{JuliaSession, Nothing}

Get a Julia session by ID. Thread-safe.
"""
function get_julia_session(id::String)
    lock(JULIA_SESSION_REGISTRY_LOCK) do
        get(JULIA_SESSION_REGISTRY, id, nothing)
    end
end

"""
    list_julia_sessions() -> Vector{JuliaSession}

List all registered Julia sessions. Thread-safe.
"""
function list_julia_sessions()
    lock(JULIA_SESSION_REGISTRY_LOCK) do
        collect(values(JULIA_SESSION_REGISTRY))
    end
end

"""  
    update_julia_session_status(id::String, status::Symbol; error=nothing)

Update the status of a registered Julia session, optionally storing error information.

When status changes to :ready, automatically processes any pending requests.
"""
function update_julia_session_status(
    id::String,
    status::Symbol;
    error::Union{String,Nothing} = nothing,
)
    lock(JULIA_SESSION_REGISTRY_LOCK) do
        if haskey(JULIA_SESSION_REGISTRY, id)
            JULIA_SESSION_REGISTRY[id].status = status
            JULIA_SESSION_REGISTRY[id].last_heartbeat = now()
            if error !== nothing
                JULIA_SESSION_REGISTRY[id].last_error = error
                JULIA_SESSION_REGISTRY[id].missed_heartbeats += 1
            elseif status == :ready
                # Clear error and reset counter when back to ready
                JULIA_SESSION_REGISTRY[id].last_error = nothing
                JULIA_SESSION_REGISTRY[id].missed_heartbeats = 0
                JULIA_SESSION_REGISTRY[id].disconnect_time = nothing

                # Process any pending requests if we just reconnected
                if !isempty(JULIA_SESSION_REGISTRY[id].pending_requests)
                    @info "Julia session reconnected, processing buffered requests" id = id buffer_size =
                        length(JULIA_SESSION_REGISTRY[id].pending_requests)
                    @async process_pending_requests(id)
                end
            end
        end
    end
end

# ============================================================================
# MCP Session Management
# ============================================================================

"""
    create_mcp_session(target_julia_session_id::Union{String,Nothing}) -> MCPSession

Create a new MCP session for a client connection.

Registers the session in the global registry and logs creation.
"""
function create_mcp_session(target_julia_session_id::Union{String,Nothing})
    session = MCPSession(target_julia_session_id = target_julia_session_id)

    lock(MCP_SESSION_LOCK) do
        MCP_SESSION_REGISTRY[session.id] = session
    end

    @info "Created MCP session" session_id = session.id target_julia_session_id =
        target_julia_session_id
    return session
end

"""
    get_mcp_session(session_id::String) -> Union{MCPSession, Nothing}

Get an MCP session by its ID. Thread-safe.
"""
function get_mcp_session(session_id::String)
    lock(MCP_SESSION_LOCK) do
        return get(MCP_SESSION_REGISTRY, session_id, nothing)
    end
end

"""
    delete_mcp_session!(session_id::String)

Delete an MCP session and clean up resources.
"""
function delete_mcp_session!(session_id::String)
    lock(MCP_SESSION_LOCK) do
        if haskey(MCP_SESSION_REGISTRY, session_id)
            session = MCP_SESSION_REGISTRY[session_id]
            close_session!(session)
            delete!(MCP_SESSION_REGISTRY, session_id)
            @info "Deleted MCP session" session_id = session_id
        end
    end
end

"""
    cleanup_inactive_sessions!(max_age::Dates.Period=Dates.Hour(1))

Remove MCP sessions that haven't been active for longer than max_age.

Useful for periodic cleanup of stale client connections.
"""
function cleanup_inactive_sessions!(max_age::Dates.Period = Dates.Hour(1))
    cutoff = now() - max_age
    lock(MCP_SESSION_LOCK) do
        inactive =
            [id for (id, session) in MCP_SESSION_REGISTRY if session.last_activity < cutoff]
        for id in inactive
            session = MCP_SESSION_REGISTRY[id]
            close_session!(session)
            delete!(MCP_SESSION_REGISTRY, id)
            @info "Cleaned up inactive session" session_id = id
        end
    end
end
