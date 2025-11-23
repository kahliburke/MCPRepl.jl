"""
Validation Functions for Proxy Registration

Pure validation functions that can be unit tested without HTTP infrastructure or database.
These functions contain business logic for validating registration parameters.
"""

"""
    validate_registration_params(id, port, pid)

Validate registration parameters for a REPL session.

Returns `(true, nothing)` if all parameters are valid.
Returns `(false, error_message::String)` if any parameter is invalid.

This is a pure function designed for unit testing - it performs validation logic
without side effects like HTTP responses or logging.

# Arguments
- `id`: Session identifier (must be non-empty string, or nothing triggers required error)
- `port`: Port number (must be in range 1024-65535 for non-privileged ports)
- `pid`: Process ID (must be positive integer if provided, can be nothing)

# Examples
```julia
validate_registration_params("my-session", 8080, 12345)  # (true, nothing)
validate_registration_params("", 8080, 12345)  # (false, "Session ID cannot be empty")
validate_registration_params("my-session", 80, 12345)  # (false, "Port must be between 1024 and 65535 (got 80)")
validate_registration_params("my-session", 8080, -1)  # (false, "Process ID must be a positive integer (got -1)")
```

# Port Range Rationale
We require ports >= 1024 to avoid privileged ports (0-1023) which require root access.
This prevents accidental security issues and makes the proxy more portable.
"""
function validate_registration_params(
    id::Union{String,Nothing},
    port::Union{Int,Nothing},
    pid::Union{Int,Nothing},
)
    # Check for required parameters
    if id === nothing
        return (false, "Parameter 'id' is required")
    end
    if port === nothing
        return (false, "Parameter 'port' is required")
    end

    # Validate ID - must be non-empty after stripping whitespace
    if isempty(strip(id))
        return (false, "Session ID cannot be empty")
    end

    # Validate port range - avoid privileged ports (0-1023)
    if port < 1024 || port > 65535
        return (false, "Port must be between 1024 and 65535 (got $port)")
    end

    # Validate PID if provided - must be positive
    if pid !== nothing && pid <= 0
        return (false, "Process ID must be a positive integer (got $pid)")
    end

    return (true, nothing)
end

"""
    validate_session_id(session_id)

Validate a session ID string.

Returns `(true, nothing)` if valid.
Returns `(false, error_message)` if invalid.

# Rules
- Must not be nothing
- Must not be empty after stripping whitespace
- Should be a reasonable length (1-255 characters)

# Examples
```julia
validate_session_id("my-session")  # (true, nothing)
validate_session_id("")  # (false, "Session ID cannot be empty")
validate_session_id("   ")  # (false, "Session ID cannot be empty")
validate_session_id(nothing)  # (false, "Session ID is required")
```
"""
function validate_session_id(session_id::Union{String,Nothing})
    if session_id === nothing
        return (false, "Session ID is required")
    end

    stripped = strip(session_id)
    if isempty(stripped)
        return (false, "Session ID cannot be empty")
    end

    if length(stripped) > 255
        return (
            false,
            "Session ID must be 255 characters or less (got $(length(stripped)))",
        )
    end

    return (true, nothing)
end

"""
    validate_port(port)

Validate a port number for REPL registration.

Returns `(true, nothing)` if valid.
Returns `(false, error_message)` if invalid.

# Rules
- Must not be nothing
- Must be between 1024 and 65535 (non-privileged ports only)

# Examples
```julia
validate_port(8080)  # (true, nothing)
validate_port(80)  # (false, "Port must be between 1024 and 65535 (got 80)")
validate_port(70000)  # (false, "Port must be between 1024 and 65535 (got 70000)")
validate_port(nothing)  # (false, "Port is required")
```
"""
function validate_port(port::Union{Int,Nothing})
    if port === nothing
        return (false, "Port is required")
    end

    if port < 1024 || port > 65535
        return (false, "Port must be between 1024 and 65535 (got $port)")
    end

    return (true, nothing)
end

"""
    validate_pid(pid)

Validate a process ID.

Returns `(true, nothing)` if valid.
Returns `(false, error_message)` if invalid.

PID can be nothing (optional), but if provided must be a positive integer.

# Examples
```julia
validate_pid(12345)  # (true, nothing)
validate_pid(nothing)  # (true, nothing) - PID is optional
validate_pid(0)  # (false, "Process ID must be a positive integer (got 0)")
validate_pid(-1)  # (false, "Process ID must be a positive integer (got -1)")
```
"""
function validate_pid(pid::Union{Int,Nothing})
    # PID is optional
    if pid === nothing
        return (true, nothing)
    end

    if pid <= 0
        return (false, "Process ID must be a positive integer (got $pid)")
    end

    return (true, nothing)
end
