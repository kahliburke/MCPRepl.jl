"""
Unit test to ensure session id and name fields are always correct and distinct.

Critical invariants:
- id field MUST be the UUID
- name field MUST be the logical name
- id and name are DIFFERENT fields with DIFFERENT values
- This applies regardless of how the session was started (proxy, manual, etc.)
"""

using ReTest
using SQLite
using JSON
using Dates
using DBInterface
using UUIDs

# Load modules directly
include("../src/database.jl")
using .Database

@testset "Session ID and Name Field Integrity" begin
    db_path = tempname() * ".db"

    try
        Database.init_db!(db_path)

        @testset "Database-level registration" begin
            uuid = string(UUIDs.uuid4())
            name = "my-project"

            # Register at database level
            Database.register_julia_session!(uuid, name, "ready"; port = 40000, pid = 9999)

            # Query back from database
            session = Database.get_julia_session(uuid)
            @test session !== nothing

            # CRITICAL: id must be UUID, name must be logical name
            @test session.id == uuid
            @test session.name == name
            @test session.id != session.name  # They MUST be different
        end

        @testset "Registration with different port" begin
            uuid = string(UUIDs.uuid4())
            name = "another-project"

            # Register at database level with different port
            Database.register_julia_session!(uuid, name, "ready"; port = 50000, pid = 1234)

            # Verify in database
            session = Database.get_julia_session(uuid)
            @test session !== nothing
            @test session.id == uuid
            @test session.name == name
            @test session.id != session.name
        end

        @testset "Multiple sessions maintain distinct IDs and names" begin
            sessions_data = [
                (string(UUIDs.uuid4()), "project-alpha"),
                (string(UUIDs.uuid4()), "project-beta"),
                (string(UUIDs.uuid4()), "project-gamma"),
            ]

            for (uuid, name) in sessions_data
                Database.register_julia_session!(uuid, name, "ready"; port = 40000)
            end

            # Verify each session has correct id and name
            for (expected_uuid, expected_name) in sessions_data
                session = Database.get_julia_session(expected_uuid)
                @test session !== nothing
                @test session.id == expected_uuid
                @test session.name == expected_name
                @test session.id != session.name
            end
        end

        @testset "Session name can be same as another session's ID (edge case)" begin
            # Edge case: one session's name happens to be another's UUID
            uuid1 = string(UUIDs.uuid4())
            uuid2 = string(UUIDs.uuid4())

            # Session 1: normal registration
            Database.register_julia_session!(uuid1, "normal-name", "ready"; port = 40001)

            # Session 2: name happens to be uuid1's value (weird but legal)
            Database.register_julia_session!(uuid2, uuid1, "ready"; port = 40002)

            # Verify both sessions are correct
            session1 = Database.get_julia_session(uuid1)
            @test session1.id == uuid1
            @test session1.name == "normal-name"

            session2 = Database.get_julia_session(uuid2)
            @test session2.id == uuid2
            @test session2.name == uuid1  # Name equals uuid1 (but id is uuid2)
            @test session2.id != session2.name  # Still different
        end

        @testset "Raw SQL verification of id and name columns" begin
            uuid = string(UUIDs.uuid4())
            name = "sql-test-project"

            Database.register_julia_session!(uuid, name, "ready"; port = 60000, pid = 5555)

            # Query database directly with SQL
            db = Database.DB[]
            result = DBInterface.execute(
                db,
                "SELECT id, name FROM julia_sessions WHERE id = ?",
                (uuid,),
            )

            for row in result
                @test row.id == uuid
                @test row.name == name
                @test row.id != row.name
                # Ensure neither field contains the wrong value
                @test row.id != name
                @test row.name != uuid
                return
            end

            error("No row found in database")
        end

        @testset "Session re-registration preserves id and name" begin
            uuid = string(UUIDs.uuid4())
            name = "persistent-session"

            # Initial registration
            Database.register_julia_session!(uuid, name, "ready"; port = 70000, pid = 7777)

            # Re-register (simulating reconnection)
            Database.register_julia_session!(uuid, name, "ready"; port = 70001, pid = 7778)

            # Verify id and name are still correct
            session = Database.get_julia_session(uuid)
            @test session.id == uuid
            @test session.name == name
            @test session.id != session.name
        end

        @testset "All returned sessions have correct id/name structure" begin
            # Register several sessions
            for i = 1:5
                uuid = string(UUIDs.uuid4())
                name = "batch-session-$i"
                Database.register_julia_session!(uuid, name, "ready"; port = 80000 + i)
            end

            # Get all sessions
            db = Database.DB[]
            result = DBInterface.execute(
                db,
                "SELECT id, name FROM julia_sessions WHERE status = 'ready'",
            )

            count = 0
            for row in result
                # Every session must have distinct id and name
                @test !isempty(row.id)
                @test !isempty(row.name)
                @test row.id != row.name
                count += 1
            end

            @test count >= 5  # At least our 5 test sessions
        end

        @testset "Session lookup by UUID returns correct name" begin
            uuid = string(UUIDs.uuid4())
            name = "lookup-test"

            Database.register_julia_session!(uuid, name, "ready"; port = 90000)

            # Lookup by UUID
            session = Database.get_julia_session(uuid)
            @test session !== nothing
            @test session.id == uuid
            @test session.name == name

            # Name should NOT be the UUID
            @test session.name != uuid
        end

    finally
        isfile(db_path) && rm(db_path)
    end
end
