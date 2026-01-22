
module MCPRepl

using REPL
using JSON
using InteractiveUtils
using Profile
using HTTP
using Random
using SHA
using Dates
using Coverage
using ReTest
using CodeTracking
using Pkg
using Sockets
using TOML

export @mcp_tool, MCPTool
export start!, stop!, test_server

include("utils.jl")
include("database.jl")
include("dashboard.jl")
include("proxy.jl")
include("qdrant_client.jl")
include("tools.jl")
include("Generate.jl")

# Export public API functions
export start!, stop!, setup, test_server, reset
export setup_security, security_status, generate_key, revoke_key
export allow_ip, deny_ip, set_security_mode, quick_setup, gentle_setup
export call_tool, list_tools, tool_help
export start_proxy, stop_proxy  # Proxy server functions
export register_tool!, registry  # Project hook API
export Proxy  # Proxy server module
# export Generate  # Project template generator module
# export Dashboard
# export Database

# ============================================================================
# Port Management
# ============================================================================

"""
    find_free_port(start_port::Int=40000, end_port::Int=49999) -> Int

Find an available port in the specified range by attempting to bind to each port.

# Arguments
- `start_port::Int=40000`: Start of port range to search (default: 40000-49999 for dynamic ports)
- `end_port::Int=49999`: End of port range to search

# Returns
- `Int`: First available port in the range

# Throws
- `ErrorException`: If no free port is found in the range

# Examples
```julia
# Find port in default range (40000-49999)
port = find_free_port()

# Find port in custom range
port = find_free_port(4000, 4999)
```
"""
function find_free_port(start_port::Int = 40000, end_port::Int = 49999)
    last_error = nothing
    ports_tried = 0

    for port = start_port:end_port
        ports_tried += 1
        try
            # Try to bind to the port - if successful, it's available
            server = Sockets.listen(Sockets.InetAddr(parse(IPAddr, "127.0.0.1"), port))
            close(server)
            @info "Found free port" port = port ports_tried = ports_tried
            return port
        catch e
            # Port is in use or binding failed, try next one
            last_error = e
            if ports_tried <= 5 || ports_tried == end_port - start_port + 1
                @debug "Port unavailable" port = port exception = e
            end
            continue
        end
    end

    # Provide detailed error message
    error_msg = "No free ports available in range $start_port-$end_port"
    if last_error !== nothing
        error_msg *= ". Last error: $(sprint(showerror, last_error))"
    end
    error(error_msg)
end

# Version tracking - gets git commit hash at runtime
function version_info()
    try
        pkg_dir = pkgdir(@__MODULE__)
        git_dir = joinpath(pkg_dir, ".git")

        # Check if it's a git repo first (dev package)
        if isdir(git_dir)
            try
                commit = readchomp(`git -C $(pkg_dir) rev-parse --short HEAD`)
                dirty = success(`git -C $(pkg_dir) diff --quiet`) ? "" : "-dirty"
                return "$(commit)$(dirty)"
            catch git_error
                @warn "Failed to get git version" exception = git_error
                # Fall through to read from Project.toml
            end
        end

        # Read version from Project.toml
        project_file = joinpath(pkg_dir, "Project.toml")
        if isfile(project_file)
            project = TOML.parsefile(project_file)
            if haskey(project, "version")
                return "v$(project["version"])"
            end
        end

        return "unknown"
    catch e
        @warn "Failed to get version info" exception = e
        return "unknown"
    end
end

# ============================================================================
# Tool Definition Macros
# ============================================================================

"""
    @mcp_tool id description params handler

Define an MCP tool with symbol-based identification.

# Arguments
- `id`: Symbol literal (e.g., :exec_repl) - becomes both internal ID and string name
- `description`: String describing the tool
- `params`: Parameters schema Dict
- `handler`: Function taking (args) or (args, stream_channel)

# Examples
```julia
tool = @mcp_tool :exec_repl "Execute Julia code" Dict(
    "type" => "object",
    "properties" => Dict("expression" => Dict("type" => "string")),
    "required" => ["expression"]
) (args, stream_channel=nothing) -> begin
    execute_repllike(get(args, "expression", ""); stream_channel=stream_channel)
end
```
"""
macro mcp_tool(id, description, params, handler)
    if !(id isa QuoteNode || (id isa Expr && id.head == :quote))
        error("@mcp_tool requires a symbol literal for id, got: $id")
    end

    # Extract the symbol from QuoteNode
    id_sym = id isa QuoteNode ? id.value : id.args[1]
    name_str = string(id_sym)

    return esc(
        quote
            MCPTool(
                $(QuoteNode(id_sym)),    # :exec_repl
                $name_str,                # "exec_repl"
                $description,
                $params,
                $handler,
            )
        end,
    )
end

include("security.jl")
include("security_wizard.jl")
include("repl_status.jl")
include("tool_definitions.jl")
include("MCPServer.jl")
include("setup.jl")
include("vscode.jl")
include("lsp.jl")
include("lsp_tool_definitions.jl")
include("qdrant_tools.jl")
include("qdrant_indexer.jl")

# ============================================================================
# VS Code Response Storage for Bidirectional Communication
# ============================================================================

# Global dictionary to store VS Code command responses
# Key: request_id (String), Value: (result, error, timestamp)
const VSCODE_RESPONSES = Dict{String,Tuple{Any,Union{Nothing,String},Float64}}()

# Lock for thread-safe access to response dictionary
const VSCODE_RESPONSE_LOCK = ReentrantLock()

# Global dictionary to store single-use nonces for VS Code callbacks
# Key: request_id (String), Value: (nonce, timestamp)
const VSCODE_NONCES = Dict{String,Tuple{String,Float64}}()

# Lock for thread-safe access to nonces dictionary
const VSCODE_NONCE_LOCK = ReentrantLock()

# Lock for serializing REPL-like execution.
# `execute_repllike` currently uses stdout/stderr redirection which is process-global;
# concurrent calls can collide and leave the session in a bad state.
const EXEC_REPLLIKE_LOCK = ReentrantLock()


"""
    store_vscode_response(request_id::String, result, error::Union{Nothing,String})

Store a response from VS Code for later retrieval.
Thread-safe storage using VSCODE_RESPONSE_LOCK.
"""
function store_vscode_response(request_id::String, result, error::Union{Nothing,String})
    lock(VSCODE_RESPONSE_LOCK) do
        VSCODE_RESPONSES[request_id] = (result, error, time())
    end
end

"""
    retrieve_vscode_response(request_id::String; timeout::Float64=5.0, poll_interval::Float64=0.1)

Retrieve a stored VS Code response, waiting up to `timeout` seconds.
Returns (result, error) tuple or throws TimeoutError.
Automatically cleans up the stored response after retrieval.
"""
function retrieve_vscode_response(
    request_id::String;
    timeout::Float64 = 5.0,
    poll_interval::Float64 = 0.1,
)
    start_time = time()

    while (time() - start_time) < timeout
        response = lock(VSCODE_RESPONSE_LOCK) do
            get(VSCODE_RESPONSES, request_id, nothing)
        end

        if response !== nothing
            # Clean up the stored response
            lock(VSCODE_RESPONSE_LOCK) do
                delete!(VSCODE_RESPONSES, request_id)
            end
            return (response[1], response[2])  # (result, error)
        end

        sleep(poll_interval)
    end

    error("Timeout waiting for VS Code response (request_id: $request_id)")
end

"""
    cleanup_old_vscode_responses(max_age::Float64=60.0)

Remove responses older than `max_age` seconds to prevent memory leaks.
Should be called periodically.
"""
function cleanup_old_vscode_responses(max_age::Float64 = 60.0)
    current_time = time()
    lock(VSCODE_RESPONSE_LOCK) do
        for (request_id, (_, _, timestamp)) in collect(VSCODE_RESPONSES)
            if (current_time - timestamp) > max_age
                delete!(VSCODE_RESPONSES, request_id)
            end
        end
    end
end

# ============================================================================
# Nonce Management for VS Code Authentication
# ============================================================================

"""
    generate_nonce()

Generate a cryptographically secure random nonce for single-use authentication.
Returns a 32-character hex string.
"""
function generate_nonce()
    return bytes2hex(rand(Random.RandomDevice(), UInt8, 16))
end

"""
    store_nonce(request_id::String, nonce::String)

Store a nonce for a specific request ID. Thread-safe.
"""
function store_nonce(request_id::String, nonce::String)
    lock(VSCODE_NONCE_LOCK) do
        VSCODE_NONCES[request_id] = (nonce, time())
    end
end

"""
    validate_and_consume_nonce(request_id::String, nonce::String)::Bool

Validate that a nonce matches the stored nonce for a request ID, then consume it (delete it).
Returns true if valid, false otherwise. Thread-safe.
"""
function validate_and_consume_nonce(request_id::String, nonce::String)::Bool
    lock(VSCODE_NONCE_LOCK) do
        stored = get(VSCODE_NONCES, request_id, nothing)
        if stored === nothing
            return false
        end

        stored_nonce, _ = stored
        # Delete immediately to prevent reuse
        delete!(VSCODE_NONCES, request_id)

        return stored_nonce == nonce
    end
end

"""
    cleanup_old_nonces(max_age::Float64=60.0)

Remove nonces older than `max_age` seconds to prevent memory leaks.
Should be called periodically.
"""
function cleanup_old_nonces(max_age::Float64 = 60.0)
    current_time = time()
    lock(VSCODE_NONCE_LOCK) do
        for (request_id, (_, timestamp)) in collect(VSCODE_NONCES)
            if (current_time - timestamp) > max_age
                delete!(VSCODE_NONCES, request_id)
            end
        end
    end
end

# ============================================================================
# VS Code URI Helpers
# ============================================================================

# Helper function to trigger VS Code commands via URI
function trigger_vscode_uri(uri::String)
    if Sys.isapple()
        run(`open $uri`)
    elseif Sys.islinux()
        run(`xdg-open $uri`)
    elseif Sys.iswindows()
        run(`cmd /c start $uri`)
    else
        error("Unsupported operating system")
    end
end

# Helper function to build VS Code command URI
function build_vscode_uri(
    command::String;
    args::Union{Nothing,String} = nothing,
    request_id::Union{Nothing,String} = nothing,
    mcp_port::Int = 3000,
    nonce::Union{Nothing,String} = nothing,
    publisher::String = "MCPRepl",
    name::String = "vscode-remote-control",
)
    uri = "vscode://$(publisher).$(name)?cmd=$(command)"
    if args !== nothing
        uri *= "&args=$(args)"
    end
    if request_id !== nothing
        uri *= "&request_id=$(request_id)"
    end
    if mcp_port != 3000
        uri *= "&mcp_port=$(mcp_port)"
    end
    if nonce !== nothing
        uri *= "&nonce=$(HTTP.URIs.escapeuri(nonce))"
    end
    return uri
end

struct IOBufferDisplay <: AbstractDisplay
    io::IOBuffer
    IOBufferDisplay() = new(IOBuffer())
end
# Resolve ambiguities with Base.Multimedia
Base.displayable(::IOBufferDisplay, ::AbstractString) = true
Base.displayable(::IOBufferDisplay, ::MIME) = true
Base.displayable(::IOBufferDisplay, _) = true
Base.display(d::IOBufferDisplay, x) = show(d.io, MIME("text/plain"), x)
Base.display(d::IOBufferDisplay, mime::AbstractString, x) = show(d.io, MIME(mime), x)
Base.display(d::IOBufferDisplay, mime::MIME, x) = show(d.io, mime, x)
Base.display(d::IOBufferDisplay, mime, x) = show(d.io, mime, x)

"""
    remove_println_calls(expr, toplevel=true)

Strip println, print, printstyled, @show, and logging macros from an AST expression.
When quiet mode is on, agents shouldn't use these to communicate since
the user already sees code execution in their REPL.

Logging macros (@error, @debug, @info, @warn) are only removed at the top level,
not inside function definitions or other nested code.
"""
function remove_println_calls(expr, toplevel::Bool = true)
    if expr isa Expr
        # Check if this is a print-related call
        if expr.head == :call
            func = expr.args[1]
            # List of functions to remove (always, regardless of level)
            print_funcs = [:println, :print, :printstyled]
            # Match direct calls (println, print, printstyled)
            if func in print_funcs
                return nothing
            end
            # Match qualified calls (Base.println, Main.print, etc.)
            if (
                func isa Expr &&
                func.head == :. &&
                length(func.args) >= 2 &&
                func.args[end] isa QuoteNode &&
                func.args[end].value in print_funcs
            )
                return nothing
            end
        elseif expr.head == :macrocall
            macro_name = expr.args[1]
            # Remove @show always
            if macro_name == Symbol("@show")
                return nothing
            end
            # Remove logging macros ONLY at top level
            if toplevel
                logging_macros =
                    [Symbol("@error"), Symbol("@debug"), Symbol("@info"), Symbol("@warn")]
                if macro_name in logging_macros
                    return nothing
                end
                # Also handle qualified logging macros
                if (
                    macro_name isa Expr &&
                    macro_name.head == :. &&
                    length(macro_name.args) >= 2 &&
                    macro_name.args[end] isa QuoteNode &&
                    macro_name.args[end].value in [:error, :debug, :info, :warn]
                )
                    return nothing
                end
            end
        end

        # Determine if we're entering a nested scope (not top level anymore)
        entering_nested = expr.head in [:function, :macro, :let, :do, :try, :->]

        # Recursively process all arguments, filtering out nothings
        new_args = []
        for arg in expr.args
            cleaned = remove_println_calls(arg, toplevel && !entering_nested)
            if cleaned !== nothing
                push!(new_args, cleaned)
            end
        end
        # If we have a block and removed some statements, rebuild it
        if expr.head == :block && length(new_args) != length(expr.args)
            return Expr(expr.head, new_args...)
        else
            return Expr(expr.head, new_args...)
        end
    end
    return expr
end

function execute_repllike(
    str;
    silent::Bool = false,
    quiet::Bool = true,
    description::Union{String,Nothing} = nothing,
    show_prompt::Bool = true,
)
    lock(EXEC_REPLLIKE_LOCK)
    try
        # Check for Pkg.activate usage
        if contains(str, "activate(") && !contains(str, r"#.*overwrite no-activate-rule")
            return """
                ERROR: Using Pkg.activate to change environments is not allowed.
                You should assume you are in the correct environment for your tasks.
                You may use Pkg.status() to see the current environment and available packages.
                If you need to use a third-party 'activate' function, add '# overwrite no-activate-rule' at the end of your command.
            """
        end

        # Check if we have an active REPL (interactive mode) or running in server mode
        # Note: `Base.active_repl` may exist but be `nothing` in non-interactive contexts.
        repl =
            (isdefined(Base, :active_repl) && (Base.active_repl !== nothing)) ?
            Base.active_repl : nothing
        backend =
            repl !== nothing && hasproperty(repl, :backendref) ? repl.backendref : nothing
        has_repl =
            repl !== nothing &&
            backend !== nothing &&
            hasproperty(backend, :repl_channel) &&
            hasproperty(backend, :response_channel) &&
            isopen(backend.repl_channel) &&
            isopen(backend.response_channel)

        # Track whether user explicitly wants to see the return value
        # In non-quiet mode, show return value unless they added a semicolon
        show_return_value = !quiet && !REPL.ends_with_semicolon(str)

        # Auto-append semicolon in quiet mode to suppress output
        if quiet && !REPL.ends_with_semicolon(str)
            str = str * ";"
        end

        expr = Base.parse_input_line(str)

        # In quiet mode, strip println statements from the AST
        # User already sees code execution in their REPL - println is redundant
        if quiet
            expr = remove_println_calls(expr)
        end

        if has_repl && !silent
            REPL.prepare_next(repl)
        end

        # Only print the agent prompt if not silent and show_prompt is true
        if !silent && show_prompt
            printstyled("\nagent> ", color = :red, bold = :true)
            if description !== nothing
                println(description)
            else
                # Transform println calls to comments for display
                display_str = replace(str, r"println\s*\(\s*\"([^\"]*)\"\s*\)" => s"# \1")
                display_str = replace(display_str, r"@info\s+\"([^\"]*?)\"" => s"# \1")
                display_str =
                    replace(display_str, r"@warn\s+\"([^\"]*?)\"" => s"# WARNING: \1")
                display_str =
                    replace(display_str, r"@error\s+\"([^\"]*?)\"" => s"# ERROR: \1")
                # Split on semicolons for multi-line display
                display_str = replace(display_str, r";\s*" => "\n")
                # If multiline, start on new line for proper indentation
                if contains(display_str, '\n')
                    println()  # Start on new line
                    print(display_str, "\n")
                else
                    print(display_str, "\n")
                end
            end
        end

        # Evaluate the expression and capture stdout/stderr.
        # Important: in interactive REPL mode, evaluation happens on the REPL backend task.
        # Redirecting stdout/stderr in the current task won't reliably capture backend output.
        # So we run a function on the backend that performs the capture *within* the backend task.
        backend_iserr = false
        response = try
            if has_repl
                result = REPL.call_on_backend(
                    () -> begin
                        orig_stdout = stdout
                        orig_stderr = stderr

                        stdout_read, stdout_write = redirect_stdout()
                        stderr_read, stderr_write = redirect_stderr()

                        stdout_content = String[]
                        stderr_content = String[]

                        stdout_task = @async begin
                            try
                                while !eof(stdout_read)
                                    line = readline(stdout_read; keep = true)
                                    push!(stdout_content, line)
                                    if !silent
                                        write(orig_stdout, line)
                                        flush(orig_stdout)
                                    end
                                end
                            catch e
                                if !isa(e, EOFError)
                                    @debug "stdout read error" exception = e
                                end
                            end
                        end

                        stderr_task = @async begin
                            try
                                while !eof(stderr_read)
                                    line = readline(stderr_read; keep = true)
                                    push!(stderr_content, line)
                                    if !silent
                                        write(orig_stderr, line)
                                        flush(orig_stderr)
                                    end
                                end
                            catch e
                                if !isa(e, EOFError)
                                    @debug "stderr read error" exception = e
                                end
                            end
                        end

                        value = nothing
                        caught = nothing
                        bt = nothing
                        try
                            value = Core.eval(Main, expr)
                        catch e
                            caught = e
                            bt = catch_backtrace()
                        finally
                            redirect_stdout(orig_stdout)
                            redirect_stderr(orig_stderr)

                            close(stdout_write)
                            close(stderr_write)

                            wait(stdout_task)
                            wait(stderr_task)

                            close(stdout_read)
                            close(stderr_read)
                        end

                        (
                            stdout = join(stdout_content),
                            stderr = join(stderr_content),
                            value = value,
                            exception = caught,
                            backtrace = bt,
                        )
                    end,
                    backend,
                )

                val, iserr = if result isa Pair
                    (result.first, result.second)
                elseif result isa Tuple && length(result) == 2
                    (result[1], result[2])
                else
                    (result, false)
                end

                backend_iserr = iserr
                val
            else
                # Server/non-interactive mode: capture in the current task.
                orig_stdout = stdout
                orig_stderr = stderr

                stdout_read, stdout_write = redirect_stdout()
                stderr_read, stderr_write = redirect_stderr()

                stdout_content = String[]
                stderr_content = String[]

                stdout_task = @async begin
                    try
                        while !eof(stdout_read)
                            line = readline(stdout_read; keep = true)
                            push!(stdout_content, line)
                            if !silent
                                write(orig_stdout, line)
                                flush(orig_stdout)
                            end
                        end
                    catch e
                        if !isa(e, EOFError)
                            @debug "stdout read error" exception = e
                        end
                    end
                end

                stderr_task = @async begin
                    try
                        while !eof(stderr_read)
                            line = readline(stderr_read; keep = true)
                            push!(stderr_content, line)
                            if !silent
                                write(orig_stderr, line)
                                flush(orig_stderr)
                            end
                        end
                    catch e
                        if !isa(e, EOFError)
                            @debug "stderr read error" exception = e
                        end
                    end
                end

                value = nothing
                caught = nothing
                bt = nothing
                try
                    value = Core.eval(Main, expr)
                catch e
                    caught = e
                    bt = catch_backtrace()
                finally
                    redirect_stdout(orig_stdout)
                    redirect_stderr(orig_stderr)

                    close(stdout_write)
                    close(stderr_write)

                    wait(stdout_task)
                    wait(stderr_task)

                    close(stdout_read)
                    close(stderr_read)
                end

                (
                    stdout = join(stdout_content),
                    stderr = join(stderr_content),
                    value = value,
                    exception = caught,
                    backtrace = bt,
                )
            end
        catch e
            backend_iserr = true
            (exception = e, backtrace = catch_backtrace())
        end

        captured_content =
            if response isa NamedTuple &&
               haskey(response, :stdout) &&
               haskey(response, :stderr)
                String(response.stdout) * String(response.stderr)
            else
                ""
            end

        # Note: Output was already displayed in real-time by the async tasks
        # No need to print captured_content again unless silent mode

        # Format the result for display
        result_str = if response isa NamedTuple
            if haskey(response, :exception) && response.exception !== nothing
                io_buf = IOBuffer()
                try
                    showerror(io_buf, response.exception, response.backtrace)
                catch
                    # If Base's error hint machinery explodes due to a mock/partial REPL,
                    # still return the core exception message.
                    showerror(io_buf, response.exception)
                end
                "ERROR: " * String(take!(io_buf))
            elseif haskey(response, :value) && show_return_value
                io_buf = IOBuffer()
                show(io_buf, MIME("text/plain"), response.value)
                String(take!(io_buf))
            else
                ""
            end
        elseif response isa Exception
            io_buf = IOBuffer()
            showerror(io_buf, response)
            "ERROR: " * String(take!(io_buf))
        else
            ""
        end

        # Refresh REPL if not silent and we have a REPL
        if !silent && has_repl
            if !isempty(result_str)
                println(result_str)
            end
            REPL.prepare_next(repl)
            REPL.LineEdit.refresh_line(repl.mistate)
        end

        # In quiet mode, don't return captured stdout/stderr (println output)
        # EXCEPT for errors - always return errors to the agent.
        # REPL.eval_on_backend signals errors via an `iserr` flag instead of throwing.
        has_error =
            backend_iserr ||
            (
                response isa NamedTuple &&
                haskey(response, :exception) &&
                response.exception !== nothing
            ) ||
            response isa Exception

        result = if quiet && !has_error
            ""  # In quiet mode without errors, return empty string (suppresses "nothing")
        else
            # Return full output for non-quiet mode OR when there's an error
            captured_content * result_str
        end

        return result
    finally
        unlock(EXEC_REPLLIKE_LOCK)
    end
end

SERVER = Ref{Union{Nothing,MCPServer}}(nothing)
ALL_TOOLS = Ref{Union{Nothing,Vector{MCPTool}}}(nothing)

# ============================================================================
# Tool Configuration Management
# ============================================================================

"""
    load_tools_config(config_path::String = ".mcprepl/tools.json")

Load the tools configuration from .mcprepl/tools.json.
Returns a Set of enabled tool names (as Symbols).

The configuration supports:
- Tool sets that can be enabled/disabled as groups
- Individual tool overrides that take precedence over tool set settings

If the config file doesn't exist, returns `nothing` to indicate all tools should be enabled.
"""
function load_tools_config(
    config_path::String = ".mcprepl/tools.json",
    workspace_dir::String = pwd(),
)
    full_path = joinpath(workspace_dir, config_path)

    # If config doesn't exist, enable all tools (backward compatibility)
    if !isfile(full_path)
        return nothing
    end

    try
        config = JSON.parsefile(full_path; dicttype = Dict{String,Any})
        enabled_tools = Set{Symbol}()

        # First, process tool sets
        tool_sets = get(config, "tool_sets", Dict())
        for (set_name, set_config) in tool_sets
            if get(set_config, "enabled", false)
                tools = get(set_config, "tools", String[])
                for tool_name in tools
                    push!(enabled_tools, Symbol(tool_name))
                end
            end
        end

        # Then apply individual overrides
        individual_overrides = get(config, "individual_overrides", Dict())
        for (tool_name, enabled) in individual_overrides
            # Skip comment entries
            if startswith(tool_name, "_")
                continue
            end

            tool_sym = Symbol(tool_name)
            if enabled
                push!(enabled_tools, tool_sym)
            else
                delete!(enabled_tools, tool_sym)
            end
        end

        return enabled_tools
    catch e
        @warn "Error loading tools configuration from $full_path: $e. Enabling all tools."
        return nothing
    end
end

"""
    filter_tools_by_config(enabled_tools::Union{Set{Symbol},Nothing})

Filter tools from ALL_TOOLS based on the enabled tools set.
If enabled_tools is `nothing`, returns all tools (backward compatibility).
"""
function filter_tools_by_config(enabled_tools::Union{Set{Symbol},Nothing})
    if enabled_tools === nothing
        return ALL_TOOLS[]
    end

    return filter(tool -> tool.id in enabled_tools, ALL_TOOLS[])
end

# ============================================================================
# Project Hook API for Tool Registration
# ============================================================================

"""
    register_tool!(tools::Vector{MCPTool}; name::String, description::String, 
                   input_schema::Dict, handler::Function, replace::Bool=false) -> Bool

Register a new MCP tool at runtime.

# Arguments
- `tools`: The tools vector to register into (typically from `registry()`)
- `name`: Tool name (use namespaced names like "package.tool" to avoid collisions)
- `description`: Human-readable description of what the tool does
- `input_schema`: JSON schema for tool parameters
- `handler`: Function that implements the tool logic
- `replace`: If `true`, replaces existing tool with same name. If `false`, warns and skips.

# Returns
`true` if tool was registered, `false` if skipped due to name collision

# Example
```julia
function my_project_hook(registry)
    MCPRepl.register_tool!(
        registry;
        name = "myproject.search",
        description = "Search my project's documentation",
        input_schema = Dict(
            "type" => "object",
            "properties" => Dict(
                "query" => Dict("type" => "string", "description" => "Search query")
            ),
            "required" => ["query"]
        ),
        handler = function(args)
            # Tool implementation
            return Dict("result" => "Search results for: \$(args["query"])")
        end
    )
end
```
"""
function register_tool!(
    tools::Vector{MCPTool};
    name::String,
    description::String,
    input_schema::Dict,
    handler::Function,
    replace::Bool = false,
)
    tool_id = Symbol(Base.replace(name, "." => "_"))  # Convert dots to underscores for symbol

    # Check for existing tool
    existing_idx = findfirst(t -> t.name == name, tools)

    if existing_idx !== nothing
        if replace
            @warn "Replacing existing tool: $name"
            deleteat!(tools, existing_idx)
        else
            @warn "Tool already registered: $name (use replace=true to override)"
            return false
        end
    end

    # Create and register the tool
    tool = MCPTool(tool_id, name, description, input_schema, handler)
    push!(tools, tool)
    @debug "Registered tool: $name" tool_id = tool_id
    return true
end

"""
    registry() -> Vector{MCPTool}

Get the active tool registry. Returns the tools vector that will be used by the MCP server.
Use this in project hooks to register custom tools.

# Example
```julia
# In your package's module:
function mcp_register_tools!(registry)
    MCPRepl.register_tool!(
        registry;
        name = "mypackage.tool",
        description = "My custom tool",
        input_schema = ...,
        handler = my_handler
    )
end
```
"""
function registry()
    # Return reference to ALL_TOOLS which will be used by start!
    return ALL_TOOLS[]
end

"""
    discover_and_call_project_hook(tools::Vector{MCPTool}; timeout_ms::Int=2000)

Discover and call the active project's MCP tool registration hook if it exists.
This function is called automatically during MCPRepl startup.

# Hook Contract
The hook should be defined as:
```julia
module MyPackage
function mcp_register_tools!(registry)
    # Register tools using MCPRepl.register_tool!(registry; ...)
end
end
```

# Behavior
- Reads active project from Base.active_project()
- Attempts to load project package module
- Calls `mcp_register_tools!(tools)` if defined
- All errors are caught and logged (non-fatal)
- Execution is time-limited to prevent startup hangs

# Environment Variables
- `MCPREPL_DISABLE_PROJECT_HOOK=1` - Disable hook discovery entirely
"""
function discover_and_call_project_hook(tools::Vector{MCPTool}; timeout_ms::Int = 2000)
    # Get active project
    project_path = try
        Base.active_project()
    catch
        nothing
    end

    if project_path === nothing || !isfile(project_path)
        @debug "No active project found, skipping hook discovery"
        return nothing
    end

    # Parse Project.toml to get package name
    project_name = try
        project_toml = TOML.parsefile(project_path)
        get(project_toml, "name", nothing)
    catch e
        @debug "Failed to parse Project.toml" exception = e
        nothing
    end

    if project_name === nothing
        @debug "Project has no name field (not a package), skipping hook discovery"
        return nothing
    end

    @debug "Discovering MCP hook in project package" package = project_name

    # Attempt to load the package module with timeout
    task = @async begin
        try
            # Try to require the package - it returns the loaded module directly
            pkg_sym = Symbol(project_name)
            pkg_mod = Base.require(Main, pkg_sym)

            # Check if hook exists
            if !isdefined(pkg_mod, :mcp_register_tools!)
                @info "No MCP hook found in $project_name; continuing."
                return nothing
            end

            hook_fn = getfield(pkg_mod, :mcp_register_tools!)

            # Call the hook
            @info "Calling MCP hook: $project_name.mcp_register_tools!"
            Base.invokelatest(hook_fn, tools)
            @info "✅ Project tools registered from $project_name"

        catch e
            @warn "Project MCP hook failed (non-fatal)" package = project_name exception =
                (e, catch_backtrace())
            # Suppress the error - it's non-fatal
            return nothing
        end
    end

    # Wait with timeout
    timer = Timer(timeout_ms / 1000.0)
    result = try
        timedwait(() -> istaskdone(task) || !isopen(timer), timeout_ms / 1000.0; pollint = 0.1)
    finally
        close(timer)
    end

    if result == :timed_out
        @warn "Project hook timed out after $(timeout_ms)ms" package = project_name
    else
        # Wait for task to fully complete to ensure tools are registered
        try
            wait(task)
        catch e
            @debug "Project hook task error (non-fatal)" exception = e
        end
    end

    return nothing
end


"""
    start!(; port=nothing, verbose=true, security_mode=nothing, julia_session_name="", workspace_dir=pwd())

Start the MCP REPL server.

# Arguments
- `port::Union{Int,Nothing}=nothing`: Server port. Use `0` for dynamic port assignment (finds first available port in 40000-49999). If `nothing`, uses port from configuration.
- `verbose::Bool=true`: Show startup messages
- `security_mode::Union{Symbol,Nothing}=nothing`: Override security mode (:strict, :relaxed, or :lax)
- `julia_session_name::String=""`: Name for this Julia session
- `workspace_dir::String=pwd()`: Project root directory

# Dynamic Port Assignment
Set `port=0` (or use `"port": 0` in security.json) to automatically find and use an available port.
The server will search ports 40000-49999 for the first free port. This higher range avoids conflicts with common services.

# Examples
```julia
# Use configured port from security.json
MCPRepl.start!()

# Use specific port
MCPRepl.start!(port=4000)

# Use dynamic port assignment
MCPRepl.start!(port=0)

# Start with a custom name
MCPRepl.start!(julia_session_name="data-processor")

# Start in standalone mode (no proxy, includes dashboard)
MCPRepl.start!(register_with_proxy=false)
```

# Standalone Mode (Proxy-Compatible Mode)

When the proxy is not available or `bypass_proxy=true` in security config, MCPRepl runs in
standalone mode with full proxy-compatible functionality:

- **HTTP JSON-RPC**: Accepts MCP protocol requests at `/` or `/mcp` endpoints
- **Dashboard UI**: Serves React dashboard at `http://localhost:<port>/`
- **WebSocket Live Updates**: Real-time event streaming at `/ws`
- **All MCP Tools**: Full tool registry accessible via HTTP

This mode is ideal for:
- Single-session development without proxy overhead
- Testing and debugging MCP integrations
- Simplified deployment scenarios
- Direct HTTP client access to MCP protocol

"""
function start!(;
    port::Union{Int,Nothing} = nothing,
    verbose::Bool = true,
    security_mode::Union{Symbol,Nothing} = nothing,
    julia_session_name::String = "",
    workspace_dir::String = pwd(),
    session_uuid::Union{String,Nothing} = nothing,
    register_with_proxy::Bool = true,
)
    SERVER[] !== nothing && stop!() # Stop existing server if running

    # Check for persistent proxy server
    proxy_port = 3000  # Default proxy port

    # Temporarily suppress Info logs during startup to avoid interfering with spinner
    old_logger = global_logger()
    global_logger(ConsoleLogger(stderr, Logging.Warn))

    # Start animated spinner for startup
    spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
    spinner_idx = Ref(1)
    spinner_active = Ref(true)
    status_msg = Ref("Starting MCPRepl...")

    # Background task to animate spinner
    spinner_task = @async begin
        while spinner_active[]
            msg = status_msg[]
            # Magenta spinner, bold gray text
            print("\r\033[K\033[35m$(spinner[spinner_idx[]])\033[0m \033[1;90m$msg\033[0m")
            flush(stdout)
            spinner_idx[] = spinner_idx[] % length(spinner) + 1
            sleep(0.08)
        end
    end

    # Load or prompt for security configuration
    # Use workspace_dir (project root) not pwd() (which may be agent dir)
    @debug "Loading security config" workspace_dir = workspace_dir
    security_config = load_security_config(workspace_dir)

    if security_config === nothing
        # Stop spinner before showing error
        spinner_active[] = false
        wait(spinner_task)
        global_logger(old_logger)

        print("\r\033[K")  # Clear spinner line
        printstyled("\n⚠️  NO SECURITY CONFIGURATION FOUND\n", color = :red, bold = true)
        println()
        println("MCPRepl requires security configuration before starting.")
        println("Run MCPRepl.setup() to configure API keys and security settings.")
        println()
        error("Security configuration required. Run MCPRepl.setup() first.")
    else
        @debug "Security config loaded successfully" port = security_config.port mode =
            security_config.mode
    end

    # Check if proxy should be bypassed (from security config or ENV override)
    bypass_proxy =
        security_config.bypass_proxy || get(ENV, "MCPREPL_BYPASS_PROXY", "false") == "true"
    proxy_running = bypass_proxy ? false : Proxy.is_server_running(proxy_port)

    # Start proxy if needed
    if !proxy_running && !bypass_proxy
        # Start proxy server in background (using our shared status)
        status_msg[] = "Starting MCPRepl (starting proxy)..."
        Proxy.start_server(
            proxy_port;
            background = true,
            status_callback = (msg) -> (status_msg[] = msg),
        )
    elseif bypass_proxy
        @debug "Bypassing proxy - running in standalone mode"
    end

    # Determine port: function arg overrides config, otherwise use what load_security_config() found
    actual_port = if port !== nothing
        if port == 0
            # Port 0 means find a free port dynamically
            @info "Finding available port dynamically"
            find_free_port()
        else
            @info "Using port from function argument" port = port
            port
        end
    else
        # load_security_config already loaded the right port
        config_port = security_config.port
        if config_port == 0
            # Port 0 in config means find a free port dynamically
            @info "Finding available port dynamically (from config)"
            find_free_port()
        else
            @debug "Using port from loaded config" port = config_port mode =
                (julia_session_name != "" ? "agent:$julia_session_name" : "normal")
            config_port
        end
    end

    # Override security mode if specified
    if security_mode !== nothing
        if !(security_mode in [:strict, :relaxed, :lax])
            # Stop spinner before showing error
            spinner_active[] = false
            wait(spinner_task)
            global_logger(old_logger)

            print("\r\033[K")  # Clear spinner line
            error("Invalid security_mode. Must be :strict, :relaxed, or :lax")
        end
        security_config = SecurityConfig(
            security_mode,
            security_config.api_keys,
            security_config.allowed_ips,
            security_config.port,
            security_config.bypass_proxy,
            security_config.created_at,
        )
    end

    # Update status message
    status_msg[] = "Starting MCPRepl (security: $(security_config.mode))..."

    # Show security status if verbose
    if verbose
        printstyled("\n📡 Server Port: ", color = :cyan, bold = true)
        printstyled("$actual_port\n", color = :green, bold = true)
        println()
    end

    # Create LSP tools
    lsp_tools = create_lsp_tools()

    # Create Qdrant tools
    qdrant_tools = create_qdrant_tools()

    # Load tools configuration from workspace directory
    enabled_tools = load_tools_config(".mcprepl/tools.json", workspace_dir)

    # Collect all tools (defined in tool_definitions.jl and lsp_tool_definitions.jl)
    all_tools = [
        ping_tool,
        usage_instructions_tool,
        usage_quiz_tool,
        tool_help_tool,
        repl_tool,
        manage_repl_tool,
        vscode_command_tool,
        list_vscode_commands_tool,
        investigate_tool,
        search_methods_tool,
        macro_expand_tool,
        type_info_tool,
        profile_tool,
        list_names_tool,
        code_lowered_tool,
        code_typed_tool,
        format_tool,
        lint_tool,
        open_and_breakpoint_tool,
        start_debug_session_tool,
        add_watch_expression_tool,
        copy_debug_value_tool,
        debug_step_over_tool,
        debug_step_into_tool,
        debug_step_out_tool,
        debug_continue_tool,
        debug_stop_tool,
        pkg_add_tool,
        pkg_rm_tool,
        run_tests_tool,
        lsp_tools...,  # LSP tools from lsp_tool_definitions.jl
        qdrant_tools...,  # Qdrant vector database tools
    ]

    MCPRepl.ALL_TOOLS[] = all_tools

    # Filter tools based on configuration
    active_tools = filter_tools_by_config(enabled_tools)

    # Show tool configuration status if verbose and config exists
    if verbose && enabled_tools !== nothing
        disabled_count = length(all_tools) - length(active_tools)
        if disabled_count > 0
            printstyled("🔧 Tools: ", color = :cyan, bold = true)
            println("$(length(active_tools)) enabled, $disabled_count disabled by config")
        end
    end

    # Discover and call project hook for tool registration BEFORE starting server
    # This ensures project-registered tools are included in the server's tool list
    if get(ENV, "MCPREPL_DISABLE_PROJECT_HOOK", "") != "1"
        try
            # Call synchronously with timeout to avoid startup delays
            discover_and_call_project_hook(active_tools, timeout_ms = 2000)
        catch e
            @debug "Project hook discovery failed (non-fatal)" exception = e
        end
    end

    # Update status for server launch
    status_msg[] = "Starting MCPRepl (launching server on port $actual_port)..."
    SERVER[] = start_mcp_server(
        active_tools,
        actual_port;
        verbose = verbose,
        security_config = security_config,
        session_uuid = session_uuid,
    )

    # Register this REPL with the proxy if proxy is running and registration is enabled.
    # If we're explicitly bypassing the proxy, never attempt registration.
    if register_with_proxy && proxy_running
        # Wait for the backend HTTP server to be ready to accept connections
        # This prevents race conditions where the proxy flushes buffered requests
        # before the backend can handle them
        max_attempts = 50  # 5 seconds total (50 * 0.1s)
        server_ready = false

        for attempt = 1:max_attempts
            try
                # Try a simple TCP connection to verify the server is listening
                sock = Sockets.connect(actual_port)
                close(sock)
                server_ready = true
                @debug "Backend server ready after attempt $attempt"
                break
            catch e
                if attempt == max_attempts
                    @debug "Backend server connection failed" attempt = attempt error = e
                end
                sleep(0.1)
            end
        end

        if !server_ready
            @warn "Backend server not ready after 5 seconds, skipping proxy registration"
        else
            @debug "Proceeding with proxy registration" port = actual_port
        end

        if server_ready
            try
                # Determine REPL ID
                # Priority: MCPREPL_ID env var > julia_session_name > workspace basename
                repl_id = if haskey(ENV, "MCPREPL_ID") && !isempty(ENV["MCPREPL_ID"])
                    ENV["MCPREPL_ID"]
                elseif !isempty(julia_session_name)
                    julia_session_name  # Use julia_session_name directly without prefix
                else
                    basename(workspace_dir)
                end

                # Register with proxy
                registration = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "method" => "proxy/register",
                    "params" => Dict(
                        "uuid" => SERVER[].uuid,
                        "name" => repl_id,
                        "port" => actual_port,
                        "pid" => getpid(),
                        "metadata" => Dict(
                            "workspace" => workspace_dir,
                            "julia_session_name" => julia_session_name,
                        ),
                    ),
                )

                @debug "Proxy registration payload" registration
                response = HTTP.post(
                    "http://127.0.0.1:$proxy_port/",
                    ["Content-Type" => "application/json"],
                    JSON.json(registration);
                    readtimeout = 5,
                    status_exception = false,
                )

                if response.status == 200
                    if verbose
                        printstyled(
                            "📝 Registered with proxy as '$repl_id'\n",
                            color = :green,
                            bold = true,
                        )
                    end
                elseif response.status == 409
                    # Duplicate registration - parse error message and show to user
                    response_data = JSON.parse(String(response.body))
                    error_msg = get(
                        get(response_data, "error", Dict()),
                        "message",
                        "Session ID already in use",
                    )

                    # Stop spinner before showing error
                    spinner_active[] = false
                    wait(spinner_task)
                    global_logger(old_logger)

                    print("\r\033[K")  # Clear spinner line
                    printstyled("❌ Registration failed: ", color = :red, bold = true)
                    println(error_msg)
                    printstyled("💡 Tip: ", color = :yellow, bold = true)
                    println(
                        "Use a different julia_session_name or stop the existing session",
                    )
                    # Registration is required for proxy routing; stop the server to avoid a
                    # confusing half-started state.
                    try
                        stop!()
                    catch
                    end
                    return nothing
                else
                    # Try to parse error response for details
                    error_details = ""
                    try
                        response_data = JSON.parse(String(response.body))
                        if haskey(response_data, "error")
                            error_details = get(response_data["error"], "message", "")
                        end
                    catch
                        # If parsing fails, show raw body (truncated)
                        body_str = String(response.body)
                        error_details =
                            length(body_str) > 200 ? first(body_str, 200) * "..." : body_str
                    end

                    # Registration failures should not prevent standalone use.
                    # Treat common cases (proxy not running / wrong service on port 3000 / old proxy)
                    # as non-fatal and continue.
                    if verbose
                        printstyled(
                            "⚠️  Proxy registration skipped: ",
                            color = :yellow,
                            bold = true,
                        )
                        if !isempty(error_details)
                            println(error_details)
                        else
                            println("HTTP $(response.status)")
                        end
                    end

                    @warn "Failed to register with proxy (continuing without proxy)" status =
                        response.status error = error_details
                end

                # Only start heartbeat if registration succeeded
                if response.status == 200

                    # Start heartbeat task to keep proxy updated
                    @async begin
                        @debug "Heartbeat task started" repl_id = repl_id proxy_port =
                            proxy_port
                        # Capture metadata in closure for heartbeat
                        heartbeat_metadata = Dict(
                            "workspace" => workspace_dir,
                            "julia_session_name" => julia_session_name,
                        )
                        while SERVER[] !== nothing
                            try
                                sleep(5)  # Send heartbeat every 5 seconds
                                @debug "Heartbeat check" server_active =
                                    (SERVER[] !== nothing) proxy_running =
                                    Proxy.is_server_running(proxy_port)
                                if SERVER[] !== nothing &&
                                   Proxy.is_server_running(proxy_port)
                                    heartbeat = Dict(
                                        "jsonrpc" => "2.0",
                                        "id" => rand(1:1000000),
                                        "method" => "proxy/heartbeat",
                                        "params" => Dict(
                                            "uuid" => SERVER[].uuid,
                                            "name" => repl_id,
                                            "port" => actual_port,
                                            "pid" => getpid(),
                                            "metadata" => heartbeat_metadata,
                                        ),
                                    )
                                    @debug "Sending heartbeat" repl_id = repl_id
                                    HTTP.post(
                                        "http://127.0.0.1:$proxy_port/",
                                        ["Content-Type" => "application/json"],
                                        JSON.json(heartbeat);
                                        readtimeout = 5,
                                        connect_timeout = 2,
                                    )
                                    @debug "Heartbeat sent successfully" repl_id = repl_id
                                else
                                    @warn "Heartbeat skipped" server_active =
                                        (SERVER[] !== nothing) proxy_running =
                                        Proxy.is_server_running(proxy_port)
                                end
                            catch e
                                # Ignore heartbeat errors, they're not critical
                                @warn "Heartbeat failed" repl_id = repl_id exception = e
                            end
                        end
                        @info "Heartbeat task ended" repl_id = repl_id
                    end
                end  # if response.status == 200
            catch e
                @warn "Failed to register with proxy (continuing without proxy)" exception =
                    e
            end
        end  # if server_ready
    elseif bypass_proxy && verbose
        printstyled("\n🔌 Standalone Mode (Proxy-Compatible)\n", color = :cyan, bold = true)
        printstyled("   📊 Dashboard: ", color = :green)
        println("http://localhost:$actual_port/")
        printstyled("   🔧 MCP JSON-RPC: ", color = :green)
        println("http://localhost:$actual_port/mcp")
        printstyled("   💡 Tip: ", color = :yellow)
        println("This server includes the full dashboard UI and accepts MCP calls via HTTP")
        println()
    end  # if register_with_proxy

    # Stop the spinner and show completion
    spinner_active[] = false
    wait(spinner_task)  # Wait for spinner task to finish

    # Restore original logger
    global_logger(old_logger)

    # Green checkmark, dark blue text, yellow dragon, muted cyan port number
    print(
        "\r\033[K\033[1;32m✓\033[0m \033[38;5;24mMCP REPL server started\033[0m \033[33m🐉\033[0m \033[90m(port $actual_port)\033[0m\n",
    )
    flush(stdout)

    if isdefined(Base, :active_repl) && Base.active_repl !== nothing
        try
            set_prefix!(Base.active_repl)
            # Refresh the prompt to show the new prefix
            if isdefined(Base.active_repl, :mistate) && Base.active_repl.mistate !== nothing
                REPL.LineEdit.refresh_line(Base.active_repl.mistate)
            end
        catch e
            @debug "Failed to set REPL prefix" exception = e
        end
    else
        atreplinit(set_prefix!)
    end
    nothing
end

function set_prefix!(repl)
    try
        mode = get_mainmode(repl)
        if mode !== nothing
            mode.prompt = REPL.contextual_prompt(repl, "✻ julia> ")
        end
    catch e
        @debug "Failed to set REPL prefix" exception = e
    end
end
function unset_prefix!(repl)
    try
        mode = get_mainmode(repl)
        if mode !== nothing
            mode.prompt = REPL.contextual_prompt(repl, REPL.JULIA_PROMPT)
        end
    catch e
        @debug "Failed to unset REPL prefix" exception = e
    end
end
function get_mainmode(repl)
    try
        if !isdefined(repl, :interface) || repl.interface === nothing
            return nothing
        end
        modes = filter(repl.interface.modes) do mode
            mode isa REPL.Prompt &&
                mode.prompt isa Function &&
                contains(mode.prompt(), "julia>")
        end
        return isempty(modes) ? nothing : only(modes)
    catch e
        @debug "Failed to get main REPL mode" exception = e
        return nothing
    end
end

function stop!()
    if SERVER[] !== nothing
        println("Stop existing server...")
        stop_mcp_server(SERVER[])
        SERVER[] = nothing
        if isdefined(Base, :active_repl) && Base.active_repl !== nothing
            try
                unset_prefix!(Base.active_repl) # Reset the prompt prefix
            catch e
                @debug "Failed to reset REPL prefix" exception = e
            end
        end
    else
        println("No server running to stop.")
    end
end

"""
    test_server(port::Int=3000; max_attempts::Int=3, delay::Float64=0.5)

Test if the MCP server is running and responding to REPL requests.

Attempts to connect to the server on the specified port and send a simple
exec_repl command. Returns `true` if successful, `false` otherwise.

# Arguments
- `port::Int`: The port number the MCP server is running on (default: 3000)
- `max_attempts::Int`: Maximum number of connection attempts (default: 3)
- `delay::Float64`: Delay in seconds between attempts (default: 0.5)

# Example
```julia
if MCPRepl.test_server(3000)
    println("✓ MCP Server is responding")
else
    println("✗ MCP Server is not responding")
end
```
"""
function test_server(
    port::Int = 3000;
    host = "127.0.0.1",
    max_attempts::Int = 3,
    delay::Float64 = 0.5,
)
    for attempt = 1:max_attempts
        try
            # Use HTTP.jl for a clean, proper request
            body = """{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"exec_repl","arguments":{"expression":"println(\\\"🎉 MCP Server ready!\\\")","silent":true}}}"""

            # Build headers with security if configured
            headers = Dict{String,String}("Content-Type" => "application/json")

            # Prefer explicit env var when present
            env_key = get(ENV, "JULIA_MCP_API_KEY", "")

            # Load workspace security config (if available)
            security_config = try
                load_security_config()
            catch
                nothing
            end

            auth_key = nothing

            if !isempty(env_key)
                auth_key = env_key
            elseif security_config !== nothing && security_config.mode != :lax
                # Use the first configured key, if any
                if !isempty(security_config.api_keys)
                    auth_key = first(security_config.api_keys)
                end
            end

            if auth_key !== nothing
                headers["Authorization"] = "Bearer $(auth_key)"
            end

            response = HTTP.post(
                "http://$host:$port/",
                collect(headers),
                body;
                readtimeout = 5,
                connect_timeout = 2,
            )

            # Check if we got a successful response
            if response.status == 200
                REPL.prepare_next(Base.active_repl)
                return true
            end
        catch e
            if attempt < max_attempts
                sleep(delay)
            end
        end
    end

    println("✗ MCP Server on port $port is not responding after $max_attempts attempts")
    return false
end

# ============================================================================
# Public Security Management Functions
# ============================================================================

"""
    security_status()

Display current security configuration.
"""
function security_status()
    config = load_security_config()
    if config === nothing
        printstyled("\n⚠️  No security configuration found\n", color = :yellow, bold = true)
        println("Run MCPRepl.setup_security() to configure")
        println()
        return
    end
    show_security_status(config)
end

"""
    setup_security(; force::Bool=false)

Launch the security setup wizard.
"""
function setup_security(; force::Bool = false, gentle::Bool = false)
    return security_setup_wizard(pwd(); force = force, gentle = gentle)
end

"""
    generate_key()

Generate and add a new API key to the current configuration.
"""
function generate_key()
    return add_api_key!(pwd())
end

"""
    revoke_key(key::String)

Revoke (remove) an API key from the configuration.
"""
function revoke_key(key::String)
    return remove_api_key!(key, pwd())
end

"""
    allow_ip(ip::String)

Add an IP address to the allowlist.
"""
function allow_ip(ip::String)
    return add_allowed_ip!(ip, pwd())
end

"""
    deny_ip(ip::String)

Remove an IP address from the allowlist.
"""
function deny_ip(ip::String)
    return remove_allowed_ip!(ip, pwd())
end

"""
    set_security_mode(mode::Symbol)

Change the security mode (:strict, :relaxed, or :lax).
"""
function set_security_mode(mode::Symbol)
    return change_security_mode!(mode, pwd())
end

"""
    call_tool(tool_id::Union{Symbol,String}, args::Dict)

Call an MCP tool directly from the REPL without hanging.

This helper function handles the two-parameter signature that most tools expect
(args and stream_channel), making it easier to call tools programmatically.

**Symbol-first API**: Pass symbols (e.g., `:exec_repl`) for type safety.
String names are still supported for backward compatibility.

# Examples
```julia
# Symbol-based (recommended)
MCPRepl.call_tool(:exec_repl, Dict("expression" => "2 + 2"))
MCPRepl.call_tool(:investigate_environment, Dict())
MCPRepl.call_tool(:search_methods, Dict("query" => "println"))

# String-based (deprecated, for compatibility)
MCPRepl.call_tool("exec_repl", Dict("expression" => "2 + 2"))
```

# Available Tools
Call `list_tools()` to see all available tools and their descriptions.
"""
function call_tool(tool_id::Symbol, args::Dict)
    if SERVER[] === nothing
        error("MCP server is not running. Start it with MCPRepl.start!()")
    end

    server = SERVER[]
    if !haskey(server.tools, tool_id)
        error("Tool :$tool_id not found. Call list_tools() to see available tools.")
    end

    tool = server.tools[tool_id]

    # Execute tool handler synchronously when called from REPL
    # This avoids deadlock when tools call execute_repllike
    try
        # Try calling with just args first (most common case)
        # If that fails with MethodError, try with streaming channel parameter
        result = try
            tool.handler(args)
        catch e
            if e isa MethodError && hasmethod(tool.handler, Tuple{typeof(args),typeof(nothing)})
                # Handler supports streaming, call with both parameters
                tool.handler(args, nothing)
            else
                rethrow(e)
            end
        end
        return result
    catch e
        rethrow(e)
    end
end

# String-based overload for backward compatibility (deprecated)
function call_tool(tool_name::String, args::Dict)
    @warn "String-based tool names are deprecated. Use :$(Symbol(tool_name)) instead." maxlog =
        1
    tool_id = Symbol(tool_name)
    return call_tool(tool_id, args)
end

function call_tool(tool_id::Symbol, args::Pair{Symbol,String}...)
    return call_tool(tool_id, Dict([String(k) => v for (k, v) in args]))
end

"""
    list_tools()

List all available MCP tools with their names and descriptions.

Returns a dictionary mapping tool names to their descriptions.
"""
function list_tools()
    if SERVER[] === nothing
        error("MCP server is not running. Start it with MCPRepl.start!()")
    end

    server = SERVER[]
    tools_info = Dict{Symbol,String}()

    for (id, tool) in server.tools
        tools_info[id] = tool.description
    end

    # Print formatted output
    println("\n📚 Available MCP Tools")
    println("="^70)
    println()

    for (name, desc) in sort(collect(tools_info))
        printstyled("  • ", name, "\n", color = :cyan, bold = true)
        # Print first line of description
        first_line = split(desc, "\n")[1]
        println("    ", first_line)
        println()
    end

    return tools_info
end

"""
    tool_help(tool_id::Symbol)
Get detailed help/documentation for a specific MCP tool.
"""
function tool_help(tool_id::Symbol; extended::Bool = false)
    if SERVER[] === nothing
        error("MCP server is not running. Start it with MCPRepl.start!()")
    end

    server = SERVER[]
    if !haskey(server.tools, tool_id)
        error("Tool :$tool_id not found. Call list_tools() to see available tools.")
    end

    tool = server.tools[tool_id]

    println("\n📖 Help for MCP Tool :$tool_id")
    println("="^70)
    println()
    println(tool.description)
    println()

    # Try to load extended documentation if requested
    if extended
        extended_help_path =
            joinpath(dirname(dirname(@__FILE__)), "extended-help", "$(string(tool_id)).md")

        if isfile(extended_help_path)
            println("\n" * "="^70)
            println("Extended Documentation")
            println("="^70)
            println()
            println(read(extended_help_path, String))
        else
            println("(No extended documentation available for this tool)")
        end
    end

    return tool
end

function restart()
    call_tool(:manage_repl, Dict("command" => "restart"))
end
function shutdown()
    call_tool(:manage_repl, Dict("command" => "shutdown"))
end

"""
    start_proxy(port::Int=3000; background::Bool=false)

Start the MCP proxy server. Wrapper for Proxy.start_server().
"""
function start_proxy(port::Int = 3000; background::Bool = false)
    return Proxy.start_server(port; background = background)
end

"""
    stop_proxy(port::Int=3000)

Stop the proxy server on the specified port. Wrapper for Proxy.stop_server().
"""
function stop_proxy(port::Int = 3000)
    return Proxy.stop_server(port)
end

end #module
