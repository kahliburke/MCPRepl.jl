using Test
using SQLite
using JSON
using DataFrames
using Dates
using DBInterface

# Load the Database module directly
include("../src/database.jl")
using .Database

@testset "Database Event and Interaction Logging" begin
    # Use temporary database for testing
    test_db = tempname() * ".db"

    @testset "Database Initialization" begin
        db = init_db!(test_db)
        @test db !== nothing
        @test isfile(test_db)
    end

    @testset "Session Registration" begin
        session_id = "test-session-1"
        metadata = Dict("project" => "test-project", "user" => "test-user")

        register_session!(session_id, "active"; metadata = metadata)

        # Verify session was created
        sessions = get_all_sessions()
        @test nrow(sessions) >= 1

        session_row = filter(row -> row.session_id == session_id, sessions)
        @test nrow(session_row) == 1
        @test session_row[1, :status] == "active"
    end

    @testset "Event Logging" begin
        session_id = "test-session-1"

        # Log a simple event
        log_event!(
            session_id,
            "test.event",
            Dict("message" => "This is a test event", "value" => 42),
        )

        # Log an event with duration
        log_event!(
            session_id,
            "tool.call.complete",
            Dict("tool" => "test_tool", "result" => "success");
            duration_ms = 123.45,
        )

        # Verify events were logged
        events = get_events(session_id = session_id)
        @test nrow(events) >= 2

        # Check event with duration
        tool_events = filter(row -> row.event_type == "tool.call.complete", events)
        @test nrow(tool_events) >= 1
        @test tool_events[1, :duration_ms] ≈ 123.45
    end

    @testset "Interaction Logging" begin
        session_id = "test-session-2"
        register_session!(session_id)

        # Log an inbound request
        request = Dict(
            "jsonrpc" => "2.0",
            "id" => "req-123",
            "method" => "tools/call",
            "params" => Dict("name" => "execute", "arguments" => Dict("code" => "1+1")),
        )
        log_interaction!(
            session_id,
            "inbound",
            "request",
            request;
            request_id = "req-123",
            method = "tools/call",
        )

        # Log an outbound response
        response = Dict(
            "jsonrpc" => "2.0",
            "id" => "req-123",
            "result" => Dict("content" => [Dict("type" => "text", "text" => "2")]),
        )
        log_interaction!(
            session_id,
            "outbound",
            "response",
            response;
            request_id = "req-123",
            method = "tools/call",
        )

        # Verify interactions were logged
        interactions = get_interactions(session_id = session_id)
        @test nrow(interactions) == 2

        # Check inbound request
        inbound = filter(row -> row.direction == "inbound", interactions)
        @test nrow(inbound) == 1
        @test inbound[1, :message_type] == "request"
        @test inbound[1, :request_id] == "req-123"
        @test inbound[1, :method] == "tools/call"

        # Parse and verify content
        request_content = JSON.parse(inbound[1, :content])
        @test request_content["method"] == "tools/call"

        # Check outbound response
        outbound = filter(row -> row.direction == "outbound", interactions)
        @test nrow(outbound) == 1
        @test outbound[1, :message_type] == "response"
        @test outbound[1, :request_id] == "req-123"
    end

    @testset "Session Reconstruction" begin
        session_id = "test-session-3"
        register_session!(session_id)

        # Create a realistic session with multiple interactions and events
        # 1. Inbound request
        log_interaction_safe!(
            session_id,
            "inbound",
            "request",
            Dict("jsonrpc" => "2.0", "id" => "1", "method" => "tools/call");
            request_id = "1",
            method = "tools/call",
        )

        # 2. Tool call start event
        log_event_safe!(
            session_id,
            "tool.call.start",
            Dict("tool" => "execute", "request_id" => "1"),
        )

        # Small sleep to ensure timestamp ordering
        sleep(0.01)

        # 3. Tool call complete event
        log_event_safe!(
            session_id,
            "tool.call.complete",
            Dict("tool" => "execute", "request_id" => "1");
            duration_ms = 50.0,
        )

        # 4. Outbound response
        log_interaction_safe!(
            session_id,
            "outbound",
            "response",
            Dict("jsonrpc" => "2.0", "id" => "1", "result" => Dict("status" => "ok"));
            request_id = "1",
        )

        # Reconstruct the session
        timeline = reconstruct_session(session_id)

        @test nrow(timeline) == 4

        # Verify chronological order (timestamps should be ascending)
        timestamps = timeline.timestamp
        for i = 1:(length(timestamps)-1)
            @test timestamps[i] <= timestamps[i+1]
        end

        # Verify we have both types
        types = unique(timeline.type)
        @test "interaction" in types
        @test "event" in types

        # Check specific entries
        interactions_in_timeline = filter(row -> row.type == "interaction", timeline)
        @test nrow(interactions_in_timeline) == 2

        events_in_timeline = filter(row -> row.type == "event", timeline)
        @test nrow(events_in_timeline) == 2
    end

    @testset "Session Summary" begin
        session_id = "test-session-4"
        register_session!(session_id, "active"; metadata = Dict("test" => true))

        # Add some interactions and events
        for i = 1:5
            log_interaction_safe!(
                session_id,
                "inbound",
                "request",
                "Test request $i";
                request_id = "req-$i",
            )
            log_interaction_safe!(
                session_id,
                "outbound",
                "response",
                "Test response $i";
                request_id = "req-$i",
            )
            log_event_safe!(session_id, "test.event", Dict("iteration" => i))
        end

        # Get summary
        summary = get_session_summary(session_id)

        @test summary["session_id"] == session_id
        @test summary["total_interactions"] == 10  # 5 requests + 5 responses
        @test summary["total_events"] == 5
        @test summary["total_data_bytes"] > 0
        @test summary["complete_request_response_pairs"] == 5
    end

    @testset "Safe Logging (No Crash on DB Error)" begin
        # Close database
        close_db!()

        # These should not crash even with no DB initialized (they will log warnings)
        # We're testing that they return without error, not that they're silent
        try
            log_event_safe!("no-db-session", "test.event", Dict("should_not_crash" => true))
            @test true  # If we get here, it didn't crash
        catch e
            @test false  # Should not throw
        end

        try
            log_interaction_safe!(
                "no-db-session",
                "inbound",
                "request",
                "test";
                request_id = "test",
            )
            @test true  # If we get here, it didn't crash
        catch e
            @test false  # Should not throw
        end

        # Reinitialize for cleanup
        init_db!(test_db)
    end

    @testset "Query Filtering" begin
        session_id = "test-session-5"
        register_session!(session_id)

        # Add different types of interactions
        log_interaction!(
            session_id,
            "inbound",
            "request",
            "req1";
            request_id = "r1",
            method = "tools/call",
        )
        log_interaction!(
            session_id,
            "outbound",
            "response",
            "resp1";
            request_id = "r1",
            method = "tools/call",
        )
        log_interaction!(
            session_id,
            "inbound",
            "request",
            "req2";
            request_id = "r2",
            method = "tools/list",
        )

        # Filter by direction
        inbound = get_interactions(session_id = session_id, direction = "inbound")
        @test nrow(inbound) == 2
        @test all(row -> row.direction == "inbound", eachrow(inbound))

        outbound = get_interactions(session_id = session_id, direction = "outbound")
        @test nrow(outbound) == 1

        # Filter by request_id
        r1_interactions = get_interactions(session_id = session_id, request_id = "r1")
        @test nrow(r1_interactions) == 2  # request + response pair
    end

    # Cleanup
    @testset "Cleanup" begin
        close_db!()
        rm(test_db; force = true)
    end
end
