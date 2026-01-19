using Pkg
Pkg.activate(".")
import Base.Threads

# Load Revise for hot reloading (optional but recommended)
try
    using Revise
    @info "✓ Revise loaded - code changes will be tracked and auto-reloaded"
catch e
    @info "ℹ Revise not loaded (optional - install with: Pkg.add(\"Revise\"))"
end
using MCPRepl

# To bypass proxy and run MCP server in standalone mode:
# ENV["MCPREPL_BYPASS_PROXY"] = "true"

# Start MCP REPL server for AI agent integration
try
    if Threads.threadid() == 1
        Threads.@spawn begin
            try
                sleep(1)
                MCPRepl.start!(verbose = false)

                # Wait a moment for server to fully initialize
                sleep(0.5)

                # Startup complete - prompt is already clean from start!()
            catch e
                @warn "Could not start MCP REPL server" exception = e
            end
        end
    end
catch e
    @warn "Could not start MCP REPL server" exception = e
end
