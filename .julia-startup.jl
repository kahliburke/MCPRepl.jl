# MCPRepl Bridge — auto-connect this REPL to the TUI server
try
    using MCPRepl
    MCPReplBridge.serve(name = "MCPRepl")
catch e
    @warn "MCPRepl bridge failed to start" exception = e
end
