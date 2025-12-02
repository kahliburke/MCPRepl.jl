"""
Proxy Tool Definitions

MCP tools provided by the proxy server for session and system management.
"""

# ============================================================================
# Tool Definition Infrastructure
# ============================================================================

struct MCPTool
    id::Symbol
    name::String
    description::String
    parameters::Dict{String,Any}
    handler::Function
end

macro mcp_tool(id, description, params, handler)
    if !(id isa QuoteNode || (id isa Expr && id.head == :quote))
        error("@mcp_tool requires a symbol literal for id, got: $id")
    end

    id_sym = id isa QuoteNode ? id.value : id.args[1]
    name_str = string(id_sym)

    return esc(
        quote
            MCPTool($(QuoteNode(id_sym)), $name_str, $description, $params, $handler)
        end,
    )
end

# ============================================================================
# Proxy Tools
# ============================================================================

"""
Help tool - provides comprehensive information about the MCPRepl proxy system
"""
const HELP_TOOL =
    @mcp_tool :help "Get comprehensive information about the MCPRepl proxy system, its architecture, and how to use it" Dict(
        "type" => "object",
        "properties" => Dict(),
        "required" => [],
    ) (args) -> begin
        """
        # MCPRepl Proxy System

        ## Architecture
        The MCPRepl proxy is a persistent MCP server that routes requests to multiple Julia execution sessions (backends). It provides:
        - Session management with MCP-compliant session IDs
        - Dynamic Julia session spawning and lifecycle management
        - Request routing to appropriate backend sessions
        - Real-time monitoring dashboard
        - Proxy-level tools for system management

        ## Workflow
        1. **Initialize**: MCP client connects and receives a session ID
        2. **Discover**: Use `list_julia_sessions` to see available sessions
        3. **Start**: Use `start_julia_session` to spawn new Julia backends
        4. **Execute**: Call Julia tools (ex, eval, etc.) - routed to backend
        5. **Monitor**: Access dashboard at http://localhost:3000/dashboard

        ## Available Tools
        - **help**: This comprehensive guide
        - **proxy_status**: Current proxy status and connected sessions
        - **list_julia_sessions**: List all Julia execution sessions
        - **start_julia_session**: Spawn a new Julia backend
        - **kill_stale_sessions**: Find and kill detached MCPRepl sessions
        - **dashboard_url**: Get monitoring dashboard link

        When a Julia session is connected, additional Julia-specific tools become available (code execution, introspection, LSP features, etc.).

        ## Session Management
        Each MCP client receives a unique session ID on initialization. Sessions can be associated with specific Julia backends using the X-MCPRepl-Target header, or remain at proxy-level for management operations.

        ## Targeting Julia Sessions
        You can route requests to specific Julia sessions in three ways (in order of priority):
        1. **Per-request parameter**: Add `"target": "session_name_or_uuid"` to any request params
        2. **HTTP header**: Set `X-MCPRepl-Target` header during initialization
        3. **Session default**: Set at initialization, used if no override specified

        Example per-request targeting:
        ```json
        {
          "method": "tools/call",
          "params": {
            "name": "ex",
            "target": "KoopmanInvest",
            "arguments": {"code": "1 + 1"}
          }
        }
        ```

        ## Getting Started
        1. Call `list_julia_sessions` to see available sessions (shows names and UUIDs)
        2. If none exist, call `start_julia_session` with a project path
        3. Once started, Julia tools become available automatically
        4. Use the `target` parameter to route requests to specific sessions
        5. Use `dashboard_url` to access real-time monitoring
        """
    end

"""
Proxy status tool - shows current proxy state and connected sessions
"""
const PROXY_STATUS_TOOL =
    @mcp_tool :proxy_status "Get the status of the MCP proxy server and connected REPL backends" Dict(
        "type" => "object",
        "properties" => Dict(),
        "required" => [],
    ) (args, julia_sessions) -> begin
        num_julia_sessions = length(julia_sessions)
        status_text = "MCP Proxy Status:\n- Port: 3000\n- Connected agents: $num_julia_sessions\n- Status: Running\n- Dashboard: http://localhost:3000/dashboard"
        if num_julia_sessions == 0
            status_text *= "\n\nNo backend REPL agents are currently connected. Start a backend REPL to enable Julia tools."
        else
            status_text *= "\n\nConnected agents:\n"
            for repl in julia_sessions
                status_text *= "  - $(repl.name) (port $(repl.port), status: $(repl.status))\n"
            end
        end
        status_text
    end

"""
List Julia sessions tool - shows all registered execution sessions
"""
const LIST_JULIA_SESSIONS_TOOL =
    @mcp_tool :list_julia_sessions "List all registered Julia execution sessions and their connection status" Dict(
        "type" => "object",
        "properties" => Dict(),
        "required" => [],
    ) (args, julia_sessions) -> begin
        if isempty(julia_sessions)
            """
            No Julia sessions currently registered.

            To connect a Julia session:
            1. Start a Julia session with MCPRepl
            2. It will automatically register with this proxy
            3. Julia tools will become available
            """
        else
            agent_text = "Connected Julia sessions ($(length(julia_sessions))):\n\n"
            for repl in julia_sessions
                pid_str = repl.pid === nothing ? "N/A" : string(repl.pid)
                agent_text *= "**$(repl.name)**\n"
                agent_text *= "  - UUID: $(repl.id)\n"
                agent_text *= "  - Port: $(repl.port)\n"
                agent_text *= "  - PID: $pid_str\n"
                agent_text *= "  - Status: $(repl.status)\n"
                agent_text *= "  - Last activity: $(repl.last_activity)\n\n"
            end
            agent_text
        end
    end

"""
Dashboard URL tool - provides link to monitoring dashboard
"""
const DASHBOARD_URL_TOOL =
    @mcp_tool :dashboard_url "Get the URL to access the monitoring dashboard" Dict(
        "type" => "object",
        "properties" => Dict(),
        "required" => [],
    ) (args) -> begin
        """
        Dashboard URL: http://localhost:3000/dashboard

        The dashboard provides real-time monitoring of:
        - Connected Julia sessions
        - Tool calls and code execution
        - Event logs and metrics
        - Session status and heartbeats
        """
    end

"""
Kill stale sessions tool - finds and kills detached MCPRepl Julia processes
"""
const KILL_STALE_SESSIONS_TOOL =
    @mcp_tool :kill_stale_sessions "Find and kill detached or stale MCPRepl Julia session processes. Useful for cleaning up orphaned sessions." Dict(
        "type" => "object",
        "properties" => Dict(
            "dry_run" => Dict(
                "type" => "boolean",
                "description" => "If true, only list stale processes without killing them (default: true)",
            ),
            "force" => Dict(
                "type" => "boolean",
                "description" => "If true, kill all MCPRepl sessions including registered ones (default: false)",
            ),
            "proxy_port" => Dict(
                "type" => "string",
                "description" => "Only target sessions for specific proxy port (optional)",
            ),
        ),
        "required" => [],
    ) (args, julia_sessions, list_julia_sessions_fn) -> begin
        # This tool needs special handling in proxy.jl due to system process access
        :kill_stale_sessions_special
    end

"""
Start Julia session tool - spawns a new Julia backend process
"""
const START_JULIA_SESSION_TOOL =
    @mcp_tool :start_julia_session "Start a new Julia execution session for a specific project. The session will register with the proxy and provide Julia tools." Dict(
        "type" => "object",
        "properties" => Dict(
            "project_path" => Dict(
                "type" => "string",
                "description" => "Path to the Julia project directory (containing Project.toml)",
            ),
            "session_name" => Dict(
                "type" => "string",
                "description" => "Optional name for the Julia session (defaults to project directory name)",
            ),
        ),
        "required" => ["project_path"],
    ) (args, julia_sessions, list_julia_sessions_fn) -> begin
        # This tool needs special handling in proxy.jl due to process spawning
        # Handler will be called from proxy request handler
        # Return value indicates this is a special tool
        :start_julia_session_special
    end

"""
Connect to Julia Session tool - associates this MCP session with a specific Julia REPL session
"""
const CONNECT_TO_SESSION_TOOL =
    @mcp_tool :connect_to_session "Connect this MCP client to a specific Julia REPL session to access its tools. Use list_julia_sessions to see available sessions." Dict(
        "type" => "object",
        "properties" => Dict(
            "session_id" => Dict(
                "type" => "string",
                "description" => "UUID or name of the Julia session to connect to",
            ),
        ),
        "required" => ["session_id"],
    ) (args) -> begin
        # This tool is special - it needs the MCP session context
        # The actual implementation is handled in the proxy.jl tools/call handler
        # This is just the schema definition
        "This tool must be called through the proxy with MCP session context"
    end

# ============================================================================
# Tool Registry
# ============================================================================

const PROXY_TOOLS = Dict{String,MCPTool}(
    "help" => HELP_TOOL,
    "proxy_status" => PROXY_STATUS_TOOL,
    "list_julia_sessions" => LIST_JULIA_SESSIONS_TOOL,
    "connect_to_session" => CONNECT_TO_SESSION_TOOL,
    "dashboard_url" => DASHBOARD_URL_TOOL,
    "kill_stale_sessions" => KILL_STALE_SESSIONS_TOOL,
    "start_julia_session" => START_JULIA_SESSION_TOOL,
)

"""
    get_proxy_tool_schemas() -> Vector{Dict}

Get MCP tool schema definitions for all proxy tools.
"""
function get_proxy_tool_schemas()
    return [
        Dict(
            "name" => tool.name,
            "description" => tool.description,
            "inputSchema" => tool.parameters,
        ) for tool in values(PROXY_TOOLS)
    ]
end
