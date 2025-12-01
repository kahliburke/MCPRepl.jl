"""
Unit test to ensure session names are preserved and not overwritten by logging functions.

This test catches the bug where log_event_safe! and log_interaction_safe! would
auto-create Julia sessions with UUID as the name, overwriting the correct logical name.
"""

using ReTest
using SQLite
using JSON
using Dates
using DBInterface

using MCPRepl
using MCPRepl.Database

@testset "Session Name Preservation" begin
    # Use temporary database for testing
    test_db = tempname() * ".db"

    try
        Database.init_db!(test_db)

        @testset "Basic registration stores correct name" begin
            uuid = "test-uuid-001"
            name = "my-project-name"

            Database.register_julia_session!(uuid, name, "ready"; port = 40000, pid = 1000)

            session = Database.get_julia_session(uuid)
            @test session !== nothing
            @test session.id == uuid
            @test session.name == name
            @test session.name != uuid  # Name should NOT be UUID
        end

        @testset "Name survives event logging" begin
            uuid = "test-uuid-002"
            name = "event-test-session"

            Database.register_julia_session!(uuid, name, "ready"; port = 40001, pid = 1001)
            Database.log_event_safe!(
                "test.event",
                Dict("data" => "value");
                julia_session_id = uuid,
            )

            session = Database.get_julia_session(uuid)
            @test session !== nothing
            @test session.name == name
            @test session.name != uuid  # CRITICAL: name should NOT be overwritten with UUID
        end

        @testset "Name survives interaction logging" begin
            uuid = "test-uuid-003"
            name = "interaction-test-session"

            Database.register_julia_session!(uuid, name, "ready"; port = 40002, pid = 1002)
            Database.log_interaction_safe!(
                "inbound",
                "request",
                Dict("method" => "test");
                julia_session_id = uuid,
            )

            session = Database.get_julia_session(uuid)
            @test session !== nothing
            @test session.name == name
            @test session.name != uuid  # CRITICAL: name should NOT be overwritten with UUID
        end

        @testset "Multiple logging calls don't corrupt name" begin
            uuid = "test-uuid-004"
            name = "multi-log-session"

            Database.register_julia_session!(uuid, name, "ready"; port = 40003, pid = 1003)

            for i = 1:5
                Database.log_event_safe!(
                    "test.event.$i",
                    Dict("i" => i);
                    julia_session_id = uuid,
                )
                Database.log_interaction_safe!(
                    "inbound",
                    "request",
                    Dict("id" => i);
                    julia_session_id = uuid,
                )
            end

            session = Database.get_julia_session(uuid)
            @test session !== nothing
            @test session.name == name
            @test session.name != uuid
        end

        @testset "Different sessions maintain distinct names" begin
            sessions = [
                ("uuid-alpha", "project-alpha"),
                ("uuid-beta", "project-beta"),
                ("uuid-gamma", "project-gamma"),
            ]

            for (uuid, name) in sessions
                Database.register_julia_session!(uuid, name, "ready"; port = 50000)
                Database.log_event_safe!("test.event", Dict(); julia_session_id = uuid)
            end

            for (uuid, expected_name) in sessions
                session = Database.get_julia_session(uuid)
                @test session !== nothing
                @test session.name == expected_name
                @test session.name != uuid
            end
        end

    finally
        isfile(test_db) && rm(test_db)
    end
end
