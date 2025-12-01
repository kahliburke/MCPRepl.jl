"""
Unit test for logs endpoint session lookup.

This test catches the bug where the logs endpoint tried to access session.uuid
instead of session.id, causing log file lookup to fail.
"""

using ReTest
using SQLite
using JSON
using DBInterface
using UUIDs

# Load modules
using MCPRepl
using MCPRepl.Database

@testset "Logs Endpoint Session Lookup" begin
    db_path = tempname() * ".db"

    try
        Database.init_db!(db_path)

        @testset "get_julia_session returns object with 'id' field" begin
            uuid = string(UUIDs.uuid4())
            name = "test-session"

            # Register session
            Database.register_julia_session!(uuid, name, "ready"; port = 40000, pid = 1234)

            # Get session (simulating what logs endpoint does)
            session = Database.get_julia_session(uuid)
            @test session !== nothing

            # CRITICAL: Must have 'id' field (not 'uuid')
            @test hasfield(typeof(session), :id) || haskey(session, :id)

            # Must NOT have 'uuid' field (common bug)
            if session isa NamedTuple
                @test !haskey(session, :uuid)
            end

            # The id field must contain the UUID
            if session isa NamedTuple
                @test session.id == uuid
            else
                @test session.id == uuid
            end
        end

        @testset "Session data structure for logs lookup" begin
            uuid = string(UUIDs.uuid4())
            name = "logs-test-session"

            Database.register_julia_session!(uuid, name, "ready"; port = 50000, pid = 5678)

            session = Database.get_julia_session(uuid)
            @test session !== nothing

            # Simulate what dashboard_routes.jl does at line 407:
            # search_uuid = session !== nothing ? session.id : session_id
            # This MUST work (not session.uuid)
            search_uuid = session.id  # Should not throw
            @test search_uuid == uuid
        end

        @testset "Session lookup is by UUID only" begin
            uuid = string(UUIDs.uuid4())
            name = "uuid-only-lookup"

            Database.register_julia_session!(uuid, name, "ready"; port = 60000)

            # Lookup MUST be by UUID (not by name)
            session = Database.get_julia_session(uuid)
            @test session !== nothing

            # Must have 'id' field
            if session isa NamedTuple
                @test haskey(session, :id)
                @test session.id == uuid
            else
                @test hasfield(typeof(session), :id)
                @test session.id == uuid
            end
        end

        @testset "Session query returns consistent structure" begin
            # Register multiple sessions
            sessions_data = [
                (string(UUIDs.uuid4()), "session-1"),
                (string(UUIDs.uuid4()), "session-2"),
                (string(UUIDs.uuid4()), "session-3"),
            ]

            for (uuid, name) in sessions_data
                Database.register_julia_session!(uuid, name, "ready"; port = 70000)
            end

            # Test lookup by UUID only
            for (uuid, name) in sessions_data
                # Lookup by UUID (only valid method)
                session = Database.get_julia_session(uuid)
                @test session !== nothing

                # Must have 'id' field with correct value
                if session isa NamedTuple
                    @test haskey(session, :id)
                    @test session.id == uuid
                else
                    @test session.id == uuid
                end
            end
        end

    finally
        isfile(db_path) && rm(db_path)
    end
end
