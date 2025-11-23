# ============================================================================
# Logging Setup
# ============================================================================

function setup_proxy_logging(port::Int)
    cache_dir = get(ENV, "XDG_CACHE_HOME") do
        if Sys.iswindows()
            joinpath(ENV["LOCALAPPDATA"], "MCPRepl")
        else
            joinpath(homedir(), ".cache", "mcprepl")
        end
    end
    mkpath(cache_dir)

    log_file = joinpath(cache_dir, "proxy-$port.log")

    # Use FileLogger with automatic flushing and timestamp formatting
    logger = LoggingExtras.TransformerLogger(
        LoggingExtras.FileLogger(log_file; append = true, always_flush = true),
    ) do log
        merge(log, (; message = "$(Dates.format(now(), "HH:MM:SS.sss")) $(log.message)"))
    end
    global_logger(logger)

    @info "Proxy logging initialized" log_file = log_file
    return log_file
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
    request_id = nothing,
    method = nothing,
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
            julia_session = get(JULIA_SESSION_REGISTRY, julia_session_id, nothing)
            if julia_session !== nothing
                julia_session_port = julia_session.port
                julia_session_pid = julia_session.pid
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