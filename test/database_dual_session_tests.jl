using ReTest
using SQLite
using JSON
using DataFrames
using Dates
using DBInterface
using MCPRepl
using MCPRepl.Database: get_julia_session

@testset "Dual-Session Database Model" begin
    # Use temporary database for testing
    test_db = tempname() * ".db"

    @testset "Database Initialization with Dual Sessions" begin
        db = init_db!(test_db)
        @test db !== nothing
        @test isfile(test_db)

        # Enable foreign key constraints for testing
        DBInterface.execute(db, "PRAGMA foreign_keys = ON")

        # Verify both session tables exist
        tables =
            DBInterface.execute(db, "SELECT name FROM sqlite_master WHERE type='table'") |>
            DataFrame
        @test "mcp_sessions" in tables.name
        @test "julia_sessions" in tables.name
    end

    @testset "MCP Session Registration" begin
        mcp_id = "mcp-client-123"
        metadata = Dict("client_name" => "vscode", "version" => "1.0.0")

        register_mcp_session!(
            mcp_id,
            "active";
            name = "VSCode Client",
            session_type = "mcp_client",
            metadata = metadata,
        )

        # Verify session was created
        db = Database.DB[]
        sessions =
            DBInterface.execute(db, "SELECT * FROM mcp_sessions WHERE id = ?", (mcp_id,)) |>
            DataFrame

        @test nrow(sessions) == 1
        @test sessions[1, :name] == "VSCode Client"
        @test sessions[1, :status] == "active"
        @test sessions[1, :session_type] == "mcp_client"
    end

    @testset "Julia Session Registration" begin
        julia_id = "MCPRepl"

        register_julia_session!(
            julia_id,
            "MCPRepl Project",
            "active";
            port = 3001,
            pid = 12345,
            metadata = Dict("project_path" => "/path/to/project"),
        )

        # Verify session was created
        db = Database.DB[]
        sessions =
            DBInterface.execute(
                db,
                "SELECT * FROM julia_sessions WHERE id = ?",
                (julia_id,),
            ) |> DataFrame

        @test nrow(sessions) == 1
        @test sessions[1, :name] == "MCPRepl Project"
        @test sessions[1, :port] == 3001
        @test sessions[1, :pid] == 12345
        @test sessions[1, :status] == "active"
    end

    @testset "Julia Session with Nullable Port" begin
        julia_id = "auto-created-session"

        # Should work with no port/pid (auto-created sessions)
        register_julia_session!(
            julia_id,
            "Auto Created",
            "active";
            metadata = Dict("auto_created" => true),
        )

        db = Database.DB[]
        sessions =
            DBInterface.execute(
                db,
                "SELECT * FROM julia_sessions WHERE id = ?",
                (julia_id,),
            ) |> DataFrame

        @test nrow(sessions) == 1
        @test sessions[1, :name] == "Auto Created"
        @test ismissing(sessions[1, :port])
        @test ismissing(sessions[1, :pid])
    end

    @testset "Event Logging with Dual Sessions" begin
        mcp_id = "mcp-event-test"
        julia_id = "julia-event-test"

        register_mcp_session!(mcp_id, "active"; name = "Test MCP")
        register_julia_session!(julia_id, "Test Julia"; port = 3002)

        # Log event with both session IDs
        log_event!(
            "tool.call.start",
            Dict("tool" => "ex", "code" => "2+2");
            mcp_session_id = mcp_id,
            julia_session_id = julia_id,
        )

        # Log event with only MCP session
        log_event!(
            "request.received",
            Dict("method" => "initialize");
            mcp_session_id = mcp_id,
        )

        # Log event with only Julia session
        log_event!("repl.heartbeat", Dict("status" => "ok"); julia_session_id = julia_id)

        # Verify events were logged
        db = Database.DB[]
        events = DBInterface.execute(db, "SELECT * FROM events ORDER BY id") |> DataFrame

        @test nrow(events) >= 3

        # Check dual-session event
        dual_event = filter(row -> row.event_type == "tool.call.start", events)
        @test nrow(dual_event) == 1
        @test dual_event[1, :mcp_session_id] == mcp_id
        @test dual_event[1, :julia_session_id] == julia_id

        # Check MCP-only event
        mcp_event = filter(row -> row.event_type == "request.received", events)
        @test nrow(mcp_event) == 1
        @test mcp_event[1, :mcp_session_id] == mcp_id
        @test ismissing(mcp_event[1, :julia_session_id])

        # Check Julia-only event
        julia_event = filter(row -> row.event_type == "repl.heartbeat", events)
        @test nrow(julia_event) == 1
        @test ismissing(julia_event[1, :mcp_session_id])
        @test julia_event[1, :julia_session_id] == julia_id
    end

    @testset "Interaction Logging with HTTP Metadata" begin
        mcp_id = "mcp-interaction-test"
        julia_id = "julia-interaction-test"

        register_mcp_session!(mcp_id, "active"; name = "Test MCP Client")
        register_julia_session!(julia_id, "Test Julia REPL"; port = 3003, pid = 99999)

        # Log inbound request with full HTTP metadata
        request = Dict(
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => Dict("name" => "ex", "arguments" => Dict("e" => "2+2")),
        )

        log_interaction!(
            "inbound",
            "request",
            request;
            mcp_session_id = mcp_id,
            julia_session_id = julia_id,
            request_id = "1",
            method = "tools/call",
            http_method = "POST",
            http_path = "/",
            http_headers = JSON.json(Dict("Content-Type" => "application/json")),
            remote_addr = "127.0.0.1",
            user_agent = "node",
            content_type = "application/json",
        )

        # Log outbound response
        response = Dict(
            "jsonrpc" => "2.0",
            "id" => 1,
            "result" => Dict("content" => [Dict("type" => "text", "text" => "4")]),
        )

        log_interaction!(
            "outbound",
            "response",
            response;
            mcp_session_id = mcp_id,
            julia_session_id = julia_id,
            request_id = "1",
            method = "tools/call",
            http_status_code = 200,
            processing_time_ms = 45.6,
        )

        # Verify interactions
        db = Database.DB[]
        interactions =
            DBInterface.execute(
                db,
                "SELECT * FROM interactions WHERE request_id = ?",
                ("1",),
            ) |> DataFrame

        @test nrow(interactions) == 2

        # Check inbound with HTTP metadata
        inbound = filter(row -> row.direction == "inbound", interactions)
        @test nrow(inbound) == 1
        @test inbound[1, :mcp_session_id] == mcp_id
        @test inbound[1, :julia_session_id] == julia_id
        @test inbound[1, :http_method] == "POST"
        @test inbound[1, :http_path] == "/"
        @test inbound[1, :user_agent] == "node"
        @test inbound[1, :content_type] == "application/json"
        @test inbound[1, :remote_addr] == "127.0.0.1"

        # Check outbound with processing time
        outbound = filter(row -> row.direction == "outbound", interactions)
        @test nrow(outbound) == 1
        @test outbound[1, :http_status_code] == 200
        @test outbound[1, :processing_time_ms] ≈ 45.6
    end

    @testset "Safe Logging with Auto-Creation" begin
        # Should auto-create MCP sessions if they don't exist
        # Note: Julia sessions are NOT auto-created - they must be registered by the REPL
        mcp_auto = "mcp-auto-123"
        julia_auto = "julia-auto-456"

        log_interaction_safe!(
            "inbound",
            "request",
            "test content";
            mcp_session_id = mcp_auto,
            julia_session_id = julia_auto,
            julia_session_port = 4000,
            julia_session_pid = 11111,
            request_id = "auto-1",
        )

        # Verify MCP session was auto-created
        db = Database.DB[]

        mcp_sessions =
            DBInterface.execute(
                db,
                "SELECT * FROM mcp_sessions WHERE id = ?",
                (mcp_auto,),
            ) |> DataFrame
        @test nrow(mcp_sessions) == 1

        # Verify session_data contains auto_created flag in nested metadata
        session_data = JSON.parse(mcp_sessions[1, :session_data])
        @test session_data["metadata"]["auto_created"] == true

        # Julia sessions are NOT auto-created (by design)
        # They must be properly registered with a logical name by the REPL itself
        julia_sessions =
            DBInterface.execute(
                db,
                "SELECT * FROM julia_sessions WHERE id = ?",
                (julia_auto,),
            ) |> DataFrame
        @test nrow(julia_sessions) == 0  # Should NOT be auto-created
    end

    @testset "ETL: Tool Executions" begin
        mcp_id = "mcp-etl-test"
        julia_id = "julia-etl-test"

        register_mcp_session!(mcp_id, "active"; name = "ETL Test Client")
        register_julia_session!(julia_id, "ETL Test REPL", "active"; port = 5000)

        # Create a request-response pair
        request_id = "etl-req-1"

        log_interaction!(
            "inbound",
            "request",
            Dict(
                "jsonrpc" => "2.0",
                "id" => 1,
                "method" => "tools/call",
                "params" =>
                    Dict("name" => "ex", "arguments" => Dict("e" => "println(\"hello\")")),
            );
            mcp_session_id = mcp_id,
            julia_session_id = julia_id,
            request_id = request_id,
            method = "tools/call",
        )

        sleep(0.05)  # Simulate processing time

        log_interaction!(
            "outbound",
            "response",
            Dict(
                "jsonrpc" => "2.0",
                "id" => 1,
                "result" =>
                    Dict("content" => [Dict("type" => "text", "text" => "hello\\n")]),
            );
            mcp_session_id = mcp_id,
            julia_session_id = julia_id,
            request_id = request_id,
            method = "tools/call",
        )

        # Run ETL - module already loaded at top level
        db = Database.DB[]
        result = DatabaseETL.run_etl_pipeline(db; mode = :incremental)

        @test result.success == true
        @test result.tool_executions >= 1

        # Check tool_executions table
        tool_execs =
            DBInterface.execute(
                db,
                "SELECT * FROM tool_executions WHERE request_id = ?",
                (request_id,),
            ) |> DataFrame

        @test nrow(tool_execs) >= 1
        @test tool_execs[1, :mcp_session_id] == mcp_id
        @test tool_execs[1, :tool_name] == "ex"
        @test tool_execs[1, :duration_ms] > 0
    end

    @testset "Foreign Key Constraints" begin
        # Should fail to insert interaction with non-existent session
        db = Database.DB[]

        @test_throws SQLite.SQLiteException DBInterface.execute(
            db,
            """
            INSERT INTO interactions (
                mcp_session_id, julia_session_id, timestamp, direction,
                message_type, content, content_size
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "non-existent-mcp",
                "non-existent-julia",
                Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss"),
                "inbound",
                "request",
                "test",
                4,
            ),
        )
    end

    @testset "Session Activity Updates" begin
        mcp_id = "mcp-activity-test"
        julia_id = "julia-activity-test"

        register_mcp_session!(mcp_id, "active"; name = "Activity Test")
        register_julia_session!(julia_id, "Activity REPL", "active"; port = 6000)

        # Get initial timestamps
        db = Database.DB[]
        initial_mcp =
            DBInterface.execute(
                db,
                "SELECT last_activity FROM mcp_sessions WHERE id = ?",
                (mcp_id,),
            ) |> DataFrame
        initial_time_mcp = initial_mcp[1, :last_activity]

        sleep(0.1)

        # Log interaction
        log_interaction!(
            "inbound",
            "request",
            "activity test";
            mcp_session_id = mcp_id,
            julia_session_id = julia_id,
        )

        # Check that last_activity was updated
        updated_mcp =
            DBInterface.execute(
                db,
                "SELECT last_activity FROM mcp_sessions WHERE id = ?",
                (mcp_id,),
            ) |> DataFrame
        @test updated_mcp[1, :last_activity] > initial_time_mcp

        updated_julia =
            DBInterface.execute(
                db,
                "SELECT last_activity FROM julia_sessions WHERE id = ?",
                (julia_id,),
            ) |> DataFrame
        # Julia session should also be updated
        @test !ismissing(updated_julia[1, :last_activity])
    end

    @testset "get_julia_session by UUID or Name" begin
        # Create a session with unique UUID and name
        test_uuid = "test-julia-uuid-lookup-$(rand(1000:9999))"
        test_name = "TestJuliaLookup"

        register_julia_session!(
            test_uuid,
            test_name,
            "active";
            port = 7001,
            pid = 99999,
            metadata = Dict("lookup_test" => true),
        )

        # Test lookup by UUID
        session_by_uuid = get_julia_session(test_uuid)
        @test session_by_uuid !== nothing
        @test session_by_uuid.id == test_uuid
        @test session_by_uuid.name == test_name
        @test session_by_uuid.port == 7001

        # Test lookup by name
        session_by_name = get_julia_session(test_name)
        @test session_by_name !== nothing
        @test session_by_name.id == test_uuid
        @test session_by_name.name == test_name
        @test session_by_name.port == 7001

        # Test lookup by non-existent identifier
        nonexistent = get_julia_session("nonexistent-session-xyz")
        @test nonexistent === nothing
    end

    # Cleanup
    @testset "Cleanup" begin
        close_db!()
        rm(test_db; force = true)
    end
end
