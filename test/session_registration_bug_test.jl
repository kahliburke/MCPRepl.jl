"""
Unit test to catch session registration bugs
Specifically: name field showing UUID instead of logical name
"""

using ReTest
using SQLite
using JSON
using Dates
using DBInterface
using UUIDs

# Load modules directly
using MCPRepl
using MCPRepl.Database

include("../src/session.jl")
using .Session

@testset "Session Registration Name Bug" begin
    db_path = tempname() * ".db"

    try
        Database.init_db!(db_path)

        @testset "Database stores correct name (not UUID)" begin
            uuid = "test-uuid-12345"
            name = "my-project-session"

            # Register session at database level
            Database.register_julia_session!(uuid, name, "ready"; port = 40000, pid = 9999)

            # Query back
            session = Database.get_julia_session(uuid)
            @test session !== nothing

            # CRITICAL: name should be the logical name, NOT the UUID
            @test session.name == name
            @test session.name != uuid
            @test session.id == uuid
        end

        @testset "Multiple sessions with different names" begin
            sessions_to_register = [
                ("uuid-1", "project-alpha"),
                ("uuid-2", "project-beta"),
                ("uuid-3", "my-repl-session"),
            ]

            for (uuid, name) in sessions_to_register
                Database.register_julia_session!(uuid, name, "ready"; port = 40000)
            end

            # Verify each has correct name
            for (uuid, expected_name) in sessions_to_register
                session = Database.get_julia_session(uuid)
                @test session !== nothing
                @test session.name == expected_name
                @test session.name != uuid  # Name should NOT be the UUID
            end
        end

        @testset "Name field in raw database" begin
            uuid = "raw-db-test"
            name = "my-logical-name"

            Database.register_julia_session!(uuid, name, "ready"; port = 50000, pid = 5000)

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
                @test row.name != uuid  # CRITICAL TEST
                return
            end

            @test false "No row found"
        end

    finally
        isfile(db_path) && rm(db_path)
    end
end