using ReTest
using Dates
using HTTP
using JSON

using MCPRepl
using MCPRepl.Proxy
using MCPRepl.Database

@testset "Proxy State Management" begin
    # Initialize temp database for these tests
    test_db = tempname() * ".db"
    Database.init_db!(test_db)

    @testset "REPL Connection Structure" begin
        # Clear registry
        empty!(Proxy.JULIA_SESSION_REGISTRY)

        # Register a REPL
        Proxy.register_julia_session("test-repl", 3001; pid = 12345)

        # Verify structure with new fields
        repl = Proxy.get_julia_session("test-repl")
        @test repl !== nothing
        @test repl.status == :ready
        @test repl.pending_requests isa Vector
        @test isempty(repl.pending_requests)
        @test repl.disconnect_time === nothing
        @test repl.missed_heartbeats == 0
    end

    @testset "Status Transitions" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)
        Proxy.register_julia_session("status-test", 3002; pid = 12346)

        # ready -> disconnected
        lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
            Proxy.JULIA_SESSION_REGISTRY["status-test"].status = :disconnected
            Proxy.JULIA_SESSION_REGISTRY["status-test"].disconnect_time = now()
        end
        repl = Proxy.get_julia_session("status-test")
        @test repl.status == :disconnected
        @test repl.disconnect_time !== nothing

        # disconnected -> reconnecting
        lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
            Proxy.JULIA_SESSION_REGISTRY["status-test"].status = :reconnecting
        end
        repl = Proxy.get_julia_session("status-test")
        @test repl.status == :reconnecting

        # reconnecting -> ready (via update_julia_session_status)
        Proxy.update_julia_session_status("status-test", :ready)
        repl = Proxy.get_julia_session("status-test")
        @test repl.status == :ready
        @test repl.missed_heartbeats == 0
        @test repl.disconnect_time === nothing

        # ready -> stopped
        lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
            Proxy.JULIA_SESSION_REGISTRY["status-test"].status = :stopped
        end
        repl = Proxy.get_julia_session("status-test")
        @test repl.status == :stopped
    end

    @testset "Request Buffering" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)
        Proxy.register_julia_session("buffer-test", 3003; pid = 12347)

        # Simulate adding pending requests
        mock_request = Dict("method" => "test", "id" => 1)
        # Note: We can't create a real HTTP.Stream easily, so we test the structure

        lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
            Proxy.JULIA_SESSION_REGISTRY["buffer-test"].status = :disconnected
            # Would normally add: push!(Proxy.JULIA_SESSION_REGISTRY["buffer-test"].pending_requests, (mock_request, mock_stream))
        end

        repl = Proxy.get_julia_session("buffer-test")
        @test repl.status == :disconnected
        @test isempty(repl.pending_requests)  # Empty because we didn't add mock stream
    end

    @testset "Heartbeat Timeout Detection" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)
        Proxy.register_julia_session("heartbeat-test", 3004; pid = 12348)

        # Simulate old heartbeat
        lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
            Proxy.JULIA_SESSION_REGISTRY["heartbeat-test"].last_heartbeat =
                now() - Second(20)
        end

        repl = Proxy.get_julia_session("heartbeat-test")
        time_since = now() - repl.last_heartbeat
        @test time_since > Second(15)
        @test repl.status == :ready  # Still ready until monitor runs

        # Manually trigger the timeout logic
        lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
            if haskey(Proxy.JULIA_SESSION_REGISTRY, "heartbeat-test")
                Proxy.JULIA_SESSION_REGISTRY["heartbeat-test"].status = :disconnected
                Proxy.JULIA_SESSION_REGISTRY["heartbeat-test"].disconnect_time = now()
            end
        end

        repl = Proxy.get_julia_session("heartbeat-test")
        @test repl.status == :disconnected
        @test repl.disconnect_time !== nothing
    end

    @testset "Reconnection Recovery" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)
        Proxy.register_julia_session("recovery-test", 3005; pid = 12349)

        # Simulate disconnection
        lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
            Proxy.JULIA_SESSION_REGISTRY["recovery-test"].status = :disconnected
            Proxy.JULIA_SESSION_REGISTRY["recovery-test"].disconnect_time = now()
            Proxy.JULIA_SESSION_REGISTRY["recovery-test"].missed_heartbeats = 2
        end

        # Recover via update_julia_session_status(:ready)
        Proxy.update_julia_session_status("recovery-test", :ready)

        repl = Proxy.get_julia_session("recovery-test")
        @test repl.status == :ready
        @test repl.missed_heartbeats == 0
        @test repl.disconnect_time === nothing
    end

    @testset "Heartbeat Recovery from Disconnected State" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)
        Proxy.register_julia_session("heartbeat-recovery-test", 3008; pid = 12352)

        # Simulate disconnection via timeout
        lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
            Proxy.JULIA_SESSION_REGISTRY["heartbeat-recovery-test"].status = :disconnected
            Proxy.JULIA_SESSION_REGISTRY["heartbeat-recovery-test"].disconnect_time = now()
            Proxy.JULIA_SESSION_REGISTRY["heartbeat-recovery-test"].missed_heartbeats = 3
        end

        repl = Proxy.get_julia_session("heartbeat-recovery-test")
        @test repl.status == :disconnected
        @test repl.missed_heartbeats == 3

        # Simulate heartbeat coming in (updates last_heartbeat and recovers status)
        lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
            if haskey(Proxy.JULIA_SESSION_REGISTRY, "heartbeat-recovery-test")
                Proxy.JULIA_SESSION_REGISTRY["heartbeat-recovery-test"].last_heartbeat =
                    now()
                Proxy.JULIA_SESSION_REGISTRY["heartbeat-recovery-test"].missed_heartbeats =
                    0
                # Automatically recover from disconnected state on heartbeat
                if Proxy.JULIA_SESSION_REGISTRY["heartbeat-recovery-test"].status in
                   (:stopped, :disconnected, :reconnecting)
                    Proxy.JULIA_SESSION_REGISTRY["heartbeat-recovery-test"].status = :ready
                    Proxy.JULIA_SESSION_REGISTRY["heartbeat-recovery-test"].last_error =
                        nothing
                    Proxy.JULIA_SESSION_REGISTRY["heartbeat-recovery-test"].disconnect_time =
                        nothing
                end
            end
        end

        repl = Proxy.get_julia_session("heartbeat-recovery-test")
        @test repl.status == :ready
        @test repl.missed_heartbeats == 0
        @test repl.disconnect_time === nothing
    end

    @testset "Permanent Stop After Timeout" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)
        Proxy.register_julia_session("timeout-test", 3006; pid = 12350)

        # Simulate long disconnection (>5 minutes)
        lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
            Proxy.JULIA_SESSION_REGISTRY["timeout-test"].status = :disconnected
            Proxy.JULIA_SESSION_REGISTRY["timeout-test"].disconnect_time = now() - Minute(6)
        end

        repl = Proxy.get_julia_session("timeout-test")
        disconnect_duration = now() - repl.disconnect_time
        @test disconnect_duration > Minute(5)

        # Should be marked as stopped by error handler
        # (we test the condition, actual marking happens in route_to_session_streaming)
    end

    @testset "Missed Heartbeats Counter" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)
        Proxy.register_julia_session("counter-test", 3007; pid = 12351)

        repl = Proxy.get_julia_session("counter-test")
        @test repl.missed_heartbeats == 0

        # Increment counter via update_julia_session_status with error
        Proxy.update_julia_session_status("counter-test", :ready; error = "Test error")
        repl = Proxy.get_julia_session("counter-test")
        @test repl.missed_heartbeats == 1

        # Reset counter via successful ready status
        Proxy.update_julia_session_status("counter-test", :ready)
        repl = Proxy.get_julia_session("counter-test")
        @test repl.missed_heartbeats == 0
    end

    @testset "MCP Session Auto-Creation on Missing Session" begin
        # This tests the scenario where an MCP session ID doesn't exist
        # (e.g., after proxy restart) and gets auto-created on demand

        empty!(Proxy.MCP_SESSION_REGISTRY)

        # Create a test MCP session ID
        test_session_id = "test-mcp-session-123"

        # Verify it doesn't exist initially
        @test Proxy.get_mcp_session(test_session_id) === nothing

        # Simulate what connect_to_session does: create on the fly
        session = Proxy.create_mcp_session(nothing)

        # Override with the client's session ID
        lock(Proxy.MCP_SESSION_LOCK) do
            delete!(Proxy.MCP_SESSION_REGISTRY, session.id)
            session.id = test_session_id
            Proxy.MCP_SESSION_REGISTRY[test_session_id] = session
        end

        # Verify the session now exists with the expected ID
        retrieved = Proxy.get_mcp_session(test_session_id)
        @test retrieved !== nothing
        @test retrieved.id == test_session_id
        @test retrieved.target_julia_session_id === nothing

        # Test setting a target
        retrieved.target_julia_session_id = "julia-uuid-123"
        @test retrieved.target_julia_session_id == "julia-uuid-123"

        # Clean up
        empty!(Proxy.MCP_SESSION_REGISTRY)
    end

    # Cleanup
    Database.close_db!()
    rm(test_db; force = true)
end
