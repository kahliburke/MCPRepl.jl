# ============================================================================
# Vite Dev Server Management
# ============================================================================

"""
    is_dev_environment() -> Bool

Check if we're in a development environment (dashboard-ui source exists).
"""
function is_dev_environment()
    # Since this file is at src/proxy/vite.jl, we need to go up 2 levels to reach project root
    dashboard_src = joinpath(dirname(dirname(dirname(@__FILE__))), "dashboard-ui", "src")
    return isdir(dashboard_src)
end

"""
    is_vite_running() -> Bool

Check if Vite dev server is running on port 3001.
"""
function is_vite_running()
    try
        sock = connect("localhost", VITE_DEV_PORT)
        close(sock)
        return true
    catch
        return false
    end
end

"""
    start_vite_dev_server()

Start the Vite dev server if in development mode and not already running.
"""
function start_vite_dev_server()
    # Only start in dev environment
    if !is_dev_environment()
        @debug "Not in dev environment, skipping Vite dev server"
        return nothing
    end

    # Check if already running
    if is_vite_running()
        @info "Vite dev server already running on port $VITE_DEV_PORT"
        return nothing
    end

    # Check if process reference exists and is still running
    if VITE_DEV_PROCESS[] !== nothing && process_running(VITE_DEV_PROCESS[])
        @info "Vite dev server process already started"
        return VITE_DEV_PROCESS[]
    end

    # Since this file is at src/proxy/vite.jl, go up 2 levels to reach project root
    dashboard_dir = joinpath(dirname(dirname(dirname(@__FILE__))), "dashboard-ui")

    # Check if node_modules exists
    if !isdir(joinpath(dashboard_dir, "node_modules"))
        @warn "dashboard-ui/node_modules not found. Run 'npm install' first."
        return nothing
    end

    @info "Starting Vite dev server..." dashboard_dir = dashboard_dir port = VITE_DEV_PORT

    try
        # Check if npm is available
        npm_check = try
            read(`which npm`, String)
            true
        catch
            false
        end

        if !npm_check
            @error "npm not found in PATH. Cannot start Vite dev server."
            return nothing
        end

        # Create log file for Vite output
        log_file = joinpath(dashboard_dir, ".vite-dev.log")

        # Start npm run dev in the background
        # Redirect output to log file for debugging
        proc = cd(dashboard_dir) do
            log_io = open(log_file, "w")
            # Note: log_io will be closed when process exits or via atexit
            run(pipeline(`npm run dev`, stdout = log_io, stderr = log_io), wait = false)
        end

        VITE_DEV_PROCESS[] = proc

        # Give it a moment to start
        sleep(3)

        if is_vite_running()
            @info "✅ Vite dev server started on port $VITE_DEV_PORT"
            return proc
        else
            @warn "Vite dev server may not have started successfully. Check $(log_file) for details."
            # Try to read first few lines of log for immediate feedback
            try
                log_content = readlines(log_file)
                if !isempty(log_content)
                    @warn "Vite log (first 5 lines):" log_lines =
                        join(log_content[1:min(5, length(log_content))], "\n")
                end
            catch
            end
            return proc
        end
    catch e
        @error "Failed to start Vite dev server" exception = (e, catch_backtrace())
        return nothing
    end
end

"""
    stop_vite_dev_server()

Stop the Vite dev server if it's running.
"""
function stop_vite_dev_server()
    if VITE_DEV_PROCESS[] !== nothing
        try
            kill(VITE_DEV_PROCESS[])
            @info "Vite dev server stopped"
        catch e
            @debug "Error stopping Vite dev server" exception = (e, catch_backtrace())
        end
        VITE_DEV_PROCESS[] = nothing
    end
end