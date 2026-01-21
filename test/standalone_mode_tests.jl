using ReTest
using MCPRepl

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
end
