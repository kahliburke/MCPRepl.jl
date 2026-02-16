"""
    is_server_running(port::Int=3000) -> Bool

Check if a proxy server is already running on the specified port.
"""
function is_server_running(port::Int = 3000)
    try
        # Try to connect to the port
        sock = connect(ip"127.0.0.1", port)
        close(sock)
        return true
    catch
        return false
    end
end

"""
    get_server_pid(port::Int=3000) -> Union{Int, Nothing}

Get the PID of the running proxy server from the PID file.
Returns nothing if no PID file exists or process is not running.
"""
function get_server_pid(port::Int = 3000)
    pid_file = get_pid_file_path(port)

    if !isfile(pid_file)
        return nothing
    end

    try
        pid_str = strip(read(pid_file, String))
        pid = parse(Int, pid_str)

        # Verify process is actually running using parent module's Utils
        if isdefined(Main, :MCPRepl) && isdefined(Main.MCPRepl, :Utils)
            if Main.MCPRepl.Utils.process_running(pid)
                return pid
            else
                # Stale PID file, remove it
                rm(pid_file, force = true)
                return nothing
            end
        else
            # Can't verify, assume running
            return pid
        end
    catch
        return nothing
    end
end

"""
    get_pid_file_path(port::Int=3000) -> String

Get the path to the PID file for a proxy server on the given port.
"""
function get_pid_file_path(port::Int = 3000)
    return joinpath(mcprepl_cache_dir(), "proxy-$port.pid")
end

"""
    write_pid_file(port::Int=3000)

Write the current process PID to the PID file.
"""
function write_pid_file(port::Int = 3000)
    pid_file = get_pid_file_path(port)
    write(pid_file, string(getpid()))
    SERVER_PID_FILE[] = pid_file
end

"""
    remove_pid_file(port::Int=3000)

Remove the PID file for the proxy server.
"""
function remove_pid_file(port::Int = 3000)
    pid_file = get_pid_file_path(port)
    rm(pid_file, force = true)
end