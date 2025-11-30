"""
Session Status Management

Defines valid session statuses and provides validated update functions.
"""
module SessionStatus

using Dates
using SQLite
using DBInterface

# ============================================================================
# Status Constants
# ============================================================================

# Julia session statuses
const READY = "ready"              # Session connected, accepting requests
const DOWN = "down"                # Lost heartbeat, buffering requests
const RESTARTING = "restarting"    # Restart command sent, buffering requests
const STOPPED = "stopped"          # Permanently stopped, reject requests

# MCP session statuses
const ACTIVE = "active"            # Agent currently connected
const INACTIVE = "inactive"        # Agent disconnected >1hr (historical record)

# Valid status sets
const VALID_JULIA_STATUSES = Set([READY, DOWN, RESTARTING, STOPPED])
const VALID_MCP_STATUSES = Set([ACTIVE, INACTIVE])

# Statuses that should buffer requests (instead of rejecting)
const BUFFERING_STATUSES = Set([DOWN, RESTARTING])

# ============================================================================
# Validation
# ============================================================================

"""
    validate_julia_status(status::String)

Validate a Julia session status. Throws ArgumentError if invalid.
"""
function validate_julia_status(status::String)
    if !(status in VALID_JULIA_STATUSES)
        error(
            "Invalid Julia session status: '$status'. Valid statuses: $(join(sort(collect(VALID_JULIA_STATUSES)), ", "))",
        )
    end
end

"""
    validate_mcp_status(status::String)

Validate an MCP session status. Throws ArgumentError if invalid.
"""
function validate_mcp_status(status::String)
    if !(status in VALID_MCP_STATUSES)
        error(
            "Invalid MCP session status: '$status'. Valid statuses: $(join(sort(collect(VALID_MCP_STATUSES)), ", "))",
        )
    end
end

"""
    should_buffer(status::String) -> Bool

Returns true if requests should be buffered for this status.
"""
function should_buffer(status::String)
    return status in BUFFERING_STATUSES
end

"""
    is_active(status::String) -> Bool

Returns true if session is active (ready or temporarily unavailable).
"""
function is_active(status::String)
    return status in Set([READY, DOWN, RESTARTING])
end

# ============================================================================
# Status Update Functions (require database module)
# ============================================================================

"""
    update_julia_session_status!(db::SQLite.DB, session_id::String, status::String)

Update Julia session status with validation.
This is the ONLY function that should update Julia session status.
"""
function update_julia_session_status!(db::SQLite.DB, session_id::String, status::String)
    validate_julia_status(status)

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
    update_mcp_session_status!(db::SQLite.DB, session_id::String, status::String)

Update MCP session status with validation.
This is the ONLY function that should update MCP session status.
"""
function update_mcp_session_status!(db::SQLite.DB, session_id::String, status::String)
    validate_mcp_status(status)

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

export READY,
    DOWN,
    RESTARTING,
    STOPPED,
    ACTIVE,
    INACTIVE,
    VALID_JULIA_STATUSES,
    VALID_MCP_STATUSES,
    BUFFERING_STATUSES,
    validate_julia_status,
    validate_mcp_status,
    should_buffer,
    is_active,
    update_julia_session_status!,
    update_mcp_session_status!

end # module
