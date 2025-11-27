#!/usr/bin/env julia
"""
MCP Proxy Server Launcher

Usage:
    julia proxy.jl [command] [options]

Commands:
    start       Start the proxy server (default)
    stop        Stop the running proxy server
    restart     Restart the proxy server
    status      Check if proxy is running
    clean       Remove all logs and database files

Options:
    --background, -b    Run in background (for start/restart)
    --port PORT, -p     Port to use (default: 3000)
    --clean, -c         Clean logs/database before starting (for start/restart)

Examples:
    julia proxy.jl                    # Start in foreground
    julia proxy.jl start --background # Start in background
    julia proxy.jl start --clean      # Clean then start
    julia proxy.jl clean              # Just clean files
    julia proxy.jl restart            # Restart proxy
    julia proxy.jl stop               # Stop proxy
    julia proxy.jl status             # Check status
"""

using Pkg
Pkg.activate(@__DIR__)

# Include and use the Proxy module
using MCPRepl
using MCPRepl.Proxy

# Parse command line arguments
const command = length(ARGS) >= 1 ? ARGS[1] : "start"
const background = "--background" in ARGS || "-b" in ARGS
const clean_first = "--clean" in ARGS || "-c" in ARGS

# Parse port if provided
port = 3000
for (i, arg) in enumerate(ARGS)
    if arg == "--port" || arg == "-p"
        if i < length(ARGS)
            global port = parse(Int, ARGS[i+1])
        end
    end
end

# Execute command
if command == "start"
    # Clean first if requested
    if clean_first
        println("🧹 Cleaning logs and database...")
        Proxy.clean_proxy_data(port; verbose = true)
        println()
    end

    if Proxy.is_server_running(port)
        existing_pid = Proxy.get_server_pid(port)
        println("❌ Proxy already running on port $port (PID: $existing_pid)")
        println("   Use 'restart' command to restart it")
        exit(1)
    end

    println("🚀 Starting proxy server on port $port$(background ? " (background)" : "")...")
    server = Proxy.start_server(port; background = background)

    if !background && server !== nothing
        println("✅ Proxy server running on port $port. Press Ctrl+C to stop.")
        println("📊 Dashboard: http://localhost:3001")
        println("📝 Logs: ~/.cache/mcprepl/proxy-$port.log")
        wait(server)
    end

elseif command == "stop"
    if !Proxy.is_server_running(port)
        println("ℹ️  No proxy server running on port $port")
        exit(0)
    end

    existing_pid = Proxy.get_server_pid(port)
    println("🛑 Stopping proxy server on port $port (PID: $existing_pid)...")
    Proxy.stop_server(port)
    println("✅ Proxy stopped")

elseif command == "restart"
    # Clean first if requested
    if clean_first
        println("🧹 Cleaning logs and database...")
        Proxy.clean_proxy_data(port; verbose = true)
        println()
    end

    println(
        "🔄 Restarting proxy server on port $port$(background ? " (background)" : "")...",
    )
    server = Proxy.restart_server(port; background = background)

    if !background && server !== nothing
        println("✅ Proxy server running on port $port. Press Ctrl+C to stop.")
        println("📊 Dashboard: http://localhost:3001")
        println("📝 Logs: ~/.cache/mcprepl/proxy-$port.log")
        wait(server)
    end

elseif command == "status"
    if Proxy.is_server_running(port)
        existing_pid = Proxy.get_server_pid(port)
        println("✅ Proxy server is running")
        println("   Port: $port")
        println("   PID: $existing_pid")
        println("   Dashboard: http://localhost:3001")
        println("   Logs: ~/.cache/mcprepl/proxy-$port.log")
    else
        println("❌ Proxy server is not running on port $port")
        exit(1)
    end

elseif command == "clean"
    println("🧹 Cleaning all proxy logs and database files...")
    println()
    files = Proxy.clean_proxy_data(port; verbose = true)
    println()
    if !isempty(files)
        println("✅ Clean complete! Ready for a fresh start.")
    end

elseif command == "help" || command == "--help" || command == "-h"
    println(__doc__)

else
    println("❌ Unknown command: $command")
    println("   Use 'julia proxy.jl help' for usage information")
    exit(1)
end
