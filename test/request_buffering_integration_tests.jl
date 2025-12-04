using ReTest
using UUIDs
using HTTP
using JSON
using Sockets

using MCPRepl
using MCPRepl.Proxy
using MCPRepl.Database

# Helper to create a mock HTTP.Stream for testing
mock_http_stream() = HTTP.Stream(HTTP.Request("GET", "/"), IOBuffer())

# Helper to find an available port
function find_available_port(start_port = 10000)
    for port = start_port:(start_port+100)
        try
            server = listen(port)
            close(server)
            return port
        catch
            continue
        end
    end
    error("Could not find available port")
end

# Mock backend server that records received requests
mutable struct MockBackend
    port::Int
    server::Union{HTTP.Server,Nothing}
    received_requests::Vector{Dict}
    response_body::String
    response_delay::Float64
    lock::ReentrantLock

    MockBackend(port::Int) = new(
        port,
        nothing,
        Dict[],
        """{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"mock response"}]}}""",
        0.0,
        ReentrantLock(),
    )
end

function start!(backend::MockBackend)
    backend.server = HTTP.serve!(backend.port; verbose = false) do request
        body = String(request.body)
        req_dict = JSON.parse(body)

        lock(backend.lock) do
            push!(backend.received_requests, req_dict)
        end

        if backend.response_delay > 0
            sleep(backend.response_delay)
        end

        # Return response with matching request ID
        response = Dict(
            "jsonrpc" => "2.0",
            "id" => get(req_dict, "id", 1),
            "result" => Dict(
                "content" => [Dict("type" => "text", "text" => "mock response")],
            ),
        )
        return HTTP.Response(
            200,
            ["Content-Type" => "application/json"],
            JSON.json(response),
        )
    end
    return backend
end

function stop!(backend::MockBackend)
    if backend.server !== nothing
        close(backend.server)
        backend.server = nothing
    end
end

function clear_requests!(backend::MockBackend)
    lock(backend.lock) do
        empty!(backend.received_requests)
    end
end

function get_requests(backend::MockBackend)
    lock(backend.lock) do
        copy(backend.received_requests)
    end
end

@testset "Request Buffering Integration Tests" begin
    # Initialize temp database
    test_db = tempname() * ".db"
    Database.init_db!(test_db)

    @testset "registration retrieves and flushes buffered requests" begin
        port = find_available_port()
        backend = MockBackend(port)
        start!(backend)

        uuid = string(uuid4())
        session_name = "test-reg-flush-$(rand(1000:9999))"

        try
            # Buffer a request BEFORE registration
            request = Dict("jsonrpc" => "2.0", "id" => 200, "method" => "test/method")
            lock(Proxy.PENDING_REQUESTS_LOCK) do
                Proxy.PENDING_REQUESTS[uuid] = [(request, mock_http_stream())]
            end

            # Verify it's buffered
            buffered = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, uuid) ? length(Proxy.PENDING_REQUESTS[uuid]) : 0
            end
            @test buffered == 1

            # Register session - should trigger flush
            success, _ =
                Proxy.register_julia_session(uuid, session_name, port; pid = Int(getpid()))
            @test success

            # Give async flush time to complete
            sleep(0.5)

            # Verify buffer was cleared
            buffered_after = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, uuid) ? length(Proxy.PENDING_REQUESTS[uuid]) : 0
            end
            @test buffered_after == 0

            # Verify backend received the request
            received = get_requests(backend)
            @test length(received) == 1
            @test received[1]["id"] == 200
        finally
            stop!(backend)
            Proxy.unregister_julia_session(uuid)
        end
    end

    @testset "session restart retrieves requests buffered under old UUID" begin
        port1 = find_available_port()
        port2 = find_available_port(port1 + 1)
        backend = MockBackend(port2)
        start!(backend)

        old_uuid = string(uuid4())
        new_uuid = string(uuid4())
        session_name = "test-restart-flush-$(rand(1000:9999))"

        try
            # Register first session
            success1, _ = Proxy.register_julia_session(
                old_uuid,
                session_name,
                port1;
                pid = Int(getpid()),
            )
            @test success1

            # Buffer a request under old UUID
            request = Dict("jsonrpc" => "2.0", "id" => 300, "method" => "restart/test")
            lock(Proxy.PENDING_REQUESTS_LOCK) do
                Proxy.PENDING_REQUESTS[old_uuid] = [(request, mock_http_stream())]
            end

            # Register NEW session with same name (simulates restart)
            success2, _ = Proxy.register_julia_session(
                new_uuid,
                session_name,
                port2;
                pid = Int(getpid()),
            )
            @test success2

            # Give async flush time to complete
            sleep(0.5)

            # Verify old UUID buffer was cleared
            old_buffered = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, old_uuid) ?
                length(Proxy.PENDING_REQUESTS[old_uuid]) : 0
            end
            @test old_buffered == 0

            # Verify backend received the request
            received = get_requests(backend)
            @test length(received) == 1
            @test received[1]["id"] == 300
        finally
            stop!(backend)
            Proxy.unregister_julia_session(old_uuid)
            Proxy.unregister_julia_session(new_uuid)
        end
    end

    @testset "flush handles backend connection errors gracefully" begin
        port = find_available_port()
        # Don't start the backend - simulate connection failure

        uuid = string(uuid4())
        session_name = "test-error-$(rand(1000:9999))"

        try
            # Buffer a request BEFORE registration
            request = Dict("jsonrpc" => "2.0", "id" => 400, "method" => "error/test")
            lock(Proxy.PENDING_REQUESTS_LOCK) do
                Proxy.PENDING_REQUESTS[uuid] = [(request, mock_http_stream())]
            end

            # Register session pointing to non-existent backend
            # This should not throw - errors are logged but handled
            success, _ =
                Proxy.register_julia_session(uuid, session_name, port; pid = Int(getpid()))
            @test success

            # Give async flush time to attempt and fail
            sleep(0.5)

            # Buffer should still be cleared (request was attempted)
            buffered_after = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, uuid) ? length(Proxy.PENDING_REQUESTS[uuid]) : 0
            end
            @test buffered_after == 0

            # Test passes if no exception was thrown
            @test true
        finally
            Proxy.unregister_julia_session(uuid)
        end
    end

    @testset "stopped session is excluded from session lookup" begin
        uuid = string(uuid4())
        session_name = "test-stopped-$(rand(1000:9999))"
        port = find_available_port()

        try
            # Register session
            success, _ =
                Proxy.register_julia_session(uuid, session_name, port; pid = Int(getpid()))
            @test success

            # Verify session is found
            session = Proxy.get_julia_session(uuid)
            @test session !== nothing
            @test session.status == "ready"

            # Unregister (marks as stopped)
            Proxy.unregister_julia_session(uuid)

            # Verify session status is now "stopped"
            session = Proxy.get_julia_session(uuid)
            @test session !== nothing
            @test session.status == "stopped"

            # Verify list_julia_sessions excludes stopped sessions
            sessions = Proxy.list_julia_sessions()
            stopped_sessions = filter(s -> s.id == uuid, sessions)
            @test isempty(stopped_sessions)
        finally
            # Cleanup is already done by unregister
        end
    end

    @testset "replaced session is excluded from session lookup" begin
        old_uuid = string(uuid4())
        new_uuid = string(uuid4())
        session_name = "test-replaced-$(rand(1000:9999))"
        port1 = find_available_port()
        port2 = find_available_port(port1 + 1)

        try
            # Register first session
            success1, _ = Proxy.register_julia_session(
                old_uuid,
                session_name,
                port1;
                pid = Int(getpid()),
            )
            @test success1

            # Register second session with same name (simulates restart)
            success2, _ = Proxy.register_julia_session(
                new_uuid,
                session_name,
                port2;
                pid = Int(getpid()),
            )
            @test success2

            # Verify old session is marked as "replaced"
            old_session = Proxy.get_julia_session(old_uuid)
            @test old_session !== nothing
            @test old_session.status == "replaced"

            # Verify new session is "ready"
            new_session = Proxy.get_julia_session(new_uuid)
            @test new_session !== nothing
            @test new_session.status == "ready"

            # Verify list_julia_sessions excludes replaced sessions
            sessions = Proxy.list_julia_sessions()
            replaced_sessions = filter(s -> s.id == old_uuid, sessions)
            @test isempty(replaced_sessions)

            # Verify the new session IS in the list
            new_sessions = filter(s -> s.id == new_uuid, sessions)
            @test length(new_sessions) == 1
        finally
            Proxy.unregister_julia_session(old_uuid)
            Proxy.unregister_julia_session(new_uuid)
        end
    end

    @testset "reconnection timeout removes request from buffer and sends error" begin
        uuid = string(uuid4())
        session_name = "test-timeout-$(rand(1000:9999))"
        port = find_available_port()

        try
            # Register session
            success, _ =
                Proxy.register_julia_session(uuid, session_name, port; pid = Int(getpid()))
            @test success

            # Mark session as down
            Proxy.update_julia_session_status(uuid, "down")

            # Buffer a request
            request = Dict("jsonrpc" => "2.0", "id" => 500, "method" => "timeout/test")
            http_stream = mock_http_stream()
            lock(Proxy.PENDING_REQUESTS_LOCK) do
                Proxy.PENDING_REQUESTS[uuid] = [(request, http_stream)]
            end

            # Verify it's buffered
            buffered = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, uuid) ? length(Proxy.PENDING_REQUESTS[uuid]) : 0
            end
            @test buffered == 1

            # Call send_reconnection_updates with a short timeout
            # This should wait, then timeout and remove the request
            @async Proxy.send_reconnection_updates(
                uuid,
                request,
                http_stream;
                timeout_seconds = 2,
            )

            # Wait for timeout to expire
            sleep(3)

            # Verify request was removed from buffer
            buffered_after = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, uuid) ? length(Proxy.PENDING_REQUESTS[uuid]) : 0
            end
            @test buffered_after == 0
        finally
            Proxy.unregister_julia_session(uuid)
        end
    end

    @testset "reconnection succeeds before timeout" begin
        port = find_available_port()
        backend = MockBackend(port)

        uuid = string(uuid4())
        session_name = "test-reconnect-success-$(rand(1000:9999))"

        try
            # Register session initially
            success, _ =
                Proxy.register_julia_session(uuid, session_name, port; pid = Int(getpid()))
            @test success

            # Mark session as down
            Proxy.update_julia_session_status(uuid, "down")

            # Buffer a request
            request = Dict("jsonrpc" => "2.0", "id" => 600, "method" => "reconnect/test")
            http_stream = mock_http_stream()
            lock(Proxy.PENDING_REQUESTS_LOCK) do
                Proxy.PENDING_REQUESTS[uuid] = [(request, http_stream)]
            end

            # Start the wait task with a long timeout
            wait_task = @async Proxy.send_reconnection_updates(
                uuid,
                request,
                http_stream;
                timeout_seconds = 10,
            )

            # After a short delay, "reconnect" by starting backend and updating status
            sleep(0.5)
            start!(backend)
            Proxy.update_julia_session_status(uuid, "ready")

            # Wait task should complete quickly (session is ready)
            sleep(1)

            # Buffer should be cleared (either by status update or by send_reconnection_updates)
            buffered = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, uuid) ? length(Proxy.PENDING_REQUESTS[uuid]) : 0
            end
            @test buffered == 0

            # Backend should have received the request (flushed on status update to "ready")
            received = get_requests(backend)
            @test length(received) >= 1
        finally
            stop!(backend)
            Proxy.unregister_julia_session(uuid)
        end
    end

    @testset "requests buffered under session name are retrieved on registration" begin
        port = find_available_port()
        backend = MockBackend(port)
        start!(backend)

        uuid = string(uuid4())
        session_name = "test-name-buffer-$(rand(1000:9999))"

        try
            # Buffer a request under the SESSION NAME (not UUID) before registration
            request = Dict("jsonrpc" => "2.0", "id" => 700, "method" => "name/buffer/test")
            lock(Proxy.PENDING_REQUESTS_LOCK) do
                Proxy.PENDING_REQUESTS[session_name] = [(request, mock_http_stream())]
            end

            # Verify it's buffered under name
            buffered = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, session_name) ?
                length(Proxy.PENDING_REQUESTS[session_name]) : 0
            end
            @test buffered == 1

            # Register session - should find and flush requests buffered under name
            success, _ =
                Proxy.register_julia_session(uuid, session_name, port; pid = Int(getpid()))
            @test success

            # Give async flush time to complete
            sleep(0.5)

            # Verify buffer was cleared (both name and uuid should be empty)
            buffered_name = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, session_name) ?
                length(Proxy.PENDING_REQUESTS[session_name]) : 0
            end
            @test buffered_name == 0

            # Verify backend received the request
            received = get_requests(backend)
            @test length(received) == 1
            @test received[1]["id"] == 700
        finally
            stop!(backend)
            Proxy.unregister_julia_session(uuid)
        end
    end

    @testset "multiple buffered requests are all flushed on registration" begin
        port = find_available_port()
        backend = MockBackend(port)
        start!(backend)

        uuid = string(uuid4())
        session_name = "test-multi-buffer-$(rand(1000:9999))"

        try
            # Buffer MULTIPLE requests before registration
            requests = [
                Dict("jsonrpc" => "2.0", "id" => 801, "method" => "multi/test1"),
                Dict("jsonrpc" => "2.0", "id" => 802, "method" => "multi/test2"),
                Dict("jsonrpc" => "2.0", "id" => 803, "method" => "multi/test3"),
            ]
            lock(Proxy.PENDING_REQUESTS_LOCK) do
                Proxy.PENDING_REQUESTS[uuid] = [(r, mock_http_stream()) for r in requests]
            end

            # Verify all are buffered
            buffered = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, uuid) ? length(Proxy.PENDING_REQUESTS[uuid]) : 0
            end
            @test buffered == 3

            # Register session - should flush all
            success, _ =
                Proxy.register_julia_session(uuid, session_name, port; pid = Int(getpid()))
            @test success

            # Give async flush time to complete
            sleep(1.0)

            # Verify buffer was cleared
            buffered_after = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, uuid) ? length(Proxy.PENDING_REQUESTS[uuid]) : 0
            end
            @test buffered_after == 0

            # Verify backend received ALL requests
            received = get_requests(backend)
            @test length(received) == 3
            received_ids = Set([r["id"] for r in received])
            @test 801 in received_ids
            @test 802 in received_ids
            @test 803 in received_ids
        finally
            stop!(backend)
            Proxy.unregister_julia_session(uuid)
        end
    end

    @testset "buffer_request! adds request to pending buffer" begin
        uuid = string(uuid4())
        request = Dict("jsonrpc" => "2.0", "id" => 900, "method" => "buffer/direct")
        http_stream = mock_http_stream()

        try
            # Clear any existing buffer for this uuid
            lock(Proxy.PENDING_REQUESTS_LOCK) do
                delete!(Proxy.PENDING_REQUESTS, uuid)
            end

            # Call buffer_request! directly
            Proxy.buffer_request!(uuid, request, http_stream)

            # Verify it was buffered
            buffered = lock(Proxy.PENDING_REQUESTS_LOCK) do
                if haskey(Proxy.PENDING_REQUESTS, uuid)
                    Proxy.PENDING_REQUESTS[uuid]
                else
                    []
                end
            end
            @test length(buffered) == 1
            @test buffered[1][1]["id"] == 900

            # Add another request
            request2 = Dict("jsonrpc" => "2.0", "id" => 901, "method" => "buffer/direct2")
            Proxy.buffer_request!(uuid, request2, mock_http_stream())

            # Verify both are buffered
            buffered = lock(Proxy.PENDING_REQUESTS_LOCK) do
                Proxy.PENDING_REQUESTS[uuid]
            end
            @test length(buffered) == 2
        finally
            # Clean up
            lock(Proxy.PENDING_REQUESTS_LOCK) do
                delete!(Proxy.PENDING_REQUESTS, uuid)
            end
        end
    end

    @testset "flush_pending_requests_with_error clears buffer" begin
        uuid = string(uuid4())

        try
            # Buffer some requests
            requests = [
                Dict("jsonrpc" => "2.0", "id" => 1001, "method" => "error/test1"),
                Dict("jsonrpc" => "2.0", "id" => 1002, "method" => "error/test2"),
            ]
            lock(Proxy.PENDING_REQUESTS_LOCK) do
                Proxy.PENDING_REQUESTS[uuid] = [(r, mock_http_stream()) for r in requests]
            end

            # Verify buffered
            buffered = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, uuid) ? length(Proxy.PENDING_REQUESTS[uuid]) : 0
            end
            @test buffered == 2

            # Call flush_pending_requests_with_error
            Proxy.flush_pending_requests_with_error(uuid, "Session permanently failed")

            # Verify buffer was cleared
            buffered_after = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, uuid) ? length(Proxy.PENDING_REQUESTS[uuid]) : 0
            end
            @test buffered_after == 0
        finally
            # Clean up just in case
            lock(Proxy.PENDING_REQUESTS_LOCK) do
                delete!(Proxy.PENDING_REQUESTS, uuid)
            end
        end
    end

    @testset "update_julia_session_status to ready triggers flush" begin
        port = find_available_port()
        backend = MockBackend(port)
        start!(backend)

        uuid = string(uuid4())
        session_name = "test-status-flush-$(rand(1000:9999))"

        try
            # Register session first
            success, _ =
                Proxy.register_julia_session(uuid, session_name, port; pid = Int(getpid()))
            @test success

            # Mark as down
            Proxy.update_julia_session_status(uuid, "down")

            # Buffer a request while down
            request =
                Dict("jsonrpc" => "2.0", "id" => 1100, "method" => "status/flush/test")
            lock(Proxy.PENDING_REQUESTS_LOCK) do
                Proxy.PENDING_REQUESTS[uuid] = [(request, mock_http_stream())]
            end

            # Verify buffered
            buffered = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, uuid) ? length(Proxy.PENDING_REQUESTS[uuid]) : 0
            end
            @test buffered == 1

            # Update status to ready - should trigger flush
            Proxy.update_julia_session_status(uuid, "ready")

            # Give async flush time to complete
            sleep(0.5)

            # Verify buffer was cleared
            buffered_after = lock(Proxy.PENDING_REQUESTS_LOCK) do
                haskey(Proxy.PENDING_REQUESTS, uuid) ? length(Proxy.PENDING_REQUESTS[uuid]) : 0
            end
            @test buffered_after == 0

            # Verify backend received the request
            received = get_requests(backend)
            @test length(received) >= 1
            @test any(r -> r["id"] == 1100, received)
        finally
            stop!(backend)
            Proxy.unregister_julia_session(uuid)
        end
    end

    @testset "session lookup by name returns ready session over down session" begin
        session_name = "test-lookup-priority-$(rand(1000:9999))"
        uuid_down = string(uuid4())
        uuid_ready = string(uuid4())
        port1 = find_available_port()
        port2 = find_available_port(port1 + 1)

        try
            # Register first session and mark it down
            success1, _ = Proxy.register_julia_session(
                uuid_down,
                session_name,
                port1;
                pid = Int(getpid()),
            )
            @test success1
            Proxy.update_julia_session_status(uuid_down, "down")

            # Register second session with same name (stays ready)
            success2, _ = Proxy.register_julia_session(
                uuid_ready,
                session_name,
                port2;
                pid = Int(getpid()),
            )
            @test success2

            # Look up by name - should return the ready session
            session = Proxy.get_julia_session(session_name)
            @test session !== nothing
            @test session.id == uuid_ready
            @test session.status == "ready"

            # Also verify looking up by UUID still works for both
            down_session = Proxy.get_julia_session(uuid_down)
            @test down_session !== nothing
            @test down_session.status in ["down", "replaced"]  # Might be replaced by the second registration

            ready_session = Proxy.get_julia_session(uuid_ready)
            @test ready_session !== nothing
            @test ready_session.status == "ready"
        finally
            Proxy.unregister_julia_session(uuid_down)
            Proxy.unregister_julia_session(uuid_ready)
        end
    end

    # Cleanup
    Database.close_db!()
    rm(test_db; force = true)
end
