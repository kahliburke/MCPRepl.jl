using HTTP
using JSON
using Logging
using UUIDs

# Import Session module
include("session.jl")
using .Session

# ============================================================================
# Multi-Session Support (In-Memory)
# ============================================================================

# Global session registry for standalone mode
const STANDALONE_SESSIONS = Dict{String,MCPSession}()
const STANDALONE_SESSIONS_LOCK = ReentrantLock()

"""
    get_or_create_session(session_id::Union{String,Nothing}, is_initialize::Bool) -> (MCPSession, Bool)

Get existing session by ID or create a new one for initialize requests.
Returns (session, is_new) tuple.
"""
function get_or_create_session(session_id::Union{String,Nothing}, is_initialize::Bool)
    lock(STANDALONE_SESSIONS_LOCK) do
        if is_initialize
            # Always create a new session for initialize requests
            session = MCPSession()
            STANDALONE_SESSIONS[session.id] = session
            @info "Created new MCP session" session_id = session.id
            return (session, true)
        elseif session_id !== nothing && haskey(STANDALONE_SESSIONS, session_id)
            # Return existing session
            return (STANDALONE_SESSIONS[session_id], false)
        else
            # No session found - this will be handled by the caller
            return (nothing, false)
        end
    end
end

"""
    extract_session_id(req::HTTP.Request) -> Union{String,Nothing}

Extract Mcp-Session-Id header from request.
"""
function extract_mcp_session_id(req)
    for (name, value) in req.headers
        if lowercase(name) == "mcp-session-id"
            return String(value)
        end
    end
    return nothing
end

# Import Prompts module
include("prompts.jl")
using .Prompts

# Import Dashboard for standalone mode
import ..Dashboard

# Import types and functions from parent module
import ..MCPRepl:
    SecurityConfig, extract_api_key, validate_api_key, get_client_ip, validate_ip

# Server with tool registry and session management
mutable struct MCPServer
    uuid::String                          # Unique identifier for this session (persists across reconnections)
    port::Int
    server::HTTP.Server
    tools::Dict{Symbol,MCPTool}           # Symbol-keyed registry
    name_to_id::Dict{String,Symbol}       # String→Symbol lookup for JSON-RPC
    session::Union{MCPSession,Nothing}    # MCP session (one per server)
end

# Create request handler with access to tools and session
function create_handler(
    tools::Dict{Symbol,MCPTool},
    name_to_id::Dict{String,Symbol},
    port::Int,
    security_config::Union{SecurityConfig,Nothing} = nothing,
    session::Union{MCPSession,Nothing} = nothing,
)
    return function handle_request(req::HTTP.Request)
        # Security check - apply to ALL endpoints including vscode-response
        nonce_validated = false  # Track if nonce auth succeeded

        if security_config !== nothing
            # Special handling for vscode-response endpoint with nonce auth
            if req.target == "/vscode-response" && req.method == "POST"
                # Extract the nonce (Bearer token) from Authorization header
                nonce = extract_api_key(req)

                # Parse request body to get request_id
                body = String(req.body)
                request_id = nothing
                try
                    response_data = JSON.parse(body; dicttype = Dict{String,Any})
                    request_id = get(response_data, "request_id", nothing)
                catch e
                    # Will fail validation below if can't parse
                end

                # Validate and consume nonce
                if nonce !== nothing && request_id !== nothing
                    if MCPRepl.validate_and_consume_nonce(string(request_id), String(nonce))
                        # Nonce is valid and consumed
                        # Skip all other security checks - nonce auth is sufficient
                        nonce_validated = true
                    else
                        return HTTP.Response(
                            401,
                            ["Content-Type" => "application/json"],
                            JSON.json(
                                Dict("error" => "Unauthorized: Invalid or expired nonce"),
                            ),
                        )
                    end
                elseif security_config.mode != :lax
                    # No valid nonce, fall back to API key validation for vscode-response
                    if nonce === nothing
                        return HTTP.Response(
                            401,
                            ["Content-Type" => "application/json"],
                            JSON.json(
                                Dict(
                                    "error" => "Unauthorized: Missing nonce or API key in Authorization header",
                                ),
                            ),
                        )
                    end

                    if !validate_api_key(String(nonce), security_config)
                        return HTTP.Response(
                            401,
                            ["Content-Type" => "application/json"],
                            JSON.json(Dict("error" => "Unauthorized: Invalid API key")),
                        )
                    end

                    # If using API key (not nonce), still need to validate IP
                    client_ip = get_client_ip(req)
                    if !validate_ip(client_ip, security_config)
                        return HTTP.Response(
                            403,
                            ["Content-Type" => "application/json"],
                            JSON.json(
                                Dict(
                                    "error" => "Forbidden: IP address $client_ip not allowed",
                                ),
                            ),
                        )
                    end
                end
            elseif !nonce_validated
                # For non-vscode-response endpoints, use standard API key validation
                # Extract and validate API key
                api_key = extract_api_key(req)
                if api_key === nothing && security_config.mode != :lax
                    return HTTP.Response(
                        401,
                        ["Content-Type" => "application/json"],
                        JSON.json(
                            Dict(
                                "error" => "Unauthorized: Missing API key in Authorization header",
                            ),
                        ),
                    )
                end

                if !validate_api_key(String(something(api_key, "")), security_config)
                    return HTTP.Response(
                        403,
                        ["Content-Type" => "application/json"],
                        JSON.json(Dict("error" => "Forbidden: Invalid API key")),
                    )
                end

                # Validate IP address
                client_ip = get_client_ip(req)
                if !validate_ip(client_ip, security_config)
                    return HTTP.Response(
                        403,
                        ["Content-Type" => "application/json"],
                        JSON.json(
                            Dict("error" => "Forbidden: IP address $client_ip not allowed"),
                        ),
                    )
                end
            end
        end

        # Parse JSON-RPC request
        body = String(req.body)

        try
            # Handle VS Code response endpoint (for bidirectional communication)
            if req.target == "/vscode-response" && req.method == "POST"
                try
                    response_data = JSON.parse(body; dicttype = Dict{String,Any})
                    request_id = get(response_data, "request_id", nothing)

                    if request_id === nothing
                        return HTTP.Response(
                            400,
                            ["Content-Type" => "application/json"],
                            JSON.json(Dict("error" => "Missing request_id")),
                        )
                    end

                    result = get(response_data, "result", nothing)
                    error = get(response_data, "error", nothing)

                    # Store the response using MCPRepl function
                    MCPRepl.store_vscode_response(string(request_id), result, error)

                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(Dict("status" => "ok")),
                    )
                catch e
                    return HTTP.Response(
                        500,
                        ["Content-Type" => "application/json"],
                        JSON.json(Dict("error" => "Failed to process response: $e")),
                    )
                end
            end

            # Handle AGENTS.md well-known documentation (before JSON parsing)
            # Serve AGENTS.md from project root if it exists
            if req.target == "/.well-known/agents.md" ||
               req.target == "/agents.md" ||
               req.target == "/.well-known/AGENTS.md" ||
               req.target == "/AGENTS.md"
                agents_path = joinpath(pwd(), "AGENTS.md")
                if isfile(agents_path)
                    agents_content = read(agents_path, String)
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "text/markdown; charset=utf-8"],
                        agents_content,
                    )
                else
                    return HTTP.Response(
                        404,
                        ["Content-Type" => "text/plain"],
                        "AGENTS.md not found in project root",
                    )
                end
            end

            # Handle MCP JSON-RPC endpoint (for standalone/proxy-compatible mode)
            if req.target == "/mcp" && req.method == "POST"
                # Route MCP JSON-RPC calls to the standard handler
                # This allows HTTP-based MCP clients to connect directly without a proxy
                # Fall through to the JSON-RPC handling below
            end

            # Handle WebSocket connections for live dashboard updates
            if req.target == "/ws"
                return HTTP.WebSockets.upgrade(req) do ws
                    # Add client to broadcast list
                    lock(Dashboard.WS_CLIENTS_LOCK) do
                        push!(Dashboard.WS_CLIENTS, ws)
                    end

                    try
                        # Keep connection alive and handle incoming messages
                        while !eof(ws)
                            msg = HTTP.WebSockets.receive(ws)
                            # Echo back for ping/pong
                            HTTP.WebSockets.send(ws, msg)
                        end
                    catch e
                        @debug "WebSocket connection closed" exception = e
                    finally
                        # Remove client from broadcast list
                        lock(Dashboard.WS_CLIENTS_LOCK) do
                            delete!(Dashboard.WS_CLIENTS, ws)
                        end
                    end
                end
            end

            # Handle OAuth well-known metadata requests first (before JSON parsing)
            # Only advertise OAuth if security is configured (not in lax mode)
            if req.target == "/.well-known/oauth-authorization-server"
                if security_config !== nothing && security_config.mode != :lax
                    oauth_metadata = Dict(
                        "issuer" => "http://localhost:$port",
                        "authorization_endpoint" => "http://localhost:$port/oauth/authorize",
                        "token_endpoint" => "http://localhost:$port/oauth/token",
                        "registration_endpoint" => "http://localhost:$port/oauth/register",
                        "grant_types_supported" =>
                            ["authorization_code", "client_credentials"],
                        "response_types_supported" => ["code"],
                        "scopes_supported" => ["read", "write"],
                        "client_registration_types_supported" => ["dynamic"],
                        "code_challenge_methods_supported" => ["S256"],
                    )
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(oauth_metadata),
                    )
                else
                    # No OAuth in lax mode - return 404
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle dynamic client registration
            # Only support OAuth if security is configured (not in lax mode)
            if req.target == "/oauth/register" && req.method == "POST"
                if security_config !== nothing && security_config.mode != :lax
                    client_id = "claude-code-" * string(rand(UInt64), base = 16)
                    client_secret = string(rand(UInt128), base = 16)

                    registration_response = Dict(
                        "client_id" => client_id,
                        "client_secret" => client_secret,
                        "client_id_issued_at" => Int(floor(time())),
                        "grant_types" => ["authorization_code", "client_credentials"],
                        "response_types" => ["code"],
                        "redirect_uris" => [
                            "http://localhost:8080/callback",
                            "http://127.0.0.1:8080/callback",
                        ],
                        "token_endpoint_auth_method" => "client_secret_basic",
                        "scope" => "read write",
                    )
                    return HTTP.Response(
                        201,
                        ["Content-Type" => "application/json"],
                        JSON.json(registration_response),
                    )
                else
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle authorization endpoint
            if startswith(req.target, "/oauth/authorize")
                if security_config !== nothing && security_config.mode != :lax
                    # For local development, auto-approve all requests
                    uri = HTTP.URI(req.target)
                    query_params = HTTP.queryparams(uri)
                    redirect_uri = get(query_params, "redirect_uri", "")
                    state = get(query_params, "state", "")

                    auth_code = "auth_" * string(rand(UInt64), base = 16)
                    redirect_url = "$redirect_uri?code=$auth_code&state=$state"

                    return HTTP.Response(302, ["Location" => redirect_url], "")
                else
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle token endpoint
            if req.target == "/oauth/token" && req.method == "POST"
                if security_config !== nothing && security_config.mode != :lax
                    access_token = "access_" * string(rand(UInt128), base = 16)

                    token_response = Dict(
                        "access_token" => access_token,
                        "token_type" => "Bearer",
                        "expires_in" => 3600,
                        "scope" => "read write",
                    )
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(token_response),
                    )
                else
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle GET requests - return 405 per Streamable HTTP spec (we don't support SSE streaming)
            if req.method == "GET"
                return HTTP.Response(
                    405,
                    ["Content-Type" => "application/json", "Allow" => "POST"],
                    JSON.json(
                        Dict(
                            "jsonrpc" => "2.0",
                            "id" => nothing,
                            "error" => Dict(
                                "code" => -32600,
                                "message" => "Method Not Allowed - server does not support SSE streaming via GET",
                            ),
                        ),
                    ),
                )
            end

            # Handle DELETE requests - return 405 per Streamable HTTP spec
            if req.method == "DELETE"
                return HTTP.Response(
                    405,
                    ["Content-Type" => "application/json", "Allow" => "POST"],
                    JSON.json(
                        Dict(
                            "jsonrpc" => "2.0",
                            "id" => nothing,
                            "error" => Dict(
                                "code" => -32600,
                                "message" => "Method Not Allowed - session termination via DELETE not supported",
                            ),
                        ),
                    ),
                )
            end

            # Handle empty body for POST requests
            # Note: Static file endpoints (AGENTS.md, OAuth metadata) already handled above
            if isempty(body)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 0,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - empty body",
                    ),
                )
                return HTTP.Response(
                    400,
                    ["Content-Type" => "application/json"],
                    JSON.json(error_response),
                )
            end

            # Support both root "/" and "/mcp" endpoints for HTTP JSON-RPC
            # This allows MCP clients to use either endpoint
            request = JSON.parse(body; dicttype = Dict{String,Any})

            # Check if method field exists
            if !haskey(request, "method")
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", 0),
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - missing method field",
                    ),
                )
                return HTTP.Response(
                    400,
                    ["Content-Type" => "application/json"],
                    JSON.json(error_response),
                )
            end

            # Handle initialization
            if request["method"] == "initialize"
                params = get(request, "params", Dict{String,Any}())

                try
                    # Use session management if available
                    if session !== nothing
                        init_result = initialize_session!(session, params)
                    else
                        # Fallback without session management
                        init_result = Dict(
                            "protocolVersion" => "2025-11-25",
                            "capabilities" => Dict(
                                "tools" => Dict(),
                                "prompts" => Dict(),
                                "resources" => Dict(),
                                "logging" => Dict(),
                            ),
                            "serverInfo" =>
                                Dict("name" => "MCPRepl", "version" => "0.4.0"),
                        )
                    end

                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "result" => init_result,
                    )

                    # Include Mcp-Session-Id header per Streamable HTTP transport spec
                    session_id = session !== nothing ? session.id : string(UUIDs.uuid4())
                    return HTTP.Response(
                        200,
                        [
                            "Content-Type" => "application/json",
                            "Mcp-Session-Id" => session_id,
                        ],
                        JSON.json(response),
                    )
                catch e
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32603,
                            "message" => "Initialize error: $(sprint(showerror, e))",
                        ),
                    )
                    return HTTP.Response(
                        500,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end
            end

            # Handle initialized notification
            if request["method"] == "notifications/initialized"
                # This is a notification - return 202 Accepted with no body per Streamable HTTP spec
                # Mark session as fully initialized if it's in INITIALIZED state
                if session !== nothing && session.state == Session.INITIALIZED
                    @info "Session initialized" session_id = session.id
                end
                return HTTP.Response(202, [], "")
            end

            # Handle logging/setLevel request
            if request["method"] == "logging/setLevel"
                params = get(request, "params", Dict())
                level = get(params, "level", nothing)

                # Validate log level according to RFC 5424
                valid_levels = [
                    "debug",
                    "info",
                    "notice",
                    "warning",
                    "error",
                    "critical",
                    "alert",
                    "emergency",
                ]

                if level === nothing || !(level in valid_levels)
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Invalid params: level must be one of $(join(valid_levels, ", "))",
                        ),
                    )
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end

                # Map MCP log levels to Julia Logging levels
                level_map = Dict(
                    "debug" => Logging.Debug,
                    "info" => Logging.Info,
                    "notice" => Logging.Info,
                    "warning" => Logging.Warn,
                    "error" => Logging.Error,
                    "critical" => Logging.Error,
                    "alert" => Logging.Error,
                    "emergency" => Logging.Error,
                )

                julia_level = level_map[level]

                # Set the global log level
                try
                    global_logger(ConsoleLogger(stderr, julia_level))
                    @info "Log level set" level = level julia_level = julia_level

                    response =
                        Dict("jsonrpc" => "2.0", "id" => request["id"], "result" => Dict())
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(response),
                    )
                catch e
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32603,
                            "message" => "Internal error: $(string(e))",
                        ),
                    )
                    return HTTP.Response(
                        500,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end
            end

            # Handle session info request (custom extension)
            if request["method"] == "session/info"
                if session !== nothing
                    session_info = get_session_info(session)
                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "result" => session_info,
                    )
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(response),
                    )
                else
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" =>
                            Dict("code" => -32603, "message" => "No session available"),
                    )
                    return HTTP.Response(
                        500,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end
            end

            # Handle tool listing
            if request["method"] == "tools/list"
                tool_list = [
                    Dict(
                        "name" => tool.name,
                        "description" => tool.description,
                        "inputSchema" => tool.parameters,
                    ) for tool in values(tools)
                ]

                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict("tools" => tool_list),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON.json(response),
                )
            end

            # Handle resources/list request
            if request["method"] == "resources/list"
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict("resources" => []),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON.json(response),
                )
            end

            # Handle resources/templates/list request
            if request["method"] == "resources/templates/list"
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict("resourceTemplates" => []),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON.json(response),
                )
            end

            # Handle prompts/list request
            if request["method"] == "prompts/list"
                prompts = get_prompts()
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict("prompts" => prompts),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON.json(response),
                )
            end

            # Handle prompts/get request
            if request["method"] == "prompts/get"
                prompt_name = get(request["params"], "name", nothing)

                if prompt_name === nothing
                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Missing required parameter: name",
                        ),
                    )
                    return HTTP.Response(
                        400,
                        ["Content-Type" => "application/json"],
                        JSON.json(response),
                    )
                end

                prompt_content = get_prompt(String(prompt_name))

                if prompt_content === nothing
                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Prompt not found: $prompt_name",
                        ),
                    )
                    return HTTP.Response(
                        404,
                        ["Content-Type" => "application/json"],
                        JSON.json(response),
                    )
                end

                # Get prompt arguments if provided
                prompt_args = get(request["params"], "arguments", Dict())

                # Return the prompt with messages
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict(
                        "description" => "Learn how to use MCPRepl effectively",
                        "messages" => [
                            Dict(
                                "role" => "user",
                                "content" => Dict(
                                    "type" => "text",
                                    "text" => prompt_content,
                                ),
                            ),
                        ],
                    ),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON.json(response),
                )
            end

            # Handle tool calls
            if request["method"] == "tools/call"
                tool_name_str = request["params"]["name"]
                tool_id = get(name_to_id, tool_name_str, nothing)

                if tool_id !== nothing && haskey(tools, tool_id)
                    tool = tools[tool_id]
                    args = get(request["params"], "arguments", Dict())

                    # Validate parameters - collect all errors first
                    error_messages = String[]

                    # Check for unknown parameters first
                    if haskey(tool.parameters, "properties")
                        allowed_params = keys(tool.parameters["properties"])
                        unknown_params = String[]
                        for param in keys(args)
                            if !(param in allowed_params)
                                push!(unknown_params, param)
                            end
                        end

                        if !isempty(unknown_params)
                            allowed_list = join(sort(collect(allowed_params)), ", ")
                            push!(
                                error_messages,
                                "Unknown parameter(s): $(join(unknown_params, ", ")). Valid parameters are: $allowed_list",
                            )
                        end
                    end

                    # Check for missing required parameters
                    if haskey(tool.parameters, "required")
                        required_params = tool.parameters["required"]
                        missing_params = String[]
                        for param in required_params
                            if !haskey(args, param)
                                push!(missing_params, param)
                            end
                        end

                        if !isempty(missing_params)
                            push!(
                                error_messages,
                                "Missing required parameter(s): $(join(missing_params, ", "))",
                            )
                        end
                    end

                    # If there are any validation errors, return them all
                    if !isempty(error_messages)
                        error_response = Dict(
                            "jsonrpc" => "2.0",
                            "id" => request["id"],
                            "error" => Dict(
                                "code" => -32602,
                                "message" => join(error_messages, ". "),
                            ),
                        )
                        return HTTP.Response(
                            400,
                            ["Content-Type" => "application/json"],
                            JSON.json(error_response),
                        )
                    end

                    # Track timing for tools (except for those that show agent> prompts)
                    excluded_tools = [
                        "ex",
                        "search_methods",
                        "macro_expand",
                        "code_lowered",
                        "code_typed",
                    ]
                    show_timing = !(tool.name in excluded_tools)

                    # Show tool start indicator (stays on same line)
                    if show_timing
                        print("🔧 ")
                        printstyled(tool.name, color = :light_blue)
                        flush(stdout)
                    end

                    start_time = time()

                    # Non-streaming mode (streaming handled in hybrid_handler)
                    # Use invokelatest to pick up Revise changes to tool handlers
                    result_text = try
                        Base.invokelatest(tool.handler, args)
                    finally
                        # Show completion with timing (updates the line or adds new line)
                        if show_timing
                            elapsed = time() - start_time
                            # Format time nicely
                            time_str = if elapsed < 1.0
                                @sprintf("%.0fms", elapsed * 1000)
                            else
                                @sprintf("%.1fs", elapsed)
                            end
                            # Use carriage return to overwrite the line if no output, or write on current line if there was output
                            print("\r\033[K🔧 ")
                            printstyled(tool.name, color = :light_blue)
                            printstyled(" ✓ ", color = :green)
                            printstyled("($time_str)\n", color = :light_black)
                            flush(stdout)
                        end
                    end

                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "result" => Dict(
                            "content" =>
                                [Dict("type" => "text", "text" => result_text)],
                        ),
                    )
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(response),
                    )
                else
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Tool not found: $tool_name_str",
                        ),
                    )
                    return HTTP.Response(
                        404,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end
            end

            # Method not found
            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", 0),
                "error" => Dict("code" => -32601, "message" => "Method not found"),
            )
            return HTTP.Response(
                404,
                ["Content-Type" => "application/json"],
                JSON.json(error_response),
            )

        catch e
            # Internal error - show in REPL and return to client
            printstyled("\nMCP Server error: $e\n", color = :red)

            # Try to get the original request ID for proper JSON-RPC error response
            request_id = 0  # Default to 0 instead of nothing to satisfy JSON-RPC schema
            try
                if !isempty(body)
                    parsed_request = JSON.parse(body; dicttype = Dict{String,Any})
                    # Only use the request ID if it's a valid JSON-RPC ID (string or number)
                    raw_id = get(parsed_request, :id, 0)
                    if raw_id isa Union{String,Number}
                        request_id = raw_id
                    end
                end
            catch
                # If we can't parse the request, use default ID
                request_id = 0
            end

            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => request_id,
                "error" => Dict("code" => -32603, "message" => "Internal error: $e"),
            )
            return HTTP.Response(
                500,
                ["Content-Type" => "application/json"],
                JSON.json(error_response),
            )
        end
    end
end


function start_mcp_server(
    tools::Vector{MCPTool},
    port::Int = 3000;
    verbose::Bool = true,
    security_config::Union{SecurityConfig,Nothing} = nothing,
    session_uuid::Union{String,Nothing} = nothing,
)
    # Use provided UUID or generate a new one (persists across reconnections)
    session_uuid = session_uuid !== nothing ? session_uuid : string(UUIDs.uuid4())

    # Build symbol-keyed registry
    tools_dict = Dict{Symbol,MCPTool}(tool.id => tool for tool in tools)
    # Build string→symbol mapping for JSON-RPC
    name_to_id = Dict{String,Symbol}(tool.name => tool.id for tool in tools)

    # Multi-session support: sessions are created/retrieved per Mcp-Session-Id header
    # Uses the existing Proxy.create_mcp_session() and Proxy.get_mcp_session() infrastructure

    # Create a hybrid handler that supports both regular and streaming responses
    function hybrid_handler(http::HTTP.Stream)
        # Use Base.invokelatest to allow Revise to hot-reload the handler logic
        return Base.invokelatest(
            _hybrid_handler_impl,
            http,
            tools_dict,
            name_to_id,
            security_config,
            port,
        )
    end

    function _hybrid_handler_impl(
        http::HTTP.Stream,
        tools_dict,
        name_to_id,
        security_config,
        port,
    )
        req = http.message

        # CRITICAL: Read the request body FIRST before any response
        # HTTP.jl requires reading the full request before writing responses
        body = String(read(http))

        # Security check - apply to ALL endpoints including vscode-response
        nonce_validated = false  # Track if nonce auth succeeded

        if security_config !== nothing
            # Special handling for vscode-response endpoint with nonce auth
            if req.target == "/vscode-response" && req.method == "POST"
                # Extract the nonce (Bearer token) from Authorization header
                nonce = extract_api_key(req)

                # Parse request body to get request_id
                request_id = nothing
                try
                    response_data = JSON.parse(body; dicttype = Dict{String,Any})
                    request_id = get(response_data, "request_id", nothing)
                catch e
                    # Will fail validation below if can't parse
                end

                # Validate and consume nonce
                if nonce !== nothing && request_id !== nothing
                    if MCPRepl.validate_and_consume_nonce(string(request_id), String(nonce))
                        # Nonce is valid and consumed - skip all other security checks
                        nonce_validated = true
                    else
                        # Nonce validation failed
                        HTTP.setstatus(http, 401)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(
                                Dict("error" => "Unauthorized: Invalid or expired nonce"),
                            ),
                        )
                        return nothing
                    end
                elseif security_config.mode != :lax
                    # No valid nonce, fall back to API key validation for vscode-response
                    if nonce === nothing
                        HTTP.setstatus(http, 401)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(
                                Dict(
                                    "error" => "Unauthorized: Missing nonce or API key in Authorization header",
                                ),
                            ),
                        )
                        return nothing
                    end

                    if !validate_api_key(String(nonce), security_config)
                        HTTP.setstatus(http, 401)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(Dict("error" => "Unauthorized: Invalid API key")),
                        )
                        return nothing
                    end

                    # If using API key (not nonce), still need to validate IP
                    client_ip = get_client_ip(req)
                    if !validate_ip(client_ip, security_config)
                        HTTP.setstatus(http, 403)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(
                                Dict(
                                    "error" => "Forbidden: IP address $client_ip not allowed",
                                ),
                            ),
                        )
                        return nothing
                    end
                end
            elseif !nonce_validated
                # For non-vscode-response endpoints, use standard API key validation
                api_key = extract_api_key(req)
                if api_key === nothing && security_config.mode != :lax
                    HTTP.setstatus(http, 401)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict(
                                "error" => "Unauthorized: Missing API key in Authorization header",
                            ),
                        ),
                    )
                    return nothing
                end

                if !validate_api_key(String(something(api_key, "")), security_config)
                    HTTP.setstatus(http, 403)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict("error" => "Forbidden: Invalid API key")))
                    return nothing
                end

                # Validate IP address
                client_ip = get_client_ip(req)
                if !validate_ip(client_ip, security_config)
                    HTTP.setstatus(http, 403)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict("error" => "Forbidden: IP address $client_ip not allowed"),
                        ),
                    )
                    return nothing
                end
            end
        end

        try
            # Handle AGENTS.md endpoint (can have empty body for GET requests)
            if req.target == "/.well-known/agents.md" ||
               req.target == "/agents.md" ||
               req.target == "/.well-known/AGENTS.md" ||
               req.target == "/AGENTS.md"
                agents_path = joinpath(pwd(), "AGENTS.md")
                if isfile(agents_path)
                    agents_content = read(agents_path, String)
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "text/markdown; charset=utf-8")
                    HTTP.startwrite(http)
                    write(http, agents_content)
                    return nothing
                else
                    HTTP.setstatus(http, 404)
                    HTTP.setheader(http, "Content-Type" => "text/plain")
                    HTTP.startwrite(http)
                    write(http, "AGENTS.md not found in project root")
                    return nothing
                end
            end

            # Handle VS Code response endpoint FIRST (before any JSON parsing)
            if req.target == "/vscode-response" && req.method == "POST"
                try
                    response_data = JSON.parse(body; dicttype = Dict{String,Any})
                    request_id = get(response_data, "request_id", nothing)

                    if request_id === nothing
                        HTTP.setstatus(http, 400)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(http, JSON.json(Dict("error" => "Missing request_id")))
                        return nothing
                    end

                    result = get(response_data, "result", nothing)
                    error = get(response_data, "error", nothing)

                    # Store the response
                    MCPRepl.store_vscode_response(string(request_id), result, error)

                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict("status" => "ok")))
                    return nothing
                catch e
                    HTTP.setstatus(http, 500)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(Dict("error" => "Failed to process response: $e")),
                    )
                    return nothing
                end
            end

            # Handle dashboard routes for GET requests (for standalone/proxy-compatible mode)
            if req.method == "GET"
                # Normalize API paths - handle both /api/* and /dashboard/api/*
                # Strip query string for path matching
                target_path = split(req.target, '?')[1]
                api_path =
                    startswith(target_path, "/dashboard/api/") ?
                    replace(target_path, r"^/dashboard" => "") : target_path

                # Dashboard API: sessions list
                if api_path == "/api/sessions"
                    # In standalone mode, return all active MCP sessions
                    # Format matches dashboard TypeScript Session interface
                    sessions_response = Dict{String,Any}()
                    lock(STANDALONE_SESSIONS_LOCK) do
                        for (sid, sess) in STANDALONE_SESSIONS
                            # Map session state to dashboard status
                            status =
                                if sess.state in (
                                    Session.UNINITIALIZED,
                                    Session.INITIALIZED,
                                    Session.INITIALIZING,
                                )
                                    "ready"
                                elseif sess.state == Session.CLOSED
                                    "stopped"
                                else
                                    "ready"  # Default to ready
                                end

                            session_info = Dict(
                                "uuid" => sess.id,
                                "name" => basename(pwd()),  # Use current directory name
                                "port" => port,
                                "pid" => getpid(),
                                "status" => status,
                                "created_at" => Dates.format(
                                    sess.created_at,
                                    "yyyy-mm-dd HH:MM:SS",
                                ),
                                "last_heartbeat" => Dates.format(
                                    sess.last_activity,
                                    "yyyy-mm-dd HH:MM:SS",
                                ),
                                "last_event" => Dates.format(
                                    sess.last_activity,
                                    "yyyy-mm-dd HH:MM:SS",
                                ),
                            )
                            sessions_response[sess.id] = session_info
                        end
                    end

                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(sessions_response))
                    return nothing
                end

                # Dashboard API: proxy info
                if api_path == "/api/proxy-info"
                    # In standalone mode, return info about this server
                    num_sessions = lock(STANDALONE_SESSIONS_LOCK) do
                        length(STANDALONE_SESSIONS)
                    end
                    proxy_info = Dict(
                        "mode" => "standalone",
                        "version" => "0.8.0",
                        "port" => port,
                        "has_database" => false,
                        "active_sessions" => num_sessions,
                    )
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(proxy_info))
                    return nothing
                end

                # Dashboard API: tools list
                if api_path == "/api/tools"
                    # Return the list of available MCP tools in dashboard format
                    # In standalone mode, all tools are "proxy_tools" (we are the server)
                    tools_list = map(collect(values(tools_dict))) do tool
                        Dict(
                            "name" => tool.name,
                            "description" => tool.description,
                            "inputSchema" => tool.parameters,
                        )
                    end

                    # Dashboard expects proxy_tools and session_tools structure
                    response = Dict(
                        "proxy_tools" => tools_list,
                        "session_tools" => Dict{String,Vector}(),  # Empty in standalone mode
                    )

                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(response))
                    return nothing
                end

                # Dashboard API: events list
                if startswith(api_path, "/api/events")
                    # Handle SSE streaming endpoint
                    if contains(api_path, "/stream")
                        # Generate unique channel ID
                        channel_id = "sse-$(time_ns())"

                        # Create SSE channel for this connection
                        channel = Dashboard.create_sse_channel(channel_id)

                        # Set up SSE response headers
                        HTTP.setstatus(http, 200)
                        HTTP.setheader(http, "Content-Type" => "text/event-stream")
                        HTTP.setheader(http, "Cache-Control" => "no-cache")
                        HTTP.setheader(http, "Connection" => "keep-alive")
                        HTTP.setheader(http, "Access-Control-Allow-Origin" => "*")
                        HTTP.startwrite(http)

                        # Send initial event to prime the connection
                        write(http, "id: $(channel_id)\n")
                        write(http, "data: {\"status\": \"connected\"}\n\n")
                        flush(http)

                        try
                            heartbeat_interval = 30.0  # Send heartbeat every 30 seconds
                            last_heartbeat = time()

                            # Keep connection alive and send events as they arrive
                            while isopen(http) && isopen(channel)
                                # Check if there's a pending event (non-blocking)
                                if isready(channel)
                                    event = try
                                        take!(channel)
                                    catch e
                                        if isa(e, InvalidStateException)
                                            break  # Channel closed
                                        end
                                        nothing
                                    end

                                    if event !== nothing
                                        # Send event in SSE format
                                        write(http, "id: $(time_ns())\n")
                                        event_data = JSON.json(
                                            Dict(
                                                "id" => event.id,
                                                "type" => string(event.event_type),
                                                "timestamp" => Dates.format(
                                                    event.timestamp,
                                                    "yyyy-mm-dd HH:MM:SS.sss",
                                                ),
                                                "data" => event.data,
                                                "duration_ms" => event.duration_ms,
                                            ),
                                        )
                                        write(http, "data: $(event_data)\n\n")
                                        flush(http)
                                    end
                                end

                                # Send heartbeat comment to keep connection alive
                                if time() - last_heartbeat > heartbeat_interval
                                    write(http, ": heartbeat\n\n")
                                    flush(http)
                                    last_heartbeat = time()
                                end

                                # Small sleep to prevent busy waiting
                                sleep(0.1)
                            end
                        catch e
                            if !isa(e, Base.IOError)
                                @warn "SSE channel error" exception = e
                            end
                        finally
                            # Clean up channel
                            Dashboard.remove_sse_channel(channel_id)
                        end

                        return nothing
                    end

                    # Parse limit parameter if present
                    limit = 100
                    if occursin("?", req.target)
                        query = split(req.target, "?")[2]
                        for param in split(query, "&")
                            if startswith(param, "limit=")
                                limit = parse(Int, split(param, "=")[2])
                            end
                        end
                    end

                    events = Dashboard.get_events(limit = limit)
                    events_json = map(events) do e
                        Dict(
                            "id" => e.id,
                            "type" => string(e.event_type),
                            "timestamp" =>
                                Dates.format(e.timestamp, "yyyy-mm-dd HH:MM:SS.sss"),
                            "data" => e.data,
                            "duration_ms" => e.duration_ms,
                        )
                    end
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(events_json))
                    return nothing
                end

                # Dashboard API: logs (not available in standalone mode)
                if startswith(api_path, "/api/logs")
                    # In standalone mode, we don't persist logs to files
                    # Return a helpful message instead of an error
                    response = Dict(
                        "content" => "Log file viewing is not available in standalone mode.\n\nIn standalone mode, the Julia REPL output is displayed directly in your terminal.\n\nTo view logs:\n1. Check your terminal where Julia is running\n2. Or use the proxy mode which logs all activity to files",
                        "file" => "Not available (standalone mode)",
                        "total_lines" => 0,
                        "files" => [],
                    )
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(response))
                    return nothing
                end

                # Dashboard UI static files (must be last to avoid catching API routes)
                # Serve root, /dashboard/*, and static assets like /vite.svg, /*.js, /*.css
                if req.target == "/" ||
                   startswith(req.target, "/dashboard") ||
                   endswith(req.target, ".svg") ||
                   endswith(req.target, ".js") ||
                   endswith(req.target, ".css") ||
                   endswith(req.target, ".png") ||
                   endswith(req.target, ".jpg") ||
                   endswith(req.target, ".ico")

                    # Check if Vite dev server is running on port 3001
                    vite_running = try
                        sock = connect("localhost", 3001)
                        close(sock)
                        true
                    catch
                        false
                    end

                    if vite_running
                        # Proxy to Vite dev server for hot-reloading during development
                        try
                            vite_url = "http://localhost:3001$(req.target)"
                            vite_response = HTTP.get(vite_url)

                            HTTP.setstatus(http, vite_response.status)
                            for (k, v) in vite_response.headers
                                HTTP.setheader(http, k => v)
                            end
                            HTTP.startwrite(http)
                            write(http, vite_response.body)
                            return nothing
                        catch e
                            @warn "Failed to proxy to Vite dev server, falling back to static files" exception =
                                e
                        end
                    end

                    # Fallback to static built files
                    filepath =
                        req.target == "/" ? "index.html" :
                        replace(req.target, r"^/dashboard/?" => "")
                    response = Dashboard.serve_static_file(filepath)
                    HTTP.setstatus(http, response.status)
                    for (k, v) in response.headers
                        HTTP.setheader(http, k => v)
                    end
                    HTTP.startwrite(http)
                    write(http, response.body)
                    return nothing
                end
            end

            # Handle GET requests on MCP endpoint - return 405 per Streamable HTTP spec
            if req.method == "GET" && (
                req.target == "/mcp" ||
                req.target == "/" ||
                startswith(req.target, "/mcp?")
            )
                HTTP.setstatus(http, 405)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.setheader(http, "Allow" => "POST")
                HTTP.startwrite(http)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => nothing,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Method Not Allowed - server does not support SSE streaming via GET",
                    ),
                )
                write(http, JSON.json(error_response))
                return nothing
            end

            # Handle DELETE requests - return 405 per Streamable HTTP spec
            if req.method == "DELETE"
                HTTP.setstatus(http, 405)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.setheader(http, "Allow" => "POST")
                HTTP.startwrite(http)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => nothing,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Method Not Allowed - session termination via DELETE not supported",
                    ),
                )
                write(http, JSON.json(error_response))
                return nothing
            end

            if isempty(body)
                HTTP.setstatus(http, 400)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 0,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - empty body",
                    ),
                )
                write(http, JSON.json(error_response))
                return nothing
            end

            # Session lookup/creation for multi-session support
            session_id = extract_mcp_session_id(req)

            # Parse request to check if it's an initialize
            parsed_request = try
                JSON.parse(body; dicttype = Dict{String,Any})
            catch
                nothing
            end

            is_initialize =
                parsed_request !== nothing &&
                get(parsed_request, "method", "") == "initialize"

            # Get or create session
            session, is_new_session = get_or_create_session(session_id, is_initialize)

            # For non-initialize requests without a valid session, return error
            if !is_initialize && session === nothing
                HTTP.setstatus(http, 400)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" =>
                        parsed_request !== nothing ? get(parsed_request, "id", 0) : 0,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - missing or invalid Mcp-Session-Id header. Send initialize request first.",
                    ),
                )
                write(http, JSON.json(error_response))
                return nothing
            end

            # All requests go to create_handler
            # create_handler handles:
            # - Security checks (already done above, but also in create_handler for direct calls)
            # - OAuth endpoints
            # - VS Code response endpoint
            # - initialize, tools/list, and tools/call
            req_with_body = HTTP.Request(req.method, req.target, req.headers, body)
            handler = create_handler(tools_dict, name_to_id, port, security_config, session)
            response = handler(req_with_body)

            HTTP.setstatus(http, response.status)
            for (name, value) in response.headers
                HTTP.setheader(http, name => value)
            end
            HTTP.startwrite(http)
            write(http, response.body)
            return nothing

        catch e
            HTTP.setstatus(http, 500)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)

            request_id = try
                parsed = JSON.parse(body; dicttype = Dict{String,Any})
                get(parsed, :id, 0)
            catch
                0
            end

            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => request_id,
                "error" => Dict("code" => -32603, "message" => "Internal error: $e"),
            )
            write(http, JSON.json(error_response))
            return nothing
        end
    end

    # Start server with stream=true to enable streaming responses
    # Temporarily suppress HTTP.jl's "Listening on" info message
    old_logger = global_logger()
    global_logger(ConsoleLogger(stderr, Logging.Warn))

    # Auto-start Vite dev server in development mode for hot-reloading
    try
        dashboard_src = abspath(joinpath(@__DIR__, "..", "dashboard-ui", "src"))
        if isdir(dashboard_src)
            # Check if Vite is already running
            vite_running = try
                sock = connect("localhost", 3001)
                close(sock)
                true
            catch
                false
            end

            if !vite_running
                dashboard_dir = abspath(joinpath(@__DIR__, "..", "dashboard-ui"))
                if isdir(joinpath(dashboard_dir, "node_modules"))
                    @info "Starting Vite dev server for hot-reloading..."
                    log_file = joinpath(dashboard_dir, ".vite-dev.log")
                    cd(dashboard_dir) do
                        log_io = open(log_file, "w")
                        run(
                            pipeline(`npm run dev`, stdout = log_io, stderr = log_io),
                            wait = false,
                        )
                    end
                    sleep(2)  # Give Vite time to start
                    @info "✅ Vite dev server started on port 3001 (dashboard will hot-reload)"
                end
            else
                @info "Vite dev server already running on port 3001"
            end
        end
    catch e
        @debug "Could not start Vite dev server (development features disabled)" exception =
            e
    end

    server = HTTP.serve!(hybrid_handler, port; verbose = false, stream = true)
    global_logger(old_logger)

    # Server started successfully (session is now managed per-request via STANDALONE_SESSIONS)
    return MCPServer(session_uuid, port, server, tools_dict, name_to_id, nothing)
end

function stop_mcp_server(server::MCPServer)
    # Close all sessions in the registry
    lock(STANDALONE_SESSIONS_LOCK) do
        for (sid, session) in STANDALONE_SESSIONS
            try
                close_session!(session)
            catch e
                @warn "Error closing session" session_id = sid exception = e
            end
        end
        empty!(STANDALONE_SESSIONS)
    end

    HTTP.close(server.server)
    println("MCP Server stopped")
end
