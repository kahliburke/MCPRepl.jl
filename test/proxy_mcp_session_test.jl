"""
Unit test to ensure the proxy itself has an MCP session ID for tool calls it makes.

When the proxy makes tool calls on its own behalf (e.g., from dashboard Quick Start),
those interactions should be associated with the proxy's own MCP session ID, not NULL.
"""

using ReTest
using SQLite
using JSON
using DBInterface
using UUIDs

# Load modules
include("../src/database.jl")
using .Database

@testset "Proxy MCP Session Identification" begin
    db_path = tempname() * ".db"

    try
        Database.init_db!(db_path)

        @testset "Proxy tool calls should have mcp_session_id" begin
            # Simulate what happens when proxy calls a tool (e.g., start_julia_session from dashboard)
            proxy_mcp_id = "proxy-system-session"  # Proxy's own MCP session ID
            request_id = "dashboard-request-1"

            # Register the proxy's MCP session
            Database.register_mcp_session!(proxy_mcp_id)

            # Log a tool call made by the proxy itself
            request_content = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "start_julia_session",
                        "arguments" => Dict("project_path" => "/test/path"),
                    ),
                ),
            )

            Database.log_interaction!(
                "inbound",
                "request",
                request_content;
                mcp_session_id = proxy_mcp_id,  # CRITICAL: must not be NULL
                request_id = request_id,
                method = "tools/call",
            )

            # Query the interaction
            db = Database.DB[]
            result = DBInterface.execute(
                db,
                "SELECT mcp_session_id, method FROM interactions WHERE request_id = ?",
                (request_id,),
            )

            found = false
            for row in result
                @test row.mcp_session_id !== nothing
                @test row.mcp_session_id !== missing
                @test row.mcp_session_id == proxy_mcp_id
                @test row.method == "tools/call"
                found = true
            end

            @test found
        end

        @testset "Dashboard tool calls should not have NULL mcp_session_id" begin
            # This test ensures dashboard-initiated tool calls are properly tracked
            proxy_mcp_id = "proxy-dashboard"
            Database.register_mcp_session!(proxy_mcp_id)

            # Simulate dashboard quick start
            request_content = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 2,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "start_julia_session",
                        "arguments" => Dict(
                            "project_path" => "/home/user/project",
                            "session_name" => "my-project",
                        ),
                    ),
                ),
            )

            Database.log_interaction!(
                "inbound",
                "request",
                request_content;
                mcp_session_id = proxy_mcp_id,
                request_id = "2",
                method = "tools/call",
            )

            # Verify mcp_session_id is not NULL
            db = Database.DB[]
            result = DBInterface.execute(
                db,
                "SELECT mcp_session_id FROM interactions WHERE request_id = '2' AND method = 'tools/call'",
            )

            for row in result
                # CRITICAL: mcp_session_id must NOT be NULL
                @test row.mcp_session_id !== nothing
                @test row.mcp_session_id !== missing
                @test !isempty(row.mcp_session_id)
            end
        end

        @testset "All tool calls should have mcp_session_id after ETL" begin
            # This ensures the ETL properly handles tool executions
            proxy_mcp_id = "proxy-etl-test"
            Database.register_mcp_session!(proxy_mcp_id)

            request_content = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 3,
                    "method" => "tools/call",
                    "params" =>
                        Dict("name" => "list_julia_sessions", "arguments" => Dict()),
                ),
            )

            response_content = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 3,
                    "result" =>
                        Dict("content" => [Dict("type" => "text", "text" => "[]")]),
                ),
            )

            Database.log_interaction!(
                "inbound",
                "request",
                request_content;
                mcp_session_id = proxy_mcp_id,
                request_id = "3",
                method = "tools/call",
            )

            Database.log_interaction!(
                "outbound",
                "response",
                response_content;
                mcp_session_id = proxy_mcp_id,
                request_id = "3",
            )

            # Run ETL
            include("../src/database_etl.jl")
            using .DatabaseETL

            db = Database.DB[]
            DatabaseETL.run_etl_pipeline(db)

            # Verify tool_executions has mcp_session_id
            result = DBInterface.execute(
                db,
                "SELECT mcp_session_id, tool_name FROM tool_executions WHERE request_id = '3'",
            )

            found = false
            for row in result
                @test row.mcp_session_id !== nothing
                @test row.mcp_session_id !== missing
                @test row.mcp_session_id == proxy_mcp_id
                found = true
            end

            @test found
        end

    finally
        isfile(db_path) && rm(db_path)
    end
end
