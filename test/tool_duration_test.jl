"""
Unit test for tool execution duration calculation.

This test catches the bug where tool durations can be negative due to
timestamp ordering issues in the database ETL process.
"""

using ReTest
using SQLite
using JSON
using Dates
using DBInterface
using UUIDs
using DataFrames

# Load modules
using MCPRepl
using MCPRepl.Database
using MCPRepl.Database: DatabaseETL

@testset "Tool Execution Duration Calculation" begin
    db_path = tempname() * ".db"

    try
        Database.init_db!(db_path)

        @testset "Duration should never be negative" begin
            mcp_session_id = string(UUIDs.uuid4())
            request_id = "test-request-1"

            # Register MCP session
            Database.register_mcp_session!(mcp_session_id)

            # Simulate a tool call with request and response logged in correct order
            request_time = now()
            response_time = request_time + Millisecond(1000)  # Response 1 second later

            request_content = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "start_julia_session",
                        "arguments" => Dict("project_path" => "/test/path"),
                    ),
                ),
            )

            response_content = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "result" => Dict(
                        "content" =>
                            [Dict("type" => "text", "text" => "Session started")],
                    ),
                ),
            )

            # Log request (inbound)
            Database.log_interaction!(
                "inbound",
                "request",
                request_content;
                mcp_session_id = mcp_session_id,
                request_id = request_id,
                method = "tools/call",
            )

            # Simulate processing time
            sleep(0.1)

            # Log response (outbound)
            Database.log_interaction!(
                "outbound",
                "response",
                response_content;
                mcp_session_id = mcp_session_id,
                request_id = request_id,
            )

            # Run ETL
            db = Database.DB[]
            DatabaseETL.run_etl_pipeline(db)

            # Query tool_executions
            result =
                DBInterface.execute(
                    db,
                    "SELECT tool_name, duration_ms FROM tool_executions WHERE request_id = ?",
                    (request_id,),
                ) |> DataFrame

            @test nrow(result) == 1
            row = result[1, :]

            @test row.tool_name == "start_julia_session"

            # CRITICAL: Duration must not be negative
            if row.duration_ms !== missing && row.duration_ms !== nothing
                @test row.duration_ms >= 0
            end
        end

        @testset "Duration calculation with actual timestamps" begin
            mcp_session_id = string(UUIDs.uuid4())
            request_id = "test-request-2"

            Database.register_mcp_session!(mcp_session_id)

            # Create request and response with explicit timestamps
            # This simulates what actually happens in the database
            db = Database.DB[]

            # Insert request interaction manually
            request_timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")
            request_content = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 2,
                    "method" => "tools/call",
                    "params" =>
                        Dict("name" => "list_julia_sessions", "arguments" => Dict()),
                ),
            )

            DBInterface.execute(
                db,
                """
                INSERT INTO interactions (
                    mcp_session_id, timestamp, direction, message_type,
                    request_id, method, content, content_size
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    mcp_session_id,
                    request_timestamp,
                    "inbound",
                    "request",
                    request_id,
                    "tools/call",
                    request_content,
                    sizeof(request_content),
                ),
            )

            # Wait and insert response
            sleep(0.05)
            response_timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")
            response_content = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 2,
                    "result" =>
                        Dict("content" => [Dict("type" => "text", "text" => "[]")]),
                ),
            )

            DBInterface.execute(
                db,
                """
                INSERT INTO interactions (
                    mcp_session_id, timestamp, direction, message_type,
                    request_id, content, content_size
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    mcp_session_id,
                    response_timestamp,
                    "outbound",
                    "response",
                    request_id,
                    response_content,
                    sizeof(response_content),
                ),
            )

            # Run ETL
            DatabaseETL.run_etl_pipeline(db)

            # Verify duration
            result =
                DBInterface.execute(
                    db,
                    "SELECT tool_name, duration_ms, request_time, response_time FROM tool_executions WHERE request_id = ?",
                    (request_id,),
                ) |> DataFrame

            @test nrow(result) == 1
            row = result[1, :]

            # Duration must be positive
            if row.duration_ms !== missing && row.duration_ms !== nothing
                @test row.duration_ms >= 0

                # Additionally verify the timestamps are in correct order
                req_time = DateTime(row.request_time, "yyyy-mm-dd HH:MM:SS.sss")
                resp_time = DateTime(row.response_time, "yyyy-mm-dd HH:MM:SS.sss")
                @test resp_time >= req_time
            end
        end

        @testset "Different sessions can reuse same request_id" begin
            # This tests the critical bug: request_id is only unique per session
            # Multiple MCP sessions can use request_id="1", so the ETL must match
            # on BOTH request_id AND mcp_session_id

            mcp_session_1 = string(UUIDs.uuid4())
            mcp_session_2 = string(UUIDs.uuid4())

            Database.register_mcp_session!(mcp_session_1)
            Database.register_mcp_session!(mcp_session_2)

            db = Database.DB[]

            # Session 1: request at T0, response at T1 (request_id="1")
            t0 = now()
            session1_request = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "method" => "tools/call",
                    "params" => Dict("name" => "tool_a", "arguments" => Dict()),
                ),
            )

            DBInterface.execute(
                db,
                """
                INSERT INTO interactions (mcp_session_id, timestamp, direction, message_type, request_id, method, content, content_size)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    mcp_session_1,
                    Dates.format(t0, "yyyy-mm-dd HH:MM:SS.sss"),
                    "inbound",
                    "request",
                    "1",
                    "tools/call",
                    session1_request,
                    sizeof(session1_request),
                ),
            )

            sleep(0.05)
            t1 = now()
            session1_response = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "result" =>
                        Dict("content" => [Dict("type" => "text", "text" => "ok")]),
                ),
            )

            DBInterface.execute(
                db,
                """
                INSERT INTO interactions (mcp_session_id, timestamp, direction, message_type, request_id, content, content_size)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    mcp_session_1,
                    Dates.format(t1, "yyyy-mm-dd HH:MM:SS.sss"),
                    "outbound",
                    "response",
                    "1",
                    session1_response,
                    sizeof(session1_response),
                ),
            )

            # Session 2: request at T2, response at T3 (ALSO request_id="1" - this is valid!)
            sleep(0.05)
            t2 = now()
            session2_request = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "method" => "tools/call",
                    "params" => Dict("name" => "tool_b", "arguments" => Dict()),
                ),
            )

            DBInterface.execute(
                db,
                """
                INSERT INTO interactions (mcp_session_id, timestamp, direction, message_type, request_id, method, content, content_size)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    mcp_session_2,
                    Dates.format(t2, "yyyy-mm-dd HH:MM:SS.sss"),
                    "inbound",
                    "request",
                    "1",
                    "tools/call",
                    session2_request,
                    sizeof(session2_request),
                ),
            )

            sleep(0.05)
            t3 = now()
            session2_response = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "result" =>
                        Dict("content" => [Dict("type" => "text", "text" => "ok")]),
                ),
            )

            DBInterface.execute(
                db,
                """
                INSERT INTO interactions (mcp_session_id, timestamp, direction, message_type, request_id, content, content_size)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    mcp_session_2,
                    Dates.format(t3, "yyyy-mm-dd HH:MM:SS.sss"),
                    "outbound",
                    "response",
                    "1",
                    session2_response,
                    sizeof(session2_response),
                ),
            )

            # Clear tool_executions table to ensure clean state
            DBInterface.execute(db, "DELETE FROM tool_executions")

            # Run ETL
            DatabaseETL.run_etl_pipeline(db)

            # Verify BOTH tools have correct positive durations
            result =
                DBInterface.execute(
                    db,
                    "SELECT tool_name, duration_ms, mcp_session_id FROM tool_executions ORDER BY tool_name",
                ) |> DataFrame

            @test nrow(result) == 2

            # Tool A (session 1)
            tool_a = result[result.tool_name.=="tool_a", :]
            @test nrow(tool_a) == 1
            @test tool_a[1, :mcp_session_id] == mcp_session_1
            if tool_a[1, :duration_ms] !== missing && tool_a[1, :duration_ms] !== nothing
                # CRITICAL: Duration must be positive
                @test tool_a[1, :duration_ms] >= 0
            end

            # Tool B (session 2)
            tool_b = result[result.tool_name.=="tool_b", :]
            @test nrow(tool_b) == 1
            @test tool_b[1, :mcp_session_id] == mcp_session_2
            if tool_b[1, :duration_ms] !== missing && tool_b[1, :duration_ms] !== nothing
                # CRITICAL: Duration must be positive (this will FAIL with current bug)
                @test tool_b[1, :duration_ms] >= 0
            end
        end

        @testset "ETL handles missing response gracefully" begin
            mcp_session_id = string(UUIDs.uuid4())
            request_id = "test-request-no-response"

            Database.register_mcp_session!(mcp_session_id)

            # Log only request, no response
            request_content = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 3,
                    "method" => "tools/call",
                    "params" => Dict("name" => "test_tool", "arguments" => Dict()),
                ),
            )

            Database.log_interaction!(
                "inbound",
                "request",
                request_content;
                mcp_session_id = mcp_session_id,
                request_id = request_id,
                method = "tools/call",
            )

            # Run ETL
            db = Database.DB[]
            DatabaseETL.run_etl_pipeline(db)

            # Query result
            result =
                DBInterface.execute(
                    db,
                    "SELECT duration_ms, status FROM tool_executions WHERE request_id = ?",
                    (request_id,),
                ) |> DataFrame

            @test nrow(result) == 1
            row = result[1, :]

            # Duration should be NULL/missing for pending requests
            @test row.duration_ms === missing || row.duration_ms === nothing
            @test row.status == "pending"
        end

    finally
        isfile(db_path) && rm(db_path)
    end
end
