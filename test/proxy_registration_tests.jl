"""
Unit tests for proxy REPL registration functionality.
Tests validation logic and registration behavior without HTTP server.
"""

using ReTest
using MCPRepl: Proxy

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
    using MCPRepl: Database
    using Dates

    # Create a temp database for testing
    db_path = tempname() * ".db"

    try
        # Initialize database
        Database.init_db!(db_path)

        @testset "Valid registration" begin
            # Register a Julia session
            success, error_msg = Proxy.register_julia_session(
                "test-repl-1",
                9000;
                pid = 12345,
                metadata = Dict("project" => "/tmp/test"),
            )

            @test success == true
            @test error_msg === nothing

            # Verify it's in the registry
            repl = lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
                get(Proxy.JULIA_SESSION_REGISTRY, "test-repl-1", nothing)
            end

            @test repl !== nothing
            @test repl.id == "test-repl-1"
            @test repl.port == 9000
            @test repl.pid == 12345
            @test repl.status == :ready
            @test get(repl.metadata, "project", nothing) == "/tmp/test"
        end

        @testset "Invalid registration - validation failure" begin
            # Try to register with invalid port
            success, error_msg = Proxy.register_julia_session(
                "test-repl-2",
                0;  # Invalid port
                pid = 12345,
            )

            @test success == false
            @test occursin("Port must be between 1024 and 65535", error_msg)

            # Verify it's NOT in the registry
            repl = lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
                get(Proxy.JULIA_SESSION_REGISTRY, "test-repl-2", nothing)
            end

            @test repl === nothing
        end

        @testset "Re-registration (reconnection)" begin
            # Register a REPL
            success1, _ = Proxy.register_julia_session("test-repl-3", 9001; pid = 12346)
            @test success1 == true

            # Re-register with different port (simulating restart)
            success2, error_msg2 =
                Proxy.register_julia_session("test-repl-3", 9002; pid = 12346)

            @test success2 == true
            @test error_msg2 === nothing

            # Verify updated registration
            repl = lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
                get(Proxy.JULIA_SESSION_REGISTRY, "test-repl-3", nothing)
            end

            @test repl !== nothing
            @test repl.port == 9002  # Updated port
        end

    finally
        # Clean up
        # Clear registry
        lock(Proxy.JULIA_SESSION_REGISTRY_LOCK) do
            empty!(Proxy.JULIA_SESSION_REGISTRY)
        end

        # Remove temp database
        if isfile(db_path)
            rm(db_path; force = true)
        end
    end
end
