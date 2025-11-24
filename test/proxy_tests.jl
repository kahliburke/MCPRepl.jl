using ReTest
using HTTP
using JSON

using MCPRepl
using MCPRepl.Proxy
using MCPRepl.Database

@testset "Proxy Header Parsing" begin
    @testset "HTTP.header returns SubString or String" begin
        # Create a mock request with a header
        req = HTTP.Request("POST", "/", ["X-MCPRepl-Target" => "test-session"], "")

        # Test that HTTP.header returns what we expect
        header_value = HTTP.header(req, "X-MCPRepl-Target")
        @test header_value isa AbstractString

        println("Header type: $(typeof(header_value))")
        println("Header value: $header_value")

        # Test our conversion logic
        target_id = isempty(header_value) ? nothing : String(header_value)
        @test target_id == "test-session"
        @test target_id isa String
    end

    @testset "Missing header" begin
        req = HTTP.Request("POST", "/", [], "")
        header_value = HTTP.header(req, "X-MCPRepl-Target")

        println("Missing header type: $(typeof(header_value))")
        println("Missing header value: $header_value")

        @test header_value isa AbstractString
        @test isempty(header_value)

        # Test our conversion logic
        target_id = isempty(header_value) ? nothing : String(header_value)
        @test target_id === nothing
    end
end

@testset "Julia Session Registry" begin
    @testset "Register and retrieve Julia Session" begin
        # Clear any existing registrations
        empty!(Proxy.JULIA_SESSION_REGISTRY)

        # Register a test Julia Session
        Proxy.register_julia_session(
            "test-session-1",
            3001;
            pid = 12345,
            metadata = Dict("test" => "data"),
        )

        # Verify it's in the registry
        session = Proxy.get_julia_session("test-session-1")
        @test session !== nothing
        @test session.id == "test-session-1"
        @test session.port == 3001
        @test session.pid == 12345
        @test session.status == :ready
        @test session.metadata["test"] == "data"
    end

    @testset "List julia_sessions" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)

        Proxy.register_julia_session("session-1", 3001)
        Proxy.register_julia_session("session-2", 3002)

        julia_sessions = Proxy.list_julia_sessions()
        @test length(julia_sessions) == 2
        @test any(r -> r.id == "session-1", julia_sessions)
        @test any(r -> r.id == "session-2", julia_sessions)
    end

    @testset "Unregister Julia Session" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)

        Proxy.register_julia_session("temp-session", 3003)
        @test Proxy.get_julia_session("temp-session") !== nothing
        Proxy.unregister_julia_session("temp-session")
        @test Proxy.get_julia_session("temp-session") === nothing
    end

    @testset "Update Julia Session status" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)

        Proxy.register_julia_session("status-session", 3004)
        session = Proxy.get_julia_session("status-session")
        @test session.status == :ready
        @test session.missed_heartbeats == 0

        Proxy.update_julia_session_status("status-session", :stopped)
        session = Proxy.get_julia_session("status-session")
        @test session.status == :stopped
    end

    @testset "Missed heartbeat counter" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)

        Proxy.register_julia_session("heartbeat-test", 3005)
        session = Proxy.get_julia_session("heartbeat-test")
        @test session.missed_heartbeats == 0
        @test session.status == :ready

        # Simulate first error - should increment counter but stay ready
        Proxy.update_julia_session_status("heartbeat-test", :ready; error = "Error 1")
        session = Proxy.get_julia_session("heartbeat-test")
        @test session.missed_heartbeats == 1
        @test session.last_error == "Error 1"

        # Second error - still ready
        Proxy.update_julia_session_status("heartbeat-test", :ready; error = "Error 2")
        session = Proxy.get_julia_session("heartbeat-test")
        @test session.missed_heartbeats == 2

        # Third error - now should be stopped
        Proxy.update_julia_session_status("heartbeat-test", :ready; error = "Error 3")
        session = Proxy.get_julia_session("heartbeat-test")
        @test session.missed_heartbeats == 3

        # Recovery - should reset counter
        Proxy.update_julia_session_status("heartbeat-test", :ready)
        session = Proxy.get_julia_session("heartbeat-test")
        @test session.missed_heartbeats == 0
        @test session.last_error === nothing
    end
end

@testset "HTTP Request Construction" begin
    @testset "HTTP.post with headers and body" begin
        # Test that our HTTP.post syntax is correct
        # This is the exact pattern used in route_to_session_streaming
        backend_url = "http://127.0.0.1:3006/"
        headers = ["Content-Type" => "application/json"]
        body_str = JSON.json(
            Dict(
                "jsonrpc" => "2.0",
                "id" => 1,
                "method" => "tools/list",
                "params" => Dict(),
            ),
        )

        println("\nTesting HTTP.post arguments:")
        println("  URL: $backend_url")
        println("  Headers type: $(typeof(headers))")
        println("  Headers: $headers")
        println("  Body type: $(typeof(body_str))")
        println("  Body length: $(length(body_str))")
        println("  Body preview: $(body_str[1:min(50, length(body_str))])")

        # Verify types are what HTTP.post expects
        @test backend_url isa String
        @test headers isa Vector{Pair{String,String}}
        @test body_str isa String
        @test length(headers) == 1
        @test headers[1].first == "Content-Type"
        @test headers[1].second == "application/json"
    end

    @testset "Response construction" begin
        # Test that HTTP.Response can be constructed properly
        status = 200
        body = JSON.json(Dict("result" => "test"))

        println("\nTesting HTTP.Response construction:")
        println("  Status: $status")
        println("  Body type: $(typeof(body))")

        # This should not throw
        response = HTTP.Response(status, body)
        @test response.status == 200
        @test String(response.body) == body
    end
end

@testset "JSON Object to Dict conversion" begin
    @testset "Convert JSON.Object metadata" begin
        json_str = """{"id":"test","port":3000,"metadata":{"key":"value"}}"""
        parsed = JSON.parse(json_str)

        # Test the conversion logic used in proxy/register
        metadata_raw = get(parsed, "metadata", Dict())
        metadata =
            metadata_raw isa Dict ? metadata_raw :
            Dict(String(k) => v for (k, v) in pairs(metadata_raw))

        @test metadata isa Dict
        @test metadata["key"] == "value"
    end

    @testset "Convert JSON.Object request" begin
        json_str = """{"jsonrpc":"2.0","id":1,"method":"test","params":{}}"""
        parsed = JSON.parse(json_str)

        # Test the conversion logic used in route_to_session_streaming
        request_dict =
            parsed isa Dict ? parsed : Dict(String(k) => v for (k, v) in pairs(parsed))

        @test request_dict isa Dict
        @test request_dict["method"] == "test"
    end

    @testset "Full route_to_session_streaming simulation" begin
        # This tests the exact flow that happens in the proxy
        empty!(Proxy.JULIA_SESSION_REGISTRY)

        # Register a test Julia session
        Proxy.register_julia_session("route-test", 3006; pid = Int(getpid()))

        # Create a JSON request string (as would come from HTTP)
        json_str = """{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"""

        # Parse it (this creates a JSON.Object)
        parsed = JSON.parse(json_str)
        println("\nFull routing test:")
        println("  Parsed type: $(typeof(parsed))")

        # Convert to Dict as done in handle_request
        request_dict =
            parsed isa Dict ? parsed : Dict(String(k) => v for (k, v) in pairs(parsed))
        println("  Dict type: $(typeof(request_dict))")

        # Simulate what route_to_session_streaming does
        backend_url = "http://127.0.0.1:3006/"
        headers = ["Content-Type" => "application/json"]
        body_str = JSON.json(request_dict)
        println("  Final body type: $(typeof(body_str))")
        println("  Final body: $body_str")

        # Verify all the types are correct
        @test request_dict isa Dict{String,Any}
        @test body_str isa String
        @test headers isa Vector{Pair{String,String}}

        # Test that these arguments won't cause an error when constructing Response
        @test_nowarn HTTP.Response(200, body_str)

        # Test the exact argument pattern used in route_to_session_streaming
        println("\nTesting HTTP.post argument pattern:")
        println("  Arg 1 (url): $(typeof(backend_url)) = $backend_url")
        println("  Arg 2 (headers): $(typeof(headers)) = $headers")
        println("  Arg 3 (body): $(typeof(body_str)) - length $(length(body_str))")

        # This validates our argument types match what HTTP.post expects
        @test backend_url isa AbstractString
        @test headers isa AbstractVector
        @test all(h -> h isa Pair{<:AbstractString,<:AbstractString}, headers)
        @test body_str isa AbstractString
    end

    @testset "Actual HTTP.post call with exact proxy pattern" begin
        # Start a simple echo server to test against
        echo_port = 9999
        echo_server = HTTP.serve!(echo_port; verbose = false) do req
            # Echo back the request body
            return HTTP.Response(200, req.body)
        end

        try
            # Test the exact pattern used in route_to_session_streaming
            backend_url = "http://127.0.0.1:$echo_port/"
            headers = ["Content-Type" => "application/json"]
            request_dict = Dict("jsonrpc" => "2.0", "id" => 1, "method" => "test")
            body_str = JSON.json(request_dict)

            println("\nActual HTTP.post test:")
            println("  Making real HTTP.post call...")

            # This is the EXACT call from route_to_session_streaming
            response = HTTP.post(
                backend_url,
                headers,
                body_str;
                readtimeout = 5,
                connect_timeout = 2,
            )

            @test response.status == 200
            @test String(response.body) == body_str
            println("  ✓ HTTP.post succeeded!")

        finally
            close(echo_server)
        end
    end

    @testset "Full handle_request → route_to_session_streaming → HTTP.post integration" begin
        # This tests the COMPLETE flow from handle_request to actual backend call
        echo_port = 9998
        echo_server = HTTP.serve!(echo_port; verbose = false) do req
            # Return a mock MCP response
            mock_response = Dict(
                "jsonrpc" => "2.0",
                "id" => 1,
                "result" => Dict("tools" => [Dict("name" => "test_tool")]),
            )
            return HTTP.Response(200, JSON.json(mock_response))
        end

        try
            # Register a Julia session pointing to our echo server
            empty!(Proxy.JULIA_SESSION_REGISTRY)
            Proxy.register_julia_session("integration-test", echo_port; pid = Int(getpid()))

            # Create HTTP request exactly as it would come from a client
            request_body = """{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"""
            req = HTTP.Request(
                "POST",
                "/",
                [
                    "Content-Type" => "application/json",
                    "X-MCPRepl-Target" => "integration-test",
                ],
                request_body,
            )

            println("\nFull integration test:")
            println("  Request body: $request_body")
            println("  Calling Proxy.handle_request...")

            # Call handle_request - this should parse, route, and make HTTP.post call
            response = Proxy.handle_request(req)

            println("  Response status: $(response.status)")
            response_body = String(response.body)
            println("  Response body: $(response_body[1:min(100, length(response_body))])")

            @test response.status == 200
            parsed_response = JSON.parse(response_body)
            @test haskey(parsed_response, "result")
            @test parsed_response["result"]["tools"][1]["name"] == "test_tool"
            println("  ✓ Full routing succeeded!")

        finally
            close(echo_server)
        end
    end
end

@testset "Julia Registration" begin
    # Initialize temp database for registration tests
    test_db = tempname() * ".db"
    Database.init_db!(test_db)

    @testset "Successful registration with database logging" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)

        # Register a Julia session
        Proxy.register_julia_session("test-registration-1", 5001; pid = 99999)

        # Verify it's in the registry
        @test haskey(Proxy.JULIA_SESSION_REGISTRY, "test-registration-1")
        session_info = Proxy.JULIA_SESSION_REGISTRY["test-registration-1"]
        @test session_info.port == 5001
        @test session_info.pid == 99999
        @test session_info.id == "test-registration-1"
    end

    @testset "Duplicate registration throws error" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)

        # Register once
        Proxy.register_julia_session("test-duplicate", 5002; pid = 88888)

        # Try to register again - should throw
        @test_throws Exception Proxy.register_julia_session(
            "test-duplicate",
            5003;
            pid = 77777,
        )

        # Verify original registration still intact
        @test Proxy.JULIA_SESSION_REGISTRY["test-duplicate"].port == 5002
    end

    @testset "Unregister Julia Session" begin
        empty!(Proxy.JULIA_SESSION_REGISTRY)

        # Register and verify
        Proxy.register_julia_session("test-unregister", 5004; pid = 66666)
        @test haskey(Proxy.JULIA_SESSION_REGISTRY, "test-unregister")

        # Unregister and verify removal
        Proxy.unregister_julia_session("test-unregister")
        @test !haskey(Proxy.JULIA_SESSION_REGISTRY, "test-unregister")
    end

    # Cleanup
    Database.close_db!()
    rm(test_db; force = true)
end
