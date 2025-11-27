"""
Unit tests for Dashboard API endpoints
Ensures the GUI will receive correct data from the proxy
"""

using ReTest
using MCPRepl
using MCPRepl.Proxy
using MCPRepl.Database
using HTTP
using JSON
using Dates

@testset "Dashboard API Tests" begin
    # Set up temporary database
    db_path = tempname() * ".db"

    try
        # Initialize database
        Database.init_db!(db_path)

        @testset "Sessions API - list_julia_sessions()" begin
            # Register multiple Julia sessions
            uuid1 = "julia-session-1"
            uuid2 = "julia-session-2"

            Database.register_julia_session!(
                uuid1,
                "session-1",
                "ready";
                port = 40001,
                pid = 1001,
                metadata = Dict("project" => "/path/1"),
            )
            Database.register_julia_session!(
                uuid2,
                "session-2",
                "ready";
                port = 40002,
                pid = 1002,
                metadata = Dict("project" => "/path/2"),
            )

            # Query sessions
            sessions = Proxy.list_julia_sessions()

            @test length(sessions) == 2
            @test any(s -> s.id == uuid1, sessions)
            @test any(s -> s.id == uuid2, sessions)

            # Verify all required fields are present
            session1 = findfirst(s -> s.id == uuid1, sessions)
            @test !isnothing(session1)
            s = sessions[session1]
            @test !ismissing(s.id)
            @test !ismissing(s.name)
            @test !ismissing(s.port)
            @test !ismissing(s.pid)
            @test !ismissing(s.status)
            @test !ismissing(s.start_time)
            @test !ismissing(s.last_activity)
        end

        @testset "Sessions API - get_julia_session()" begin
            uuid = "julia-session-3"
            Database.register_julia_session!(
                uuid,
                "test-session",
                "ready";
                port = 40003,
                pid = 1003,
                metadata = Dict("test" => true),
            )

            # Get specific session
            session = Proxy.get_julia_session(uuid)

            @test session !== nothing
            @test session.id == uuid
            @test session.name == "test-session"
            @test session.port == 40003
            @test session.pid == 1003
            @test session.status == "ready"
        end

        @testset "Sessions API - Missing fields handling" begin
            # Create session without optional fields
            uuid = "julia-session-minimal"
            Database.register_julia_session!(uuid, "minimal", "ready")

            session = Proxy.get_julia_session(uuid)
            @test session !== nothing

            # These might be missing/NULL
            port = ismissing(session.port) ? nothing : session.port
            pid = ismissing(session.pid) ? nothing : session.pid

            # Should handle gracefully
            @test session.id == uuid
            @test session.name == "minimal"
        end

        @testset "MCP Sessions - create and retrieve" begin
            # Create MCP session
            session = Proxy.create_mcp_session("julia-target-1")

            @test session.id !== ""
            @test session.state == MCPRepl.Proxy.Session.UNINITIALIZED
            @test session.target_julia_session_id == "julia-target-1"

            # Retrieve from database
            loaded = Proxy.get_mcp_session(session.id)
            @test loaded !== nothing
            @test loaded.id == session.id
            @test loaded.target_julia_session_id == "julia-target-1"
        end

        @testset "MCP Sessions - initialize and save" begin
            # Create and initialize session
            session = Proxy.create_mcp_session("julia-target-2")

            # Initialize
            params = Dict(
                "protocolVersion" => "2024-11-05",
                "capabilities" => Dict("roots" => Dict("listChanged" => true)),
                "clientInfo" => Dict("name" => "test-client", "version" => "1.0"),
            )
            result = MCPRepl.Proxy.Session.initialize_session!(session, params)

            @test session.state == MCPRepl.Proxy.Session.INITIALIZED
            @test session.protocol_version == "2024-11-05"
            @test haskey(session.client_info, "name")

            # Save to database
            Proxy.save_mcp_session!(session)

            # Reload and verify
            loaded = Proxy.get_mcp_session(session.id)
            @test loaded.state == MCPRepl.Proxy.Session.INITIALIZED
            @test loaded.protocol_version == "2024-11-05"
            @test loaded.client_info["name"] == "test-client"
        end

        @testset "Database query for active sessions" begin
            # Register sessions with different statuses
            Database.register_julia_session!("active-1", "active-session", "ready")
            Database.register_julia_session!("stopped-1", "stopped-session", "stopped")

            # Query only active
            sessions = Proxy.list_julia_sessions()
            active_ids = [s.id for s in sessions]

            @test "active-1" in active_ids
            @test "stopped-1" ∉ active_ids
        end

        @testset "Session update and persistence" begin
            uuid = "update-test-session"
            Database.register_julia_session!(uuid, "update-test", "ready")

            # Update status
            Proxy.update_julia_session_status(uuid, "disconnected")

            # Verify update persisted
            session = Proxy.get_julia_session(uuid)
            @test session.status == "disconnected"
        end

        @testset "MCP session activity tracking" begin
            session = Proxy.create_mcp_session(nothing)
            initial_activity = session.last_activity

            sleep(0.1)

            # Update activity
            MCPRepl.Proxy.Session.update_activity!(session)
            @test session.last_activity > initial_activity

            # Save and reload
            Proxy.save_mcp_session!(session)
            loaded = Proxy.get_mcp_session(session.id)

            # Activity should be updated in database
            @test loaded.last_activity >= initial_activity
        end

        @testset "Session data JSON blob integrity" begin
            # Create session with complex nested data
            session = Proxy.create_mcp_session("target-123")

            params = Dict(
                "protocolVersion" => "2024-11-05",
                "capabilities" =>
                    Dict("roots" => Dict("listChanged" => true), "sampling" => Dict()),
                "clientInfo" => Dict(
                    "name" => "complex-client",
                    "version" => "2.0",
                    "metadata" => Dict("nested" => Dict("deep" => "value")),
                ),
            )
            MCPRepl.Proxy.Session.initialize_session!(session, params)
            Proxy.save_mcp_session!(session)

            # Reload and verify all nested data
            loaded = Proxy.get_mcp_session(session.id)
            @test loaded.client_capabilities["roots"]["listChanged"] == true
            @test haskey(loaded.client_capabilities, "sampling")
            @test loaded.client_info["metadata"]["nested"]["deep"] == "value"
        end

        @testset "Multiple MCP sessions with same target" begin
            # Multiple clients can connect to same Julia session
            target = "shared-julia-session"

            session1 = Proxy.create_mcp_session(target)
            session2 = Proxy.create_mcp_session(target)

            @test session1.id != session2.id
            @test session1.target_julia_session_id == target
            @test session2.target_julia_session_id == target

            # Both should be retrievable
            loaded1 = Proxy.get_mcp_session(session1.id)
            loaded2 = Proxy.get_mcp_session(session2.id)

            @test loaded1.id == session1.id
            @test loaded2.id == session2.id
        end

        @testset "Database stats queries" begin
            # These are used by dashboard analytics
            stats = Database.get_global_stats()

            @test haskey(stats, "total_sessions")
            @test haskey(stats, "active_sessions")
            @test haskey(stats, "total_events")
            # Stats contain DataFrames - just verify they exist
            @test stats["total_sessions"] !== nothing
        end

    finally
        # Clean up
        isfile(db_path) && rm(db_path)
    end
end

@testset "Dashboard Route Data Format Tests" begin
    # Test that data format matches what GUI expects
    db_path = tempname() * ".db"

    try
        Database.init_db!(db_path)

        @testset "Session list format for GUI" begin
            # Register session
            uuid = "gui-test-session"
            Database.register_julia_session!(
                uuid,
                "gui-session",
                "ready";
                port = 40000,
                pid = 9999,
            )

            session = Proxy.get_julia_session(uuid)

            # Format as GUI expects (from dashboard_routes.jl)
            session_id = ismissing(session.id) ? "" : String(session.id)
            session_name = ismissing(session.name) ? "" : String(session.name)
            session_port = ismissing(session.port) ? nothing : session.port
            session_pid = ismissing(session.pid) ? nothing : session.pid
            session_status = ismissing(session.status) ? "unknown" : String(session.status)

            @test !isempty(session_id)
            @test session_id == uuid
            @test session_name == "gui-session"
            @test session_port == 40000
            @test session_pid == 9999
            @test session_status == "ready"

            # Build GUI response format
            gui_data = Dict(
                "uuid" => session_id,
                "name" => session_name,
                "port" => session_port,
                "pid" => session_pid,
                "status" => session_status,
                "last_heartbeat" => String(session.last_activity),
                "created_at" => String(session.start_time),
            )

            # Verify all fields present and correct type
            @test gui_data["uuid"] isa String
            @test gui_data["name"] isa String
            @test gui_data["port"] isa Int
            @test gui_data["pid"] isa Int
            @test gui_data["status"] isa String
        end

    finally
        isfile(db_path) && rm(db_path)
    end
end