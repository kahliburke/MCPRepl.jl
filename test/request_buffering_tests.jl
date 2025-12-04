using ReTest
using UUIDs
using HTTP
using JSON

using MCPRepl
using MCPRepl.Proxy
using MCPRepl.Database

@testset "Request Buffering Unit Tests" begin
    # Initialize temp database for these tests
    test_db = tempname() * ".db"
    Database.init_db!(test_db)

    @testset "Session status transitions" begin
        uuid = string(uuid4())
        session_name = "test-status-$(rand(1000:9999))"

        # Register session
        success, _ = Proxy.register_julia_session(uuid, session_name, 4005; pid = 99905)
        @test success

        # Initial status should be "ready"
        session = Proxy.get_julia_session(uuid)
        @test session !== nothing
        @test session.status == "ready"

        # Update to "down"
        Proxy.update_julia_session_status(uuid, "down")
        session = Proxy.get_julia_session(uuid)
        @test session.status == "down"

        # Update to "restarting"
        Proxy.update_julia_session_status(uuid, "restarting")
        session = Proxy.get_julia_session(uuid)
        @test session.status == "restarting"

        # Update back to "ready"
        Proxy.update_julia_session_status(uuid, "ready")
        session = Proxy.get_julia_session(uuid)
        @test session.status == "ready"

        # Clean up
        Proxy.unregister_julia_session(uuid)
    end

    @testset "get_julia_session prefers ready sessions by name" begin
        session_name = "test-prefer-ready-$(rand(1000:9999))"
        uuid1 = string(uuid4())
        uuid2 = string(uuid4())

        # Register first session
        success1, _ = Proxy.register_julia_session(uuid1, session_name, 4006; pid = 99906)
        @test success1

        # Mark it as down
        Proxy.update_julia_session_status(uuid1, "down")

        # Register second session with same name
        success2, _ = Proxy.register_julia_session(uuid2, session_name, 4007; pid = 99907)
        @test success2

        # When looking up by name, should return the "ready" session
        session = Proxy.get_julia_session(session_name)
        @test session !== nothing
        @test session.id == uuid2
        @test session.status == "ready"

        # Clean up
        Proxy.unregister_julia_session(uuid1)
        Proxy.unregister_julia_session(uuid2)
    end

    # Cleanup
    Database.close_db!()
    rm(test_db; force = true)
end
