# ============================================================================
# Logging Setup
# ============================================================================

function setup_proxy_logging(port::Int)
    cache_dir = mcprepl_cache_dir()

    # Two log files:
    # 1. Full debug log with everything
    full_log_file = joinpath(cache_dir, "proxy-$port.log")
    # 2. Info-only log with just INFO, WARN, ERROR (no DEBUG)
    info_log_file = joinpath(cache_dir, "proxy-$port-info.log")

    # Timestamp transformer for both loggers
    add_timestamp =
        log -> merge(
            log,
            (; message = "$(Dates.format(now(), "HH:MM:SS.sss")) $(log.message)"),
        )

    # Full logger (all levels including DEBUG)
    full_logger = LoggingExtras.TransformerLogger(
        add_timestamp,
        LoggingExtras.FileLogger(full_log_file; append = true, always_flush = true),
    )

    # Info-only logger (INFO and above, no DEBUG)
    info_logger = LoggingExtras.MinLevelLogger(
        LoggingExtras.TransformerLogger(
            add_timestamp,
            LoggingExtras.FileLogger(info_log_file; append = true, always_flush = true),
        ),
        Logging.Info,
    )

    # Use TeeLogger to write to both files
    logger = LoggingExtras.TeeLogger(full_logger, info_logger)
    global_logger(logger)

    @info "Proxy logging initialized" full_log = full_log_file info_log = info_log_file
    return full_log_file
end

# Helper function to log events to database with dual-session tracking
function log_db_event(
    event_type::String,
    data::Dict;
    mcp_session_id::Union{String,Nothing} = nothing,
    julia_session_id::Union{String,Nothing} = nothing,
    duration_ms::Union{Float64,Nothing} = nothing,
)
    try
        Database.log_event_safe!(
            event_type,
            data;
            mcp_session_id = mcp_session_id,
            julia_session_id = julia_session_id,
            duration_ms = duration_ms,
        )
    catch e
        # Silent failure
        @debug "Failed to log to database" exception = e
    end
end

# Helper function to log complete interactions (request/response messages) with dual-session tracking
function log_db_interaction(
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
    try
        # Look up REPL port/pid if we have a julia_session_id
        julia_session_port = nothing
        julia_session_pid = nothing
        if julia_session_id !== nothing
            julia_session = get_julia_session(julia_session_id)
            if julia_session !== nothing
                julia_session_port =
                    ismissing(julia_session.port) ? nothing : julia_session.port
                julia_session_pid =
                    ismissing(julia_session.pid) ? nothing : julia_session.pid
            end
        end

        Database.log_interaction_safe!(
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
            julia_session_port = julia_session_port,
            julia_session_pid = julia_session_pid,
        )
    catch e
        # Silent failure
        @debug "Failed to log interaction to database" exception = e
    end
end