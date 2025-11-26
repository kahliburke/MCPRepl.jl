"""
Database Schema for MCPRepl Event Tracking

Persistent storage of all agent interactions, tool calls, and events.
"""
module Database

using SQLite
using Dates
using DBInterface
using JSON
using DataFrames

export init_db!,
    log_event!,
    log_event_safe!,
    log_interaction!,
    log_interaction_safe!,
    get_events,
    get_interactions,
    get_events_by_time_range,
    get_session_stats,
    get_session_summary,
    reconstruct_session,
    register_session!,
    register_mcp_session!,
    register_julia_session!,
    get_active_sessions,
    get_all_sessions,
    update_session_status!,
    cleanup_old_events!,
    get_global_stats,
    get_recent_session_events,
    close_db!,
    save_mcp_session!,
    update_mcp_session_protocol!

# Global database connection
const DB = Ref{Union{SQLite.DB,Nothing}}(nothing)

"""
Initialize the SQLite database with schema.
Creates tables if they don't exist.
"""
function init_db!(db_path::String = ".mcprepl/events.db")
    # Create .mcprepl directory if it doesn't exist
    mkpath(dirname(db_path))

    db = SQLite.DB(db_path)
    DB[] = db

    # ============================================================================
    # Core Session Tables - Separate client and REPL sessions
    # ============================================================================

    # MCP sessions table - MCP clients/agents that connect to the proxy
    # Stores complete MCP session state for proxy restart persistence
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS mcp_sessions (
        id TEXT PRIMARY KEY,
        name TEXT,
        session_type TEXT NOT NULL DEFAULT 'agent',
        start_time DATETIME NOT NULL,
        last_activity DATETIME NOT NULL,
        status TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'UNINITIALIZED',
        target_julia_session_id TEXT,
        session_data TEXT
    );

""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_mcp_sessions_name
    ON mcp_sessions(name)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_mcp_sessions_target
    ON mcp_sessions(target_julia_session_id)
""",
    )

    # Julia sessions table - Julia backend execution sessions
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS julia_sessions (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        port INTEGER,
        pid INTEGER,
        start_time DATETIME NOT NULL,
        last_activity DATETIME NOT NULL,
        status TEXT NOT NULL,
        metadata TEXT
    )
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_julia_sessions_name 
    ON julia_sessions(name)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_julia_sessions_port 
    ON julia_sessions(port)
""",
    )

    # Create events table - links to both MCP and Julia sessions
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mcp_session_id TEXT,
        julia_session_id TEXT,
        event_type TEXT NOT NULL,
        timestamp DATETIME NOT NULL,
        duration_ms REAL,
        data TEXT,
        FOREIGN KEY (mcp_session_id) REFERENCES mcp_sessions(id),
        FOREIGN KEY (julia_session_id) REFERENCES julia_sessions(id)
    )
""",
    )

    # Create indices for common queries
    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_events_mcp 
    ON events(mcp_session_id, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_events_julia 
    ON events(julia_session_id, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_events_type 
    ON events(event_type, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_events_timestamp 
    ON events(timestamp DESC)
""",
    )

    # Create interactions table - complete HTTP request/response capture
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS interactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mcp_session_id TEXT,
        julia_session_id TEXT,
        timestamp DATETIME NOT NULL,
        direction TEXT NOT NULL,
        message_type TEXT NOT NULL,
        request_id TEXT,
        method TEXT,
        content TEXT NOT NULL,
        content_size INTEGER,
        
        http_method TEXT,
        http_path TEXT,
        http_headers TEXT,
        http_status_code INTEGER,
        remote_addr TEXT,
        user_agent TEXT,
        content_type TEXT,
        content_encoding TEXT,
        processing_time_ms REAL,
        
        FOREIGN KEY (mcp_session_id) REFERENCES mcp_sessions(id),
        FOREIGN KEY (julia_session_id) REFERENCES julia_sessions(id)
    )
""",
    )

    # Create indices for interactions
    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_interactions_mcp 
    ON interactions(mcp_session_id, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_interactions_julia 
    ON interactions(julia_session_id, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_interactions_request 
    ON interactions(request_id, timestamp)
""",
    )

    # ============================================================================
    # Analytics Tables - Structured data extracted from JSON blobs
    # ============================================================================

    # Tool executions table - structured tool call analytics
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS tool_executions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mcp_session_id TEXT,
        julia_session_id TEXT,
        request_id TEXT NOT NULL,
        
        tool_name TEXT NOT NULL,
        tool_method TEXT,
        
        request_time DATETIME NOT NULL,
        response_time DATETIME,
        duration_ms REAL,
        
        input_size INTEGER,
        output_size INTEGER,
        argument_count INTEGER,
        arguments TEXT,
        
        status TEXT NOT NULL,
        result_type TEXT,
        result_summary TEXT,
        
        interaction_request_id INTEGER,
        interaction_response_id INTEGER,
        
        FOREIGN KEY (mcp_session_id) REFERENCES mcp_sessions(id),
        FOREIGN KEY (julia_session_id) REFERENCES julia_sessions(id),
        FOREIGN KEY (interaction_request_id) REFERENCES interactions(id),
        FOREIGN KEY (interaction_response_id) REFERENCES interactions(id)
    )
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_tool_executions_mcp 
    ON tool_executions(mcp_session_id, request_time DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_tool_executions_julia 
    ON tool_executions(julia_session_id, request_time DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_tool_executions_tool 
    ON tool_executions(tool_name, request_time DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_tool_executions_status 
    ON tool_executions(status, request_time DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_tool_executions_duration 
    ON tool_executions(duration_ms DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_tool_executions_request 
    ON tool_executions(request_id)
""",
    )

    # Errors table - structured error tracking
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS errors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mcp_session_id TEXT,
        julia_session_id TEXT,
        timestamp DATETIME NOT NULL,
        
        error_type TEXT NOT NULL,
        error_code INTEGER,
        error_category TEXT,
        
        tool_name TEXT,
        method TEXT,
        request_id TEXT,
        
        message TEXT NOT NULL,
        stack_trace TEXT,
        
        client_info TEXT,
        input_that_caused_error TEXT,
        
        resolved BOOLEAN DEFAULT 0,
        resolution_notes TEXT,
        
        interaction_id INTEGER,
        event_id INTEGER,
        
        FOREIGN KEY (mcp_session_id) REFERENCES mcp_sessions(id),
        FOREIGN KEY (julia_session_id) REFERENCES julia_sessions(id),
        FOREIGN KEY (interaction_id) REFERENCES interactions(id),
        FOREIGN KEY (event_id) REFERENCES events(id)
    )
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_errors_mcp 
    ON errors(mcp_session_id, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_errors_julia 
    ON errors(julia_session_id, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_errors_type 
    ON errors(error_type, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_errors_code 
    ON errors(error_code, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_errors_tool 
    ON errors(tool_name, timestamp DESC) WHERE tool_name IS NOT NULL
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_errors_unresolved 
    ON errors(resolved, timestamp DESC)
""",
    )

    # Performance metrics table - time-series performance data
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS performance_metrics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mcp_session_id TEXT,
        julia_session_id TEXT,
        timestamp DATETIME NOT NULL,
        
        metric_type TEXT NOT NULL,
        metric_name TEXT NOT NULL,
        
        duration_ms REAL,
        throughput REAL,
        memory_mb REAL,
        cpu_percent REAL,
        
        tool_name TEXT,
        
        p50_ms REAL,
        p95_ms REAL,
        p99_ms REAL,
        
        FOREIGN KEY (mcp_session_id) REFERENCES mcp_sessions(id),
        FOREIGN KEY (julia_session_id) REFERENCES julia_sessions(id)
    )
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_metrics_mcp 
    ON performance_metrics(mcp_session_id, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_metrics_julia 
    ON performance_metrics(julia_session_id, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_metrics_type 
    ON performance_metrics(metric_type, metric_name, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_metrics_tool 
    ON performance_metrics(tool_name, timestamp DESC) WHERE tool_name IS NOT NULL
""",
    )

    # Session lifecycle table - detailed state transitions
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS session_lifecycle (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mcp_session_id TEXT,
        julia_session_id TEXT,
        timestamp DATETIME NOT NULL,
        
        event_type TEXT NOT NULL,
        from_state TEXT,
        to_state TEXT NOT NULL,
        
        reason TEXT,
        triggered_by TEXT,
        
        metadata TEXT,
        
        FOREIGN KEY (mcp_session_id) REFERENCES mcp_sessions(id),
        FOREIGN KEY (julia_session_id) REFERENCES julia_sessions(id)
    )
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_lifecycle_mcp 
    ON session_lifecycle(mcp_session_id, timestamp)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_lifecycle_julia 
    ON session_lifecycle(julia_session_id, timestamp)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_lifecycle_event 
    ON session_lifecycle(event_type, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_lifecycle_state 
    ON session_lifecycle(to_state, timestamp DESC)
""",
    )

    # ETL metadata table - track processing state
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS etl_metadata (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        last_processed_interaction_id INTEGER DEFAULT 0,
        last_processed_event_id INTEGER DEFAULT 0,
        last_run_time DATETIME,
        last_run_status TEXT,
        last_error TEXT
    )
""",
    )

    # Initialize ETL metadata if not exists
    DBInterface.execute(
        db,
        """
    INSERT OR IGNORE INTO etl_metadata (id, last_processed_interaction_id, last_processed_event_id)
    VALUES (1, 0, 0)
""",
    )

    # ============================================================================
    # Analytics Views
    # ============================================================================

    # Daily tool usage summary view
    DBInterface.execute(
        db,
        """
    CREATE VIEW IF NOT EXISTS v_daily_tool_usage AS
    SELECT 
        DATE(request_time) as date,
        tool_name,
        COUNT(*) as execution_count,
        AVG(duration_ms) as avg_duration_ms,
        MIN(duration_ms) as min_duration_ms,
        MAX(duration_ms) as max_duration_ms,
        SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as error_count,
        ROUND(100.0 * SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) / COUNT(*), 2) as error_rate_pct
    FROM tool_executions
    GROUP BY DATE(request_time), tool_name
    ORDER BY date DESC, execution_count DESC
""",
    )

    # MCP session summary view
    DBInterface.execute(
        db,
        """
    CREATE VIEW IF NOT EXISTS v_mcp_session_summary AS
    SELECT 
        m.id as mcp_session_id,
        m.name as mcp_session_name,
        m.start_time,
        m.last_activity,
        m.status,
        COUNT(DISTINCT te.id) as total_tool_calls,
        COUNT(DISTINCT e.id) as total_errors,
        SUM(te.duration_ms) as total_execution_time_ms,
        AVG(te.duration_ms) as avg_execution_time_ms
    FROM mcp_sessions m
    LEFT JOIN tool_executions te ON m.id = te.mcp_session_id
    LEFT JOIN errors e ON m.id = e.mcp_session_id
    GROUP BY m.id
""",
    )

    # Julia session summary view
    DBInterface.execute(
        db,
        """
    CREATE VIEW IF NOT EXISTS v_julia_session_summary AS
    SELECT 
        j.id as julia_session_id,
        j.name as julia_session_name,
        j.port,
        j.pid,
        j.start_time,
        j.last_activity,
        j.status,
        COUNT(DISTINCT te.id) as total_tool_calls,
        COUNT(DISTINCT e.id) as total_errors,
        SUM(te.duration_ms) as total_execution_time_ms,
        AVG(te.duration_ms) as avg_execution_time_ms
    FROM julia_sessions j
    LEFT JOIN tool_executions te ON j.id = te.julia_session_id
    LEFT JOIN errors e ON j.id = e.julia_session_id
    GROUP BY j.id
""",
    )

    # Error hot spots view
    DBInterface.execute(
        db,
        """
    CREATE VIEW IF NOT EXISTS v_error_hotspots AS
    SELECT 
        tool_name,
        error_type,
        error_category,
        COUNT(*) as error_count,
        COUNT(DISTINCT mcp_session_id) as affected_mcp_sessions,
        COUNT(DISTINCT julia_session_id) as affected_julia_sessions,
        MAX(timestamp) as last_occurrence
    FROM errors
    WHERE resolved = 0
    GROUP BY tool_name, error_type, error_category
    ORDER BY error_count DESC
""",
    )

    return db
end

"""
Register or update an MCP session (client connection) in the database.

Arguments:
- id: UUID string for the MCP session
- status: Session status ("active", "disconnected", etc.)
- name: Optional logical name for the session
- session_type: Type of MCP client ("vscode", "cli", etc.)
- metadata: Additional session metadata
"""
function register_mcp_session!(
    id::String,
    status::String = "active";
    name::Union{String,Nothing} = nothing,
    session_type::String = "unknown",
    target_julia_session_id::Union{String,Nothing} = nothing,
    metadata::Dict = Dict(),
)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    metadata_json = JSON.json(metadata)
    now_str = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")

    # Insert or update MCP session
    # Store protocol-specific fields in session_data JSON
    session_data = Dict(
        "protocol_version" => "",
        "client_info" => Dict{String,Any}(),
        "server_capabilities" => Dict{String,Any}(),
        "client_capabilities" => Dict{String,Any}(),
        "initialized_at" => nothing,
        "closed_at" => nothing,
        "metadata" => metadata,  # Keep user metadata in the blob
    )
    session_data_json = JSON.json(session_data)

    DBInterface.execute(
        db,
        """
        INSERT INTO mcp_sessions (id, name, session_type, start_time, last_activity, status, state, target_julia_session_id, session_data)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = COALESCE(excluded.name, name),
            last_activity = excluded.last_activity,
            status = excluded.status,
            target_julia_session_id = COALESCE(excluded.target_julia_session_id, target_julia_session_id),
            session_data = excluded.session_data
        """,
        (
            id,
            name,
            session_type,
            now_str,
            now_str,
            status,
            "UNINITIALIZED",
            target_julia_session_id,
            session_data_json,
        ),
    )
end

"""
    update_mcp_session_target!(mcp_session_id::String, target_julia_session_id::Union{String,Nothing})

Update the target Julia session for an MCP session. This persists which Julia backend
the MCP client is connected to, allowing the connection to survive proxy restarts.

Arguments:
- mcp_session_id: ID of the MCP client session
- target_julia_session_id: UUID of the Julia session to target, or nothing to clear
"""
function update_mcp_session_target!(
    mcp_session_id::String,
    target_julia_session_id::Union{String,Nothing},
)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    now_str = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")

    DBInterface.execute(
        db,
        """
        UPDATE mcp_sessions
        SET target_julia_session_id = ?, last_activity = ?
        WHERE id = ?
        """,
        (target_julia_session_id, now_str, mcp_session_id),
    )
end

"""
    update_mcp_session_protocol!(session_id::String, state::String, protocol_data::Dict)

Update MCP session state and protocol-specific data (capabilities, client info, etc).
This is called during session initialization and lifecycle changes.

Arguments:
- session_id: MCP session ID
- state: Session state (UNINITIALIZED, INITIALIZING, INITIALIZED, CLOSED)
- protocol_data: Dict with protocol_version, client_info, capabilities, etc.
"""
function update_mcp_session_protocol!(
    session_id::String,
    state::String,
    protocol_data::Dict,
)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    now_str = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")
    protocol_data_json = JSON.json(protocol_data)

    DBInterface.execute(
        db,
        """
        UPDATE mcp_sessions
        SET state = ?, session_data = ?, last_activity = ?
        WHERE id = ?
        """,
        (state, protocol_data_json, now_str, session_id),
    )
end

"""
    get_active_mcp_sessions() -> Vector{NamedTuple}

Get all active MCP sessions from the database with their target Julia session IDs.
Used to restore MCP session state on proxy startup.

Returns a vector of NamedTuples with fields:
- id: MCP session ID
- target_julia_session_id: UUID of target Julia session (or nothing)
- start_time: Session start time
- last_activity: Last activity time
"""
function get_active_mcp_sessions()
    db = DB[]
    if db === nothing
        return NamedTuple[]
    end

    result = DBInterface.execute(
        db,
        """
        SELECT id, target_julia_session_id, start_time, last_activity
        FROM mcp_sessions
        WHERE status = 'active'
        ORDER BY start_time DESC
        """,
    )

    return collect(result)
end

"""
    get_julia_session(uuid::String) -> Union{NamedTuple, Nothing}

Get a single Julia session by UUID from the database.
Returns a NamedTuple with session data or nothing if not found.
"""
function get_julia_session(uuid::String)
    db = DB[]
    if db === nothing
        return nothing
    end

    result = DBInterface.execute(
        db,
        """
        SELECT id, name, port, pid, start_time, last_activity, status, metadata
        FROM julia_sessions
        WHERE id = ?
        """,
        (uuid,),
    )

    # Convert SQLite.Row to NamedTuple to avoid forward-only iterator issues
    for row in result
        return (
            id = row.id,
            name = row.name,
            port = row.port,
            pid = row.pid,
            start_time = row.start_time,
            last_activity = row.last_activity,
            status = row.status,
            metadata = row.metadata,
        )
    end
    return nothing
end

"""
    get_mcp_session(session_id::String) -> Union{NamedTuple, Nothing}

Get a single MCP session by ID from the database.
Returns a NamedTuple with session data (state and session_data are included).
The session_data column contains JSON with protocol_version, client_info, capabilities, etc.
"""
function get_mcp_session(session_id::String)
    db = DB[]
    if db === nothing
        return nothing
    end

    result = DBInterface.execute(
        db,
        """
        SELECT id, name, session_type, start_time, last_activity, status, state, target_julia_session_id, session_data
        FROM mcp_sessions
        WHERE id = ?
        """,
        (session_id,),
    )

    # Convert SQLite.Row to NamedTuple to avoid forward-only iterator issues
    for row in result
        return (
            id = row.id,
            name = row.name,
            session_type = row.session_type,
            start_time = row.start_time,
            last_activity = row.last_activity,
            status = row.status,
            state = row.state,
            target_julia_session_id = row.target_julia_session_id,
            session_data = row.session_data,
        )
    end
    return nothing
end

"""
    get_julia_sessions_by_name(name::String) -> Vector{NamedTuple}

Get all Julia sessions with a specific name from the database.
Returns a vector of NamedTuples ordered by start time (oldest first).
"""
function get_julia_sessions_by_name(name::String)
    db = DB[]
    if db === nothing
        return NamedTuple[]
    end

    result = DBInterface.execute(
        db,
        """
        SELECT id, name, port, pid, start_time, last_activity, status, metadata
        FROM julia_sessions
        WHERE name = ?
        ORDER BY start_time ASC
        """,
        (name,),
    )

    # Convert to NamedTuples to avoid SQLite.Row forward-only iterator issues
    return [
        (
            id = row.id,
            name = row.name,
            port = row.port,
            pid = row.pid,
            start_time = row.start_time,
            last_activity = row.last_activity,
            status = row.status,
            metadata = row.metadata,
        ) for row in result
    ]
end

"""
    get_mcp_sessions_by_target(target_julia_session_id::String) -> Vector{NamedTuple}

Get all MCP sessions targeting a specific Julia session.
Returns a vector of NamedTuples.
"""
function get_mcp_sessions_by_target(target_julia_session_id::String)
    db = DB[]
    if db === nothing
        return NamedTuple[]
    end

    result = DBInterface.execute(
        db,
        """
        SELECT id, name, session_type, start_time, last_activity, status, target_julia_session_id, metadata
        FROM mcp_sessions
        WHERE target_julia_session_id = ?
        """,
        (target_julia_session_id,),
    )

    # Convert to NamedTuples to avoid SQLite.Row forward-only iterator issues
    return [
        (
            id = row.id,
            name = row.name,
            session_type = row.session_type,
            start_time = row.start_time,
            last_activity = row.last_activity,
            status = row.status,
            target_julia_session_id = row.target_julia_session_id,
            metadata = row.metadata,
        ) for row in result
    ]
end

"""
    update_mcp_session_status!(session_id::String, status::String)

Update the status of an MCP session in the database.
"""
function update_mcp_session_status!(session_id::String, status::String)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    now_str = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")

    DBInterface.execute(
        db,
        """
        UPDATE mcp_sessions
        SET status = ?, last_activity = ?
        WHERE id = ?
        """,
        (status, now_str, session_id),
    )
end

"""
Register or update a Julia session (backend REPL) in the database.

Arguments:
- id: UUID string or logical name for the Julia session
- name: Logical name for the REPL
- status: Session status ("ready", "disconnected", etc.)
- port: HTTP port the REPL is listening on
- pid: Process ID of the Julia REPL
- metadata: Additional session metadata
"""
function register_julia_session!(
    id::String,
    name::String,
    status::String = "active";
    port::Union{Int,Nothing} = nothing,
    pid::Union{Int,Nothing} = nothing,
    metadata::Dict = Dict(),
)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    metadata_json = JSON.json(metadata)
    now_str = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")

    # Insert or update Julia session
    DBInterface.execute(
        db,
        """
        INSERT INTO julia_sessions (id, name, port, pid, start_time, last_activity, status, metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            port = COALESCE(excluded.port, port),
            pid = COALESCE(excluded.pid, pid),
            last_activity = excluded.last_activity,
            status = excluded.status,
            metadata = excluded.metadata
        """,
        (id, name, port, pid, now_str, now_str, status, metadata_json),
    )
end

"""
Legacy function for backward compatibility. Determines session type and routes to appropriate function.
Will be deprecated once all callers are updated.
"""
function register_session!(
    session_id::String,
    status::String = "active";
    metadata::Dict = Dict(),
)
    # DEPRECATED: This function should not be used for Julia sessions.
    # Julia sessions need proper names from proxy/register.
    # Check if it looks like a Julia REPL session (has port/pid in metadata)
    if haskey(metadata, "port") || haskey(metadata, "pid")
        @warn "register_session! called for Julia session - use register_julia_session! with proper name instead" session_id
        # Do NOT auto-create - this would overwrite the proper name
        return
    else
        # Treat as MCP session
        register_mcp_session!(
            session_id,
            status;
            name = session_id,  # Use ID as name for legacy calls
            metadata = metadata,
        )
    end
end

"""
Log an event to the database with dual-session tracking.

Arguments:
- event_type: Type of event (tool_call, error, heartbeat, etc.)
- data: Event data as Dict
- mcp_session_id: Optional MCP session ID (initiator)
- julia_session_id: Optional Julia session ID (executor)
- duration_ms: Optional duration in milliseconds
"""
function log_event!(
    event_type::String,
    data::Dict;
    mcp_session_id::Union{String,Nothing} = nothing,
    julia_session_id::Union{String,Nothing} = nothing,
    duration_ms::Union{Float64,Nothing} = nothing,
)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")
    data_json = JSON.json(data)

    DBInterface.execute(
        db,
        """
        INSERT INTO events (mcp_session_id, julia_session_id, event_type, timestamp, duration_ms, data)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (mcp_session_id, julia_session_id, event_type, timestamp, duration_ms, data_json),
    )

    # Update last_activity for both sessions if they exist
    if mcp_session_id !== nothing
        DBInterface.execute(
            db,
            """
            UPDATE mcp_sessions 
            SET last_activity = ?
            WHERE id = ?
            """,
            (timestamp, mcp_session_id),
        )
    end

    if julia_session_id !== nothing
        DBInterface.execute(
            db,
            """
            UPDATE julia_sessions 
            SET last_activity = ?
            WHERE id = ?
            """,
            (timestamp, julia_session_id),
        )
    end
end

"""
Log an event to the database with automatic session creation if needed.
Safe wrapper that won't error if database is not initialized.
"""
function log_event_safe!(
    event_type::String,
    data::Dict;
    mcp_session_id::Union{String,Nothing} = nothing,
    julia_session_id::Union{String,Nothing} = nothing,
    duration_ms::Union{Float64,Nothing} = nothing,
)
    try
        # Ensure sessions exist (auto-create with minimal info)
        # Note: We only auto-create MCP sessions. Julia sessions MUST be registered
        # by the REPL itself via proxy/register to get the correct logical name.
        if mcp_session_id !== nothing
            register_mcp_session!(mcp_session_id; metadata = Dict("auto_created" => true))
        end
        # Do NOT auto-create julia_sessions - they need proper names from registration

        log_event!(
            event_type,
            data;
            mcp_session_id = mcp_session_id,
            julia_session_id = julia_session_id,
            duration_ms = duration_ms,
        )
    catch e
        # Silent failure - log to stderr but don't crash
        @warn "Failed to log event to database" mcp_session_id = mcp_session_id julia_session_id =
            julia_session_id event_type = event_type exception = e
    end
end

"""
Log a complete interaction (request or response) to the database with dual-session tracking.
This captures the full message content and HTTP protocol details for session reconstruction.

Arguments:
- direction: "inbound" (to proxy) or "outbound" (from proxy)
- message_type: "request", "response", "error", "log", etc.
- content: The complete message content (will be stored as JSON string)
- mcp_session_id: Optional MCP session ID (client)
- julia_session_id: Optional Julia session ID (backend REPL)
- request_id: Optional request ID to link requests and responses
- method: Optional method name for RPC calls
- http_method: HTTP method (GET, POST, etc.)
- http_path: HTTP request path
- http_headers: HTTP headers as JSON string
- http_status_code: HTTP response status code
- remote_addr: Client IP address
- user_agent: Client User-Agent header
- content_type: Content-Type header
- content_encoding: Content-Encoding header
- processing_time_ms: Time to process request (milliseconds)
"""
function log_interaction!(
    direction::String,
    message_type::String,
    content::Union{String,Dict};
    mcp_session_id::Union{String,Nothing} = nothing,
    julia_session_id::Union{String,Nothing} = nothing,
    request_id::Union{String,Nothing} = nothing,
    method::Union{String,Nothing} = nothing,
    http_method::Union{String,Nothing} = nothing,
    http_path::Union{String,Nothing} = nothing,
    http_headers::Union{String,Nothing} = nothing,
    http_status_code::Union{Int,Nothing} = nothing,
    remote_addr::Union{String,Nothing} = nothing,
    user_agent::Union{String,Nothing} = nothing,
    content_type::Union{String,Nothing} = nothing,
    content_encoding::Union{String,Nothing} = nothing,
    processing_time_ms::Union{Float64,Nothing} = nothing,
)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    content_str = content isa String ? content : JSON.json(content)
    content_size = sizeof(content_str)
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")

    DBInterface.execute(
        db,
        """
        INSERT INTO interactions (
            mcp_session_id, julia_session_id, timestamp, direction, message_type,
            request_id, method, content, content_size,
            http_method, http_path, http_headers, http_status_code,
            remote_addr, user_agent, content_type, content_encoding, processing_time_ms
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            mcp_session_id,
            julia_session_id,
            timestamp,
            direction,
            message_type,
            request_id,
            method,
            content_str,
            content_size,
            http_method,
            http_path,
            http_headers,
            http_status_code,
            remote_addr,
            user_agent,
            content_type,
            content_encoding,
            processing_time_ms,
        ),
    )

    # Update last_activity for both sessions if they exist
    if mcp_session_id !== nothing
        DBInterface.execute(
            db,
            """
            UPDATE mcp_sessions 
            SET last_activity = ?
            WHERE id = ?
            """,
            (timestamp, mcp_session_id),
        )
    end

    if julia_session_id !== nothing
        DBInterface.execute(
            db,
            """
            UPDATE julia_sessions 
            SET last_activity = ?
            WHERE id = ?
            """,
            (timestamp, julia_session_id),
        )
    end
end

"""
Log an interaction with automatic session creation.
Safe wrapper that won't error if database is not initialized.
"""
function log_interaction_safe!(
    direction::String,
    message_type::String,
    content::Union{String,Dict};
    mcp_session_id::Union{String,Nothing} = nothing,
    julia_session_id::Union{String,Nothing} = nothing,
    request_id::Union{String,Nothing} = nothing,
    method::Union{String,Nothing} = nothing,
    http_method::Union{String,Nothing} = nothing,
    http_path::Union{String,Nothing} = nothing,
    http_headers::Union{String,Nothing} = nothing,
    http_status_code::Union{Int,Nothing} = nothing,
    remote_addr::Union{String,Nothing} = nothing,
    user_agent::Union{String,Nothing} = nothing,
    content_type::Union{String,Nothing} = nothing,
    content_encoding::Union{String,Nothing} = nothing,
    processing_time_ms::Union{Float64,Nothing} = nothing,
    julia_session_port::Union{Int,Nothing} = nothing,
    julia_session_pid::Union{Int,Nothing} = nothing,
)
    try
        # Ensure sessions exist (auto-create with minimal info)
        # Note: We only auto-create MCP sessions. Julia sessions MUST be registered
        # by the REPL itself via proxy/register to get the correct logical name.
        if mcp_session_id !== nothing
            register_mcp_session!(mcp_session_id; metadata = Dict("auto_created" => true))
        end
        # Do NOT auto-create julia_sessions - they need proper names from registration

        log_interaction!(
            direction,
            message_type,
            content;
            mcp_session_id = mcp_session_id,
            julia_session_id = julia_session_id,
            request_id = request_id,
            method = method,
            http_method = http_method,
            http_path = http_path,
            http_headers = http_headers,
            http_status_code = http_status_code,
            remote_addr = remote_addr,
            user_agent = user_agent,
            content_type = content_type,
            content_encoding = content_encoding,
            processing_time_ms = processing_time_ms,
        )
    catch e
        # Silent failure - log to stderr but don't crash
        @warn "Failed to log interaction to database" mcp_session_id = mcp_session_id julia_session_id =
            julia_session_id direction = direction message_type = message_type exception = e
    end
end

"""
Retrieve recent events from the database.

Arguments:
- mcp_session_id: Filter by MCP session ID
- julia_session_id: Filter by Julia session ID
- event_type: Filter by event type
- limit: Maximum number of events to return
- offset: Number of events to skip
"""
function get_events(;
    mcp_session_id::Union{String,Nothing} = nothing,
    julia_session_id::Union{String,Nothing} = nothing,
    event_type::Union{String,Nothing} = nothing,
    limit::Int = 100,
    offset::Int = 0,
)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    query = "SELECT * FROM events WHERE 1=1"
    params = []

    if mcp_session_id !== nothing
        query *= " AND mcp_session_id = ?"
        push!(params, mcp_session_id)
    end

    if julia_session_id !== nothing
        query *= " AND julia_session_id = ?"
        push!(params, julia_session_id)
    end

    if event_type !== nothing
        query *= " AND event_type = ?"
        push!(params, event_type)
    end

    query *= " ORDER BY timestamp DESC LIMIT ? OFFSET ?"
    push!(params, limit, offset)

    result = DBInterface.execute(db, query, params) |> DataFrame
    return dataframe_to_array(result)
end

"""
Retrieve interactions from the database.
Interactions contain full message content and HTTP details for complete session reconstruction.

Arguments:
- mcp_session_id: Filter by MCP session ID
- julia_session_id: Filter by Julia session ID
- request_id: Filter by request ID (to link request/response pairs)
- direction: Filter by direction ("inbound" or "outbound")
- message_type: Filter by message type ("request", "response", etc.)
- limit: Maximum number of interactions to return
- offset: Number of interactions to skip
"""
function get_interactions(;
    mcp_session_id::Union{String,Nothing} = nothing,
    julia_session_id::Union{String,Nothing} = nothing,
    request_id::Union{String,Nothing} = nothing,
    direction::Union{String,Nothing} = nothing,
    message_type::Union{String,Nothing} = nothing,
    limit::Int = 100,
    offset::Int = 0,
)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    query = "SELECT * FROM interactions WHERE 1=1"
    params = []

    if mcp_session_id !== nothing
        query *= " AND mcp_session_id = ?"
        push!(params, mcp_session_id)
    end

    if julia_session_id !== nothing
        query *= " AND julia_session_id = ?"
        push!(params, julia_session_id)
    end

    if request_id !== nothing
        query *= " AND request_id = ?"
        push!(params, request_id)
    end

    if direction !== nothing
        query *= " AND direction = ?"
        push!(params, direction)
    end

    if message_type !== nothing
        query *= " AND message_type = ?"
        push!(params, message_type)
    end

    query *= " ORDER BY timestamp ASC LIMIT ? OFFSET ?"
    push!(params, limit, offset)

    result = DBInterface.execute(db, query, params) |> DataFrame
    return dataframe_to_array(result)
end

"""
Get statistics for a session.
"""
function get_session_stats(session_id::String)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    # Get event counts by type
    event_counts =
        DBInterface.execute(
            db,
            """
        SELECT event_type, COUNT(*) as count
        FROM events
        WHERE session_id = ?
        GROUP BY event_type
    """,
            (session_id,),
        ) |> DataFrame

    # Get total execution time
    total_time = DBInterface.execute(
        db,
        """
    SELECT SUM(duration_ms) as total_ms
    FROM events
    WHERE session_id = ? AND duration_ms IS NOT NULL
""",
        (session_id,),
    )

    # Get session info from either julia_sessions or mcp_sessions
    session_info =
        DBInterface.execute(
            db,
            """
        SELECT id, name, 'julia' as session_type, status, start_time, last_activity, port, pid, metadata
        FROM julia_sessions WHERE id = ?
        UNION ALL
        SELECT id, name, session_type, status, start_time, last_activity, NULL as port, NULL as pid, metadata
        FROM mcp_sessions WHERE id = ?
    """,
            (session_id, session_id),
        ) |> DataFrame

    return Dict(
        "session" => session_info,
        "event_counts" => event_counts,
        "total_execution_time_ms" => total_time,
    )
end

"""
Get all active sessions from both julia_sessions and mcp_sessions.
"""
function get_active_sessions()
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    return DBInterface.execute(
        db,
        """
    SELECT id, name, 'julia' as session_type, status, start_time, last_activity, port, pid, metadata
    FROM julia_sessions WHERE status = 'active'
    UNION ALL
    SELECT id, name, session_type, status, start_time, last_activity, NULL as port, NULL as pid, metadata
    FROM mcp_sessions WHERE status = 'active'
    ORDER BY last_activity DESC
""",
    ) |> DataFrame
end

"""
Get events within a time range.
"""
function get_events_by_time_range(;
    session_id::Union{String,Nothing} = nothing,
    start_time::DateTime,
    end_time::DateTime = now(),
    event_type::Union{String,Nothing} = nothing,
    limit::Int = 1000,
)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    query = "SELECT * FROM events WHERE timestamp >= ? AND timestamp <= ?"
    params = [
        Dates.format(start_time, "yyyy-mm-dd HH:MM:SS.sss"),
        Dates.format(end_time, "yyyy-mm-dd HH:MM:SS.sss"),
    ]

    if session_id !== nothing
        query *= " AND session_id = ?"
        push!(params, session_id)
    end

    if event_type !== nothing
        query *= " AND event_type = ?"
        push!(params, event_type)
    end

    query *= " ORDER BY timestamp DESC LIMIT ?"
    push!(params, limit)

    return DBInterface.execute(db, query, params) |> DataFrame
end

"""
Get session history (all sessions, not just active).
"""
function get_all_sessions(; limit::Int = 100)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    # Return all sessions from both julia_sessions and mcp_sessions tables
    # Add a session_type field to distinguish them
    result =
        DBInterface.execute(
            db,
            """
        SELECT id, name, 'julia' as session_type, status, start_time, last_activity, port, pid, metadata
        FROM julia_sessions
        UNION ALL
        SELECT id, name, session_type, status, start_time, last_activity, NULL as port, NULL as pid, metadata
        FROM mcp_sessions
        ORDER BY last_activity DESC
        LIMIT ?
    """,
            (limit,),
        ) |> DataFrame
    return dataframe_to_array(result)
end

"""
Update Julia session status.
"""
function update_session_status!(session_id::String, status::String)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    now_str = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")

    DBInterface.execute(
        db,
        """
    UPDATE julia_sessions
    SET status = ?, last_activity = ?
    WHERE id = ?
""",
        (status, now_str, session_id),
    )
end

"""
Delete old events beyond a certain age to prevent database growth.
"""
function cleanup_old_events!(days_to_keep::Int = 30)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    cutoff_date = now() - Dates.Day(days_to_keep)
    cutoff_str = Dates.format(cutoff_date, "yyyy-mm-dd HH:MM:SS.sss")

    result = DBInterface.execute(
        db,
        """
    DELETE FROM events 
    WHERE timestamp < ?
""",
        (cutoff_str,),
    )

    return result
end

"""
Get aggregate statistics across all sessions.
"""
function get_global_stats()
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    # Total sessions (count from both tables)
    total_sessions =
        DBInterface.execute(
            db,
            "SELECT (SELECT COUNT(*) FROM julia_sessions) + (SELECT COUNT(*) FROM mcp_sessions) as count",
        ) |> DataFrame

    # Active sessions (count from both tables)
    active_sessions =
        DBInterface.execute(
            db,
            "SELECT (SELECT COUNT(*) FROM julia_sessions WHERE status = 'active') + (SELECT COUNT(*) FROM mcp_sessions WHERE status = 'active') as count",
        ) |> DataFrame

    # Total events
    total_events =
        DBInterface.execute(db, "SELECT COUNT(*) as count FROM events") |> DataFrame

    # Events by type
    events_by_type =
        DBInterface.execute(
            db,
            """
            SELECT event_type, COUNT(*) as count
            FROM events
            GROUP BY event_type
            ORDER BY count DESC
        """,
        ) |> DataFrame

    # Total execution time
    total_execution_time =
        DBInterface.execute(
            db,
            """
            SELECT SUM(duration_ms) as total_ms
            FROM events
            WHERE duration_ms IS NOT NULL
        """,
        ) |> DataFrame

    return Dict(
        "total_sessions" => total_sessions,
        "active_sessions" => active_sessions,
        "total_events" => total_events,
        "events_by_type" => events_by_type,
        "total_execution_time_ms" => total_execution_time,
    )
end

"""
Get most recent N events for a session (optimized query).
"""
function get_recent_session_events(session_id::String, limit::Int = 50)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    return DBInterface.execute(
        db,
        """
    SELECT * FROM events
    WHERE session_id = ?
    ORDER BY timestamp DESC
    LIMIT ?
""",
        (session_id, limit),
    ) |> DataFrame
end

"""
Reconstruct a complete session timeline from interactions and events.
Returns a chronologically ordered list of all interactions with their context.

This function provides everything needed to replay or analyze a session:
- All inbound requests (what the client/agent sent)
- All outbound responses (what the system replied)
- All events (tool calls, errors, lifecycle)
- Complete message contents for full reconstruction

# Arguments
- `session_id::String`: The session to reconstruct
- `limit::Int=1000`: Maximum number of items to return (default 1000)

# Returns
A DataFrame with columns:
- timestamp: When the interaction occurred
- type: "interaction" or "event"
- direction: "inbound" or "outbound" (for interactions)
- message_type: Type of message/event
- content: Full message content or event data
- request_id: Request ID for correlation
- method: RPC method name if applicable
"""
function reconstruct_session(session_id::String; limit::Int = 1000)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    # Query both interactions and events, union them together in chronological order
    query = """
    SELECT 
        timestamp,
        'interaction' as type,
        direction,
        message_type,
        content,
        request_id,
        method,
        NULL as event_type,
        NULL as duration_ms
    FROM interactions
    WHERE session_id = ?

    UNION ALL

    SELECT 
        timestamp,
        'event' as type,
        NULL as direction,
        NULL as message_type,
        data as content,
        NULL as request_id,
        NULL as method,
        event_type,
        duration_ms
    FROM events
    WHERE session_id = ?

    ORDER BY timestamp ASC
    LIMIT ?
    """

    return DBInterface.execute(db, query, (session_id, session_id, limit)) |> DataFrame
end

"""
Get a summary of a session including all key statistics.
Returns total interactions, events, timespan, and more.
"""
function get_session_summary(session_id::String)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    # Try to find session in either mcp_sessions or julia_sessions
    mcp_session =
        DBInterface.execute(db, "SELECT * FROM mcp_sessions WHERE id = ?", (session_id,)) |>
        DataFrame

    julia_session =
        DBInterface.execute(
            db,
            "SELECT * FROM julia_sessions WHERE id = ?",
            (session_id,),
        ) |> DataFrame

    session_info = if nrow(mcp_session) > 0
        mcp_session
    elseif nrow(julia_session) > 0
        julia_session
    else
        DataFrame()  # Session not found in either table
    end

    # Count interactions (check both mcp_session_id and julia_session_id)
    interaction_count =
        DBInterface.execute(
            db,
            "SELECT COUNT(*) as count FROM interactions WHERE mcp_session_id = ? OR julia_session_id = ?",
            (session_id, session_id),
        ) |> DataFrame

    # Count events
    event_count =
        DBInterface.execute(
            db,
            "SELECT COUNT(*) as count FROM events WHERE mcp_session_id = ? OR julia_session_id = ?",
            (session_id, session_id),
        ) |> DataFrame

    # Get total data size
    data_size =
        DBInterface.execute(
            db,
            "SELECT SUM(content_size) as total_bytes FROM interactions WHERE mcp_session_id = ? OR julia_session_id = ?",
            (session_id, session_id),
        ) |> DataFrame

    # Get request/response pairs
    request_response_pairs =
        DBInterface.execute(
            db,
            """
            SELECT request_id, COUNT(*) as pair_count
            FROM interactions
            WHERE (mcp_session_id = ? OR julia_session_id = ?) AND request_id IS NOT NULL
            GROUP BY request_id
            HAVING pair_count >= 2
            """,
            (session_id, session_id),
        ) |> DataFrame

    return Dict(
        "session_id" => session_id,
        "session_info" => dataframe_to_array(session_info),
        "total_interactions" => interaction_count[1, :count],
        "total_events" => event_count[1, :count],
        "total_data_bytes" => something(data_size[1, :total_bytes], 0),
        "complete_request_response_pairs" => nrow(request_response_pairs),
    )
end

"""
Convert DataFrame to array of dictionaries for JSON serialization.
"""
function dataframe_to_array(df::DataFrame)
    if nrow(df) == 0
        return Dict[]
    end
    result = Dict[]
    for row in eachrow(df)
        push!(result, Dict(names(df) .=> values(row)))
    end
    return result
end

"""
    get_tool_executions(; days::Int = 7) -> Vector{Dict}

Get tool execution analytics from the last N days.
Returns tool execution records with timing and status information.
"""
function get_tool_executions(; days::Int = 7)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    cutoff_date = Dates.format(now() - Day(days), "yyyy-mm-dd HH:MM:SS")

    result =
        DBInterface.execute(
            db,
            """
            SELECT
                id, mcp_session_id, julia_session_id, request_id,
                tool_name, tool_method, request_time, response_time,
                duration_ms, input_size, output_size, argument_count,
                status, result_type, result_summary
            FROM tool_executions
            WHERE request_time >= ?
            ORDER BY request_time DESC
            LIMIT 1000
            """,
            (cutoff_date,),
        ) |> DataFrame

    return dataframe_to_array(result)
end

"""
    get_error_analytics(; days::Int = 7) -> Vector{Dict}

Get error analytics from the last N days.
Returns error records with categorization and context.
"""
function get_error_analytics(; days::Int = 7)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    cutoff_date = Dates.format(now() - Day(days), "yyyy-mm-dd HH:MM:SS")

    result =
        DBInterface.execute(
            db,
            """
            SELECT
                id, mcp_session_id, julia_session_id, timestamp,
                error_type, error_code, error_category,
                tool_name, method, request_id, message,
                resolved, resolution_notes
            FROM errors
            WHERE timestamp >= ?
            ORDER BY timestamp DESC
            LIMIT 1000
            """,
            (cutoff_date,),
        ) |> DataFrame

    return dataframe_to_array(result)
end

"""
    get_tool_summary() -> Dict

Get summary statistics of tool usage.
Returns aggregated counts and metrics per tool.
"""
function get_tool_summary()
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    result =
        DBInterface.execute(
            db,
            """
            SELECT
                tool_name,
                COUNT(*) as total_executions,
                COUNT(CASE WHEN status = 'success' THEN 1 END) as success_count,
                COUNT(CASE WHEN status = 'error' THEN 1 END) as error_count,
                AVG(duration_ms) as avg_duration_ms,
                MIN(duration_ms) as min_duration_ms,
                MAX(duration_ms) as max_duration_ms,
                AVG(input_size) as avg_input_size,
                AVG(output_size) as avg_output_size
            FROM tool_executions
            GROUP BY tool_name
            ORDER BY total_executions DESC
            """,
        ) |> DataFrame

    return dataframe_to_array(result)
end

"""
    get_error_hotspots() -> Vector{Dict}

Get most frequent errors grouped by type and tool.
Returns error frequency analysis.
"""
function get_error_hotspots()
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    result =
        DBInterface.execute(
            db,
            """
            SELECT
                error_category,
                error_type,
                tool_name,
                COUNT(*) as error_count,
                COUNT(CASE WHEN resolved = 1 THEN 1 END) as resolved_count,
                MAX(timestamp) as last_occurrence
            FROM errors
            GROUP BY error_category, error_type, tool_name
            ORDER BY error_count DESC
            LIMIT 50
            """,
        ) |> DataFrame

    return dataframe_to_array(result)
end

"""
    get_session_timeline(session_id::String) -> Vector{Dict}

Get chronological timeline of events and interactions for a session.
Combines events and interactions into a unified timeline.
"""
function get_session_timeline(session_id::String)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    # Get events
    events =
        DBInterface.execute(
            db,
            """
            SELECT
                'event' as entry_type,
                timestamp,
                event_type,
                duration_ms,
                data,
                NULL as method,
                NULL as direction,
                NULL as request_id
            FROM events
            WHERE mcp_session_id = ? OR julia_session_id = ?
            """,
            (session_id, session_id),
        ) |> DataFrame

    # Get interactions
    interactions =
        DBInterface.execute(
            db,
            """
            SELECT
                'interaction' as entry_type,
                timestamp,
                message_type as event_type,
                NULL as duration_ms,
                content as data,
                method,
                direction,
                request_id
            FROM interactions
            WHERE mcp_session_id = ? OR julia_session_id = ?
            """,
            (session_id, session_id),
        ) |> DataFrame

    # Combine and sort by timestamp
    if nrow(events) > 0 && nrow(interactions) > 0
        timeline = vcat(events, interactions)
        sort!(timeline, :timestamp, rev = true)
    elseif nrow(events) > 0
        timeline = events
    elseif nrow(interactions) > 0
        timeline = interactions
    else
        timeline = DataFrame()
    end

    return dataframe_to_array(timeline)
end

"""
    get_etl_status() -> Dict

Get ETL pipeline status and metadata.
Returns information about the last ETL run and processing status.
"""
function get_etl_status()
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    result = DBInterface.execute(
        db,
        """
        SELECT
            last_processed_interaction_id,
            last_processed_event_id,
            last_run_time,
            last_run_status,
            last_error
        FROM etl_metadata
        WHERE id = 1
        """,
    ) |> DataFrame

    if nrow(result) == 0
        return Dict(
            "status" => "not_initialized",
            "last_run_time" => nothing,
            "last_run_status" => "never_run",
        )
    end

    return Dict(
        "last_processed_interaction_id" => result[1, :last_processed_interaction_id],
        "last_processed_event_id" => result[1, :last_processed_event_id],
        "last_run_time" => result[1, :last_run_time],
        "last_run_status" => result[1, :last_run_status],
        "last_error" => result[1, :last_error],
    )
end

"""
Close the database connection.
"""
function close_db!()
    if DB[] !== nothing
        SQLite.close(DB[])
        DB[] = nothing
    end
end

# Include ETL submodule
include("database_etl.jl")
using .DatabaseETL

# Re-export ETL functions
export DatabaseETL,
    run_etl_pipeline, start_etl_scheduler, extract_tool_executions, extract_errors

end # module
