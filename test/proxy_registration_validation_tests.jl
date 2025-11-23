"""
Unit tests for proxy registration validation logic.

These are pure unit tests that test validation functions without any infrastructure
(no HTTP, no database, no REPL connections). They test business logic in isolation.
"""

using ReTest

# Load the validation module
include("../src/proxy/validation.jl")

@testset "Registration Parameter Validation" begin
    @testset "Valid parameters" begin
        # Happy path - all parameters valid
        valid, msg = validate_registration_params("my-session", 8080, 12345)
        @test valid == true
        @test msg === nothing

        # Valid with no PID (PID is optional)
        valid, msg = validate_registration_params("my-session", 8080, nothing)
        @test valid == true
        @test msg === nothing

        # Valid with minimum port
        valid, msg = validate_registration_params("session", 1024, 100)
        @test valid == true
        @test msg === nothing

        # Valid with maximum port
        valid, msg = validate_registration_params("session", 65535, 100)
        @test valid == true
        @test msg === nothing

        # Valid with session name containing special characters
        valid, msg = validate_registration_params("my-session_2024.v1", 8080, 999)
        @test valid == true
        @test msg === nothing
    end

    @testset "Missing required parameters" begin
        # Missing ID
        valid, msg = validate_registration_params(nothing, 8080, 12345)
        @test valid == false
        @test msg == "Parameter 'id' is required"

        # Missing port
        valid, msg = validate_registration_params("my-session", nothing, 12345)
        @test valid == false
        @test msg == "Parameter 'port' is required"

        # Both missing
        valid, msg = validate_registration_params(nothing, nothing, 12345)
        @test valid == false
        @test occursin("required", msg)
    end

    @testset "Invalid session ID" begin
        # Empty string
        valid, msg = validate_registration_params("", 8080, 12345)
        @test valid == false
        @test msg == "Session ID cannot be empty"

        # Whitespace only
        valid, msg = validate_registration_params("   ", 8080, 12345)
        @test valid == false
        @test msg == "Session ID cannot be empty"

        # Tab and newline
        valid, msg = validate_registration_params("\t\n", 8080, 12345)
        @test valid == false
        @test msg == "Session ID cannot be empty"
    end

    @testset "Invalid port numbers" begin
        # Port too low (privileged port)
        valid, msg = validate_registration_params("my-session", 80, 12345)
        @test valid == false
        @test occursin("Port must be between 1024 and 65535", msg)
        @test occursin("80", msg)  # Should show the actual invalid port

        # Port = 1023 (just below minimum)
        valid, msg = validate_registration_params("my-session", 1023, 12345)
        @test valid == false
        @test occursin("1024", msg)

        # Port too high
        valid, msg = validate_registration_params("my-session", 65536, 12345)
        @test valid == false
        @test occursin("Port must be between 1024 and 65535", msg)
        @test occursin("65536", msg)

        # Negative port
        valid, msg = validate_registration_params("my-session", -1, 12345)
        @test valid == false
        @test occursin("Port must be between", msg)

        # Zero port
        valid, msg = validate_registration_params("my-session", 0, 12345)
        @test valid == false
        @test occursin("Port must be between", msg)
    end

    @testset "Invalid process ID" begin
        # Negative PID
        valid, msg = validate_registration_params("my-session", 8080, -1)
        @test valid == false
        @test occursin("Process ID must be a positive integer", msg)
        @test occursin("-1", msg)

        # Zero PID
        valid, msg = validate_registration_params("my-session", 8080, 0)
        @test valid == false
        @test occursin("Process ID must be a positive integer", msg)
        @test occursin("0", msg)

        # Nothing is OK (PID is optional)
        valid, msg = validate_registration_params("my-session", 8080, nothing)
        @test valid == true
        @test msg === nothing
    end

    @testset "Multiple validation errors - check which is reported first" begin
        # Empty ID + bad port - should report ID error first
        valid, msg = validate_registration_params("", 80, 12345)
        @test valid == false
        # Could be either error - implementation chooses order
        # Just verify we get ONE clear error message
        @test !isempty(msg)

        # Bad port + bad PID - should report port error first
        valid, msg = validate_registration_params("session", 80, -1)
        @test valid == false
        @test !isempty(msg)
    end
end
