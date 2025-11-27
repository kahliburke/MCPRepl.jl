"""
Unit tests for MCPSession database serialization/deserialization
"""

using ReTest
using MCPRepl
using MCPRepl.Proxy
using MCPRepl.Proxy.Session
using MCPRepl.Database
using JSON
using Dates

@testset "MCPSession Serialization Tests" begin

    @testset "JSON.lower() serialization" begin
        # Create a session with all fields populated
        session = MCPSession(target_julia_session_id = "test-julia-session")
        session.protocol_version = "2024-11-05"
        session.client_info = Dict("name" => "test-client", "version" => "1.0")
        session.client_capabilities = Dict("roots" => Dict("listChanged" => true))
        session.state = Session.INITIALIZED
        session.initialized_at = now()

        # Serialize to JSON
        json_str = JSON.json(session)
        parsed = JSON.parse(json_str)

        # Verify all fields are present
        @test haskey(parsed, "id")
        @test haskey(parsed, "state")
        @test haskey(parsed, "protocol_version")
        @test haskey(parsed, "client_info")
        @test haskey(parsed, "server_capabilities")
        @test haskey(parsed, "client_capabilities")
        @test haskey(parsed, "created_at")
        @test haskey(parsed, "initialized_at")
        @test haskey(parsed, "closed_at")
        @test haskey(parsed, "target_julia_session_id")
        @test haskey(parsed, "last_activity")

        # Verify values
        @test parsed["id"] == session.id
        @test parsed["state"] == "INITIALIZED"
        @test parsed["protocol_version"] == "2024-11-05"
        @test parsed["target_julia_session_id"] == "test-julia-session"
        @test parsed["client_info"]["name"] == "test-client"
    end

    @testset "session_from_db() deserialization" begin
        # Create mock database row
        session_data = Dict(
            "protocol_version" => "2024-11-05",
            "client_info" => Dict("name" => "test-client"),
            "server_capabilities" => Dict("tools" => Dict("listChanged" => true)),
            "client_capabilities" => Dict("roots" => Dict("listChanged" => true)),
            "initialized_at" => "2025-01-25T10:00:00",
            "closed_at" => nothing,
        )

        db_row = (
            id = "test-session-id",
            state = "INITIALIZED",
            session_data = JSON.json(session_data),
            start_time = "2025-01-25 10:00:00.000",
            last_activity = "2025-01-25 10:05:00.000",
            target_julia_session_id = "test-julia-session",
        )

        # Deserialize
        session = session_from_db(db_row)

        # Verify all fields
        @test session.id == "test-session-id"
        @test session.state == Session.INITIALIZED
        @test session.protocol_version == "2024-11-05"
        @test session.client_info["name"] == "test-client"
        @test session.target_julia_session_id == "test-julia-session"
        @test !ismissing(session.created_at)
        @test !ismissing(session.last_activity)
    end

    @testset "Round-trip: serialize -> deserialize" begin
        # Create original session
        original = MCPSession(target_julia_session_id = "julia-123")
        original.protocol_version = "2024-11-05"
        original.client_info = Dict("name" => "claude", "version" => "1.0")
        original.state = Session.INITIALIZED
        original.initialized_at = now()

        # Serialize
        json_str = JSON.json(original)
        session_data = JSON.parse(json_str)

        # Create mock DB row
        db_row = (
            id = original.id,
            state = string(original.state),
            session_data = json_str,
            start_time = Dates.format(original.created_at, "yyyy-mm-dd HH:MM:SS.sss"),
            last_activity = Dates.format(original.last_activity, "yyyy-mm-dd HH:MM:SS.sss"),
            target_julia_session_id = original.target_julia_session_id,
        )

        # Deserialize
        restored = session_from_db(db_row)

        # Verify key fields match
        @test restored.id == original.id
        @test restored.state == original.state
        @test restored.protocol_version == original.protocol_version
        @test restored.target_julia_session_id == original.target_julia_session_id
        @test restored.client_info == original.client_info
    end
end

@testset "Database Integration Tests" begin
    # Set up temporary database
    db_path = tempname() * ".db"

    try
        # Initialize database
        Database.init_db!(db_path)

        @testset "register_mcp_session! creates row" begin
            session_id = "test-mcp-session-1"
            Database.register_mcp_session!(
                session_id,
                "active";
                target_julia_session_id = "julia-123",
            )

            # Verify row exists
            db_session = Database.get_mcp_session(session_id)
            @test db_session !== nothing
            @test db_session.id == session_id
            @test db_session.status == "active"
        end

        @testset "update_mcp_session_protocol! saves session data" begin
            session_id = "test-mcp-session-2"

            # Register
            Database.register_mcp_session!(session_id, "active")

            # Create session and update
            session = MCPSession(target_julia_session_id = "julia-456")
            session.id = session_id
            session.protocol_version = "2024-11-05"
            session.state = Session.INITIALIZED

            # Save via update_mcp_session_protocol!
            session_json = JSON.parse(JSON.json(session))
            Database.update_mcp_session_protocol!(
                session_id,
                string(session.state),
                session_json,
            )

            # Load and verify
            db_row = Database.get_mcp_session(session_id)
            @test db_row !== nothing
            @test db_row.state == "INITIALIZED"

            # Deserialize and check
            restored = session_from_db(db_row)
            @test restored.protocol_version == "2024-11-05"
            @test restored.state == Session.INITIALIZED
        end

        @testset "Proxy session_registry functions" begin
            # Test create_mcp_session
            session = Proxy.create_mcp_session("julia-789")
            @test session.target_julia_session_id == "julia-789"
            @test session.state == Session.UNINITIALIZED

            # Test get_mcp_session returns MCPSession struct
            loaded = Proxy.get_mcp_session(session.id)
            @test loaded !== nothing
            @test loaded isa MCPSession
            @test loaded.id == session.id
            @test loaded.target_julia_session_id == "julia-789"

            # Test save_mcp_session!
            loaded.protocol_version = "2025-06-18"
            loaded.state = Session.INITIALIZED
            Proxy.save_mcp_session!(loaded)

            # Reload and verify
            reloaded = Proxy.get_mcp_session(session.id)
            @test reloaded.protocol_version == "2025-06-18"
            @test reloaded.state == Session.INITIALIZED
        end

    finally
        # Clean up
        isfile(db_path) && rm(db_path)
    end
end