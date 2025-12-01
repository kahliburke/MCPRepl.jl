"""
Unit tests for proxy REPL registration functionality.
Tests validation logic and registration behavior without HTTP server.
"""

using ReTest
using UUIDs
using MCPRepl: Proxy, Database

@testset "Registration validation" begin
    @testset "Valid parameters" begin
        # Test valid registration
        success, error_msg = Proxy.validate_registration_params("test-repl", 8080, 12345)
        @test success == true
        @test error_msg === nothing

        # Test valid registration without PID
        success, error_msg = Proxy.validate_registration_params("test-repl", 8080, nothing)
        @test success == true
        @test error_msg === nothing

        # Test minimum valid port (1024 is the actual minimum)
        success, error_msg = Proxy.validate_registration_params("test-repl", 1024, nothing)
        @test success == true
        @test error_msg === nothing

        # Test maximum valid port
        success, error_msg = Proxy.validate_registration_params("test-repl", 65535, nothing)
        @test success == true
        @test error_msg === nothing
    end

    @testset "Invalid ID" begin
        # Empty ID
        success, error_msg = Proxy.validate_registration_params("", 8080, nothing)
        @test success == false
        @test error_msg == "Session ID cannot be empty"

        # Whitespace-only ID
        success, error_msg = Proxy.validate_registration_params("   ", 8080, nothing)
        @test success == false
        @test error_msg == "Session ID cannot be empty"
    end

    @testset "Invalid port" begin
        # Port too low
        success, error_msg = Proxy.validate_registration_params("test-repl", 0, nothing)
        @test success == false
        @test occursin("Port must be between 1024 and 65535", error_msg)

        # Negative port
        success, error_msg = Proxy.validate_registration_params("test-repl", -1, nothing)
        @test success == false
        @test occursin("Port must be between 1024 and 65535", error_msg)

        # Port too high
        success, error_msg = Proxy.validate_registration_params("test-repl", 65536, nothing)
        @test success == false
        @test occursin("Port must be between 1024 and 65535", error_msg)
    end

    @testset "Invalid PID" begin
        # Zero PID
        success, error_msg = Proxy.validate_registration_params("test-repl", 8080, 0)
        @test success == false
        @test occursin("Process ID must be a positive integer", error_msg)

        # Negative PID
        success, error_msg = Proxy.validate_registration_params("test-repl", 8080, -1)
        @test success == false
        @test occursin("Process ID must be a positive integer", error_msg)
    end
end

@testset "REPL registration" begin
    # Create a temp database for testing
    db_path = tempname() * ".db"

    try
        # Initialize database
        Database.init_db!(db_path)

        @testset "Valid registration" begin
            uuid = string(uuid4())
            # Register a Julia session
            success, error_msg = Proxy.register_julia_session(
                uuid,
                "test-repl-1",
                9000;
                pid = 12345,
                metadata = Dict("project" => "/tmp/test"),
            )

            @test success == true
            @test error_msg === nothing

            # Verify it's in the database
            session = Proxy.get_julia_session(uuid)

            @test session !== nothing
            @test session.name == "test-repl-1"
            @test session.port == 9000
            @test session.pid == 12345
            @test session.status == "ready"
        end

        @testset "Invalid registration - validation failure" begin
            uuid = string(uuid4())
            # Try to register with invalid port
            success, error_msg = Proxy.register_julia_session(
                uuid,
                "test-repl-2",
                0;  # Invalid port
                pid = 12345,
            )

            @test success == false
            @test occursin("Port must be between 1024 and 65535", error_msg)

            # Verify it's NOT in the database
            session = Proxy.get_julia_session(uuid)
            @test session === nothing
        end

        @testset "Re-registration (same UUID reconnection)" begin
            uuid = string(uuid4())

            # Register a REPL
            success1, _ =
                Proxy.register_julia_session(uuid, "test-repl-3", 9001; pid = 12346)
            @test success1 == true

            # Re-register with same UUID but different port (simulating reconnection)
            success2, error_msg2 =
                Proxy.register_julia_session(uuid, "test-repl-3", 9002; pid = 12346)

            @test success2 == true
            @test error_msg2 === nothing

            # Verify updated registration
            session = Proxy.get_julia_session(uuid)
            @test session !== nothing
            @test session.port == 9002  # Updated port
        end

        @testset "Restart with new UUID" begin
            uuid1 = string(uuid4())
            uuid2 = string(uuid4())

            # Register first session
            success1, _ =
                Proxy.register_julia_session(uuid1, "restart-test", 9003; pid = 12347)
            @test success1 == true

            # Register second session with same name but new UUID (restart scenario)
            success2, _ =
                Proxy.register_julia_session(uuid2, "restart-test", 9004; pid = 12348)
            @test success2 == true

            # Both should exist in database (old one may be marked as replaced)
            session1 = Proxy.get_julia_session(uuid1)
            session2 = Proxy.get_julia_session(uuid2)
            @test session1 !== nothing
            @test session2 !== nothing
            @test session2.status == "ready"  # New one should be ready
        end

    finally
        # Clean up
        Database.close_db!()

        # Remove temp database
        if isfile(db_path)
            rm(db_path; force = true)
        end
    end
end
