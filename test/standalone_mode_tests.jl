using ReTest
using MCPRepl
using Dates
using JSON

@testset "Standalone Mode" begin
    @testset "Server starts without proxy" begin
        # Standalone mode should work when proxy is not available
        port = MCPRepl.find_free_port(40000, 49999)
        ENV["MCPREPL_BYPASS_PROXY"] = "true"

        # Create temporary security config for testing
        temp_dir = mktempdir()
        mcprepl_dir = joinpath(temp_dir, ".mcprepl")
        mkdir(mcprepl_dir)

        # Write minimal security config in lax mode (no API key required)
        security_config = MCPRepl.SecurityConfig(
            :lax,
            String[],
            String[],
            port,
            true,
            trunc(Int64, time()),
        )
        MCPRepl.save_security_config(security_config, temp_dir)

        try
            # This should not error even though proxy isn't running
            MCPRepl.start!(port = port, verbose = false, workspace_dir = temp_dir)

            # Verify server is actually running
            @test MCPRepl.SERVER[] !== nothing
            @test MCPRepl.SERVER[].port == port

        finally
            MCPRepl.stop!()
            delete!(ENV, "MCPREPL_BYPASS_PROXY")
            rm(temp_dir; recursive = true, force = true)
        end
    end

    @testset "Configuration" begin
        # Verify bypass_proxy flag in SecurityConfig
        config = MCPRepl.SecurityConfig(
            :lax,
            String[],
            String[],
            4000,
            true,
            trunc(Int64, time()),
        )
        @test config.bypass_proxy == true

        # Verify ENV variable detection
        original = get(ENV, "MCPREPL_BYPASS_PROXY", nothing)
        try
            ENV["MCPREPL_BYPASS_PROXY"] = "true"
            bypass = get(ENV, "MCPREPL_BYPASS_PROXY", "false") == "true"
            @test bypass == true
        finally
            original === nothing ? delete!(ENV, "MCPREPL_BYPASS_PROXY") :
            (ENV["MCPREPL_BYPASS_PROXY"] = original)
        end
    end

    @testset "Session Persistence" begin
        # Test session persistence via .mcprepl/sessions.json
        test_dir = mktempdir()
        original_pwd = pwd()

        try
            cd(test_dir)

            @testset "save and load sessions" begin
                test_sessions = Dict{String,Dict}(
                    "session-1" => Dict(
                        "created_at" => "2026-01-25T10:00:00",
                        "last_seen" => "2026-01-25T10:30:00",
                    ),
                )

                MCPRepl.save_persisted_sessions(test_sessions)

                sessions_file = joinpath(test_dir, ".mcprepl", "sessions.json")
                @test isfile(sessions_file)

                # Verify JSON structure
                data = JSON.parsefile(sessions_file)
                @test haskey(data, "sessions")
                @test haskey(data["sessions"], "session-1")
            end

            @testset "filter expired sessions (1 month cutoff)" begin
                # Create sessions with varying ages
                now_str = Dates.format(now(), "yyyy-mm-dd\\THH:MM:SS")
                old_date = Dates.format(now() - Month(2), "yyyy-mm-dd\\THH:MM:SS")
                recent_date = Dates.format(now() - Day(15), "yyyy-mm-dd\\THH:MM:SS")

                test_sessions = Dict{String,Dict}(
                    "recent-session" =>
                        Dict("created_at" => recent_date, "last_seen" => now_str),
                    "expired-session" =>
                        Dict("created_at" => old_date, "last_seen" => old_date),
                    "current-session" =>
                        Dict("created_at" => now_str, "last_seen" => now_str),
                )

                MCPRepl.save_persisted_sessions(test_sessions)
                loaded = MCPRepl.load_persisted_sessions()

                # Should only have recent and current sessions (not expired)
                @test length(loaded) == 2
                @test haskey(loaded, "recent-session")
                @test haskey(loaded, "current-session")
                @test !haskey(loaded, "expired-session")
            end

            @testset "register updates last_seen" begin
                session_id = "test-session-123"

                # Register new session
                MCPRepl.register_persisted_session(session_id)
                loaded = MCPRepl.load_persisted_sessions()

                @test haskey(loaded, session_id)
                @test haskey(loaded[session_id], "created_at")
                @test haskey(loaded[session_id], "last_seen")

                initial_created = loaded[session_id]["created_at"]
                initial_seen = loaded[session_id]["last_seen"]

                # Wait and update
                sleep(0.1)
                MCPRepl.register_persisted_session(session_id)
                loaded2 = MCPRepl.load_persisted_sessions()

                # created_at should stay the same, last_seen should update
                @test loaded2[session_id]["created_at"] == initial_created
                @test loaded2[session_id]["last_seen"] != initial_seen
            end

            @testset "handles missing file gracefully" begin
                # Remove sessions file
                sessions_file = joinpath(test_dir, ".mcprepl", "sessions.json")
                if isfile(sessions_file)
                    rm(sessions_file)
                end

                # Should return empty dict without error
                loaded = MCPRepl.load_persisted_sessions()
                @test isempty(loaded)
            end

        finally
            cd(original_pwd)
            rm(test_dir; recursive = true, force = true)
        end
    end
end
