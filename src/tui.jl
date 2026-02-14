# ═══════════════════════════════════════════════════════════════════════════════
# MCPRepl TUI — Tachikoma-based terminal UI for the persistent server
#
# Elm architecture: Model → update! → view. Manages REPL connections,
# agent sessions, tool call activity, and the MCP HTTP server.
# ═══════════════════════════════════════════════════════════════════════════════

# Tachikoma is loaded at the MCPRepl module level via `using Tachikoma`.
# Exported: Model, Block, StatusBar, Span, Layout, etc.
# Non-exported widgets need explicit import:
import Tachikoma:
    TabBar,
    SelectableList,
    ListItem,
    Table,
    Gauge,
    Sparkline,
    Modal,
    TextInput,
    BOX_HEAVY,
    ResizableLayout,
    split_layout,
    render_resize_handles!,
    handle_resize!
# Tachikoma.split (for layouts) is not Base.split, so we alias it.
const tsplit = Tachikoma.split

# ── Server Log Capture ────────────────────────────────────────────────────────
# Redirect Julia's logging system into a ring buffer so @info/@warn/@error
# from the MCP server, HTTP.jl, etc. appear in the Server tab instead of
# corrupting the TUI's terminal output.

struct ServerLogEntry
    timestamp::DateTime
    level::Symbol      # :debug, :info, :warn, :error
    message::String
end

const _TUI_LOG_BUFFER = ServerLogEntry[]
const _TUI_LOG_LOCK = ReentrantLock()
const _TUI_OLD_LOGGER = Ref{Any}(nothing)

struct TUILogger <: Logging.AbstractLogger end

Logging.min_enabled_level(::TUILogger) = Logging.Info
Logging.shouldlog(::TUILogger, level, _module, group, id) = true
Logging.catch_exceptions(::TUILogger) = true

function Logging.handle_message(
    ::TUILogger,
    level,
    message,
    _module,
    group,
    id,
    filepath,
    line;
    kwargs...,
)
    lvl = if level >= Logging.Error
        :error
    elseif level >= Logging.Warn
        :warn
    else
        :info
    end
    msg = string(message)
    if !isempty(kwargs)
        parts = String[string(k, "=", repr(v)) for (k, v) in kwargs]
        msg *= "  " * join(parts, " ")
    end
    lock(_TUI_LOG_LOCK) do
        push!(_TUI_LOG_BUFFER, ServerLogEntry(now(), lvl, msg))
        while length(_TUI_LOG_BUFFER) > 500
            popfirst!(_TUI_LOG_BUFFER)
        end
    end
    return nothing
end

function _drain_log_buffer!(dest::Vector{ServerLogEntry})
    lock(_TUI_LOG_LOCK) do
        append!(dest, _TUI_LOG_BUFFER)
        empty!(_TUI_LOG_BUFFER)
    end
    while length(dest) > 500
        popfirst!(dest)
    end
end

function _push_log!(level::Symbol, message::String)
    lock(_TUI_LOG_LOCK) do
        push!(_TUI_LOG_BUFFER, ServerLogEntry(now(), level, message))
    end
end

# ── Activity Feed ─────────────────────────────────────────────────────────────
# Unified timeline of tool calls and streaming REPL output. The MCPServer
# tool handler pushes :tool_start / :tool_done events here, and the view()
# loop drains bridge SUB messages into :stdout / :stderr events.

struct ActivityEvent
    timestamp::DateTime
    kind::Symbol         # :tool_start, :tool_done, :stdout, :stderr
    tool_name::String    # tool name for tool events, "" for stream
    session_name::String # bridge session name
    data::String         # output text for stream, time_str for tool_done
    success::Bool        # meaningful only for :tool_done
end

const _TUI_ACTIVITY_BUFFER = ActivityEvent[]
const _TUI_ACTIVITY_LOCK = ReentrantLock()

"""
    _push_activity!(kind, tool_name, session_name, data; success=true)

Thread-safe push of an activity event. Called from the MCPServer tool handler.
"""
function _push_activity!(
    kind::Symbol,
    tool_name::String,
    session_name::String,
    data::String;
    success::Bool = true,
)
    lock(_TUI_ACTIVITY_LOCK) do
        push!(
            _TUI_ACTIVITY_BUFFER,
            ActivityEvent(now(), kind, tool_name, session_name, data, success),
        )
        while length(_TUI_ACTIVITY_BUFFER) > 500
            popfirst!(_TUI_ACTIVITY_BUFFER)
        end
    end
end

function _drain_activity_buffer!(dest::Vector{ActivityEvent})
    lock(_TUI_ACTIVITY_LOCK) do
        append!(dest, _TUI_ACTIVITY_BUFFER)
        empty!(_TUI_ACTIVITY_BUFFER)
    end
    while length(dest) > 2000
        popfirst!(dest)
    end
end

# ── Tool Call Results (inspectable) ──────────────────────────────────────
# Full tool call records with args + output for the Activity tab detail panel.

struct ToolCallResult
    timestamp::DateTime
    tool_name::String
    args_json::String      # JSON-encoded tool arguments
    result_text::String    # full result returned by tool handler
    duration_str::String   # "125ms" or "1.2s"
    success::Bool
    session_key::String    # 8-char short key for session routing ("" if none)
end

const _TUI_TOOL_RESULTS_BUFFER = ToolCallResult[]
const _TUI_TOOL_RESULTS_LOCK = ReentrantLock()

function _push_tool_result!(r::ToolCallResult)
    lock(_TUI_TOOL_RESULTS_LOCK) do
        push!(_TUI_TOOL_RESULTS_BUFFER, r)
        while length(_TUI_TOOL_RESULTS_BUFFER) > 500
            popfirst!(_TUI_TOOL_RESULTS_BUFFER)
        end
    end
end

function _drain_tool_results!(dest::Vector{ToolCallResult})
    lock(_TUI_TOOL_RESULTS_LOCK) do
        append!(dest, _TUI_TOOL_RESULTS_BUFFER)
        empty!(_TUI_TOOL_RESULTS_BUFFER)
    end
    while length(dest) > 500
        popfirst!(dest)
    end
end

# ── Data types ────────────────────────────────────────────────────────────────

struct ToolCallRecord
    timestamp::DateTime
    tool_name::String
    session_name::String     # which REPL handled it
    agent_id::String         # which agent sent it
    duration_ms::Int
    success::Bool
end

struct AgentInfo
    session_id::String
    client_name::String
    protocol_version::String
    connected_at::DateTime
    tool_calls::Int
    bound_repl::String       # name of the REPL this agent routes to
end

# Modal flow states
@enum ConfigFlow begin
    FLOW_IDLE
    # Project onboarding
    FLOW_ONBOARD_PATH          # TextInput for project path
    FLOW_ONBOARD_SCOPE         # Choose project-level vs user-level
    FLOW_ONBOARD_CONFIRM       # Modal confirmation
    FLOW_ONBOARD_RESULT        # Success/failure feedback
    # MCP client config
    FLOW_CLIENT_SELECT         # Choose client (Claude/VSCode/Gemini/Kilo)
    FLOW_CLIENT_SCOPE          # Choose project vs user level
    FLOW_CLIENT_PATH           # TextInput for project path (if project-level)
    FLOW_CLIENT_CONFIRM        # Modal confirmation
    FLOW_CLIENT_RESULT         # Success/failure feedback
end

# ── Model ─────────────────────────────────────────────────────────────────────

@kwdef mutable struct MCPReplModel <: Model
    quit::Bool = false
    shutting_down::Bool = false
    tick::Int = 0

    # Tabs: 1=Server, 2=Sessions, 3=Agents, 4=Activity, 5=Config
    active_tab::Int = 1

    # REPL connections (managed by ConnectionManager)
    conn_mgr::Union{ConnectionManager,Nothing} = nothing
    selected_connection::Int = 1

    # Agent sessions
    agents::Vector{AgentInfo} = AgentInfo[]
    selected_agent::Int = 1

    # Activity feed — unified timeline of tool calls + streaming output
    activity_feed::Vector{ActivityEvent} = ActivityEvent[]
    recent_tool_calls::Vector{ToolCallRecord} = ToolCallRecord[]
    tool_call_history::Vector{Float64} = zeros(120)  # calls per second, last 2 min

    # Tool call results — inspectable from Activity tab
    tool_results::Vector{ToolCallResult} = ToolCallResult[]
    selected_result::Int = 0       # 0 = none, 1+ = index into tool_results (newest-first)
    result_scroll::Int = 0         # vertical scroll in detail panel
    activity_layout::ResizableLayout = ResizableLayout(Vertical, [Percent(35), Fill()])

    # Server state
    server_port::Int = 2828
    server_running::Bool = false
    server_started::Bool = false   # true once we've attempted to start
    mcp_server::Any = nothing      # MCPServer reference
    server_log::Vector{ServerLogEntry} = ServerLogEntry[]

    # Status
    total_tool_calls::Int = 0
    start_time::Float64 = time()

    # Config flow state machine
    config_flow::ConfigFlow = FLOW_IDLE
    path_input::Any = nothing              # TextInput widget, created on demand
    flow_selected::Int = 1                 # Selection index in flow lists
    flow_modal_selected::Symbol = :cancel  # For Modal confirm/cancel

    # Onboarding state
    onboard_path::String = ""
    onboard_scope::Symbol = :project       # :project or :user

    # Client config state
    client_target::Symbol = :claude        # :claude, :vscode, :gemini, :kilo
    client_scope::Symbol = :project
    client_path::String = ""

    # Flow result
    flow_message::String = ""
    flow_success::Bool = false

    # Client detection (populated async on tab switch)
    client_statuses::Vector{Pair{String,Bool}} = Pair{String,Bool}[]
end

# ── Lifecycle ─────────────────────────────────────────────────────────────────

function Tachikoma.init!(m::MCPReplModel, _t::Tachikoma.Terminal)
    set_theme!(KOKAKU)

    # Redirect logging into the TUI ring buffer so @info/@warn from the MCP
    # server, HTTP.jl, etc. show up in the Server tab instead of on stderr.
    _TUI_OLD_LOGGER[] = global_logger()
    global_logger(TUILogger())

    # Start connection manager (discovers REPL bridges)
    m.conn_mgr = ConnectionManager()
    start!(m.conn_mgr)

    # Enable bridge mode — tool evals route to connected REPLs
    BRIDGE_MODE[] = true
    BRIDGE_CONN_MGR[] = m.conn_mgr

    # MCP server is started on the first view() tick so the TUI is already
    # rendering and can report status in the Server tab.

    m.start_time = time()
end

function Tachikoma.cleanup!(m::MCPReplModel)
    # Disable bridge mode
    BRIDGE_MODE[] = false
    BRIDGE_CONN_MGR[] = nothing

    # Stop MCP server
    if m.mcp_server !== nothing
        try
            stop_mcp_server(m.mcp_server)
        catch
        end
        m.mcp_server = nothing
        m.server_running = false
    end

    # Stop connection manager
    if m.conn_mgr !== nothing
        stop!(m.conn_mgr)
    end

    # Restore original logger so post-TUI Julia session isn't silenced
    if _TUI_OLD_LOGGER[] !== nothing
        global_logger(_TUI_OLD_LOGGER[])
        _TUI_OLD_LOGGER[] = nothing
    end
end

Tachikoma.should_quit(m::MCPReplModel) = m.quit

# ── Update ────────────────────────────────────────────────────────────────────

function Tachikoma.update!(m::MCPReplModel, evt::MouseEvent)
    # Route mouse events to resizable layouts
    if m.active_tab == 4
        handle_resize!(m.activity_layout, evt)
    end
end

function Tachikoma.update!(m::MCPReplModel, evt::KeyEvent)
    # Ignore input while shutting down
    m.shutting_down && return

    # When a modal flow is active, route all input there
    if m.config_flow != FLOW_IDLE
        evt.key == :escape && (m.config_flow = FLOW_IDLE; return)
        handle_flow_input!(m, evt)
        return
    end

    if evt.key == :char
        evt.char == 'q' && (m.shutting_down = true; return)
        evt.char == '1' && _switch_tab!(m, 1)
        evt.char == '2' && _switch_tab!(m, 2)
        evt.char == '3' && _switch_tab!(m, 3)
        evt.char == '4' && _switch_tab!(m, 4)
        evt.char == '5' && _switch_tab!(m, 5)
        # Config tab actions (tab 5)
        if m.active_tab == 5
            evt.char == 'a' && begin_onboarding!(m)
            evt.char == 'c' && begin_client_config!(m)
        end
    elseif evt.key == :tab
        _switch_tab!(m, mod1(m.active_tab + 1, 5))
    elseif evt.key == :up
        if m.active_tab == 2
            m.selected_connection = max(1, m.selected_connection - 1)
        elseif m.active_tab == 3
            m.selected_agent = max(1, m.selected_agent - 1)
        elseif m.active_tab == 4 && !isempty(m.tool_results)
            # List is newest-first; up = toward newer = increase selected_result
            m.selected_result = min(length(m.tool_results), m.selected_result + 1)
            m.result_scroll = 0
        end
    elseif evt.key == :down
        if m.active_tab == 2 && m.conn_mgr !== nothing
            n = length(m.conn_mgr.connections)
            m.selected_connection = min(max(1, n), m.selected_connection + 1)
        elseif m.active_tab == 3
            m.selected_agent = min(max(1, length(m.agents)), m.selected_agent + 1)
        elseif m.active_tab == 4 && !isempty(m.tool_results)
            # List is newest-first; down = toward older = decrease selected_result
            m.selected_result = max(1, m.selected_result - 1)
            m.result_scroll = 0
        end
    elseif evt.key == :pageup
        if m.active_tab == 4
            m.result_scroll = max(0, m.result_scroll - 5)
        end
    elseif evt.key == :pagedown
        if m.active_tab == 4
            m.result_scroll += 5
        end
    end
    evt.key == :escape && (m.shutting_down = true)
end

# ── Tab switching ────────────────────────────────────────────────────────────

function _switch_tab!(m::MCPReplModel, tab::Int)
    m.active_tab = tab
    # Trigger async client detection when entering the Config tab
    if tab == 5
        _refresh_client_status_async!(m)
    end
end

# ── Config Flow: Begin ───────────────────────────────────────────────────────

function begin_onboarding!(m::MCPReplModel)
    m.config_flow = FLOW_ONBOARD_PATH
    m.path_input = TextInput(text = string(pwd()), label = "Path: ")
    m.flow_selected = 1
    m.flow_modal_selected = :confirm
end

function begin_client_config!(m::MCPReplModel)
    m.config_flow = FLOW_CLIENT_SELECT
    m.flow_selected = 1
    m.flow_modal_selected = :confirm
end

# ── Config Flow: Input Handler ───────────────────────────────────────────────

const CLIENT_OPTIONS = [:claude, :vscode, :gemini, :kilo]
const CLIENT_LABELS =
    ["Claude Code / claude.ai", "VS Code / Copilot", "Gemini CLI", "KiloCode"]
const SCOPE_LABELS = ["Project-level", "User-level (global)"]

function handle_flow_input!(m::MCPReplModel, evt::KeyEvent)
    flow = m.config_flow

    # ── Onboarding path entry ──
    if flow == FLOW_ONBOARD_PATH
        if evt.key == :enter
            m.onboard_path = Tachikoma.text(m.path_input)
            m.flow_selected = 1
            m.config_flow = FLOW_ONBOARD_SCOPE
        elseif evt.key == :tab
            _complete_path!(m.path_input)
        else
            handle_key!(m.path_input, evt)
        end

        # ── Onboarding scope selection ──
    elseif flow == FLOW_ONBOARD_SCOPE
        if evt.key == :up
            m.flow_selected = max(1, m.flow_selected - 1)
        elseif evt.key == :down
            m.flow_selected = min(2, m.flow_selected + 1)
        elseif evt.key == :enter
            m.onboard_scope = m.flow_selected == 1 ? :project : :user
            m.flow_modal_selected = :confirm
            m.config_flow = FLOW_ONBOARD_CONFIRM
        end

        # ── Onboarding confirm ──
    elseif flow == FLOW_ONBOARD_CONFIRM
        if evt.key == :left || evt.key == :right
            m.flow_modal_selected = m.flow_modal_selected == :cancel ? :confirm : :cancel
        elseif evt.key == :enter
            if m.flow_modal_selected == :confirm
                execute_onboarding!(m)
            else
                m.config_flow = FLOW_IDLE
            end
        end

        # ── Onboarding result ──
    elseif flow == FLOW_ONBOARD_RESULT
        # Any key dismisses
        m.config_flow = FLOW_IDLE

        # ── Client select ──
    elseif flow == FLOW_CLIENT_SELECT
        if evt.key == :up
            m.flow_selected = max(1, m.flow_selected - 1)
        elseif evt.key == :down
            m.flow_selected = min(length(CLIENT_OPTIONS), m.flow_selected + 1)
        elseif evt.key == :enter
            m.client_target = CLIENT_OPTIONS[m.flow_selected]
            m.flow_selected = 1
            m.config_flow = FLOW_CLIENT_SCOPE
        end

        # ── Client scope ──
    elseif flow == FLOW_CLIENT_SCOPE
        if evt.key == :up
            m.flow_selected = max(1, m.flow_selected - 1)
        elseif evt.key == :down
            m.flow_selected = min(2, m.flow_selected + 1)
        elseif evt.key == :enter
            m.client_scope = m.flow_selected == 1 ? :project : :user
            if m.client_scope == :project
                m.path_input = TextInput(text = string(pwd()), label = "Path: ")
                m.config_flow = FLOW_CLIENT_PATH
            else
                # VS Code doesn't support user-level config via TUI
                if m.client_target == :vscode
                    m.flow_message = "VS Code MCP configs are project-scoped.\nUse project-level instead."
                    m.flow_success = false
                    m.config_flow = FLOW_CLIENT_RESULT
                else
                    m.flow_modal_selected = :confirm
                    m.config_flow = FLOW_CLIENT_CONFIRM
                end
            end
        end

        # ── Client path entry ──
    elseif flow == FLOW_CLIENT_PATH
        if evt.key == :enter
            m.client_path = Tachikoma.text(m.path_input)
            m.flow_modal_selected = :confirm
            m.config_flow = FLOW_CLIENT_CONFIRM
        elseif evt.key == :tab
            _complete_path!(m.path_input)
        else
            handle_key!(m.path_input, evt)
        end

        # ── Client confirm ──
    elseif flow == FLOW_CLIENT_CONFIRM
        if evt.key == :left || evt.key == :right
            m.flow_modal_selected = m.flow_modal_selected == :cancel ? :confirm : :cancel
        elseif evt.key == :enter
            if m.flow_modal_selected == :confirm
                execute_client_config!(m)
            else
                m.config_flow = FLOW_IDLE
            end
        end

        # ── Client result ──
    elseif flow == FLOW_CLIENT_RESULT
        m.config_flow = FLOW_IDLE
    end
end

# ── Config Flow: Execution ───────────────────────────────────────────────────

function execute_onboarding!(m::MCPReplModel)
    try
        path = rstrip(expanduser(m.onboard_path), ['/', '\\'])
        if m.onboard_scope == :project
            # Write .julia-startup.jl in the project directory
            isdir(path) || mkpath(path)
            projname = basename(path)
            startup_file = joinpath(path, ".julia-startup.jl")
            content = """
            # MCPRepl Bridge — auto-connect this REPL to the TUI server
            try
                using MCPRepl
                MCPReplBridge.serve(name=$(repr(projname)))
            catch e
                @warn "MCPRepl bridge failed to start" exception=e
            end
            """
            write(startup_file, content)
            m.flow_message = "Created $(_short_path(startup_file))\n\nAdd to your project's startup:\n  include(\".julia-startup.jl\")"
            m.flow_success = true
        else
            # Append to ~/.julia/config/startup.jl
            startup_dir = joinpath(homedir(), ".julia", "config")
            isdir(startup_dir) || mkpath(startup_dir)
            startup_file = joinpath(startup_dir, "startup.jl")

            marker = "# MCPRepl Bridge — auto-connect"
            existing = isfile(startup_file) ? read(startup_file, String) : ""
            if occursin(marker, existing)
                m.flow_message = "Bridge snippet already in\n$(_short_path(startup_file))"
                m.flow_success = true
            else
                block = """

                $marker
                try
                    using MCPRepl
                    projname = basename(something(Base.active_project(), "julia"))
                    MCPReplBridge.serve(name=projname)
                catch e
                    @warn "MCPRepl bridge failed to start" exception=e
                end
                """
                open(startup_file, "a") do io
                    write(io, block)
                end
                m.flow_message = "Appended bridge snippet to\n$(_short_path(startup_file))"
                m.flow_success = true
            end
        end
    catch e
        m.flow_message = "Error: $(sprint(showerror, e))"
        m.flow_success = false
    end
    m.config_flow = FLOW_ONBOARD_RESULT
end

function execute_client_config!(m::MCPReplModel)
    try
        port = m.server_port
        target = m.client_target
        scope = m.client_scope

        if target == :claude
            _install_claude(m, port, scope)
        elseif target == :vscode
            _install_vscode(m, port)
        elseif target == :gemini
            _install_gemini(m, port, scope)
        elseif target == :kilo
            _install_kilo(m, port, scope)
        end
    catch e
        m.flow_message = "Error: $(sprint(showerror, e))"
        m.flow_success = false
    end
    m.config_flow = FLOW_CLIENT_RESULT
end

function _install_claude(m::MCPReplModel, port::Int, scope::Symbol)
    if scope == :project
        path = expanduser(m.client_path)
        isdir(path) || mkpath(path)
        # Use claude CLI to add MCP server (stderr → devnull to avoid TUI corruption)
        cmd = pipeline(
            `claude mcp add julia-repl --transport http --url http://localhost:$port/mcp --scope project`;
            stderr = devnull,
        )
        cd(path) do
            read(cmd, String)
        end
        m.flow_message = "Added julia-repl to Claude (project)\nin $(_short_path(path))"
        m.flow_success = true
    else
        cmd = pipeline(
            `claude mcp add julia-repl --transport http --url http://localhost:$port/mcp --scope user`;
            stderr = devnull,
        )
        read(cmd, String)
        m.flow_message = "Added julia-repl to Claude (user scope)"
        m.flow_success = true
    end
end

function _install_vscode(m::MCPReplModel, port::Int)
    path = expanduser(m.client_path)
    isdir(path) || mkpath(path)
    vscode_dir = joinpath(path, ".vscode")
    isdir(vscode_dir) || mkpath(vscode_dir)
    mcp_file = joinpath(vscode_dir, "mcp.json")

    content = Dict{String,Any}(
        "servers" => Dict{String,Any}(
            "julia-repl" => Dict{String,Any}(
                "type" => "http",
                "url" => "http://localhost:$port/mcp",
            ),
        ),
    )
    write(mcp_file, _to_json(content))
    m.flow_message = "Wrote $(_short_path(mcp_file))"
    m.flow_success = true
end

function _install_gemini(m::MCPReplModel, port::Int, scope::Symbol)
    if scope == :project
        path = expanduser(m.client_path)
        isdir(path) || mkpath(path)
        gemini_dir = joinpath(path, ".gemini")
        isdir(gemini_dir) || mkpath(gemini_dir)
        target_file = joinpath(gemini_dir, "settings.json")
    else
        gemini_dir = joinpath(homedir(), ".gemini")
        isdir(gemini_dir) || mkpath(gemini_dir)
        target_file = joinpath(gemini_dir, "settings.json")
    end

    content = Dict{String,Any}(
        "mcpServers" => Dict{String,Any}(
            "julia-repl" => Dict{String,Any}(
                "type" => "http",
                "url" => "http://localhost:$port/mcp",
            ),
        ),
    )
    write(target_file, _to_json(content))
    m.flow_message = "Wrote $(_short_path(target_file))"
    m.flow_success = true
end

function _install_kilo(m::MCPReplModel, port::Int, scope::Symbol)
    if scope == :project
        path = expanduser(m.client_path)
        isdir(path) || mkpath(path)
        kilo_dir = joinpath(path, ".kilocode")
        isdir(kilo_dir) || mkpath(kilo_dir)
        target_file = joinpath(kilo_dir, "mcp.json")
    else
        kilo_dir = joinpath(homedir(), ".kilocode")
        isdir(kilo_dir) || mkpath(kilo_dir)
        target_file = joinpath(kilo_dir, "mcp.json")
    end

    content = Dict{String,Any}(
        "mcpServers" => Dict{String,Any}(
            "julia-repl" => Dict{String,Any}(
                "type" => "streamable-http",
                "url" => "http://localhost:$port/mcp",
            ),
        ),
    )
    write(target_file, _to_json(content))
    m.flow_message = "Wrote $(_short_path(target_file))"
    m.flow_success = true
end

# ── Minimal JSON helpers (no dependency on JSON3) ────────────────────────────

function _to_json(d::Dict; indent::Int = 2)
    io = IOBuffer()
    _write_json(io, d, 0, indent)
    write(io, '\n')
    String(take!(io))
end

function _write_json(io::IO, d::Dict, level::Int, indent::Int)
    write(io, "{\n")
    entries = collect(pairs(d))
    for (i, (k, v)) in enumerate(entries)
        write(io, ' '^((level + 1) * indent))
        _write_json(io, string(k), level + 1, indent)
        write(io, ": ")
        _write_json(io, v, level + 1, indent)
        i < length(entries) && write(io, ',')
        write(io, '\n')
    end
    write(io, ' '^(level * indent))
    write(io, '}')
end

function _write_json(io::IO, s::AbstractString, ::Int, ::Int)
    write(io, '"')
    for ch in s
        if ch == '"'
            write(io, "\\\"")
        elseif ch == '\\'
            write(io, "\\\\")
        elseif ch == '\n'
            write(io, "\\n")
        else
            write(io, ch)
        end
    end
    write(io, '"')
end

_write_json(io::IO, b::Bool, ::Int, ::Int) = write(io, b ? "true" : "false")
_write_json(io::IO, n::Number, ::Int, ::Int) = write(io, string(n))

function _parse_json_simple(s::AbstractString)
    # Minimal recursive-descent JSON parser for settings files.
    # Handles objects, strings, booleans, null. No arrays needed for config files.
    s = strip(s)
    isempty(s) && return Dict{String,Any}()
    try
        val, _ = _json_parse_value(s, 1)
        return val isa Dict ? val : Dict{String,Any}()
    catch
        return Dict{String,Any}()
    end
end

function _json_skip_ws(s, i)
    while i <= length(s) && s[i] in (' ', '\t', '\n', '\r')
        i += 1
    end
    i
end

function _json_parse_value(s, i)
    i = _json_skip_ws(s, i)
    i > length(s) && error("unexpected end")
    c = s[i]
    if c == '"'
        _json_parse_string(s, i)
    elseif c == '{'
        _json_parse_object(s, i)
    elseif c == 't' && i + 3 <= length(s) && s[i:i+3] == "true"
        (true, i + 4)
    elseif c == 'f' && i + 4 <= length(s) && s[i:i+4] == "false"
        (false, i + 5)
    elseif c == 'n' && i + 3 <= length(s) && s[i:i+3] == "null"
        (nothing, i + 4)
    elseif c == '-' || isdigit(c)
        j = i
        (c == '-') && (j += 1)
        while j <= length(s) && (isdigit(s[j]) || s[j] == '.')
            j += 1
        end
        (parse(Float64, s[i:j-1]), j)
    else
        error("unexpected char '$c' at $i")
    end
end

function _json_parse_string(s, i)
    i += 1  # skip opening "
    buf = IOBuffer()
    while i <= length(s) && s[i] != '"'
        if s[i] == '\\' && i + 1 <= length(s)
            i += 1
            c = s[i]
            if c == 'n'
                write(buf, '\n')
            elseif c == 't'
                write(buf, '\t')
            elseif c == '"'
                write(buf, '"')
            elseif c == '\\'
                write(buf, '\\')
            elseif c == '/'
                write(buf, '/')
            else
                write(buf, '\\')
                write(buf, c)
            end
        else
            write(buf, s[i])
        end
        i += 1
    end
    (String(take!(buf)), i + 1)  # skip closing "
end

function _json_parse_object(s, i)
    i += 1  # skip {
    d = Dict{String,Any}()
    i = _json_skip_ws(s, i)
    i <= length(s) && s[i] == '}' && return (d, i + 1)
    while true
        i = _json_skip_ws(s, i)
        key, i = _json_parse_string(s, i)
        i = _json_skip_ws(s, i)
        (i <= length(s) && s[i] == ':') || error("expected ':'")
        i += 1
        val, i = _json_parse_value(s, i)
        d[key] = val
        i = _json_skip_ws(s, i)
        i > length(s) && break
        if s[i] == ','
            i += 1
        elseif s[i] == '}'
            i += 1
            break
        else
            break
        end
    end
    (d, i)
end

# ── View ──────────────────────────────────────────────────────────────────────

function Tachikoma.view(m::MCPReplModel, f::Frame)
    m.tick += 1
    buf = f.buffer

    # Shutdown overlay — render one frame showing the message, then quit
    if m.shutting_down
        _dim_area!(buf, f.area)
        w = 36
        h = 5
        rect = center(f.area, w, h)
        block = Block(
            title = " Shutting Down ",
            border_style = tstyle(:warning, bold = true),
            title_style = tstyle(:warning, bold = true),
            box = BOX_HEAVY,
        )
        inner = render(block, rect, buf)
        if inner.width >= 4
            for row = inner.y:bottom(inner)
                for col = inner.x:right(inner)
                    set_char!(buf, col, row, ' ', Style())
                end
            end
            si = mod1(m.tick ÷ 2, length(SPINNER_BRAILLE))
            set_string!(
                buf,
                inner.x + 2,
                inner.y + 1,
                "$(SPINNER_BRAILLE[si]) Stopping server...",
                tstyle(:warning),
            )
        end
        m.quit = true
        return
    end

    # Drain captured log messages into the model each frame
    _drain_log_buffer!(m.server_log)

    # Drain activity events (tool calls from MCPServer hook)
    _drain_activity_buffer!(m.activity_feed)

    # Drain tool call results for Activity tab inspection
    _drain_tool_results!(m.tool_results)

    # Drain streaming REPL output from bridge SUB sockets
    if m.conn_mgr !== nothing
        for msg in drain_stream_messages!(m.conn_mgr)
            kind = msg.channel == "stderr" ? :stderr : :stdout
            push!(
                m.activity_feed,
                ActivityEvent(now(), kind, "", msg.session_name, msg.data, true),
            )
        end
        while length(m.activity_feed) > 2000
            popfirst!(m.activity_feed)
        end
    end

    # Reap stale MCP agent sessions every ~30s (450 ticks at 15fps).
    # Sessions with no activity for 5 minutes are closed and removed.
    if m.tick % 450 == 0
        _reap_stale_sessions!(300.0)  # 5 min threshold
    end

    # Deferred server start — kick off on first frame so the TUI is already
    # rendering and can report startup status in the Server tab.
    if !m.server_started
        m.server_started = true
        _push_log!(:info, "Starting MCP server on port $(m.server_port)...")
        Threads.@spawn try
            security_config = load_global_security_config()
            tools = collect_tools()
            m.mcp_server = start_mcp_server(
                tools,
                m.server_port;
                verbose = false,
                security_config = security_config,
                dashboard = false,
            )
            m.server_running = true
            _push_log!(:info, "MCP server listening on port $(m.server_port)")
            # Re-hide cursor in case HTTP.jl or a dependency showed it
            print(stdout, "\e[?25l")
        catch e
            m.server_running = false
            _push_log!(:error, "Server failed: $(sprint(showerror, e))")
        end
    end

    # Simulate tool call rate for sparkline
    push!(m.tool_call_history, 0.0)
    length(m.tool_call_history) > 120 && popfirst!(m.tool_call_history)

    # ── Layout: outer frame → tab bar | content | status bar ──
    outer = Block(
        title = " MCPRepl ",
        border_style = tstyle(:border),
        title_style = tstyle(:title, bold = true),
    )
    main = render(outer, f.area, buf)
    main.width < 4 && return

    rows = tsplit(Layout(Vertical, [Fixed(1), Fill(), Fixed(1)]), main)
    length(rows) < 3 && return
    tab_area = rows[1]
    content_area = rows[2]
    status_area = rows[3]

    # ── Tab bar ──
    render(
        TabBar(
            ["Server", "Sessions", "Agents", "Activity", "Config"];
            active = m.active_tab,
        ),
        tab_area,
        buf,
    )

    # ── Content by tab ──
    if m.active_tab == 1
        view_server(m, content_area, buf)
    elseif m.active_tab == 2
        view_sessions(m, content_area, buf)
    elseif m.active_tab == 3
        view_agents(m, content_area, buf)
    elseif m.active_tab == 4
        view_activity(m, content_area, buf)
    else
        view_config(m, content_area, buf)
    end

    # ── Status bar ──
    n_conns = m.conn_mgr !== nothing ? length(connected_sessions(m.conn_mgr)) : 0
    n_total = m.conn_mgr !== nothing ? length(m.conn_mgr.connections) : 0
    n_agents = lock(STANDALONE_SESSIONS_LOCK) do
        count(s -> s.state == Session.INITIALIZED, values(STANDALONE_SESSIONS))
    end
    uptime = format_uptime(time() - m.start_time)

    si = mod1(m.tick ÷ 3, length(SPINNER_BRAILLE))
    server_status = if m.server_running
        "localhost:$(m.server_port)"
    elseif !m.server_started
        "starting…"
    else
        "stopped"
    end

    render(
        StatusBar(
            left = [
                Span(" $(SPINNER_BRAILLE[si]) ", tstyle(:accent)),
                Span(
                    "Server: $server_status",
                    tstyle(
                        m.server_running ? :success : m.server_started ? :error : :warning,
                    ),
                ),
                Span("  $(DOT) ", tstyle(:border)),
                Span("$(n_conns)/$(n_total) sessions", tstyle(:primary)),
                Span("  $(DOT) ", tstyle(:border)),
                Span("$(n_agents) agents", tstyle(:secondary)),
            ],
            right = [
                Span("$(uptime) ", tstyle(:text_dim)),
                Span(" [tab]nav [q]quit ", tstyle(:text_dim)),
            ],
        ),
        status_area,
        buf,
    )
end

# ── Sessions Tab ──────────────────────────────────────────────────────────────

function view_sessions(m::MCPReplModel, area::Rect, buf::Buffer)
    cols = tsplit(Layout(Horizontal, [Percent(45), Fill()]), area)
    length(cols) < 2 && return

    # Left: connection list (snapshot under lock to avoid races with health checker)
    connections = if m.conn_mgr !== nothing
        lock(m.conn_mgr.lock) do
            copy(m.conn_mgr.connections)
        end
    else
        REPLConnection[]
    end

    items = ListItem[]
    for conn in connections
        icon = conn.status == :connected ? "●" : conn.status == :connecting ? "◐" : "○"
        style =
            conn.status == :connected ? tstyle(:success) :
            conn.status == :connecting ? tstyle(:warning) : tstyle(:error)
        label = "$icon $(conn.name)"
        # Pad to align status text
        padded = rpad(label, 20)
        status_text = string(conn.status)
        push!(items, ListItem("$padded $status_text", style))
    end

    if isempty(items)
        push!(items, ListItem("  No REPL sessions found", tstyle(:text_dim)))
        push!(items, ListItem("", tstyle(:text_dim)))
        push!(items, ListItem("  Start a bridge in your REPL:", tstyle(:text_dim)))
        push!(items, ListItem("  MCPReplBridge.serve(name=\"myproject\")", tstyle(:accent)))
    end

    render(
        SelectableList(
            items;
            selected = m.selected_connection,
            block = Block(
                title = " Julia Sessions ",
                border_style = tstyle(:border),
                title_style = tstyle(:text_dim),
            ),
            highlight_style = tstyle(:accent, bold = true),
        ),
        cols[1],
        buf,
    )

    # Right: detail panel for selected connection
    detail_block = Block(
        title = " Details ",
        border_style = tstyle(:border),
        title_style = tstyle(:text_dim),
    )
    detail_area = render(detail_block, cols[2], buf)

    if !isempty(connections) && m.selected_connection <= length(connections)
        conn = connections[m.selected_connection]
        y = detail_area.y
        x = detail_area.x + 1

        fields = [
            ("Name", conn.name),
            ("Status", string(conn.status)),
            ("Path", _short_path(conn.project_path)),
            ("Julia", conn.julia_version),
            ("PID", string(conn.pid)),
            ("Uptime", _time_ago(conn.last_seen)),
            ("Tool calls", string(conn.tool_call_count)),
            ("Session", conn.session_id[1:min(8, length(conn.session_id))] * "..."),
        ]

        for (label, value) in fields
            y > bottom(detail_area) && break
            set_string!(buf, x, y, "$(rpad(label, 12))", tstyle(:text_dim))
            set_string!(buf, x + 13, y, value, tstyle(:text))
            y += 1
        end

        # Connection health gauge
        y += 1
        if y + 1 <= bottom(detail_area)
            set_string!(buf, x, y, "Health", tstyle(:text_dim))
            y += 1
            health =
                conn.status == :connected ? 1.0 : conn.status == :connecting ? 0.5 : 0.0
            render(
                Gauge(
                    health;
                    filled_style = conn.status == :connected ? tstyle(:success) :
                                   tstyle(:warning),
                    empty_style = tstyle(:text_dim),
                ),
                Rect(x, y, detail_area.width - 2, 1),
                buf,
            )
        end
    else
        set_string!(
            buf,
            detail_area.x + 1,
            detail_area.y,
            "Select a session",
            tstyle(:text_dim),
        )
    end
end

# ── Agents Tab ────────────────────────────────────────────────────────────────

function view_agents(m::MCPReplModel, area::Rect, buf::Buffer)
    # Pull live MCP sessions from the server's session registry
    sessions = lock(STANDALONE_SESSIONS_LOCK) do
        collect(values(STANDALONE_SESSIONS))
    end
    # Only show initialized (active) sessions
    filter!(s -> s.state == Session.INITIALIZED, sessions)

    if isempty(sessions)
        block = Block(
            title = " Agent Sessions ",
            border_style = tstyle(:border),
            title_style = tstyle(:text_dim),
        )
        inner = render(block, area, buf)
        y = inner.y + 1
        set_string!(buf, inner.x + 2, y, "No agents connected", tstyle(:text_dim))
        y += 2
        set_string!(
            buf,
            inner.x + 2,
            y,
            "Agents connect via HTTP to port $(m.server_port)",
            tstyle(:text_dim),
        )
        return
    end

    # Agent table from live session data
    header = ["CLIENT", "PROTOCOL", "SESSION", "CONNECTED", "LAST ACTIVE"]
    rows = Vector{String}[]
    for s in sessions
        client_name = get(s.client_info, "name", "unknown")
        push!(
            rows,
            [
                string(client_name),
                s.protocol_version,
                s.id[1:min(8, length(s.id))] * "…",
                _time_ago(s.created_at),
                _time_ago(s.last_activity),
            ],
        )
    end

    render(
        Table(
            header,
            rows;
            block = Block(
                title = " Agent Sessions ($(length(sessions))) ",
                border_style = tstyle(:border),
                title_style = tstyle(:text_dim),
            ),
            selected = m.selected_agent,
        ),
        area,
        buf,
    )
end

# ── Activity Tab ──────────────────────────────────────────────────────────────

function view_activity(m::MCPReplModel, area::Rect, buf::Buffer)
    panes = split_layout(m.activity_layout, area)
    length(panes) < 2 && return

    # ── Top pane: tool call list (newest first) ──
    n = length(m.tool_results)

    # Auto-select newest entry when results arrive and nothing selected
    if n > 0 && m.selected_result == 0
        m.selected_result = n
    end

    items = ListItem[]
    for i = n:-1:1
        r = m.tool_results[i]
        ts = Dates.format(r.timestamp, "HH:MM:SS")
        marker = r.success ? "✓" : "✗"
        style = r.success ? tstyle(:success) : tstyle(:error)
        label = "$ts $marker $(r.tool_name) ($(r.duration_str))"
        push!(items, ListItem(label, style))
    end

    if isempty(items)
        push!(items, ListItem("  No tool calls yet", tstyle(:text_dim)))
    end

    # Map selected_result (1-based into tool_results) to display index (reversed)
    display_sel = n > 0 ? (n - m.selected_result + 1) : 0

    render(
        SelectableList(
            items;
            selected = display_sel,
            block = Block(
                title = " Tool Calls ($n) ",
                border_style = tstyle(:border),
                title_style = tstyle(:text_dim),
            ),
            highlight_style = tstyle(:accent, bold = true),
        ),
        panes[1],
        buf,
    )

    # ── Bottom pane: detail panel ──
    if n == 0 || m.selected_result < 1 || m.selected_result > n
        empty_block = Block(
            title = " Details ",
            border_style = tstyle(:border),
            title_style = tstyle(:text_dim),
        )
        ei = render(empty_block, panes[2], buf)
        if ei.width >= 4
            set_string!(
                buf,
                ei.x + 2,
                ei.y + 1,
                "Select a tool call to inspect",
                tstyle(:text_dim),
            )
        end
        render_resize_handles!(buf, m.activity_layout)
        return
    end

    r = m.tool_results[m.selected_result]
    detail_block = Block(
        title = " $(r.tool_name) ",
        border_style = tstyle(:border),
        title_style = tstyle(:accent, bold = true),
    )
    di = render(detail_block, panes[2], buf)
    di.width < 4 && return

    # Build detail lines
    lines = String[]
    push!(lines, "Status:   $(r.success ? "✓ Success" : "✗ Failed")")
    push!(lines, "Duration: $(r.duration_str)")
    push!(lines, "Time:     $(Dates.format(r.timestamp, "HH:MM:SS"))")
    # Show session routing info if present
    if !isempty(r.session_key) && BRIDGE_CONN_MGR[] !== nothing
        conn = get_connection_by_key(BRIDGE_CONN_MGR[], r.session_key)
        session_label =
            conn !== nothing ? "$(conn.name) ($(short_key(conn)))" : r.session_key
        push!(lines, "Session:  $session_label")
    end
    push!(lines, "")
    push!(lines, "── Arguments ──")
    # Pretty-print JSON args (one key per line)
    try
        args_dict = JSON.parse(r.args_json)
        for (k, v) in args_dict
            val_str = if v isa AbstractString
                repr(v)
            else
                JSON.json(v)
            end
            push!(lines, "  $k: $val_str")
        end
    catch
        push!(lines, "  $(r.args_json)")
    end
    push!(lines, "")
    push!(lines, "── Result ──")
    for ln in split(r.result_text, '\n')
        push!(lines, "  " * string(ln))
    end

    # Apply scroll and render
    max_w = di.width - 2
    visible = bottom(di) - di.y + 1
    offset = min(m.result_scroll, max(0, length(lines) - visible))
    m.result_scroll = offset  # clamp

    y = di.y
    for i = (offset+1):length(lines)
        y > bottom(di) && break
        line = lines[i]
        if length(line) > max_w && max_w > 1
            line = first(line, max_w - 1) * "…"
        end
        style = if startswith(lines[i], "──")
            tstyle(:text_dim)
        elseif startswith(lines[i], "Status:") && r.success
            tstyle(:success)
        elseif startswith(lines[i], "Status:")
            tstyle(:error)
        else
            tstyle(:text)
        end
        set_string!(buf, di.x + 1, y, line, style)
        y += 1
    end

    # Render the draggable divider between panes
    render_resize_handles!(buf, m.activity_layout)
end

# ── Server Tab ────────────────────────────────────────────────────────────────

function view_server(m::MCPReplModel, area::Rect, buf::Buffer)
    rows = tsplit(Layout(Vertical, [Fixed(9), Fill()]), area)
    length(rows) < 2 && return

    # ── Top: Server status panel ──
    status_block = Block(
        title = " Server Status ",
        border_style = tstyle(:border),
        title_style = tstyle(:text_dim),
    )
    si = render(status_block, rows[1], buf)
    if si.width >= 4
        y = si.y
        x = si.x + 1

        status_icon = if m.server_running
            "●"
        elseif m.server_started
            "○"
        else
            "◌"
        end
        status_text = if m.server_running
            "running"
        elseif m.server_started
            "stopped"
        else
            "starting…"
        end
        status_style = m.server_running ? tstyle(:success) : tstyle(:error)

        set_string!(buf, x, y, "$status_icon ", status_style)
        set_string!(buf, x + 2, y, "MCP Server", tstyle(:text))
        y += 1
        set_string!(buf, x, y, rpad("Port", 14), tstyle(:text_dim))
        set_string!(buf, x + 14, y, string(m.server_port), tstyle(:text))
        y += 1
        set_string!(buf, x, y, rpad("Status", 14), tstyle(:text_dim))
        set_string!(buf, x + 14, y, status_text, status_style)
        y += 1
        n_conns = m.conn_mgr !== nothing ? length(connected_sessions(m.conn_mgr)) : 0
        set_string!(buf, x, y, rpad("Bridge", 14), tstyle(:text_dim))
        set_string!(buf, x + 14, y, "$n_conns REPL sessions", tstyle(:text))
        y += 1
        set_string!(buf, x, y, rpad("Uptime", 14), tstyle(:text_dim))
        set_string!(buf, x + 14, y, format_uptime(time() - m.start_time), tstyle(:text))
        y += 1
        set_string!(buf, x, y, rpad("Tool Calls", 14), tstyle(:text_dim))
        set_string!(buf, x + 14, y, string(m.total_tool_calls), tstyle(:text))
    end

    # ── Bottom: Server log ──
    log_block = Block(
        title = " Server Log ($(length(m.server_log))) ",
        border_style = tstyle(:border),
        title_style = tstyle(:text_dim),
    )
    log_inner = render(log_block, rows[2], buf)
    log_inner.width < 4 && return

    if isempty(m.server_log)
        set_string!(
            buf,
            log_inner.x + 1,
            log_inner.y,
            "No log entries yet",
            tstyle(:text_dim),
        )
        return
    end

    y = log_inner.y
    x = log_inner.x + 1
    visible = log_inner.height
    start_idx = max(1, length(m.server_log) - visible + 1)
    for i = length(m.server_log):-1:start_idx
        y > bottom(log_inner) && break
        entry = m.server_log[i]
        time_str = Dates.format(entry.timestamp, "HH:MM:SS")
        level_str = rpad(string(entry.level), 5)
        level_style = if entry.level == :error
            tstyle(:error)
        elseif entry.level == :warn
            tstyle(:warning)
        else
            tstyle(:text_dim)
        end

        set_string!(buf, x, y, time_str, tstyle(:text_dim))
        set_string!(buf, x + 9, y, level_str, level_style)
        # Truncate message to fit available width
        max_msg = log_inner.width - 16
        msg = entry.message
        if length(msg) > max_msg
            msg = first(msg, max_msg - 1) * "…"
        end
        set_string!(buf, x + 15, y, msg, tstyle(:text))
        y += 1
    end
end

# ── Config Tab ────────────────────────────────────────────────────────────────

function view_config(m::MCPReplModel, area::Rect, buf::Buffer)
    view_config_base(m, area, buf)
    if m.config_flow != FLOW_IDLE
        view_config_flow(m, area, buf)
    end
end

function view_config_base(m::MCPReplModel, area::Rect, buf::Buffer)
    cols = tsplit(Layout(Horizontal, [Percent(50), Fill()]), area)
    length(cols) < 2 && return

    # ── Left column: Server + Actions ──
    left_rows = tsplit(Layout(Vertical, [Fixed(8), Fill()]), cols[1])
    length(left_rows) < 2 && return

    # Server info
    srv_block = Block(
        title = " Server ",
        border_style = tstyle(:border),
        title_style = tstyle(:text_dim),
    )
    srv = render(srv_block, left_rows[1], buf)
    if srv.width >= 4
        y = srv.y
        x = srv.x + 1
        n_conns = m.conn_mgr !== nothing ? length(connected_sessions(m.conn_mgr)) : 0
        status_icon = m.server_running ? "●" : "○"
        status_style = m.server_running ? tstyle(:success) : tstyle(:error)
        set_string!(buf, x, y, "$status_icon ", status_style)
        set_string!(buf, x + 2, y, "Port $(m.server_port)", tstyle(:text))
        y += 1
        set_string!(buf, x, y, rpad("Status", 14), tstyle(:text_dim))
        set_string!(buf, x + 14, y, m.server_running ? "running" : "stopped", status_style)
        y += 1
        set_string!(buf, x, y, rpad("Sessions", 14), tstyle(:text_dim))
        set_string!(buf, x + 14, y, "$n_conns connected", tstyle(:text))
        y += 1
        set_string!(buf, x, y, rpad("Tool Calls", 14), tstyle(:text_dim))
        set_string!(buf, x + 14, y, string(m.total_tool_calls), tstyle(:text))
        y += 1
        set_string!(buf, x, y, rpad("Socket Dir", 14), tstyle(:text_dim))
        set_string!(buf, x + 14, y, "~/.cache/mcprepl/sock", tstyle(:text))
    end

    # Actions
    act_block = Block(
        title = " Actions ",
        border_style = tstyle(:accent),
        title_style = tstyle(:accent),
    )
    act = render(act_block, left_rows[2], buf)
    if act.width >= 4
        y = act.y
        x = act.x + 1
        set_string!(buf, x, y, "[a]", tstyle(:accent, bold = true))
        set_string!(buf, x + 4, y, "Add project (bridge setup)", tstyle(:text))
        y += 1
        set_string!(buf, x, y, "[c]", tstyle(:accent, bold = true))
        set_string!(buf, x + 4, y, "Configure MCP client", tstyle(:text))
    end

    # ── Right column: MCP Client Status ──
    client_block = Block(
        title = " MCP Clients ",
        border_style = tstyle(:border),
        title_style = tstyle(:text_dim),
    )
    client_inner = render(client_block, cols[2], buf)
    client_inner.width < 4 && return

    y = client_inner.y
    x = client_inner.x + 1

    for (label, configured) in m.client_statuses
        y > bottom(client_inner) && break
        icon = configured ? "●" : "○"
        icon_style = configured ? tstyle(:success) : tstyle(:text_dim)
        status_text = configured ? "configured" : "not configured"
        set_string!(buf, x, y, "$icon ", icon_style)
        set_string!(buf, x + 2, y, rpad(label, 16), tstyle(:text))
        set_string!(buf, x + 18, y, status_text, icon_style)
        y += 1
    end

    y += 1
    if y + 2 <= bottom(client_inner)
        set_string!(buf, x, y, "Press [c] to configure a client", tstyle(:text_dim))
    end
end

# ── Config Flow Overlay ──────────────────────────────────────────────────────

function view_config_flow(m::MCPReplModel, area::Rect, buf::Buffer)
    flow = m.config_flow

    # Dim background
    _dim_area!(buf, area)

    if flow == FLOW_ONBOARD_PATH
        _render_text_input_modal(
            buf,
            area,
            " Add Project ",
            "Enter project path:",
            m.path_input,
            "[Enter] confirm  [Esc] cancel",
        )

    elseif flow == FLOW_ONBOARD_SCOPE
        _render_selection_modal(
            buf,
            area,
            " Scope ",
            SCOPE_LABELS,
            m.flow_selected,
            "[↑↓] select  [Enter] confirm  [Esc] cancel",
        )

    elseif flow == FLOW_ONBOARD_CONFIRM
        scope_label = m.onboard_scope == :project ? "project-level" : "user-level (global)"
        msg = "Install bridge snippet?\n\nPath: $(_short_path(m.onboard_path))\nScope: $scope_label"
        render(
            Modal(
                title = "Confirm Setup",
                message = msg,
                confirm_label = "Install",
                cancel_label = "Cancel",
                selected = m.flow_modal_selected,
            ),
            area,
            buf,
        )

    elseif flow == FLOW_ONBOARD_RESULT
        _render_result_modal(buf, area, m.flow_success, m.flow_message)

    elseif flow == FLOW_CLIENT_SELECT
        _render_selection_modal(
            buf,
            area,
            " Select Client ",
            CLIENT_LABELS,
            m.flow_selected,
            "[↑↓] select  [Enter] confirm  [Esc] cancel",
        )

    elseif flow == FLOW_CLIENT_SCOPE
        _render_selection_modal(
            buf,
            area,
            " Scope ",
            SCOPE_LABELS,
            m.flow_selected,
            "[↑↓] select  [Enter] confirm  [Esc] cancel",
        )

    elseif flow == FLOW_CLIENT_PATH
        client_label = CLIENT_LABELS[findfirst(==(m.client_target), CLIENT_OPTIONS)]
        _render_text_input_modal(
            buf,
            area,
            " $client_label ",
            "Enter project path:",
            m.path_input,
            "[Enter] confirm  [Esc] cancel",
        )

    elseif flow == FLOW_CLIENT_CONFIRM
        client_label = CLIENT_LABELS[findfirst(==(m.client_target), CLIENT_OPTIONS)]
        scope_label = m.client_scope == :project ? "project-level" : "user-level (global)"
        path_info =
            m.client_scope == :project ? "\nPath: $(_short_path(m.client_path))" : ""
        msg = "Configure $client_label?\n$path_info\nScope: $scope_label"
        render(
            Modal(
                title = "Confirm",
                message = msg,
                confirm_label = "Install",
                cancel_label = "Cancel",
                selected = m.flow_modal_selected,
            ),
            area,
            buf,
        )

    elseif flow == FLOW_CLIENT_RESULT
        _render_result_modal(buf, area, m.flow_success, m.flow_message)
    end
end

# ── Flow rendering helpers ───────────────────────────────────────────────────

function _dim_area!(buf::Buffer, area::Rect)
    for row = area.y:bottom(area)
        for col = area.x:right(area)
            set_char!(buf, col, row, ' ', tstyle(:text_dim))
        end
    end
end

function _render_text_input_modal(
    buf::Buffer,
    area::Rect,
    title::String,
    prompt::String,
    input,
    hint::String,
)
    w = min(60, area.width - 4)
    h = 7
    rect = center(area, w, h)

    block = Block(
        title = title,
        border_style = tstyle(:accent, bold = true),
        title_style = tstyle(:accent, bold = true),
        box = BOX_HEAVY,
    )
    inner = render(block, rect, buf)
    inner.width < 4 && return

    # Clear interior
    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style())
        end
    end

    y = inner.y
    x = inner.x + 1
    set_string!(buf, x, y, prompt, tstyle(:text))
    y += 1
    y += 1  # blank line
    render(input, Rect(x, y, inner.width - 2, 1), buf)
    y += 1
    y += 1
    set_string!(buf, x, y, hint, tstyle(:text_dim))
end

function _render_selection_modal(
    buf::Buffer,
    area::Rect,
    title::String,
    options::Vector{String},
    selected::Int,
    hint::String,
)
    w = min(50, area.width - 4)
    h = length(options) + 5
    rect = center(area, w, h)

    block = Block(
        title = title,
        border_style = tstyle(:accent, bold = true),
        title_style = tstyle(:accent, bold = true),
        box = BOX_HEAVY,
    )
    inner = render(block, rect, buf)
    inner.width < 4 && return

    # Clear interior
    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style())
        end
    end

    y = inner.y
    x = inner.x + 1
    for (i, label) in enumerate(options)
        y > bottom(inner) - 2 && break
        marker = i == selected ? "▸ " : "  "
        style = i == selected ? tstyle(:accent, bold = true) : tstyle(:text)
        set_string!(buf, x, y, marker * label, style)
        y += 1
    end
    y += 1
    if y <= bottom(inner)
        set_string!(buf, x, y, hint, tstyle(:text_dim))
    end
end

function _render_result_modal(buf::Buffer, area::Rect, success::Bool, message::String)
    lines = Base.split(message, '\n')
    w = min(max(maximum(length.(lines); init = 20) + 6, 30), area.width - 4)
    h = length(lines) + 5
    rect = center(area, w, h)

    border_style = success ? tstyle(:success, bold = true) : tstyle(:error, bold = true)
    title = success ? " Success " : " Error "
    block = Block(
        title = title,
        border_style = border_style,
        title_style = border_style,
        box = BOX_HEAVY,
    )
    inner = render(block, rect, buf)
    inner.width < 4 && return

    # Clear interior
    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style())
        end
    end

    y = inner.y
    x = inner.x + 1
    text_style = success ? tstyle(:success) : tstyle(:error)
    for line in lines
        y > bottom(inner) - 2 && break
        set_string!(buf, x, y, String(line), text_style)
        y += 1
    end
    y += 1
    if y <= bottom(inner)
        set_string!(buf, x, y, "Press any key to close", tstyle(:text_dim))
    end
end

# ── Client Status Detection ──────────────────────────────────────────────────

# Client detection runs async; results land in model.client_statuses.
const _CLIENT_STATUS_PENDING = Ref{Bool}(false)

function _refresh_client_status_async!(m::MCPReplModel)
    _CLIENT_STATUS_PENDING[] && return   # already in flight
    _CLIENT_STATUS_PENDING[] = true
    Threads.@spawn begin
        try
            statuses = Pair{String,Bool}[]

            # Claude: check config files directly (don't shell out to `claude`
            # which would connect to our MCP server and create spurious sessions)
            claude_ok = false
            for cfg_path in (
                joinpath(homedir(), ".claude", "settings.json"),
                joinpath(pwd(), ".mcp.json"),
                joinpath(pwd(), ".claude", "settings.local.json"),
            )
                if isfile(cfg_path)
                    try
                        content = read(cfg_path, String)
                        if occursin("julia-repl", content)
                            claude_ok = true
                            break
                        end
                    catch
                    end
                end
            end
            push!(statuses, "Claude" => claude_ok)

            # VS Code: project-specific, can't detect globally
            push!(statuses, "VS Code" => false)

            # Gemini: check ~/.gemini/settings.json
            gemini_settings = joinpath(homedir(), ".gemini", "settings.json")
            gemini_ok = false
            if isfile(gemini_settings)
                try
                    content = read(gemini_settings, String)
                    gemini_ok = occursin("julia-repl", content)
                catch
                end
            end
            push!(statuses, "Gemini" => gemini_ok)

            # KiloCode: check ~/.kilocode/mcp.json
            kilo_settings = joinpath(homedir(), ".kilocode", "mcp.json")
            kilo_ok = false
            if isfile(kilo_settings)
                try
                    content = read(kilo_settings, String)
                    kilo_ok = occursin("julia-repl", content)
                catch
                end
            end
            push!(statuses, "KiloCode" => kilo_ok)

            m.client_statuses = statuses
        catch
        end
        _CLIENT_STATUS_PENDING[] = false
    end
end

# ── Helpers ───────────────────────────────────────────────────────────────────

function format_uptime(seconds::Float64)
    s = round(Int, seconds)
    if s < 60
        return "$(s)s"
    elseif s < 3600
        return "$(s ÷ 60)m $(s % 60)s"
    else
        h = s ÷ 3600
        m = (s % 3600) ÷ 60
        return "$(h)h $(m)m"
    end
end

function _complete_path!(input::TextInput)
    partial = expanduser(Tachikoma.text(input))
    isempty(partial) && return

    dir, prefix = if isdir(partial) && endswith(partial, '/')
        (partial, "")
    else
        (dirname(partial), basename(partial))
    end

    isdir(dir) || return
    entries = try
        filter(readdir(dir)) do name
            startswith(name, prefix) && isdir(joinpath(dir, name))
        end
    catch
        return
    end

    if length(entries) == 1
        completed = joinpath(dir, entries[1]) * "/"
        # Collapse home dir back to ~ if original used it
        if startswith(Tachikoma.text(input), "~")
            completed = replace(completed, homedir() => "~"; count = 1)
        end
        Tachikoma.set_text!(input, completed)
    elseif length(entries) > 1
        # Complete common prefix
        common = entries[1]
        for e in entries[2:end]
            i = 0
            for (a, b) in zip(common, e)
                a == b || break
                i += 1
            end
            common = common[1:i]
        end
        if length(common) > length(prefix)
            completed = joinpath(dir, common)
            if startswith(Tachikoma.text(input), "~")
                completed = replace(completed, homedir() => "~"; count = 1)
            end
            Tachikoma.set_text!(input, completed)
        end
    end
end

function _short_path(path::String)
    home = homedir()
    if startswith(path, home)
        return "~" * path[length(home)+1:end]
    end
    return path
end

function _time_ago(dt::DateTime)
    diff = now() - dt
    secs = round(Int, Dates.value(diff) / 1000)
    if secs < 60
        return "$(secs)s ago"
    elseif secs < 3600
        return "$(secs ÷ 60)m ago"
    else
        return "$(secs ÷ 3600)h $(secs % 3600 ÷ 60)m ago"
    end
end

# ── Session Reaping ───────────────────────────────────────────────────────────

"""Remove MCP agent sessions that have been idle longer than `max_idle_secs`."""
function _reap_stale_sessions!(max_idle_secs::Float64)
    cutoff = now() - Dates.Second(round(Int, max_idle_secs))
    reaped = lock(STANDALONE_SESSIONS_LOCK) do
        stale = String[]
        for (sid, sess) in STANDALONE_SESSIONS
            if sess.last_activity < cutoff
                push!(stale, sid)
            end
        end
        for sid in stale
            try
                close_session!(STANDALONE_SESSIONS[sid])
            catch
            end
            delete!(STANDALONE_SESSIONS, sid)
        end
        stale
    end
    # Also prune the persistence file so it doesn't grow unbounded
    if !isempty(reaped)
        try
            persisted = load_persisted_sessions()
            for sid in reaped
                delete!(persisted, sid)
            end
            save_persisted_sessions(persisted)
        catch
        end
    end
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    tui(; port=2828, theme=:kokaku)

Launch the MCPRepl TUI. This is a blocking call that takes over the terminal.

Starts the MCP HTTP server in a background task and watches for REPL bridge
connections in `~/.cache/mcprepl/sock/`.

# Arguments
- `port::Int=2828`: Port for the MCP HTTP server
- `theme::Symbol=:kokaku`: Tachikoma theme name
"""
function tui(; port::Int = 2828, theme_name::Symbol = :kokaku)
    if Threads.nthreads() < 2
        @warn """MCPRepl TUI running with only 1 thread — UI may be unresponsive.
                 Start Julia with: julia -t auto
                 Or set: JULIA_NUM_THREADS=auto"""
    end
    set_theme!(theme_name)
    model = MCPReplModel(server_port = port)
    app(model; fps = 15)
end
