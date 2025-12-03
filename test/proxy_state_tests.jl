using ReTest
using Dates
using HTTP
using JSON
using UUIDs

using MCPRepl
using MCPRepl.Proxy
using MCPRepl.Database

@testset "DateTime Parsing for Database Timestamps" begin
    # The database stores timestamps in format "yyyy-mm-dd HH:MM:SS.sss"
    # This must be parsed correctly by the heartbeat monitor

    timestamp_str = "2025-12-02 20:13:17.004"

    # This is the format used in the proxy heartbeat monitor
    dt = DateTime(timestamp_str, dateformat"yyyy-mm-dd HH:MM:SS.sss")

    @test dt isa DateTime
    @test year(dt) == 2025
    @test month(dt) == 12
    @test day(dt) == 2
    @test hour(dt) == 20
    @test minute(dt) == 13
    @test second(dt) == 17
    @test millisecond(dt) == 4

    # Test that we can compute time differences
    now_time = now()
    diff = now_time - dt
    @test diff isa Dates.Millisecond

    # Test edge cases
    @test DateTime("2025-01-01 00:00:00.000", dateformat"yyyy-mm-dd HH:MM:SS.sss") ==
          DateTime(2025, 1, 1, 0, 0, 0, 0)
    @test DateTime("2025-12-31 23:59:59.999", dateformat"yyyy-mm-dd HH:MM:SS.sss") ==
          DateTime(2025, 12, 31, 23, 59, 59, 999)
end

@testset "Proxy State Management" begin
    # Initialize temp database for these tests
    test_db = tempname() * ".db"
    Database.init_db!(test_db)

    @testset "Julia Session Registration and Retrieval" begin
        # Register a Julia session
        uuid = string(uuid4())
        success, error = Proxy.register_julia_session(uuid, "test-repl", 3001; pid = 12345)
        @test success
        @test error === nothing

        # Verify we can retrieve it
        session = Proxy.get_julia_session(uuid)
        @test session !== nothing
        @test session.name == "test-repl"
        @test session.port == 3001
        @test session.pid == 12345
        @test session.status == "ready"
    end

    @testset "Julia Session Status Updates" begin
        uuid = string(uuid4())
        success, _ = Proxy.register_julia_session(uuid, "status-test", 3002; pid = 12346)
        @test success

        # Update status to down (lost heartbeat)
        Proxy.update_julia_session_status(uuid, "down")
        session = Proxy.get_julia_session(uuid)
        @test session.status == "down"

        # Update status to restarting
        Proxy.update_julia_session_status(uuid, "restarting")
        session = Proxy.get_julia_session(uuid)
        @test session.status == "restarting"

        # Update status back to ready
        Proxy.update_julia_session_status(uuid, "ready")
        session = Proxy.get_julia_session(uuid)
        @test session.status == "ready"
    end

    @testset "Julia Session Unregistration" begin
        uuid = string(uuid4())
        success, _ =
            Proxy.register_julia_session(uuid, "unregister-test", 3003; pid = 12347)
        @test success

        # Verify it exists
        session = Proxy.get_julia_session(uuid)
        @test session !== nothing

        # Unregister
        Proxy.unregister_julia_session(uuid)

        # Verify status is updated (unregistration marks as stopped)
        session = Proxy.get_julia_session(uuid)
        @test session !== nothing
        @test session.status == "stopped"
    end

    @testset "List Julia Sessions" begin
        # Register a few sessions
        uuid1 = string(uuid4())
        uuid2 = string(uuid4())
        Proxy.register_julia_session(uuid1, "list-test-1", 3004; pid = 12348)
        Proxy.register_julia_session(uuid2, "list-test-2", 3005; pid = 12349)

        # List active sessions
        sessions = Proxy.list_julia_sessions()
        @test sessions isa Vector
        @test length(sessions) >= 2

        # Find our sessions
        names = [s.name for s in sessions]
        @test "list-test-1" in names
        @test "list-test-2" in names
    end

    @testset "MCP Session Creation and Retrieval" begin
        # Create an MCP session
        session = Proxy.create_mcp_session(nothing)
        @test session !== nothing
        @test session.id isa String
        @test !isempty(session.id)

        # Retrieve it
        retrieved = Proxy.get_mcp_session(session.id)
        @test retrieved !== nothing
        @test retrieved.id == session.id
    end

    @testset "MCP Session Target Assignment" begin
        # Create MCP session
        mcp_session = Proxy.create_mcp_session(nothing)
        @test mcp_session.target_julia_session_id === nothing

        # Create a Julia session to target
        julia_uuid = string(uuid4())
        Proxy.register_julia_session(julia_uuid, "target-test", 3006; pid = 12350)

        # Assign target
        mcp_session.target_julia_session_id = julia_uuid
        Proxy.save_mcp_session!(mcp_session)

        # Retrieve and verify
        retrieved = Proxy.get_mcp_session(mcp_session.id)
        @test retrieved !== nothing
        @test retrieved.target_julia_session_id == julia_uuid
    end

    @testset "Duplicate Session Name Handling" begin
        uuid1 = string(uuid4())
        uuid2 = string(uuid4())

        # Register first session
        success1, _ =
            Proxy.register_julia_session(uuid1, "duplicate-test", 3007; pid = 12351)
        @test success1

        # Register second session with same name - both should succeed
        # (the new architecture allows same names with different UUIDs)
        success2, _ =
            Proxy.register_julia_session(uuid2, "duplicate-test", 3008; pid = 12352)
        @test success2

        # Both should exist
        session1 = Proxy.get_julia_session(uuid1)
        session2 = Proxy.get_julia_session(uuid2)
        @test session1 !== nothing
        @test session2 !== nothing
    end

    @testset "Request Buffering" begin
        # Test that buffering infrastructure exists
        uuid = string(uuid4())

        # Buffer should start empty for new session
        has_pending = lock(Proxy.PENDING_REQUESTS_LOCK) do
            haskey(Proxy.PENDING_REQUESTS, uuid)
        end
        @test !has_pending

        # Note: Full request buffering test requires HTTP streams which are difficult to mock
    end

    # Cleanup
    Database.close_db!()
    rm(test_db; force = true)
end
