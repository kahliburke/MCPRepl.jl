# ============================================================================
# Vite Dev Server Management
# ============================================================================

"""
    is_dev_environment() -> Bool

Check if we're in a development environment (dashboard-ui source exists).
"""
function is_dev_environment()
    dashboard_src = joinpath(dirname(dirname(@__FILE__)), "dashboard-ui", "src")
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

    dashboard_dir = joinpath(dirname(dirname(@__FILE__)), "dashboard-ui")

    # Check if node_modules exists
    if !isdir(joinpath(dashboard_dir, "node_modules"))
        @warn "dashboard-ui/node_modules not found. Run 'npm install' first."
        return nothing
    end

    @info "Starting Vite dev server..." dashboard_dir = dashboard_dir port = VITE_DEV_PORT

    try
        # Start npm run dev in the background
        # Need to change directory before running
        proc = cd(dashboard_dir) do
            run(pipeline(`npm run dev`, stdout = devnull, stderr = devnull), wait = false)
        end

        VITE_DEV_PROCESS[] = proc

        # Give it a moment to start
        sleep(2)

        if is_vite_running()
            @info "✅ Vite dev server started on port $VITE_DEV_PORT"
            return proc
        else
            @warn "Vite dev server may not have started successfully"
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