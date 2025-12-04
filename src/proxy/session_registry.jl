"""
REPL Registry Management

Manages Julia REPL sessions and MCP client sessions using the database as the single source of truth.
Only non-serializable runtime data (HTTP streams for pending requests) is kept in memory.

This module defines functions for session registration, lookup, and request buffering.
All session metadata is stored in and retrieved from the database.
"""

# ============================================================================
# In-Memory Runtime Data (Non-Serializable Only)
# ============================================================================

# Pending requests buffer - maps session UUID to buffered requests with HTTP streams
# This is the ONLY in-memory state; everything else comes from the database
PENDING_REQUESTS = Dict{String,Vector{Tuple{Dict,HTTP.Stream}}}()
PENDING_REQUESTS_LOCK = ReentrantLock()

# ============================================================================
# Julia Session Functions (Database-Backed)
# ============================================================================

"""
    register_julia_session(uuid::String, name::String, port::Int; pid=nothing, metadata=Dict()) -> (Bool, Union{String,Nothing})

Register a Julia session with the proxy server.

This function:
1. Validates parameters
2. Writes session to database
3. Logs events
4. Flushes any pending requests
5. Notifies MCP clients of tool changes

# Arguments
- `uuid::String`: Unique identifier (UUID) for this session
- `name::String`: Logical name for this Julia session (project name, agent name)
- `port::Int`: Port where the Session's MCP server is listening
- `pid::Union{Int,Nothing}=nothing`: Process ID of the Julia session
- `metadata::Dict=Dict()`: Additional metadata (project path, etc.)

# Returns
- `(true, nothing)` on success
- `(false, error_message)` on validation failure
"""
function register_julia_session(
    uuid::String,
    name::String,
    port::Int;
    pid::Union{Int,Nothing} = nothing,
    metadata::Dict = Dict(),
)
    # Validate input parameters
    valid, error_msg = validate_registration_params(name, port, pid)
    if !valid
        @warn "REPL registration validation failed" uuid = uuid name = name port = port pid =
            pid error = error_msg
        return (false, error_msg)
    end

    # Check if this is a re-registration or restart
    existing_sessions = Database.get_julia_sessions_by_name(name)
    is_reconnection = any(s -> s.id == uuid, existing_sessions)
    old_session_uuids = String[]

    # Check for restart case (same name, different UUID) - collect ALL old sessions
    for session in existing_sessions
        if session.id != uuid
            push!(old_session_uuids, session.id)
            @info "Detected session restart: same name, different UUID" name = name old_uuid =
                session.id new_uuid = uuid
        end
    end

    if is_reconnection
        @info "Julia session re-registering (same UUID)" uuid = uuid name = name port = port pid =
            pid
    elseif !isempty(old_session_uuids)
        @info "Julia session restarting (new UUID)" old_uuids = old_session_uuids new_uuid =
            uuid name = name port = port pid = pid
    else
        @info "Julia session registering (new)" uuid = uuid name = name port = port pid =
            pid
    end

    # Check for log file
    log_dir = abspath(joinpath(dirname(@__DIR__), "logs"))
    log_file_path = abspath(joinpath(log_dir, "session_$(uuid).log"))
    detected_log_file = isfile(log_file_path) ? log_file_path : nothing

    # Add log file info to metadata if it exists
    enhanced_metadata = copy(metadata)
    if detected_log_file !== nothing
        enhanced_metadata["log_file"] = detected_log_file
        enhanced_metadata["started_by_proxy"] = true
    end

    # Register/update in database
    try
        Database.register_julia_session!(
            uuid,
            name,
            "ready";
            port = port,
            pid = pid,
            metadata = enhanced_metadata,
        )
        log_db_event(
            "julia_session.registered",
            Dict(
                "port" => port,
                "pid" => pid,
                "metadata" => enhanced_metadata,
                "name" => name,
            );
            julia_session_id = uuid,
        )
    catch e
        @warn "Failed to register session in database" name = name uuid = uuid exception =
            (e, catch_backtrace())
        return (false, "Database error: $(sprint(showerror, e))")
    end

    # Log to dashboard
    Dashboard.log_event(
        uuid,
        Dashboard.AGENT_START,
        Dict("port" => port, "pid" => pid, "metadata" => enhanced_metadata, "name" => name),
    )

    # Get pending requests from buffer
    pending_requests = lock(PENDING_REQUESTS_LOCK) do
        # Check for pending requests under this UUID, old UUIDs, or the session name
        all_pending = Tuple{Dict,HTTP.Stream}[]
        if haskey(PENDING_REQUESTS, uuid)
            append!(all_pending, PENDING_REQUESTS[uuid])
            delete!(PENDING_REQUESTS, uuid)
        end
        for old_uuid in old_session_uuids
            if haskey(PENDING_REQUESTS, old_uuid)
                append!(all_pending, PENDING_REQUESTS[old_uuid])
                delete!(PENDING_REQUESTS, old_uuid)
            end
        end
        # Also check for requests buffered under the session name (fallback case)
        if haskey(PENDING_REQUESTS, name)
            append!(all_pending, PENDING_REQUESTS[name])
            delete!(PENDING_REQUESTS, name)
        end
        all_pending
    end

    if !isempty(pending_requests)
        @info "Julia session has buffered requests to process" uuid = uuid name = name buffer_size =
            length(pending_requests)
    end

    # If this was a restart, update MCP sessions targeting any old UUIDs
    if !isempty(old_session_uuids)
        for old_session_uuid in old_session_uuids
            mcp_sessions = Database.get_mcp_sessions_by_target(old_session_uuid)
            for mcp_session in mcp_sessions
                Database.update_mcp_session_target!(mcp_session.id, uuid)
                @info "Updated MCP session target after restart" mcp_session_id =
                    mcp_session.id old_uuid = old_session_uuid new_uuid = uuid
                @async notify_client_tools_changed(mcp_session.id)
            end

            # Clean up old session from database
            try
                Database.update_session_status!(old_session_uuid, "replaced")
            catch e
                @debug "Could not mark old session as replaced" exception = e
            end
        end
        @info "Marked old sessions as replaced" count = length(old_session_uuids)
    end

    # Flush pending requests if any
    if !isempty(pending_requests)
        @async flush_pending_requests(uuid, pending_requests)
    end

    # Notify relevant MCP clients that tools list has changed
    # Only notifies sessions targeting this Julia session or with no target
    notify_tools_list_changed(uuid)

    return (true, nothing)
end

"""
    unregister_julia_session(uuid::String)

Remove a Julia session from the proxy by UUID.
Updates database status and logs the event.
"""
function unregister_julia_session(uuid::String)
    session = Database.get_julia_session(uuid)
    if session !== nothing
        # Update status in database
        Database.update_session_status!(uuid, "stopped")

        # Log stop event to dashboard
        Dashboard.log_event(uuid, Dashboard.AGENT_STOP, Dict("name" => session.name))

        # Log unregistration to database
        log_db_event(
            "julia_session.unregistered",
            Dict(
                "name" => session.name,
                "port" => session.port,
                "pid" => session.pid,
                "status" => session.status,
            );
            julia_session_id = uuid,
        )

        @info "Julia session unregistered from proxy" uuid = uuid name = session.name
    end
end

"""
    get_julia_session(uuid::String) -> Union{NamedTuple, Nothing}

Get a Julia session by UUID from the database.
Returns a NamedTuple with session data or nothing if not found.
"""
function get_julia_session(uuid::String)
    Database.get_julia_session(uuid)
end

"""
    list_julia_sessions() -> Vector{NamedTuple}

List all active Julia sessions from the database.
Returns a vector of NamedTuples with session data.
"""
function list_julia_sessions()
    db = Database.DB[]
    if db === nothing
        return NamedTuple[]
    end

    # Include sessions that are potentially recoverable (ready, down, restarting)
    # but exclude terminal states (stopped, replaced) which won't come back
    result = DBInterface.execute(
        db,
        """
        SELECT id, name, port, pid, start_time, last_activity, status, metadata
        FROM julia_sessions
        WHERE status IN ('active', 'ready', 'down', 'restarting')
        ORDER BY start_time DESC
        """,
    )

    # Convert to NamedTuples to avoid SQLite.Row forward-only iterator issues
    # Materialize each row's data into local variables before creating NamedTuple
    sessions = NamedTuple[]
    for row in result
        # Extract all values first to avoid iterator issues
        _id = row.id
        _name = row.name
        _port = row.port
        _pid = row.pid
        _start_time = row.start_time
        _last_activity = row.last_activity
        _status = row.status
        _metadata = row.metadata
        push!(
            sessions,
            (
                id = _id,
                name = _name,
                port = _port,
                pid = _pid,
                start_time = _start_time,
                last_activity = _last_activity,
                status = _status,
                metadata = _metadata,
            ),
        )
    end
    return sessions
end

"""
    update_julia_session_status(uuid::String, status::String; error=nothing)

Update the status of a Julia session by UUID in the database.
When status is "ready", automatically processes any pending requests.
"""
function update_julia_session_status(
    uuid::String,
    status::String;
    error::Union{String,Nothing} = nothing,
)
    # Update database
    Database.update_session_status!(uuid, status)

    if error !== nothing
        # Log error to events
        log_db_event(
            "julia_session.error",
            Dict("error" => error, "status" => status);
            julia_session_id = uuid,
        )
    end

    # If session is ready, process any pending requests
    if status == "ready"
        pending_requests = lock(PENDING_REQUESTS_LOCK) do
            if haskey(PENDING_REQUESTS, uuid)
                reqs = PENDING_REQUESTS[uuid]
                delete!(PENDING_REQUESTS, uuid)
                reqs
            else
                Tuple{Dict,HTTP.Stream}[]
            end
        end

        if !isempty(pending_requests)
            session = get_julia_session(uuid)
            if session !== nothing
                @info "Julia session ready, processing buffered requests" uuid = uuid name =
                    session.name buffer_size = length(pending_requests)
                @async flush_pending_requests(uuid, pending_requests)
            end
        end
    end
end

# ============================================================================
# MCP Session Functions (Database-Backed)
# ============================================================================

"""
    create_mcp_session(target_julia_session_id::Union{String,Nothing}; session_id::Union{String,Nothing}=nothing) -> MCPSession

Create a new MCP session in the database.
If session_id is provided, uses that ID (for restoring existing sessions).
Otherwise generates a new UUID.
Returns the session as an MCPSession struct.
"""
function create_mcp_session(
    target_julia_session_id::Union{String,Nothing};
    session_id::Union{String,Nothing} = nothing,
)
    # Create MCPSession struct
    session = MCPSession(; target_julia_session_id = target_julia_session_id)

    # Override session ID if provided (for session restoration)
    if session_id !== nothing
        session.id = session_id
    end

    # Persist to database
    try
        Database.register_mcp_session!(
            session.id,
            "active";
            target_julia_session_id = target_julia_session_id,
        )
    catch e
        @error "Failed to create MCP session in database" session_id = session.id exception =
            e
        throw(e)
    end

    @info "Created MCP session" session_id = session.id target_julia_session_id =
        target_julia_session_id

    return session
end

"""
    get_mcp_session(session_id::String) -> Union{MCPSession, Nothing}

Get an MCP session by its ID from the database.
Returns an MCPSession struct or nothing if not found.
"""
function get_mcp_session(session_id::String)
    db_row = Database.get_mcp_session(session_id)
    if db_row === nothing
        return nothing
    end
    return session_from_db(db_row)
end

"""
    save_mcp_session!(session::MCPSession)

Save an MCPSession struct back to the database.
Updates both the state and the full session_data JSON blob, as well as last_activity timestamp.
"""
function save_mcp_session!(session::MCPSession)
    try
        # Serialize session to JSON (uses JSON.lower() hook)
        # JSON.lower() returns a Dict, which is what we need
        session_dict = JSON.lower(session)

        Database.update_mcp_session_protocol!(
            session.id,
            string(session.state),
            session_dict,
        )
    catch e
        @error "Failed to save MCP session to database" session_id = session.id exception =
            e
        throw(e)
    end
end

"""
    delete_mcp_session!(session_id::String)

Delete an MCP session from the database.
"""
function delete_mcp_session!(session_id::String)
    session = get_mcp_session(session_id)
    if session !== nothing
        Database.update_mcp_session_status!(session_id, "closed")
        @info "Deleted MCP session" session_id = session_id
    end
end

"""
    cleanup_inactive_sessions!(max_age::Dates.Period=Dates.Hour(1))

Mark MCP sessions inactive if they haven't had activity for longer than max_age.
"""
function cleanup_inactive_sessions!(max_age::Dates.Period = Dates.Hour(1))
    cutoff = now() - max_age
    sessions = Database.get_active_mcp_sessions()

    for session in sessions
        if Dates.DateTime(session.last_activity) < cutoff
            Database.update_mcp_session_status!(session.id, "inactive")
            @info "Marked session as inactive" session_id = session.id
        end
    end
end

# ============================================================================
# Request Buffering
# ============================================================================

"""
    buffer_request!(uuid::String, request::Dict, http::HTTP.Stream)

Buffer a request for a Julia session that is unavailable.
The request will be replayed when the session reconnects.
"""
function buffer_request!(uuid::String, request::Dict, http::HTTP.Stream)
    lock(PENDING_REQUESTS_LOCK) do
        if !haskey(PENDING_REQUESTS, uuid)
            PENDING_REQUESTS[uuid] = Tuple{Dict,HTTP.Stream}[]
        end
        push!(PENDING_REQUESTS[uuid], (request, http))
    end
    @info "Buffered request for reconnection" uuid = uuid request_id =
        get(request, "id", nothing)
end

"""
    flush_pending_requests(uuid::String, pending_requests::Vector{Tuple{Dict,HTTP.Stream}})

Forward all buffered requests to the Julia session after it reconnects.
Each request is forwarded with its stored HTTP stream so the response can be sent back.
"""
function flush_pending_requests(
    uuid::String,
    pending_requests::Vector{Tuple{Dict,HTTP.Stream}},
)
    session = get_julia_session(uuid)
    if session === nothing || session.status != "ready"
        @warn "Cannot flush pending requests: session not ready" uuid = uuid
        return
    end

    @info "Flushing pending requests to reconnected Julia session" uuid = uuid count =
        length(pending_requests)

    # Forward each buffered request to the backend
    for (request, http) in pending_requests
        @async try
            backend_url = "http://127.0.0.1:$(session.port)/"
            body_str = JSON.json(request)

            @debug "Flushing buffered request to backend" url = backend_url request_id =
                get(request, "id", nothing)

            # Retry logic for connection errors (backend might still be starting)
            max_retries = 3
            retry_delay = 0.5
            backend_response = nothing
            last_error = nothing

            for attempt = 1:max_retries
                try
                    # Forward to backend
                    backend_response = HTTP.request(
                        "POST",
                        backend_url,
                        ["Content-Type" => "application/json"],
                        body_str;
                        readtimeout = 30,
                        connect_timeout = 5,
                        status_exception = false,
                    )
                    break  # Success, exit retry loop
                catch e
                    last_error = e
                    if attempt < max_retries &&
                       (e isa HTTP.ConnectError || e isa Base.IOError)
                        @debug "Backend connection attempt failed, retrying" attempt =
                            attempt url = backend_url
                        sleep(retry_delay)
                        retry_delay *= 2  # Exponential backoff
                    else
                        rethrow()  # Out of retries or non-retryable error
                    end
                end
            end

            if backend_response === nothing
                throw(last_error)
            end

            response_body = String(backend_response.body)
            response_status = backend_response.status

            # Send response back to client through stored HTTP stream
            HTTP.setstatus(http, response_status)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, response_body)

            @debug "Buffered request flushed successfully" request_id =
                get(request, "id", nothing)
        catch e
            @error "Error flushing buffered request" request_id =
                get(request, "id", nothing) exception = e
            # Try to send error response
            try
                send_jsonrpc_error(
                    http,
                    get(request, "id", nothing),
                    -32603,
                    "Error replaying buffered request: $(sprint(showerror, e))";
                    status = 500,
                )
            catch err
                @error "Failed to send error response for buffered request" exception = err
            end
        end
    end
end
