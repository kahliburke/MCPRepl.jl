# Simple script to start just the proxy server
# The Proxy module is internal to MCPRepl, so we activate the environment and include it directly

using Pkg
Pkg.activate(@__DIR__)

using MCPRepl
using MCPRepl.Proxy
using MCPRepl.Dashboard

# Check if proxy is already running and stop it if requested
port = 3000
if Proxy.is_server_running(port)
    existing_pid = Proxy.get_server_pid(port)
    if existing_pid !== nothing
        println("⚠️  Proxy already running on port $port (PID: $existing_pid)")
        if length(ARGS) > 0 && ARGS[1] == "--restart"
            println("🔄 Stopping existing proxy...")
            Proxy.stop_server(port)
            sleep(1)  # Give it time to shutdown
        else
            println("❌ Use --restart flag to stop and restart, or stop it manually")
            exit(1)
        end
    end
end

# Start the proxy in foreground mode
println("🚀 Starting proxy server on port $port...")
server = Proxy.start_foreground_server(port)

# Keep the server running
println("Proxy server running on port 3000. Press Ctrl+C to stop.")
wait(server)
