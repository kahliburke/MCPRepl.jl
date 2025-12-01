using ReTest
using HTTP
using JSON
using UUIDs

using MCPRepl
using MCPRepl.Proxy
using MCPRepl.Database

# Initialize temp database for all proxy tests
const PROXY_TEST_DB = tempname() * ".db"

@testset "Proxy Header Parsing" begin
    @testset "HTTP.header returns SubString or String" begin
        # Create a mock request with a header
        req = HTTP.Request("POST", "/", ["X-MCPRepl-Target" => "test-session"], "")

        # Test that HTTP.header returns what we expect
        header_value = HTTP.header(req, "X-MCPRepl-Target")
        @test header_value isa AbstractString

        # Test our conversion logic
        target_id = isempty(header_value) ? nothing : String(header_value)
        @test target_id == "test-session"
        @test target_id isa String
    end

    @testset "Missing header" begin
        req = HTTP.Request("POST", "/", [], "")
        header_value = HTTP.header(req, "X-MCPRepl-Target")

        @test header_value isa AbstractString
        @test isempty(header_value)

        # Test our conversion logic
        target_id = isempty(header_value) ? nothing : String(header_value)
        @test target_id === nothing
    end
end

@testset "Julia Session Registry" begin
    # Initialize database for these tests
    Database.init_db!(PROXY_TEST_DB)

    @testset "Register and retrieve Julia Session" begin
        uuid = string(uuid4())
        success, error = Proxy.register_julia_session(
            uuid,
            "test-session-1",
            3001;
            pid = 12345,
            metadata = Dict("test" => "data"),
        )

        @test success
        @test error === nothing

        # Verify it can be retrieved
        session = Proxy.get_julia_session(uuid)
        @test session !== nothing
        @test session.name == "test-session-1"
        @test session.port == 3001
        @test session.pid == 12345
        @test session.status == "ready"
    end

    @testset "List julia_sessions" begin
        uuid1 = string(uuid4())
        uuid2 = string(uuid4())

        Proxy.register_julia_session(uuid1, "session-list-1", 3101)
        Proxy.register_julia_session(uuid2, "session-list-2", 3102)

        julia_sessions = Proxy.list_julia_sessions()
        @test length(julia_sessions) >= 2

        names = [s.name for s in julia_sessions]
        @test "session-list-1" in names
        @test "session-list-2" in names
    end

    @testset "Unregister Julia Session" begin
        uuid = string(uuid4())

        Proxy.register_julia_session(uuid, "temp-session", 3003)
        @test Proxy.get_julia_session(uuid) !== nothing

        Proxy.unregister_julia_session(uuid)

        # Session is marked stopped, not deleted
        session = Proxy.get_julia_session(uuid)
        @test session !== nothing
        @test session.status == "stopped"
    end

    @testset "Update Julia Session status" begin
        uuid = string(uuid4())

        Proxy.register_julia_session(uuid, "status-session", 3004)
        session = Proxy.get_julia_session(uuid)
        @test session.status == "ready"

        Proxy.update_julia_session_status(uuid, "stopped")
        session = Proxy.get_julia_session(uuid)
        @test session.status == "stopped"
    end

    # Cleanup
    Database.close_db!()
end

@testset "HTTP Request Construction" begin
    @testset "HTTP.post with headers and body" begin
        # Test that our HTTP.post syntax is correct
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
        # Initialize database for this test
        test_db = tempname() * ".db"
        Database.init_db!(test_db)

        try
            # Register a test Julia session
            uuid = string(uuid4())
            Proxy.register_julia_session(uuid, "route-test", 3006; pid = Int(getpid()))

            # Create a JSON request string (as would come from HTTP)
            json_str = """{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"""

            # Parse it (this creates a JSON.Object)
            parsed = JSON.parse(json_str)

            # Convert to Dict as done in handle_request
            request_dict =
                parsed isa Dict ? parsed : Dict(String(k) => v for (k, v) in pairs(parsed))

            # Simulate what route_to_session_streaming does
            backend_url = "http://127.0.0.1:3006/"
            headers = ["Content-Type" => "application/json"]
            body_str = JSON.json(request_dict)

            # Verify all the types are correct
            @test request_dict isa Dict{String,Any}
            @test body_str isa String
            @test headers isa Vector{Pair{String,String}}

            # Test that these arguments won't cause an error when constructing Response
            @test_nowarn HTTP.Response(200, body_str)

            # This validates our argument types match what HTTP.post expects
            @test backend_url isa AbstractString
            @test headers isa AbstractVector
            @test all(h -> h isa Pair{<:AbstractString,<:AbstractString}, headers)
            @test body_str isa AbstractString
        finally
            Database.close_db!()
            rm(test_db; force = true)
        end
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
        uuid = string(uuid4())
        success, error =
            Proxy.register_julia_session(uuid, "test-registration-1", 5001; pid = 99999)

        @test success
        @test error === nothing

        # Verify it's in the database
        session = Proxy.get_julia_session(uuid)
        @test session !== nothing
        @test session.port == 5001
        @test session.pid == 99999
        @test session.name == "test-registration-1"
    end

    @testset "Same name different UUID registration" begin
        uuid1 = string(uuid4())
        uuid2 = string(uuid4())

        # Register first session
        success1, _ =
            Proxy.register_julia_session(uuid1, "test-duplicate", 5002; pid = 88888)
        @test success1

        # Register second session with same name - should succeed (different UUID)
        success2, _ =
            Proxy.register_julia_session(uuid2, "test-duplicate", 5003; pid = 77777)
        @test success2

        # Both should exist
        session1 = Proxy.get_julia_session(uuid1)
        session2 = Proxy.get_julia_session(uuid2)
        @test session1 !== nothing
        @test session2 !== nothing
        @test session1.port == 5002
        @test session2.port == 5003
    end

    @testset "Unregister Julia Session" begin
        uuid = string(uuid4())

        # Register and verify
        Proxy.register_julia_session(uuid, "test-unregister", 5004; pid = 66666)
        @test Proxy.get_julia_session(uuid) !== nothing

        # Unregister - marks as stopped
        Proxy.unregister_julia_session(uuid)
        session = Proxy.get_julia_session(uuid)
        @test session !== nothing
        @test session.status == "stopped"
    end

    # Cleanup
    Database.close_db!()
    rm(test_db; force = true)
end

# Clean up global test database
try
    rm(PROXY_TEST_DB; force = true)
catch
end
