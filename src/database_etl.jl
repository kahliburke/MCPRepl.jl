"""
Database ETL Module

Extracts structured analytics from raw JSON data in interactions and events tables.
Transforms generic JSON blobs into queryable analytical tables.
"""
module DatabaseETL

using SQLite
using JSON
using Dates
using DataFrames
using DBInterface

export run_etl_pipeline,
    start_etl_scheduler,
    extract_tool_executions,
    extract_errors,
    extract_client_sessions,
    calculate_performance_metrics

"""
Main ETL coordinator - runs all extraction and transformation steps.

Args:
- db: SQLite database connection
- mode: :incremental (process only new data) or :full (reprocess everything)
"""
function run_etl_pipeline(db; mode = :incremental)
    start_time = now()
    @info "Starting ETL pipeline" mode = mode

    try
        if mode == :full
            @info "Running FULL ETL refresh - truncating analytics tables"
            truncate_analytics_tables(db)
            last_interaction_id = 0
            last_event_id = 0
        else
            @info "Running INCREMENTAL ETL"
            last_interaction_id, last_event_id = get_last_processed_ids(db)
            @info "Processing from" last_interaction_id = last_interaction_id last_event_id =
                last_event_id
        end

        # Extract and transform interactions into tool_executions
        tool_count = extract_tool_executions(db, last_interaction_id)

        # Extract errors from interactions and events
        error_count = extract_errors(db, last_interaction_id, last_event_id)

        # Update client session summaries
        client_count = update_client_sessions(db, last_interaction_id)

        # Calculate performance metrics
        metric_count = calculate_performance_metrics(db, last_interaction_id)

        # Update last processed marker
        new_interaction_id = get_max_interaction_id(db)
        new_event_id = get_max_event_id(db)
        update_etl_metadata(db, new_interaction_id, new_event_id, "success", nothing)

        duration = (now() - start_time).value / 1000.0
        @info "ETL pipeline complete" duration_seconds = duration tool_executions =
            tool_count errors = error_count client_sessions = client_count metrics =
            metric_count

        return (
            success = true,
            tool_executions = tool_count,
            errors = error_count,
            client_sessions = client_count,
            metrics = metric_count,
            duration_seconds = duration,
        )
    catch e
        @error "ETL pipeline failed" exception = (e, catch_backtrace())
        update_etl_metadata(
            db,
            get_max_interaction_id(db),
            get_max_event_id(db),
            "error",
            string(e),
        )
        return (success = false, error = string(e))
    end
end

"""
Extract tool executions from interactions table.
Parses request/response pairs and creates structured tool_executions records.
"""
function extract_tool_executions(db, last_id::Int)
    # Query for new request/response pairs
    query = """
        SELECT 
            req.id as req_id,
            resp.id as resp_id,
            req.session_id,
            req.request_id,
            req.timestamp as request_time,
            resp.timestamp as response_time,
            req.method,
            req.content as request_content,
            resp.content as response_content
        FROM interactions req
        LEFT JOIN interactions resp 
            ON req.request_id = resp.request_id 
            AND resp.direction = 'outbound'
            AND resp.message_type IN ('response', 'error')
        WHERE req.direction = 'inbound'
            AND req.message_type = 'request'
            AND req.method = 'tools/call'
            AND req.id > ?
        ORDER BY req.id
    """

    df = DBInterface.execute(db, query, (last_id,)) |> DataFrame

    if nrow(df) == 0
        return 0
    end

    count = 0
    for row in eachrow(df)
        try
            # Parse request content
            req_data = JSON.parse(row.request_content)
            params = get(req_data, "params", Dict())
            tool_name = get(params, "name", "unknown")
            arguments = get(params, "arguments", Dict())

            # Parse response content (if available)
            status = "pending"
            result_type = nothing
            result_summary = nothing
            response_time = ismissing(row.response_time) ? nothing : row.response_time

            if !ismissing(row.response_content)
                resp_data = JSON.parse(row.response_content)

                if haskey(resp_data, "result")
                    status = "success"
                    result = resp_data["result"]

                    if haskey(result, "content") && !isempty(result["content"])
                        result_type = "text"
                        content_item = result["content"][1]
                        if haskey(content_item, "text")
                            content_text = content_item["text"]
                            result_summary =
                                first(content_text, min(500, length(content_text)))
                        end
                    else
                        result_type = "other"
                        result_summary = JSON.json(result)
                    end
                elseif haskey(resp_data, "error")
                    status = "error"
                    result_type = "error"
                    error_obj = resp_data["error"]
                    result_summary = get(error_obj, "message", "Unknown error")
                end
            end

            # Calculate metrics
            duration_ms = if response_time !== nothing
                try
                    (
                        DateTime(response_time, dateformat"yyyy-mm-dd HH:MM:SS.sss") -
                        DateTime(row.request_time, dateformat"yyyy-mm-dd HH:MM:SS.sss")
                    ).value
                catch
                    nothing
                end
            else
                nothing
            end

            input_size = sizeof(row.request_content)
            output_size = ismissing(row.response_content) ? 0 : sizeof(row.response_content)
            argument_count = length(arguments)

            # Insert into tool_executions
            DBInterface.execute(
                db,
                """
            INSERT INTO tool_executions (
                session_id, request_id, tool_name, tool_method,
                request_time, response_time, duration_ms,
                input_size, output_size, argument_count,
                arguments, status, result_type, result_summary,
                interaction_request_id, interaction_response_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
                (
                    row.session_id,
                    row.request_id,
                    tool_name,
                    row.method,
                    row.request_time,
                    response_time,
                    duration_ms,
                    input_size,
                    output_size,
                    argument_count,
                    JSON.json(arguments),
                    status,
                    result_type,
                    result_summary,
                    row.req_id,
                    ismissing(row.resp_id) ? nothing : row.resp_id,
                ),
            )

            count += 1
        catch e
            @warn "Failed to extract tool execution" req_id = row.req_id exception = e
        end
    end

    @info "Extracted tool executions" count = count

    return count
end

"""
Extract errors from interactions and events tables.
Parses error responses and creates structured error records.
"""
function extract_errors(db, last_interaction_id::Int, last_event_id::Int)
    # Extract from interactions with error responses
    query = """
        SELECT 
            i.id,
            i.session_id,
            i.timestamp,
            i.request_id,
            i.method,
            i.content
        FROM interactions i
        WHERE i.direction = 'outbound'
            AND i.message_type IN ('response', 'error')
            AND i.id > ?
        ORDER BY i.id
    """

    df = DBInterface.execute(db, query, (last_interaction_id,)) |> DataFrame

    count = 0
    for row in eachrow(df)
        try
            content = JSON.parse(row.content)

            # Check if this is an error response
            if !haskey(content, "error")
                continue
            end

            error_obj = content["error"]

            error_code = get(error_obj, "code", nothing)
            error_message = get(error_obj, "message", "Unknown error")
            error_data = get(error_obj, "data", nothing)

            # Categorize error
            error_category = categorize_error_code(error_code)
            error_type = if !ismissing(row.method) && startswith(row.method, "tools/")
                "tool_error"
            else
                "protocol_error"
            end

            # Try to find the tool name from request
            tool_name = find_tool_name_for_request(db, row.request_id)

            # Extract stack trace if available
            stack_trace = if error_data !== nothing && haskey(error_data, "stack")
                error_data["stack"]
            else
                nothing
            end

            DBInterface.execute(
                db,
                """
            INSERT INTO errors (
                session_id, timestamp, error_type, error_code, error_category,
                tool_name, method, request_id, message, stack_trace, interaction_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
                (
                    row.session_id,
                    row.timestamp,
                    error_type,
                    error_code,
                    error_category,
                    tool_name,
                    row.method,
                    row.request_id,
                    error_message,
                    stack_trace,
                    row.id,
                ),
            )

            count += 1
        catch e
            @warn "Failed to extract error" interaction_id = row.id exception = e
        end
    end

    @info "Extracted errors" count = count

    return count
end

"""
Update client session summaries from interactions.
Tracks client connections, capabilities, and activity.
"""
function update_client_sessions(db, last_id::Int)
    # Find initialize requests that haven't been processed
    query = """
        SELECT 
            i.id,
            i.session_id,
            i.timestamp,
            i.content
        FROM interactions i
        WHERE i.direction = 'inbound'
            AND i.message_type = 'request'
            AND i.method = 'initialize'
            AND i.id > ?
        ORDER BY i.id
    """

    df = DBInterface.execute(db, query, (last_id,)) |> DataFrame

    count = 0
    for row in eachrow(df)
        try
            content = JSON.parse(row.content)
            params = get(content, "params", Dict())
            client_info = get(params, "clientInfo", Dict())

            client_name = get(client_info, "name", "unknown")
            client_version = get(client_info, "version", nothing)

            # Extract capabilities
            capabilities = get(params, "capabilities", Dict())
            supports_streaming = haskey(capabilities, "streaming")
            supports_notifications = haskey(capabilities, "notifications")

            protocol_version = get(params, "protocolVersion", nothing)

            # Check if client session already exists
            existing = DBInterface.execute(
                db,
                "SELECT id FROM client_sessions WHERE session_id = ?",
                (row.session_id,),
            )

            if isempty(collect(existing))
                # Insert new client session
                DBInterface.execute(
                    db,
                    """
                INSERT INTO client_sessions (
                    session_id, client_name, client_version,
                    connect_time, last_activity,
                    supports_streaming, supports_notifications,
                    protocol_version, initialization_params
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
                    (
                        row.session_id,
                        client_name,
                        client_version,
                        row.timestamp,
                        row.timestamp,
                        supports_streaming,
                        supports_notifications,
                        protocol_version,
                        JSON.json(params),
                    ),
                )

                count += 1
            else
                # Update last activity
                DBInterface.execute(
                    db,
                    "UPDATE client_sessions SET last_activity = ? WHERE session_id = ?",
                    (row.timestamp, row.session_id),
                )
            end
        catch e
            @warn "Failed to extract client session" interaction_id = row.id exception = e
        end
    end

    @info "Updated client sessions" count = count

    return count
end

"""
Calculate performance metrics from tool executions.
Aggregates timing and throughput data.
"""
function calculate_performance_metrics(db, last_id::Int)
    # Calculate hourly aggregates for tools executed since last_id
    query = """
        SELECT 
            session_id,
            tool_name,
            strftime('%Y-%m-%d %H:00:00', request_time) as hour,
            COUNT(*) as execution_count,
            AVG(duration_ms) as avg_duration_ms,
            MIN(duration_ms) as min_duration_ms,
            MAX(duration_ms) as max_duration_ms
        FROM tool_executions
        WHERE interaction_request_id > ?
            AND duration_ms IS NOT NULL
        GROUP BY session_id, tool_name, hour
        ORDER BY hour DESC
    """

    df = DBInterface.execute(db, query, (last_id,)) |> DataFrame

    if nrow(df) == 0
        return 0
    end

    count = 0
    for row in eachrow(df)
        try
            # Calculate p50, p95, p99 for this hour/tool combination
            # For now, use avg as approximation (could do more sophisticated calculation)
            p50 = row.avg_duration_ms
            p95 = row.max_duration_ms * 0.95
            p99 = row.max_duration_ms * 0.99

            # Calculate throughput (executions per second)
            throughput = row.execution_count / 3600.0  # per hour -> per second

            DBInterface.execute(
                db,
                """
            INSERT INTO performance_metrics (
                session_id, timestamp, metric_type, metric_name,
                duration_ms, throughput, tool_name,
                p50_ms, p95_ms, p99_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
                (
                    row.session_id,
                    row.hour,
                    "tool_execution",
                    "hourly_aggregate",
                    row.avg_duration_ms,
                    throughput,
                    row.tool_name,
                    p50,
                    p95,
                    p99,
                ),
            )

            count += 1
        catch e
            @warn "Failed to calculate performance metrics" row = row exception = e
        end
    end

    @info "Calculated performance metrics" count = count

    return count
end

# ============================================================================
# Helper Functions
# ============================================================================

"""Categorize JSON-RPC error codes into named categories."""
function categorize_error_code(code)
    if code === nothing
        return "unknown_error"
    end

    code_map = Dict(
        -32700 => "parse_error",
        -32600 => "invalid_request",
        -32601 => "method_not_found",
        -32602 => "invalid_params",
        -32603 => "internal_error",
    )
    get(code_map, code, "application_error")
end

"""Find tool name from a request ID by looking up the original request."""
function find_tool_name_for_request(db, request_id)
    if ismissing(request_id)
        return nothing
    end

    result = DBInterface.execute(
        db,
        """
        SELECT content
        FROM interactions
        WHERE request_id = ? AND direction = 'inbound' AND message_type = 'request'
        LIMIT 1
    """,
        (request_id,),
    )

    for row in result
        try
            content = JSON.parse(row.content)
            params = get(content, "params", Dict())
            return get(params, "name", nothing)
        catch
            return nothing
        end
    end

    return nothing
end

"""Get the last processed IDs from ETL metadata."""
function get_last_processed_ids(db)
    result =
        DBInterface.execute(
            db,
            "SELECT last_processed_interaction_id, last_processed_event_id FROM etl_metadata WHERE id = 1",
        ) |> DataFrame

    if nrow(result) == 0
        return (0, 0)
    end

    return (result[1, :last_processed_interaction_id], result[1, :last_processed_event_id])
end

"""Get maximum interaction ID in database."""
function get_max_interaction_id(db)
    result =
        DBInterface.execute(db, "SELECT COALESCE(MAX(id), 0) as max_id FROM interactions")
    for row in result
        return row.max_id
    end
    return 0
end

"""Get maximum event ID in database."""
function get_max_event_id(db)
    result = DBInterface.execute(db, "SELECT COALESCE(MAX(id), 0) as max_id FROM events")
    for row in result
        return row.max_id
    end
    return 0
end

"""Update ETL metadata with processing status."""
function update_etl_metadata(
    db,
    last_interaction_id::Int,
    last_event_id::Int,
    status::String,
    error::Union{String,Nothing},
)
    DBInterface.execute(
        db,
        """
        UPDATE etl_metadata 
        SET last_processed_interaction_id = ?,
            last_processed_event_id = ?,
            last_run_time = ?,
            last_run_status = ?,
            last_error = ?
        WHERE id = 1
    """,
        (
            last_interaction_id,
            last_event_id,
            Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss"),
            status,
            error,
        ),
    )
end

"""Truncate all analytics tables for full refresh."""
function truncate_analytics_tables(db)
    tables = [
        "tool_executions",
        "errors",
        "performance_metrics",
        "client_sessions",
        "session_lifecycle",
    ]

    for table in tables
        DBInterface.execute(db, "DELETE FROM $table")
    end

    @info "Truncated analytics tables" tables = tables
end

"""
Start ETL scheduler to run pipeline periodically.
Returns an async task that can be stopped.

Args:
- db: SQLite database connection
- interval_seconds: How often to run ETL (default: 60 seconds)
"""
function start_etl_scheduler(db; interval_seconds = 60)
    @info "Starting ETL scheduler" interval_seconds = interval_seconds

    task = @async begin
        while true
            try
                sleep(interval_seconds)
                run_etl_pipeline(db; mode = :incremental)
            catch e
                @error "ETL scheduler error" exception = (e, catch_backtrace())
                # Continue running despite errors
            end
        end
    end

    return task
end

end # module DatabaseETL
