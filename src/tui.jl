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
const _TUI_LOG_FILE = Ref{Union{IOStream,Nothing}}(nothing)

# stderr capture — prevent background code from corrupting the terminal
const _TUI_ORIG_STDERR = Ref{Any}(nothing)
const _TUI_STDERR_TASK = Ref{Union{Task,Nothing}}(nothing)
const _TUI_STDERR_RUNNING = Ref{Bool}(false)

const _TUI_LOG_PATH = joinpath(mcprepl_cache_dir(), "server.log")

function _open_log_file!()
    try
        mkpath(dirname(_TUI_LOG_PATH))
        _TUI_LOG_FILE[] = open(_TUI_LOG_PATH, "a")
    catch
        _TUI_LOG_FILE[] = nothing
    end
end

function _close_log_file!()
    io = _TUI_LOG_FILE[]
    _TUI_LOG_FILE[] = nothing
    io === nothing && return
    try
        close(io)
    catch
    end
end

function _write_log_entry(ts::DateTime, level::Symbol, msg::String)
    io = _TUI_LOG_FILE[]
    io === nothing && return
    try
        write(
            io,
            Dates.format(ts, "yyyy-mm-dd HH:MM:SS"),
            " [",
            uppercase(string(level)),
            "] ",
            msg,
            "\n",
        )
        flush(io)
    catch
    end
end

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
    ts = now()
    lock(_TUI_LOG_LOCK) do
        push!(_TUI_LOG_BUFFER, ServerLogEntry(ts, lvl, msg))
        while length(_TUI_LOG_BUFFER) > 500
            popfirst!(_TUI_LOG_BUFFER)
        end
    end
    _write_log_entry(ts, lvl, msg)
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
    ts = now()
    lock(_TUI_LOG_LOCK) do
        push!(_TUI_LOG_BUFFER, ServerLogEntry(ts, level, message))
    end
    _write_log_entry(ts, level, message)
end

# ── stderr capture ───────────────────────────────────────────────────────────
# Redirect stderr to a pipe so background code (HTTP.jl, etc.) can't write
# raw bytes to the terminal and corrupt the TUI display.

const _TUI_STDERR_WR = Ref{Any}(nothing)

function _start_stderr_capture!()
    _TUI_STDERR_RUNNING[] = true
    _TUI_ORIG_STDERR[] = stderr
    rd, wr = redirect_stderr()
    _TUI_STDERR_WR[] = wr
    _TUI_STDERR_TASK[] = @async begin
        try
            while _TUI_STDERR_RUNNING[]
                line = readline(rd; keep = false)
                isempty(line) && continue
                _push_log!(:warn, "stderr: $line")
            end
        catch e
            e isa EOFError && return
            e isa InterruptException && return
        finally
            try
                close(rd)
            catch
            end
        end
    end
end

function _stop_stderr_capture!()
    _TUI_STDERR_RUNNING[] = false
    # Restore original stderr first
    orig = _TUI_ORIG_STDERR[]
    if orig !== nothing
        try
            redirect_stderr(orig)
        catch
        end
        _TUI_ORIG_STDERR[] = nothing
    end
    # Close the pipe write end so the reader task gets EOF
    wr = _TUI_STDERR_WR[]
    if wr !== nothing
        try
            close(wr)
        catch
        end
        _TUI_STDERR_WR[] = nothing
    end
    task = _TUI_STDERR_TASK[]
    if task !== nothing && !istaskdone(task)
        try
            wait(task)
        catch
        end
    end
    _TUI_STDERR_TASK[] = nothing
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

const _LAST_TOOL_SUCCESS = Ref{Float64}(0.0)
const _LAST_TOOL_ERROR = Ref{Float64}(0.0)
const _ECG_NEW_COMPLETIONS = Ref{Int}(0)

function _push_tool_result!(r::ToolCallResult)
    lock(_TUI_TOOL_RESULTS_LOCK) do
        push!(_TUI_TOOL_RESULTS_BUFFER, r)
        while length(_TUI_TOOL_RESULTS_BUFFER) > 500
            popfirst!(_TUI_TOOL_RESULTS_BUFFER)
        end
    end
    # Update health gauge timestamps (thread-safe via Ref)
    t = time()
    if r.success
        _LAST_TOOL_SUCCESS[] = t
    else
        _LAST_TOOL_ERROR[] = t
    end
    _ECG_NEW_COMPLETIONS[] += 1
    # Persist to database (fire-and-forget)
    _persist_tool_call!(r)
end

"""Persist a tool call result to the SQLite analytics database."""
function _persist_tool_call!(r::ToolCallResult)
    db = Database.DB[]
    db === nothing && return
    try
        # Parse duration string back to ms
        dur_ms = if endswith(r.duration_str, "ms")
            parse(Float64, r.duration_str[1:end-2])
        elseif endswith(r.duration_str, "s")
            parse(Float64, r.duration_str[1:end-1]) * 1000.0
        else
            0.0
        end
        summary = length(r.result_text) > 500 ? r.result_text[1:500] : r.result_text
        Database.DBInterface.execute(
            db,
            """
    INSERT INTO tool_executions (
        session_key, request_id, tool_name, request_time,
        duration_ms, input_size, output_size, arguments,
        status, result_summary
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
""",
            (
                r.session_key,
                string(UUIDs.uuid4()),
                r.tool_name,
                Dates.format(r.timestamp, dateformat"yyyy-mm-dd HH:MM:SS"),
                dur_ms,
                sizeof(r.args_json),
                sizeof(r.result_text),
                r.args_json,
                r.success ? "success" : "error",
                summary,
            ),
        )
    catch e
        @debug "Failed to persist tool call" exception = (e, catch_backtrace())
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

# ── In-Flight Tool Calls (live progress) ─────────────────────────────────────
# Tracks tool calls that are currently executing, displayed at the top of the
# Activity tab with a live elapsed timer.

mutable struct InFlightToolCall
    id::Int                  # unique monotonic ID for pairing start/done
    timestamp::Float64       # time() when started (for elapsed calculation)
    timestamp_dt::DateTime   # DateTime for display
    tool_name::String
    args_json::String
    session_key::String
    last_progress::String    # most recent progress message
    progress_lines::Vector{String}  # all progress lines for detail view
end

const _TUI_INFLIGHT_BUFFER = Tuple{Symbol,InFlightToolCall}[]  # (:start/:done/:progress, call)
const _TUI_INFLIGHT_LOCK = ReentrantLock()
const _INFLIGHT_ID_COUNTER = Ref{Int}(0)

"""Push an in-flight start event. Returns the unique inflight ID."""
function _push_inflight_start!(
    tool_name::String,
    args_json::String,
    session_key::String,
)::Int
    lock(_TUI_INFLIGHT_LOCK) do
        _INFLIGHT_ID_COUNTER[] += 1
        id = _INFLIGHT_ID_COUNTER[]
        ifc = InFlightToolCall(
            id,
            time(),
            now(),
            tool_name,
            args_json,
            session_key,
            "",
            String[],
        )
        push!(_TUI_INFLIGHT_BUFFER, (:start, ifc))
        return id
    end
end

"""Push an in-flight progress event (SSE streaming updates)."""
function _push_inflight_progress!(id::Int, message::String)
    lock(_TUI_INFLIGHT_LOCK) do
        ifc = InFlightToolCall(id, 0.0, now(), "", "", "", message, String[])
        push!(_TUI_INFLIGHT_BUFFER, (:progress, ifc))
    end
end

"""Push an in-flight done event (tool finished executing)."""
function _push_inflight_done!(id::Int)
    lock(_TUI_INFLIGHT_LOCK) do
        ifc = InFlightToolCall(id, 0.0, now(), "", "", "", "", String[])
        push!(_TUI_INFLIGHT_BUFFER, (:done, ifc))
    end
end

"""Drain the in-flight buffer into the model's inflight_calls vector."""
function _drain_inflight_buffer!(dest::Vector{InFlightToolCall})
    lock(_TUI_INFLIGHT_LOCK) do
        for (kind, ifc) in _TUI_INFLIGHT_BUFFER
            if kind == :start
                push!(dest, ifc)
            elseif kind == :progress
                for existing in dest
                    if existing.id == ifc.id
                        existing.last_progress = ifc.last_progress
                        push!(existing.progress_lines, ifc.last_progress)
                        # Cap progress lines to avoid unbounded growth
                        while length(existing.progress_lines) > 200
                            popfirst!(existing.progress_lines)
                        end
                        break
                    end
                end
            elseif kind == :done
                idx = findfirst(x -> x.id == ifc.id, dest)
                idx !== nothing && deleteat!(dest, idx)
            end
        end
        empty!(_TUI_INFLIGHT_BUFFER)
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

# Modal flow states
@enum ConfigFlow begin
    FLOW_IDLE
    # Project onboarding
    FLOW_ONBOARD_PATH          # TextInput for project path
    FLOW_ONBOARD_SCOPE         # Choose project-level vs user-level
    FLOW_ONBOARD_CONFIRM       # Modal confirmation
    FLOW_ONBOARD_RESULT        # Success/failure feedback
    # MCP client config (user-level)
    FLOW_CLIENT_SELECT         # Choose client
    FLOW_CLIENT_CONFIRM        # Modal confirmation
    FLOW_CLIENT_RESULT         # Success/failure feedback
end

# Stress test state machine
@enum StressState STRESS_IDLE STRESS_RUNNING STRESS_COMPLETE STRESS_ERROR

# ── Model ─────────────────────────────────────────────────────────────────────

@kwdef mutable struct MCPReplModel <: Model
    quit::Bool = false
    shutting_down::Bool = false
    tick::Int = 0

    # Tabs: 1=Server, 2=Sessions, 3=Activity, 4=Config
    active_tab::Int = 1

    # REPL connections (managed by ConnectionManager)
    conn_mgr::Union{ConnectionManager,Nothing} = nothing
    selected_connection::Int = 1

    # Session tab layouts (resizable)
    sessions_layout::ResizableLayout = ResizableLayout(Horizontal, [Percent(45), Fill()])
    sessions_left_layout::ResizableLayout = ResizableLayout(Vertical, [Fill(), Percent(40)])

    # Server tab layout (resizable)
    server_layout::ResizableLayout = ResizableLayout(Vertical, [Fixed(9), Fill()])

    # Config tab layouts (resizable)
    config_layout::ResizableLayout = ResizableLayout(Horizontal, [Percent(50), Fill()])
    config_left_layout::ResizableLayout = ResizableLayout(Vertical, [Fixed(8), Fill()])

    # Activity feed — unified timeline of tool calls + streaming output
    activity_feed::Vector{ActivityEvent} = ActivityEvent[]
    recent_tool_calls::Vector{ToolCallRecord} = ToolCallRecord[]
    tool_call_history::Vector{Float64} = zeros(120)  # calls per second, last 2 min

    # Tool call results — inspectable from Activity tab
    tool_results::Vector{ToolCallResult} = ToolCallResult[]
    selected_result::Int = 0       # 0 = none, 1+ = index into tool_results (newest-first)
    result_scroll::Int = 0         # vertical scroll in detail panel
    activity_layout::ResizableLayout = ResizableLayout(Vertical, [Percent(35), Fill()])
    activity_filter::String = ""   # "" = all, or session_key to filter by
    result_word_wrap::Bool = true   # word wrap in detail panel
    detail_paragraph::Union{Paragraph,Nothing} = nothing  # cached for scroll state
    _detail_for_result::Int = -1   # which selected_result the paragraph was built for

    # In-flight tool calls — currently executing, shown at top of Activity list
    inflight_calls::Vector{InFlightToolCall} = InFlightToolCall[]
    selected_inflight::Int = 0     # 0 = none selected, 1+ = index into inflight_calls (newest-first)
    activity_follow::Bool = true   # follow mode: auto-select newest entry each frame

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
    client_target::Symbol = :claude
    bridge_mirror_repl::Bool = false

    # Flow result
    flow_message::String = ""
    flow_success::Bool = false

    # Client detection (populated async on tab switch)
    client_statuses::Vector{Pair{String,Bool}} = Pair{String,Bool}[]

    # Async task queue (Tachikoma pattern)
    _task_queue::TaskQueue = TaskQueue()

    # Database & analytics
    db_initialized::Bool = false
    activity_mode::Symbol = :live    # :live (current view) or :analytics (DB summary)
    analytics_cache::Any = nothing   # cached query results (NamedTuple or nothing)
    analytics_last_refresh::Float64 = 0.0

    # Dynamic health gauge timestamps
    last_tool_success::Float64 = 0.0    # time() of last successful tool call
    last_tool_error::Float64 = 0.0      # time() of last failed tool call

    # ECG heartbeat trace
    ecg_trace::Vector{Float64} = fill(0.5, 240)  # rolling Y-values, scrolls left each tick
    ecg_pending_blips::Int = 0                    # queued QRS complexes waiting to fire
    ecg_inject_countdown::Int = 0                 # countdown within current QRS injection
    ecg_last_ping_seen::DateTime = DateTime(0)    # latest last_ping we've consumed

    # Session reaping (wall-clock based, fps-independent)
    _last_reap_time::Float64 = time()

    # Background reindex: project_path → timestamp of last files_changed notification
    _reindex_pending::Dict{String,Float64} = Dict{String,Float64}()

    # Server log scroll pane
    log_pane::Union{ScrollPane,Nothing} = nothing
    log_word_wrap::Bool = false
    _log_pane_synced::Int = 0   # number of server_log entries already pushed to pane

    # Pane focus — which pane has keyboard focus on each tab
    # Tab 1: 1=status, 2=log | Tab 2: 1=bridges, 2=agents, 3=detail
    # Tab 3: 1=list, 2=detail | Tab 4: 1=server, 2=actions, 3=clients
    # Tab 5: 1=form, 2=output | Tab 6: 1=runs list, 2=results
    focused_pane::Dict{Int,Int} = Dict(1 => 2, 2 => 1, 3 => 1, 4 => 1, 5 => 1, 6 => 1)

    # ── Tests tab (tab 6) ──
    test_runs::Vector{TestRun} = TestRun[]
    selected_test_run::Int = 0             # 0 = none, 1+ = index into test_runs
    tests_layout::ResizableLayout = ResizableLayout(Horizontal, [Percent(35), Fill()])
    test_view_mode::Symbol = :results      # :results or :output (raw)
    test_follow::Bool = true               # follow mode: auto-select newest run
    test_output_pane::Union{ScrollPane,Nothing} = nothing
    _test_output_synced::Int = 0           # raw_output lines pushed to scroll pane

    # ── Advanced tab (stress test) ──
    stress_state::StressState = STRESS_IDLE
    stress_code::String = "sleep(3); 42"
    stress_agents::String = "5"
    stress_stagger::String = "0.0"
    stress_timeout::String = "30"
    stress_session_idx::Int = 1         # selected session index
    stress_field_idx::Int = 1           # which form field has focus (1-6, 6=Run)
    stress_editing::Bool = false        # true when a form field is in edit mode
    stress_code_area::Any = nothing     # TextArea widget, created on demand
    stress_output::Vector{String} = String[]
    stress_output_lock::ReentrantLock = ReentrantLock()
    stress_scroll_pane::Union{ScrollPane,Nothing} = nothing
    stress_horde_scroll::Int = 0        # vertical scroll offset for agent horde
    stress_process::Any = nothing       # process handle for kill
    stress_result_file::String = ""     # path to written results
    advanced_layout::ResizableLayout = ResizableLayout(Vertical, [Fixed(14), Fill()])
end

# Number of focusable panes per tab
const _PANE_COUNTS = Dict(1 => 2, 2 => 3, 3 => 2, 4 => 3, 5 => 3, 6 => 2)

"""Return the border style for a pane — highlighted if focused."""
function _pane_border(m::MCPReplModel, tab::Int, pane::Int)
    focused = get(m.focused_pane, tab, 1) == pane
    focused ? tstyle(:accent) : tstyle(:border)
end

"""Return the title style for a pane — highlighted if focused."""
function _pane_title(m::MCPReplModel, tab::Int, pane::Int)
    focused = get(m.focused_pane, tab, 1) == pane
    focused ? tstyle(:accent, bold = true) : tstyle(:text_dim)
end

# ── Server Log Pane Helpers ───────────────────────────────────────────────────

function _log_entry_spans(entry::ServerLogEntry)
    time_str = Dates.format(entry.timestamp, "HH:MM:SS")
    level_str = rpad(string(entry.level), 5)
    level_style = if entry.level == :error
        tstyle(:error)
    elseif entry.level == :warn
        tstyle(:warning)
    else
        tstyle(:text_dim)
    end
    return Span[
        Span(time_str * " ", tstyle(:text_dim)),
        Span(level_str * " ", level_style),
        Span(entry.message, tstyle(:text)),
    ]
end

"""Build wrapped span lines for a single log entry. Prefix is "HH:MM:SS level " (15 chars)."""
function _log_entry_spans_wrapped(entry::ServerLogEntry, width::Int)
    time_str = Dates.format(entry.timestamp, "HH:MM:SS")
    level_str = rpad(string(entry.level), 5)
    level_style = if entry.level == :error
        tstyle(:error)
    elseif entry.level == :warn
        tstyle(:warning)
    else
        tstyle(:text_dim)
    end
    prefix_len = 15  # "HH:MM:SS level "
    msg = entry.message
    msg_width = max(10, width - prefix_len)
    lines = Vector{Span}[]
    if length(msg) <= msg_width
        push!(
            lines,
            Span[
                Span(time_str * " ", tstyle(:text_dim)),
                Span(level_str * " ", level_style),
                Span(msg, tstyle(:text)),
            ],
        )
    else
        # First line with prefix
        push!(
            lines,
            Span[
                Span(time_str * " ", tstyle(:text_dim)),
                Span(level_str * " ", level_style),
                Span(first(msg, msg_width), tstyle(:text)),
            ],
        )
        # Continuation lines indented to align with message
        rest = SubString(msg, nextind(msg, 0, msg_width + 1))
        indent = " "^prefix_len
        while !isempty(rest)
            chunk_len = min(length(rest), msg_width)
            push!(
                lines,
                Span[
                    Span(indent, tstyle(:text_dim)),
                    Span(first(rest, chunk_len), tstyle(:text)),
                ],
            )
            if chunk_len >= length(rest)
                break
            end
            rest = SubString(rest, nextind(rest, 0, chunk_len + 1))
        end
    end
    return lines
end

function _ensure_log_pane!(m::MCPReplModel)
    if m.log_pane === nothing
        m.log_pane = ScrollPane(
            Vector{Span}[];
            following = true,
            reverse = false,
            block = nothing,
            show_scrollbar = true,
        )
        m._log_pane_synced = 0
    end
end

"""Sync new server_log entries into the ScrollPane."""
function _sync_log_pane!(m::MCPReplModel, width::Int = 0)
    _ensure_log_pane!(m)
    pane = m.log_pane::ScrollPane
    n = length(m.server_log)
    if m._log_pane_synced > n
        # Log was truncated (ring buffer popfirst!), rebuild
        m._log_pane_synced = 0
        pane.content = Vector{Span}[]
    end
    for i = (m._log_pane_synced+1):n
        entry = m.server_log[i]
        if m.log_word_wrap && width > 0
            for line in _log_entry_spans_wrapped(entry, width)
                push_line!(pane, line)
            end
        else
            push_line!(pane, _log_entry_spans(entry))
        end
    end
    m._log_pane_synced = n
end

"""Rebuild the entire pane content (e.g. after toggling word wrap)."""
function _rebuild_log_pane!(m::MCPReplModel, width::Int = 0)
    _ensure_log_pane!(m)
    pane = m.log_pane::ScrollPane
    lines = Vector{Span}[]
    for entry in m.server_log
        if m.log_word_wrap && width > 0
            append!(lines, _log_entry_spans_wrapped(entry, width))
        else
            push!(lines, _log_entry_spans(entry))
        end
    end
    set_content!(pane, lines)
    m._log_pane_synced = length(m.server_log)
end

# ── Background Reindex (bridge → TUI files_changed notifications) ────────────

const REINDEX_DEBOUNCE_SECONDS = 2.0

"""
    _process_pending_reindexes!(m)

Check `_reindex_pending` for projects whose last notification is older than the
debounce window, and kick off a background sync for each.
"""
function _process_pending_reindexes!(m::MCPReplModel)
    isempty(m._reindex_pending) && return
    now_t = time()
    ready = String[]
    for (path, ts) in m._reindex_pending
        if now_t - ts >= REINDEX_DEBOUNCE_SECONDS
            push!(ready, path)
        end
    end
    for path in ready
        delete!(m._reindex_pending, path)
        _trigger_background_reindex(path)
    end
end

"""
    _trigger_background_reindex(project_path)

Async reindex: check that a Qdrant collection exists for this project, then
run `sync_index` silently. Results are logged to the TUI server log.
"""
function _trigger_background_reindex(project_path::String)
    # Skip if project_path is empty or would result in "default" collection
    if isempty(project_path) || project_path == "/"
        return
    end
    @async Logging.with_logger(TUILogger()) do
        try
            col_name = String(get_project_collection_name(project_path))
            if col_name == "default"
                return  # refuse to operate on a "default" collection
            end
            collections = QdrantClient.list_collections()
            if !(col_name in collections)
                return  # project not indexed — nothing to sync
            end
            result = sync_index(
                project_path;
                collection = col_name,
                verbose = false,
                silent = true,
            )
            if result.reindexed > 0 || result.deleted > 0
                _push_log!(
                    :info,
                    "Auto-reindex ($col_name): $(result.reindexed) reindexed, $(result.deleted) deleted, $(result.chunks) chunks",
                )
            end
        catch e
            _push_log!(:warn, "Auto-reindex failed: $(sprint(showerror, e))")
        end
    end
end

# ── Lifecycle ─────────────────────────────────────────────────────────────────

function Tachikoma.init!(m::MCPReplModel, _t::Tachikoma.Terminal)
    set_theme!(KOKAKU)

    # Open persistent log file
    _open_log_file!()

    # Redirect logging into the TUI ring buffer so @info/@warn from the MCP
    # server, HTTP.jl, etc. show up in the Server tab instead of on stderr.
    _TUI_OLD_LOGGER[] = global_logger()
    global_logger(TUILogger())

    # Capture stderr so background code can't corrupt the terminal
    _start_stderr_capture!()

    # Start connection manager (discovers REPL bridges)
    m.conn_mgr = ConnectionManager()
    start!(m.conn_mgr)
    register_sessions_changed_callback!(m.conn_mgr)
    m.bridge_mirror_repl = get_bridge_mirror_repl_preference()

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

    # Restore stderr before logger so logging can write to stderr again
    _stop_stderr_capture!()

    # Restore original logger so post-TUI Julia session isn't silenced
    if _TUI_OLD_LOGGER[] !== nothing
        global_logger(_TUI_OLD_LOGGER[])
        _TUI_OLD_LOGGER[] = nothing
    end

    # Close log file
    _close_log_file!()
end

Tachikoma.should_quit(m::MCPReplModel) = m.quit
Tachikoma.task_queue(m::MCPReplModel) = m._task_queue

# ── Update ────────────────────────────────────────────────────────────────────

function Tachikoma.update!(m::MCPReplModel, evt::MouseEvent)
    # Route mouse events to scroll panes and resizable layouts
    if m.active_tab == 1
        handle_resize!(m.server_layout, evt)
        m.log_pane !== nothing && handle_mouse!(m.log_pane, evt)
    elseif m.active_tab == 2
        handle_resize!(m.sessions_layout, evt)
        handle_resize!(m.sessions_left_layout, evt)
    elseif m.active_tab == 3
        handle_resize!(m.activity_layout, evt)
        m.detail_paragraph !== nothing && handle_mouse!(m.detail_paragraph, evt)
    elseif m.active_tab == 4
        handle_resize!(m.config_layout, evt)
        handle_resize!(m.config_left_layout, evt)
    elseif m.active_tab == 5
        handle_resize!(m.advanced_layout, evt)
        m.stress_scroll_pane !== nothing && handle_mouse!(m.stress_scroll_pane, evt)
    elseif m.active_tab == 6
        handle_resize!(m.tests_layout, evt)
        m.test_output_pane !== nothing && handle_mouse!(m.test_output_pane, evt)
    end
end

function Tachikoma.update!(m::MCPReplModel, evt::TaskEvent)
    if evt.id == :client_status
        # Merge a single client detection result into the statuses list
        name, detected = evt.value::Pair{String,Bool}
        idx = findfirst(p -> p.first == name, m.client_statuses)
        if idx !== nothing
            m.client_statuses[idx] = name => detected
        else
            push!(m.client_statuses, name => detected)
        end
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

    # When a stress test form field is in edit mode, capture all input
    if m.active_tab == 5 && m.stress_editing
        _handle_stress_field_edit!(m, evt)
        return
    end

    if evt.key == :char
        evt.char == 'q' && (m.shutting_down = true; return)
        # Tab switching: number keys + letter shortcuts
        evt.char == '1' && (_switch_tab!(m, 1); return)
        evt.char == '2' && (_switch_tab!(m, 2); return)
        evt.char == '3' && (_switch_tab!(m, 3); return)
        evt.char == '4' && (_switch_tab!(m, 4); return)
        evt.char == '5' && (_switch_tab!(m, 5); return)
        evt.char == '6' && (_switch_tab!(m, 6); return)
        evt.char == 's' && (_switch_tab!(m, 1); return)
        evt.char == 'e' && (_switch_tab!(m, 2); return)
        evt.char == 'a' && (_switch_tab!(m, 3); return)
        evt.char == 'c' && (_switch_tab!(m, 4); return)
        evt.char == 'v' && (_switch_tab!(m, 5); return)
        evt.char == 't' && (_switch_tab!(m, 6); return)
        # Server tab actions (tab 1)
        if m.active_tab == 1 && evt.char == 'w'
            m.log_word_wrap = !m.log_word_wrap
            _rebuild_log_pane!(m)
            return
        end
        # Activity tab actions (tab 3)
        if m.active_tab == 3
            if evt.char == 'f'
                m.activity_mode == :live && _cycle_activity_filter!(m)
                return
            elseif evt.char == 'F'
                m.activity_mode == :live && (m.activity_follow = !m.activity_follow)
                return
            elseif evt.char == 'w'
                m.activity_mode == :live && begin
                    m.result_word_wrap = !m.result_word_wrap
                    m._detail_for_result = -1  # invalidate cached paragraph
                end
                return
            elseif evt.char == 'd'
                # Toggle between live and analytics mode
                m.activity_mode = m.activity_mode == :live ? :analytics : :live
                if m.activity_mode == :analytics
                    _refresh_analytics!(m)
                end
                return
            elseif evt.char == 'r'
                # Force refresh analytics data
                if m.activity_mode == :analytics
                    _refresh_analytics!(m; force = true)
                end
                return
            end
        end
        # Config tab actions (tab 4)
        if m.active_tab == 4
            evt.char == 'o' && begin_onboarding!(m)
            evt.char == 'i' && begin_client_config!(m)
            evt.char == 'm' && toggle_bridge_mirror_repl!(m)
        end
        # Advanced tab actions (tab 5)
        if m.active_tab == 5
            _handle_stress_key!(m, evt)
            return
        end
        # Tests tab actions (tab 6)
        if m.active_tab == 6
            _handle_tests_key!(m, evt)
            return
        end
    elseif evt.key == :tab
        # Cycle focus between panes within the current tab
        tab = m.active_tab
        n_panes = get(_PANE_COUNTS, tab, 0)
        if n_panes > 1
            cur = get(m.focused_pane, tab, 1)
            m.focused_pane[tab] = mod1(cur + 1, n_panes)
        end
        return
    elseif evt.key == :backtab  # shift-tab: cycle backwards
        tab = m.active_tab
        n_panes = get(_PANE_COUNTS, tab, 0)
        if n_panes > 1
            cur = get(m.focused_pane, tab, 1)
            m.focused_pane[tab] = mod1(cur - 1, n_panes)
        end
        return
    elseif evt.key == :enter
        if m.active_tab == 5
            _handle_stress_enter!(m)
            return
        end
    elseif evt.key in (:left, :right)
        if m.active_tab == 5
            _handle_stress_arrow!(m, evt)
            return
        end
    elseif evt.key in (:up, :down, :pageup, :pagedown)
        _handle_scroll!(m, evt)
        return
    end
    # Escape on Advanced/Tests tab — cancel running ops, don't quit
    if evt.key == :escape
        if m.active_tab == 5
            if m.stress_state == STRESS_RUNNING
                _cancel_stress_test!(m)
            end
            return
        end
        if m.active_tab == 6
            _handle_tests_escape!(m)
            return
        end
        m.shutting_down = true
    end
end

function _handle_scroll!(m::MCPReplModel, evt::KeyEvent)
    tab = m.active_tab
    fp = get(m.focused_pane, tab, 1)

    if tab == 1
        # Pane 2 = log (only scrollable pane on server tab)
        if fp == 2 && m.log_pane !== nothing
            handle_key!(m.log_pane, evt)
        end
    elseif tab == 2
        if fp == 1
            # Bridges list
            if evt.key == :up
                m.selected_connection = max(1, m.selected_connection - 1)
            elseif evt.key == :down && m.conn_mgr !== nothing
                n = length(m.conn_mgr.connections)
                m.selected_connection = min(max(1, n), m.selected_connection + 1)
            end
            # Pane 2 (agents) and 3 (detail) — no scrolling yet
        end
    elseif tab == 3
        # Analytics mode doesn't use the live list navigation
        m.activity_mode == :analytics && return
        if fp == 1
            # Manual navigation disables follow mode
            m.activity_follow = false
            # Tool call list — navigate across in-flight + completed entries
            # Display order: in-flight reversed (newest first), then completed reversed (newest first)
            filter_key = m.activity_filter

            # Build filtered in-flight indices (display order: reversed)
            fi_indices = Int[]
            for i = 1:length(m.inflight_calls)
                if isempty(filter_key) || m.inflight_calls[i].session_key == filter_key
                    push!(fi_indices, i)
                end
            end
            reverse!(fi_indices)

            # Build filtered completed indices (display order: reversed)
            fc_indices = Int[]
            for i = 1:length(m.tool_results)
                if isempty(filter_key) || m.tool_results[i].session_key == filter_key
                    push!(fc_indices, i)
                end
            end
            reverse!(fc_indices)

            total = length(fi_indices) + length(fc_indices)
            if total > 0
                # Find current position in combined list
                cur = 0
                if m.selected_inflight > 0
                    pos = findfirst(==(m.selected_inflight), fi_indices)
                    if pos !== nothing
                        cur = pos
                    end
                elseif m.selected_result > 0
                    pos = findfirst(==(m.selected_result), fc_indices)
                    if pos !== nothing
                        cur = length(fi_indices) + pos
                    end
                end

                # Move selection
                new_pos = cur
                if evt.key == :up
                    new_pos = max(1, cur - 1)
                elseif evt.key == :down
                    new_pos = min(total, cur + 1)
                end
                if new_pos == 0
                    new_pos = 1
                end

                # Map position back to inflight or completed
                if new_pos <= length(fi_indices)
                    m.selected_inflight = fi_indices[new_pos]
                    m.selected_result = 0
                else
                    m.selected_inflight = 0
                    ci = new_pos - length(fi_indices)
                    m.selected_result = fc_indices[ci]
                end
            end
            m.result_scroll = 0
            m._detail_for_result = -1  # force rebuild of detail
        elseif fp == 2
            # Detail panel scroll — delegate to Paragraph widget
            if m.detail_paragraph !== nothing
                handle_key!(m.detail_paragraph, evt)
            end
        end
    elseif tab == 5
        if fp == 1
            # Navigate form fields (1-5 = fields, 6 = Run button)
            if evt.key == :up
                m.stress_field_idx = max(1, m.stress_field_idx - 1)
            elseif evt.key == :down
                m.stress_field_idx = min(6, m.stress_field_idx + 1)
            end
        elseif fp == 2
            # Scroll agent horde
            step = evt.key in (:pageup, :pagedown) ? 5 : 1
            if evt.key in (:up, :pageup)
                m.stress_horde_scroll = max(0, m.stress_horde_scroll - step)
            elseif evt.key in (:down, :pagedown)
                m.stress_horde_scroll += step
            end
        elseif fp == 3
            # Scroll log output pane
            m.stress_scroll_pane !== nothing && handle_key!(m.stress_scroll_pane, evt)
        end
    elseif tab == 6
        if fp == 1
            # Navigate test runs list (displayed newest-first / reversed)
            n = length(m.test_runs)
            if n > 0
                # Manual navigation disables follow mode
                m.test_follow = false
                if evt.key == :up
                    # Up in reversed list = increase index (toward newest)
                    m.selected_test_run = min(n, m.selected_test_run + 1)
                    m._test_output_synced = 0  # reset output pane
                    m.test_output_pane = nothing
                elseif evt.key == :down
                    # Down in reversed list = decrease index (toward oldest)
                    m.selected_test_run = max(1, m.selected_test_run - 1)
                    m._test_output_synced = 0
                    m.test_output_pane = nothing
                end
            end
        elseif fp == 2
            # Scroll results/output pane
            m.test_output_pane !== nothing && handle_key!(m.test_output_pane, evt)
        end
    end
end

# ── Tab switching ────────────────────────────────────────────────────────────

function _switch_tab!(m::MCPReplModel, tab::Int)
    m.active_tab = tab
    # Trigger async client detection when entering the Config tab
    if tab == 4
        _refresh_client_status_async!(m)
    end
end

# ── Config Flow: Begin ───────────────────────────────────────────────────────

function begin_onboarding!(m::MCPReplModel)
    m.config_flow = FLOW_ONBOARD_PATH
    m.path_input = TextInput(text = string(pwd()), label = "Path: ", tick = m.tick)
    m.flow_selected = 1
    m.flow_modal_selected = :confirm
end

function begin_client_config!(m::MCPReplModel)
    m.config_flow = FLOW_CLIENT_SELECT
    m.flow_selected = 1
    m.flow_modal_selected = :confirm
end

# ── Config Flow: Input Handler ───────────────────────────────────────────────

const CLIENT_OPTIONS = [:claude, :gemini, :codex, :copilot, :vscode, :kilo]
const CLIENT_LABELS = [
    "Claude Code",
    "Gemini CLI",
    "OpenAI Codex",
    "GitHub Copilot",
    "VS Code / Copilot",
    "KiloCode",
]
const SCOPE_LABELS = ["Project-level", "User-level (global)"]  # used by onboarding flow

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
            m.flow_modal_selected = :confirm
            m.config_flow = FLOW_CLIENT_CONFIRM
        end

        # ── Client confirm ──
    elseif flow == FLOW_CLIENT_CONFIRM
        if evt.key == :enter
            execute_client_config!(m)
        elseif evt.char == 'r'
            client_label = CLIENT_LABELS[findfirst(==(m.client_target), CLIENT_OPTIONS)]
            configured = any(p -> p.first == client_label && p.second, m.client_statuses)
            configured && remove_client_config!(m)
        end

        # ── Client result ──
    elseif flow == FLOW_CLIENT_RESULT
        m.config_flow = FLOW_IDLE
        # Refresh client statuses so the Config panel reflects the change
        _refresh_client_status_async!(m)
    end
end

# ── Config Flow: Execution ───────────────────────────────────────────────────

function execute_onboarding!(m::MCPReplModel)
    try
        path = rstrip(expanduser(m.onboard_path), ['/', '\\'])
        if m.onboard_scope == :project
            # Write .julia-startup.jl in the project directory
            isdir(path) || mkpath(path)
            startup_file = joinpath(path, ".julia-startup.jl")
            content = Generate.render_template("julia-startup.jl")
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
                block = "\n" * Generate.render_template("julia-startup.jl")
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

"""Get the first API key from security config, or `nothing` if lax/unconfigured."""
function _get_api_key()
    cfg = load_global_security_config()
    cfg === nothing && return nothing
    cfg.mode == :lax && return nothing
    isempty(cfg.api_keys) && return nothing
    return first(cfg.api_keys)
end

function execute_client_config!(m::MCPReplModel)
    try
        port = m.server_port
        target = m.client_target
        api_key = _get_api_key()

        if target == :claude
            _install_claude(m, port, api_key)
        elseif target == :gemini
            _install_gemini(m, port, api_key)
        elseif target == :codex
            _install_codex(m, port, api_key)
        elseif target == :copilot
            _install_copilot(m, port, api_key)
        elseif target == :vscode
            _install_vscode(m, port, api_key)
        elseif target == :kilo
            _install_kilo(m, port, api_key)
        end
    catch e
        m.flow_message = "Error: $(sprint(showerror, e))"
        m.flow_success = false
    end
    m.config_flow = FLOW_CLIENT_RESULT
end

function toggle_bridge_mirror_repl!(m::MCPReplModel)
    new_value = !m.bridge_mirror_repl
    m.bridge_mirror_repl = set_bridge_mirror_repl_preference!(new_value)

    applied = 0
    total = 0
    if m.conn_mgr !== nothing
        conns = connected_sessions(m.conn_mgr)
        total = length(conns)
        for conn in conns
            set_mirror_repl!(conn, m.bridge_mirror_repl) && (applied += 1)
        end
    end

    state = m.bridge_mirror_repl ? "enabled" : "disabled"
    _push_log!(
        :info,
        "Host REPL mirroring $state (applied to $applied/$total connected bridge sessions)",
    )
end

function remove_client_config!(m::MCPReplModel)
    try
        target = m.client_target
        if target == :claude
            _remove_claude(m)
        elseif target == :gemini
            _remove_gemini(m)
        elseif target == :codex
            _remove_codex(m)
        elseif target == :copilot
            _remove_copilot(m)
        elseif target == :vscode
            _remove_vscode(m)
        elseif target == :kilo
            _remove_kilo(m)
        end
    catch e
        m.flow_message = "Error: $(sprint(showerror, e))"
        m.flow_success = false
    end
    m.config_flow = FLOW_CLIENT_RESULT
end

# ── Remove helpers ────────────────────────────────────────────────────────────

function _remove_claude(m::MCPReplModel)
    try
        read(
            pipeline(`claude mcp remove --scope user julia-repl`; stderr = devnull),
            String,
        )
    catch
    end
    m.flow_message = "Removed julia-repl from Claude Code"
    m.flow_success = true
end

function _remove_gemini(m::MCPReplModel)
    try
        read(
            pipeline(`gemini mcp remove --scope user julia-repl`; stderr = devnull),
            String,
        )
    catch
    end
    m.flow_message = "Removed julia-repl from Gemini CLI"
    m.flow_success = true
end

function _remove_codex(m::MCPReplModel)
    try
        read(pipeline(`codex mcp remove julia-repl`; stderr = devnull), String)
    catch
    end
    _codex_env_remove!("MCPREPL_API_KEY")
    m.flow_message = "Removed julia-repl from Codex CLI"
    m.flow_success = true
end

function _remove_copilot(m::MCPReplModel)
    target_file = joinpath(homedir(), ".copilot", "mcp-config.json")
    _remove_server_from_json!(target_file, "mcpServers")
    m.flow_message = "Removed julia-repl from\n$(_short_path(target_file))"
    m.flow_success = true
end

function _remove_vscode(m::MCPReplModel)
    mcp_dir = if Sys.isapple()
        joinpath(homedir(), "Library", "Application Support", "Code", "User")
    elseif Sys.iswindows()
        joinpath(get(ENV, "APPDATA", joinpath(homedir(), "AppData", "Roaming")), "Code", "User")
    else
        joinpath(get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")), "Code", "User")
    end
    target_file = joinpath(mcp_dir, "mcp.json")
    _remove_server_from_json!(target_file, "servers")
    m.flow_message = "Removed julia-repl from\n$(_short_path(target_file))"
    m.flow_success = true
end

function _remove_kilo(m::MCPReplModel)
    target_file = joinpath(_kilo_settings_dir(), "mcp_settings.json")
    _remove_server_from_json!(target_file, "mcpServers")
    m.flow_message = "Removed julia-repl from\n$(_short_path(target_file))"
    m.flow_success = true
end

"""Remove `julia-repl` from a JSON config file under the given servers key."""
function _remove_server_from_json!(path::String, servers_key::String)
    isfile(path) || error("Config file not found: $path")
    data = JSON.parsefile(path)
    servers = get(data, servers_key, nothing)
    servers === nothing && error("No $servers_key section in $path")
    haskey(servers, "julia-repl") || error("julia-repl not found in $path")
    delete!(servers, "julia-repl")
    data[servers_key] = servers
    write(path, _to_json(data))
end

"""Set or update `key=value` in `~/.codex/.env`, preserving other lines."""
function _codex_env_set!(key::String, value::String)
    env_file = joinpath(homedir(), ".codex", ".env")
    lines = isfile(env_file) ? readlines(env_file) : String[]
    # Remove any existing line for this key
    filter!(l -> !startswith(l, "$key="), lines)
    push!(lines, "$key=$value")
    write(env_file, join(lines, "\n") * "\n")
end

"""Remove `key` from `~/.codex/.env`, preserving other lines."""
function _codex_env_remove!(key::String)
    env_file = joinpath(homedir(), ".codex", ".env")
    isfile(env_file) || return
    lines = readlines(env_file)
    filter!(l -> !startswith(l, "$key="), lines)
    if isempty(lines)
        rm(env_file)
    else
        write(env_file, join(lines, "\n") * "\n")
    end
end

# ── Install helpers ───────────────────────────────────────────────────────────

function _install_claude(m::MCPReplModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    try
        read(
            pipeline(`claude mcp remove --scope user julia-repl`; stderr = devnull),
            String,
        )
    catch
    end
    args = `claude mcp add --transport http --scope user julia-repl $url`
    if api_key !== nothing
        args = `$args -H "Authorization: Bearer $api_key"`
    end
    read(pipeline(args; stderr = stderr), String)
    m.flow_message = "Added julia-repl to Claude Code\n(scope: user)"
    m.flow_success = true
end

function _install_vscode(m::MCPReplModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    # VS Code user-level MCP config
    mcp_dir = if Sys.isapple()
        joinpath(homedir(), "Library", "Application Support", "Code", "User")
    elseif Sys.iswindows()
        joinpath(get(ENV, "APPDATA", joinpath(homedir(), "AppData", "Roaming")), "Code", "User")
    else
        joinpath(get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")), "Code", "User")
    end
    isdir(mcp_dir) || mkpath(mcp_dir)
    mcp_file = joinpath(mcp_dir, "mcp.json")

    # Merge with existing config to preserve other servers
    existing = if isfile(mcp_file)
        try
            JSON.parsefile(mcp_file)
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    servers = get(existing, "servers", Dict{String,Any}())
    entry = Dict{String,Any}("type" => "http", "url" => url)
    if api_key !== nothing
        entry["headers"] = Dict{String,Any}("Authorization" => "Bearer $api_key")
    end
    servers["julia-repl"] = entry
    existing["servers"] = servers
    write(mcp_file, _to_json(existing))
    m.flow_message = "Wrote $(_short_path(mcp_file))"
    m.flow_success = true
end

function _install_gemini(m::MCPReplModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    try
        read(
            pipeline(`gemini mcp remove --scope user julia-repl`; stderr = devnull),
            String,
        )
    catch
    end
    args = `gemini mcp add --transport http --scope user julia-repl $url`
    if api_key !== nothing
        args = `$args -H "Authorization: Bearer $api_key"`
    end
    read(pipeline(args; stderr = devnull), String)
    m.flow_message = "Added julia-repl to Gemini CLI\n(~/.gemini/settings.json)"
    m.flow_success = true
end

function _install_kilo(m::MCPReplModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    kilo_dir = _kilo_settings_dir()
    isdir(kilo_dir) || mkpath(kilo_dir)
    target_file = joinpath(kilo_dir, "mcp_settings.json")

    # Merge with existing config to preserve other servers
    existing = if isfile(target_file)
        try
            JSON.parsefile(target_file)
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    servers = get(existing, "mcpServers", Dict{String,Any}())
    entry = Dict{String,Any}("type" => "streamable-http", "url" => url)
    if api_key !== nothing
        entry["headers"] = Dict{String,Any}("Authorization" => "Bearer $api_key")
    end
    servers["julia-repl"] = entry
    existing["mcpServers"] = servers
    write(target_file, _to_json(existing))
    m.flow_message = "Wrote $(_short_path(target_file))"
    m.flow_success = true
end

function _install_codex(m::MCPReplModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    try
        read(pipeline(`codex mcp remove julia-repl`; stderr = devnull), String)
    catch
    end
    args = if api_key !== nothing
        `codex mcp add --url $url --bearer-token-env-var MCPREPL_API_KEY julia-repl`
    else
        `codex mcp add --url $url julia-repl`
    end
    read(pipeline(args; stderr = devnull), String)
    if api_key !== nothing
        _codex_env_set!("MCPREPL_API_KEY", api_key)
    end
    m.flow_message = "Added julia-repl to Codex CLI\n(~/.codex/config.toml)"
    m.flow_success = true
end

function _install_copilot(m::MCPReplModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    copilot_dir = joinpath(homedir(), ".copilot")
    isdir(copilot_dir) || mkpath(copilot_dir)
    target_file = joinpath(copilot_dir, "mcp-config.json")

    # Merge with existing config to preserve other servers
    existing = if isfile(target_file)
        try
            JSON.parsefile(target_file)
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    servers = get(existing, "mcpServers", Dict{String,Any}())
    entry = Dict{String,Any}("type" => "http", "url" => url)
    if api_key !== nothing
        entry["headers"] = Dict{String,Any}("Authorization" => "Bearer $api_key")
    end
    servers["julia-repl"] = entry
    existing["mcpServers"] = servers
    write(target_file, _to_json(existing))
    m.flow_message = "Wrote $(_short_path(target_file))"
    m.flow_success = true
end

# ── Minimal JSON helpers (no dependency on JSON3) ────────────────────────────

function _to_json(d::AbstractDict; indent::Int = 2)
    io = IOBuffer()
    _write_json(io, d, 0, indent)
    write(io, '\n')
    String(take!(io))
end

function _write_json(io::IO, d::AbstractDict, level::Int, indent::Int)
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
_write_json(io::IO, ::Nothing, ::Int, ::Int) = write(io, "null")

function _write_json(io::IO, arr::AbstractVector, level::Int, indent::Int)
    if isempty(arr)
        write(io, "[]")
        return
    end
    write(io, "[\n")
    for (i, v) in enumerate(arr)
        write(io, ' '^((level + 1) * indent))
        _write_json(io, v, level + 1, indent)
        i < length(arr) && write(io, ',')
        write(io, '\n')
    end
    write(io, ' '^(level * indent))
    write(io, ']')
end

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
    _advance_ecg!(m)
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

    # Sync health gauge timestamps from thread-safe Refs
    if _LAST_TOOL_SUCCESS[] > m.last_tool_success
        m.last_tool_success = _LAST_TOOL_SUCCESS[]
    end
    if _LAST_TOOL_ERROR[] > m.last_tool_error
        m.last_tool_error = _LAST_TOOL_ERROR[]
    end

    # Drain in-flight tool call events — track selected ID to detect index shifts
    _prev_sel_id =
        if m.selected_inflight > 0 && m.selected_inflight <= length(m.inflight_calls)
            m.inflight_calls[m.selected_inflight].id
        else
            -1
        end
    _drain_inflight_buffer!(m.inflight_calls)
    # Fix selected_inflight if deleteat! shifted indices under us
    if _prev_sel_id > 0
        new_idx = findfirst(x -> x.id == _prev_sel_id, m.inflight_calls)
        m.selected_inflight = new_idx === nothing ? 0 : new_idx
    end

    # Drain streaming REPL output from bridge SUB sockets
    if m.conn_mgr !== nothing
        for msg in drain_stream_messages!(m.conn_mgr)
            if msg.channel == "files_changed"
                m._reindex_pending[msg.data] = time()
            elseif msg.channel in ("eval_complete", "eval_error")
                # Async eval lifecycle messages — log but don't push to activity feed
                # (the tool handler already pushes tool_start/tool_done events)
                status = msg.channel == "eval_complete" ? "completed" : "error"
                _push_log!(:info, "Bridge eval $status ($(msg.session_name))")
            else
                kind = msg.channel == "stderr" ? :stderr : :stdout
                push!(
                    m.activity_feed,
                    ActivityEvent(now(), kind, "", msg.session_name, msg.data, true),
                )
            end
        end
        while length(m.activity_feed) > 2000
            popfirst!(m.activity_feed)
        end
        _process_pending_reindexes!(m)
    end

    # Reap stale MCP agent sessions every ~30s.
    # Sessions with no activity for 5 minutes are closed and removed.
    if time() - m._last_reap_time > 30.0
        _reap_stale_sessions!(300.0)  # 5 min threshold
        m._last_reap_time = time()
    end

    # Deferred server start — kick off on first frame so the TUI is already
    # rendering and can report startup status in the Server tab.
    if !m.server_started
        m.server_started = true

        # Initialize analytics database before server starts
        _push_log!(:info, "Initializing database...")
        try
            db_path = joinpath(mcprepl_cache_dir(), "mcprepl.db")
            Database.init_db!(db_path)
            m.db_initialized = true
            _push_log!(:info, "Database ready at $db_path")
        catch e
            _push_log!(:warning, "Database init failed: $(sprint(showerror, e))")
        end

        _push_log!(:info, "Starting MCP server on port $(m.server_port)...")
        Threads.@spawn try
            security_config = load_global_security_config()
            tools = collect_tools()
            m.mcp_server = start_mcp_server(
                tools,
                m.server_port;
                verbose = false,
                security_config = security_config,
            )
            m.server_running = true
            BRIDGE_PORT[] = m.server_port
            _push_log!(:info, "MCP server listening on port $(m.server_port)")

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
            [
                [Span("S", tstyle(:warning)), Span("erver", tstyle(:text))],
                [
                    Span("S", tstyle(:text)),
                    Span("e", tstyle(:warning)),
                    Span("ssions", tstyle(:text)),
                ],
                [Span("A", tstyle(:warning)), Span("ctivity", tstyle(:text))],
                [Span("C", tstyle(:warning)), Span("onfig", tstyle(:text))],
                [
                    Span("Ad", tstyle(:text)),
                    Span("v", tstyle(:warning)),
                    Span("anced", tstyle(:text)),
                ],
                [Span("T", tstyle(:warning)), Span("ests", tstyle(:text))],
            ];
            active = m.active_tab,
        ),
        tab_area,
        buf,
    )

    # ── Drain cross-thread buffers every frame (regardless of active tab) ──
    _drain_stress_output!(m)
    _drain_test_updates!(m.test_runs)

    # ── Content by tab ──
    if m.active_tab == 1
        view_server(m, content_area, buf)
    elseif m.active_tab == 2
        view_sessions(m, content_area, buf)
    elseif m.active_tab == 3
        view_activity(m, content_area, buf)
    elseif m.active_tab == 4
        view_config(m, content_area, buf)
    elseif m.active_tab == 5
        view_advanced(m, content_area, buf)
    elseif m.active_tab == 6
        # Follow mode: always snap to newest run
        if m.test_follow && !isempty(m.test_runs)
            m.selected_test_run = length(m.test_runs)
        elseif m.selected_test_run == 0 && !isempty(m.test_runs)
            m.selected_test_run = length(m.test_runs)
        end
        view_tests(m, content_area, buf)
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
                Span(" tab:focus [q]uit ", tstyle(:text_dim)),
            ],
        ),
        status_area,
        buf,
    )
end

# ── Sessions Tab (REPL bridges + MCP agents) ────────────────────────────────

function view_sessions(m::MCPReplModel, area::Rect, buf::Buffer)
    cols = split_layout(m.sessions_layout, area)
    length(cols) < 2 && return
    render_resize_handles!(buf, m.sessions_layout)

    # ── Left column: REPL bridges (top) + MCP agents (bottom) ──
    # Pull live MCP agent sessions
    agent_sessions = lock(STANDALONE_SESSIONS_LOCK) do
        collect(values(STANDALONE_SESSIONS))
    end
    filter!(s -> s.state == Session.INITIALIZED, agent_sessions)

    left_rows = split_layout(m.sessions_left_layout, cols[1])
    length(left_rows) < 2 && return
    render_resize_handles!(buf, m.sessions_left_layout)

    # ── REPL bridges list ──
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
        dname = isempty(conn.display_name) ? conn.name : conn.display_name
        label = "$icon $dname"
        padded = rpad(label, 20)
        status_text = string(conn.status)
        push!(items, ListItem("$padded $status_text", style))
    end

    if isempty(items)
        push!(items, ListItem("  No REPL sessions found", tstyle(:text_dim)))
        push!(items, ListItem("", tstyle(:text_dim)))
        push!(items, ListItem("  Start a bridge in your REPL:", tstyle(:text_dim)))
        push!(items, ListItem("  MCPReplBridge.serve()", tstyle(:accent)))
    end

    render(
        SelectableList(
            items;
            selected = m.selected_connection,
            block = Block(
                title = " REPL Bridges ($(length(connections))) ",
                border_style = _pane_border(m, 2, 1),
                title_style = _pane_title(m, 2, 1),
            ),
            highlight_style = tstyle(:accent, bold = true),
            tick = m.tick,
        ),
        left_rows[1],
        buf,
    )

    # ── MCP agents table ──
    if isempty(agent_sessions)
        agent_block = Block(
            title = " Agents ",
            border_style = _pane_border(m, 2, 2),
            title_style = _pane_title(m, 2, 2),
        )
        inner = render(agent_block, left_rows[2], buf)
        if inner.width >= 4
            set_string!(buf, inner.x + 1, inner.y, "No agents connected", tstyle(:text_dim))
        end
    else
        header = ["CLIENT", "SESSION", "ACTIVE"]
        rows = Vector{String}[]
        for s in agent_sessions
            client_name = get(s.client_info, "name", "unknown")
            push!(
                rows,
                [
                    string(client_name),
                    s.id[1:min(8, length(s.id))] * "…",
                    _time_ago(s.last_activity),
                ],
            )
        end
        render(
            Table(
                header,
                rows;
                block = Block(
                    title = " Agents ($(length(agent_sessions))) ",
                    border_style = _pane_border(m, 2, 2),
                    title_style = _pane_title(m, 2, 2),
                ),
            ),
            left_rows[2],
            buf,
        )
    end

    # ── Right: detail panel for selected bridge connection ──
    detail_block = Block(
        title = " Details ",
        border_style = _pane_border(m, 2, 3),
        title_style = _pane_title(m, 2, 3),
    )
    detail_area = render(detail_block, cols[2], buf)

    if !isempty(connections) && m.selected_connection <= length(connections)
        conn = connections[m.selected_connection]
        y = detail_area.y
        x = detail_area.x + 1

        dname = isempty(conn.display_name) ? conn.name : conn.display_name
        fields = [
            ("Name", dname),
            ("Status", string(conn.status)),
            ("Path", _short_path(conn.project_path)),
            ("Julia", conn.julia_version),
            ("PID", string(conn.pid)),
            ("Uptime", _time_ago(conn.connected_at)),
            ("Last seen", _time_ago(conn.last_seen)),
            ("Tool calls", string(conn.tool_call_count)),
            ("Session", conn.session_id[1:min(8, length(conn.session_id))] * "..."),
        ]

        for (label, value) in fields
            y > bottom(detail_area) && break
            set_string!(buf, x, y, "$(rpad(label, 12))", tstyle(:text_dim))
            set_string!(buf, x + 13, y, value, tstyle(:text))
            y += 1
        end

        # Health gauge (error-rate, per-session)
        conn_key = conn.session_id[1:min(8, length(conn.session_id))]
        y += 1
        if y + 1 <= bottom(detail_area)
            health, _ = _compute_health(m, conn_key)
            set_string!(buf, x, y, "Health", tstyle(:text_dim))
            y += 1
            gs =
                health >= 0.7 ? tstyle(:success) :
                health >= 0.3 ? tstyle(:warning) : tstyle(:error)
            render(
                Gauge(
                    health;
                    filled_style = gs,
                    empty_style = tstyle(:text_dim),
                    tick = m.tick,
                ),
                Rect(x, y, detail_area.width - 2, 1),
                buf,
            )
            y += 1
        end

        # ECG heartbeat
        y += 1
        ecg_h = 3
        ecg_w = detail_area.width - 2
        if y + ecg_h <= bottom(detail_area) && ecg_w >= 10
            set_string!(buf, x, y, "Heartbeat", tstyle(:text_dim))
            y += 1
            _render_ecg_trace(m, Rect(x, y, ecg_w, ecg_h), buf, conn_key)
            y += ecg_h
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

const _QRS_WAVEFORM = Float64[
    0.5,
    0.45,
    0.55,
    0.5,   # P-wave
    0.35,                     # Q dip
    0.95,                     # R peak (sharp spike)
    0.1,                      # S trough
    0.5,
    0.55,
    0.6,
    0.55,
    0.5,  # T-wave + return to baseline
]

function _advance_ecg!(m::MCPReplModel)
    new = _ECG_NEW_COMPLETIONS[]
    if new > 0
        _ECG_NEW_COMPLETIONS[] = 0
        m.ecg_pending_blips += new
    end
    # Heartbeat from bridge health-check pings — one blip per new ping
    if m.conn_mgr !== nothing
        latest = lock(m.conn_mgr.lock) do
            foldl((acc, c) -> max(acc, c.last_ping), m.conn_mgr.connections; init = DateTime(0))
        end
        if latest > m.ecg_last_ping_seen
            m.ecg_pending_blips += 1
            m.ecg_last_ping_seen = latest
        end
    end
    if m.ecg_inject_countdown <= 0 && m.ecg_pending_blips > 0
        m.ecg_inject_countdown = length(_QRS_WAVEFORM)
        m.ecg_pending_blips -= 1
    end
    # Scroll left
    trace = m.ecg_trace
    for i = 1:(length(trace)-1)
        trace[i] = trace[i+1]
    end
    # New rightmost value
    if m.ecg_inject_countdown > 0
        idx = length(_QRS_WAVEFORM) - m.ecg_inject_countdown + 1
        trace[end] = _QRS_WAVEFORM[idx]
        m.ecg_inject_countdown -= 1
    else
        trace[end] = 0.5
    end
end

function _render_ecg_trace(m::MCPReplModel, rect::Rect, buf::Buffer, key::String = "")
    w, h = rect.width, rect.height
    (w < 2 || h < 1) && return

    health, _ = _compute_health(m, key)
    style =
        health >= 0.7 ? tstyle(:success) : health >= 0.3 ? tstyle(:warning) : tstyle(:error)

    c = SixelCanvas(w, h; style = style)
    dot_w = w * 2
    dot_h = h * 4
    trace = m.ecg_trace
    n = length(trace)
    start_idx = max(1, n - dot_w + 1)

    prev_dx, prev_dy = -1, -1
    for dx = 0:(dot_w-1)
        tidx = start_idx + dx
        val = (tidx >= 1 && tidx <= n) ? trace[tidx] : 0.5
        dy = round(Int, (1.0 - clamp(val, 0.0, 1.0)) * (dot_h - 1))
        dy = clamp(dy, 0, dot_h - 1)
        set_point!(c, dx, dy)
        prev_dx >= 0 && line!(c, prev_dx, prev_dy, dx, dy)
        prev_dx, prev_dy = dx, dy
    end
    render(c, rect, buf)
end

"""Compute error-rate health from recent tool results. Returns (health, has_data).
When `key` is non-empty, only results matching that session key are counted."""
function _compute_health(m::MCPReplModel, key::String = "")::Tuple{Float64,Bool}
    results = m.tool_results
    if isempty(key)
        isempty(results) && return (1.0, false)
        n = min(50, length(results))
        recent = @view results[(end-n+1):end]
        errors = count(r -> !r.success, recent)
        return (1.0 - errors / n, true)
    else
        # Filter to this session's results, take last 50
        matched = 0
        errors = 0
        for i = length(results):-1:1
            r = results[i]
            r.session_key == key || continue
            matched += 1
            r.success || (errors += 1)
            matched >= 50 && break
        end
        matched == 0 && return (1.0, false)
        return (1.0 - errors / matched, true)
    end
end

# ── Activity Tab ──────────────────────────────────────────────────────────────

"""Cycle activity filter: All → session1 → session2 → … → All."""
function _cycle_activity_filter!(m::MCPReplModel)
    # Collect unique session keys from both in-flight and completed results
    seen_keys = String[]
    for ifc in m.inflight_calls
        if !isempty(ifc.session_key) && ifc.session_key ∉ seen_keys
            push!(seen_keys, ifc.session_key)
        end
    end
    for r in m.tool_results
        if !isempty(r.session_key) && r.session_key ∉ seen_keys
            push!(seen_keys, r.session_key)
        end
    end

    # Also pull session keys from active connections (even if no calls yet)
    mgr = m.conn_mgr
    if mgr !== nothing
        for conn in mgr.connections
            sk = short_key(conn)
            if !isempty(sk) && sk ∉ seen_keys
                push!(seen_keys, sk)
            end
        end
    end
    isempty(seen_keys) && return

    # Build cycle: "" (all) → key1 → key2 → … → "" (all)
    if isempty(m.activity_filter)
        m.activity_filter = seen_keys[1]
    else
        idx = findfirst(==(m.activity_filter), seen_keys)
        if idx === nothing || idx == length(seen_keys)
            m.activity_filter = ""  # back to all
        else
            m.activity_filter = seen_keys[idx+1]
        end
    end
    # Reset selection when filter changes
    m.selected_result = 0
    m.selected_inflight = 0
    m._detail_for_result = -1
end

"""Resolve a session_key to a short display name (e.g. "rEVAlation")."""
function _session_display_name(session_key::String)::String
    isempty(session_key) && return ""
    mgr = BRIDGE_CONN_MGR[]
    mgr === nothing && return session_key
    conn = get_connection_by_key(mgr, session_key)
    conn === nothing && return session_key
    return isempty(conn.display_name) ? conn.name : conn.display_name
end

"""Refresh analytics data from the database (cached for 30s unless forced)."""
function _refresh_analytics!(m::MCPReplModel; force::Bool = false)
    db = Database.DB[]
    db === nothing && return
    t = time()
    if !force && (t - m.analytics_last_refresh) < 30.0 && m.analytics_cache !== nothing
        return
    end
    try
        tool_summary = Database.get_tool_summary()
        error_hotspots = Database.get_error_hotspots()
        recent_execs = Database.get_tool_executions(; days = 1)
        m.analytics_cache = (
            tool_summary = tool_summary,
            error_hotspots = error_hotspots,
            recent_execs = recent_execs,
        )
        m.analytics_last_refresh = t
    catch e
        @debug "Analytics refresh failed" exception = (e, catch_backtrace())
    end
end

"""Render analytics dashboard view in the Activity tab."""
function _view_analytics(m::MCPReplModel, area::Rect, buf::Buffer)
    # Auto-refresh every 30s
    _refresh_analytics!(m)

    cache = m.analytics_cache
    y = area.y
    x = area.x + 1
    w = area.width - 2

    title_block = Block(
        title = " Analytics [d]ata [r]efresh ",
        border_style = tstyle(:accent),
        title_style = tstyle(:accent, bold = true),
    )
    inner = render(title_block, area, buf)
    y = inner.y
    x = inner.x + 1
    w = inner.width - 2

    if cache === nothing || Database.DB[] === nothing
        set_string!(
            buf,
            x,
            y,
            "No analytics data yet (database not ready)",
            tstyle(:text_dim),
        )
        return
    end

    # ── Tool Usage Summary ──
    set_string!(buf, x, y, "── Tool Usage Summary ──", tstyle(:accent, bold = true))
    y += 1

    ts = cache.tool_summary
    if isempty(ts)
        set_string!(buf, x, y, "  No tool executions recorded", tstyle(:text_dim))
        y += 1
    else
        # Table header
        hdr =
            rpad("Tool", 22) *
            rpad("Count", 8) *
            rpad("Avg(ms)", 10) *
            rpad("Errors", 8) *
            "Err%"
        set_string!(buf, x, y, hdr, tstyle(:text_dim))
        y += 1
        for (i, row) in enumerate(ts)
            y > bottom(inner) && break
            name = rpad(get(row, "tool_name", "?"), 22)
            total = get(row, "total_executions", 0)
            count = rpad(string(total), 8)
            avg_ms = get(row, "avg_duration_ms", 0.0)
            avg = rpad(@sprintf("%.0f", avg_ms), 10)
            errs = get(row, "error_count", 0)
            err_str = rpad(string(errs), 8)
            err_pct = total > 0 ? @sprintf("%.0f%%", 100.0 * errs / total) : "0%"
            line = name * count * avg * err_str * err_pct
            style = errs > 0 ? tstyle(:warning) : tstyle(:text)
            set_string!(buf, x, y, line, style)
            y += 1
        end
    end

    y += 1
    y > bottom(inner) && return

    # ── Error Hotspots ──
    set_string!(buf, x, y, "── Error Hotspots ──", tstyle(:error, bold = true))
    y += 1

    eh = cache.error_hotspots
    if isempty(eh)
        set_string!(buf, x, y, "  No errors recorded", tstyle(:success))
        y += 1
    else
        for (i, row) in enumerate(eh)
            i > 5 && break
            y > bottom(inner) && break
            cat = get(row, "error_category", "")
            etype = get(row, "error_type", "")
            tool = get(row, "tool_name", "")
            cnt = get(row, "error_count", 0)
            label = isempty(cat) ? etype : "$cat: $etype"
            line = "  $(rpad(label, 30)) $(rpad(tool, 18)) ×$cnt"
            set_string!(buf, x, y, line, tstyle(:error))
            y += 1
        end
    end

    y += 1
    y > bottom(inner) && return

    # ── Recent Activity Sparkline ──
    set_string!(buf, x, y, "── Calls/min (last hour) ──", tstyle(:secondary, bold = true))
    y += 1
    y > bottom(inner) && return

    # Build per-minute histogram from recent executions
    bins = zeros(60)
    now_t = now()
    for row in cache.recent_execs
        rt_str = get(row, "request_time", "")
        isempty(rt_str) && continue
        try
            rt = DateTime(rt_str, dateformat"yyyy-mm-dd HH:MM:SS")
            delta_min = Dates.value(now_t - rt) / 60000.0
            idx = clamp(60 - floor(Int, delta_min), 1, 60)
            bins[idx] += 1.0
        catch
        end
    end

    spark_w = min(w, 60)
    spark_data = bins[max(1, 61 - spark_w):60]
    if any(>(0), spark_data)
        render(Sparkline(spark_data; style = tstyle(:accent)), Rect(x, y, spark_w, 1), buf)
    else
        set_string!(buf, x, y, "  (no recent activity)", tstyle(:text_dim))
    end
end

function view_activity(m::MCPReplModel, area::Rect, buf::Buffer)
    # Analytics mode: render DB-backed summary instead of live tool list
    if m.activity_mode == :analytics
        _view_analytics(m, area, buf)
        return
    end

    panes = split_layout(m.activity_layout, area)
    length(panes) < 2 && return

    # ── Build filtered in-flight list ──
    filter_key = m.activity_filter
    filtered_inflight = Int[]  # indices into m.inflight_calls matching filter
    for i = 1:length(m.inflight_calls)
        if isempty(filter_key) || m.inflight_calls[i].session_key == filter_key
            push!(filtered_inflight, i)
        end
    end
    n_inflight = length(filtered_inflight)

    # ── Build filtered completed index list (indices into tool_results) ──
    filtered = Int[]  # indices into m.tool_results matching the filter
    for i = 1:length(m.tool_results)
        if isempty(filter_key) || m.tool_results[i].session_key == filter_key
            push!(filtered, i)
        end
    end
    nf = length(filtered)

    # Total items in the combined list
    total_items = n_inflight + nf

    # Track previous selection to detect changes and invalidate detail cache
    prev_sel_inflight = m.selected_inflight
    prev_sel_result = m.selected_result

    # If selected_inflight points to an index that no longer exists (call completed),
    # fall through to completed selection
    if m.selected_inflight > 0 && m.selected_inflight ∉ filtered_inflight
        m.selected_inflight = 0
        # Try to select the newest completed result instead
        if nf > 0
            m.selected_result = filtered[end]
        end
    end

    # Follow mode: always snap to the newest entry (in-flight preferred)
    if m.activity_follow
        if n_inflight > 0
            m.selected_inflight = filtered_inflight[end]
            m.selected_result = 0
        elseif nf > 0
            m.selected_inflight = 0
            m.selected_result = filtered[end]
        end
    end

    # Auto-select when nothing is selected (initial state or after filter change)
    if m.selected_inflight == 0 && m.selected_result == 0
        if n_inflight > 0
            m.selected_inflight = filtered_inflight[end]
        elseif nf > 0
            m.selected_result = filtered[end]
        end
    end
    # If selected_result is stale (no longer in filtered), fix it
    if m.selected_inflight == 0 && m.selected_result > 0 && m.selected_result ∉ filtered
        m.selected_result = nf > 0 ? filtered[end] : 0
    end

    # Invalidate detail cache when selection changed during fixup above
    if m.selected_inflight != prev_sel_inflight || m.selected_result != prev_sel_result
        m._detail_for_result = -1
        m.detail_paragraph = nothing
    end

    # ── Top pane: tool call list (in-flight at top, then completed newest-first) ──
    items = ListItem[]
    display_sel = 0
    item_idx = 0

    # In-flight calls (newest first = reversed)
    for ii in reverse(filtered_inflight)
        item_idx += 1
        ifc = m.inflight_calls[ii]
        elapsed = time() - ifc.timestamp
        elapsed_str =
            elapsed < 1.0 ? @sprintf("%.0fms", elapsed * 1000) : @sprintf("%.1fs", elapsed)
        ts = Dates.format(ifc.timestamp_dt, "HH:MM:SS")
        sess_name = _session_display_name(ifc.session_key)
        sess_tag = isempty(filter_key) && !isempty(sess_name) ? " [$sess_name]" : ""
        si = mod1(m.tick ÷ 2, length(SPINNER_BRAILLE))
        label = "$ts $(SPINNER_BRAILLE[si]) $(ifc.tool_name)$sess_tag ($elapsed_str)"
        push!(items, ListItem(label, tstyle(:warning)))
        if m.selected_inflight == ii
            display_sel = item_idx
        end
    end

    # Completed calls (newest first)
    for ri in Iterators.reverse(filtered)
        item_idx += 1
        r = m.tool_results[ri]
        ts = Dates.format(r.timestamp, "HH:MM:SS")
        marker = r.success ? "✓" : "✗"
        style = r.success ? tstyle(:success) : tstyle(:error)
        sess_name = _session_display_name(r.session_key)
        sess_tag = isempty(filter_key) && !isempty(sess_name) ? " [$sess_name]" : ""
        label = "$ts $marker $(r.tool_name)$sess_tag ($(r.duration_str))"
        push!(items, ListItem(label, style))
        if m.selected_inflight == 0 && ri == m.selected_result
            display_sel = item_idx
        end
    end

    if isempty(items)
        msg = isempty(filter_key) ? "No tool calls yet" : "No calls for this session"
        push!(items, ListItem("  $msg", tstyle(:text_dim)))
    end

    # Build title with filter indicator
    filter_label = if isempty(filter_key)
        "All"
    else
        name = _session_display_name(filter_key)
        isempty(name) ? filter_key : name
    end
    count_str = n_inflight > 0 ? "$(n_inflight) running, $nf done" : "$nf"
    follow_str = m.activity_follow ? "[F]ollow:on" : "[F]ollow:off"
    list_title =
        isempty(filter_key) ? " Tool Calls ($count_str) [f]ilter $follow_str [d]ata " :
        " Tool Calls ($count_str) [f] $filter_label $follow_str [d]ata "

    render(
        SelectableList(
            items;
            selected = display_sel,
            block = Block(
                title = list_title,
                border_style = _pane_border(m, 3, 1),
                title_style = _pane_title(m, 3, 1),
            ),
            highlight_style = tstyle(:accent, bold = true),
            tick = m.tick,
        ),
        panes[1],
        buf,
    )

    # ── Bottom pane: detail panel ──
    # Determine what's selected: in-flight or completed
    show_inflight =
        m.selected_inflight > 0 && m.selected_inflight <= length(m.inflight_calls)
    show_completed =
        !show_inflight &&
        m.selected_result > 0 &&
        m.selected_result <= length(m.tool_results)

    if !show_inflight && !show_completed
        empty_block = Block(
            title = " Details ",
            border_style = _pane_border(m, 3, 2),
            title_style = _pane_title(m, 3, 2),
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

    if show_inflight
        # Build detail for in-flight call (rebuilt every frame for live elapsed)
        ifc = m.inflight_calls[m.selected_inflight]
        elapsed = time() - ifc.timestamp
        elapsed_str =
            elapsed < 1.0 ? @sprintf("%.0fms", elapsed * 1000) : @sprintf("%.1fs", elapsed)
        spans = Span[]
        si = mod1(m.tick ÷ 2, length(SPINNER_BRAILLE))
        _detail_span!(spans, "$(SPINNER_BRAILLE[si]) Running", :warning, "Status:   ")
        _detail_span!(spans, elapsed_str, :text, "Elapsed:  ")
        _detail_span!(
            spans,
            Dates.format(ifc.timestamp_dt, "HH:MM:SS"),
            :text,
            "Started:  ",
        )
        sess_name = _session_display_name(ifc.session_key)
        if !isempty(sess_name)
            _detail_span!(
                spans,
                "$sess_name ($(ifc.session_key))",
                :secondary,
                "Session:  ",
            )
        end
        push!(spans, Span("\n", tstyle(:text)))
        push!(spans, Span("── Arguments ──\n", tstyle(:text_dim)))
        try
            args_dict = JSON.parse(ifc.args_json)
            for (k, v) in args_dict
                val_str = v isa AbstractString ? repr(v) : JSON.json(v)
                push!(spans, Span("  $k: $val_str\n", tstyle(:text)))
            end
        catch
            push!(spans, Span("  $(ifc.args_json)\n", tstyle(:text)))
        end
        if !isempty(ifc.progress_lines)
            push!(spans, Span("\n", tstyle(:text)))
            push!(spans, Span("── Progress ──\n", tstyle(:text_dim)))
            # Show last N progress lines to keep detail readable
            start_idx = max(1, length(ifc.progress_lines) - 50)
            for i = start_idx:length(ifc.progress_lines)
                push!(spans, Span("  " * ifc.progress_lines[i] * "\n", tstyle(:text)))
            end
        end
        wrap_mode = m.result_word_wrap ? word_wrap : no_wrap
        p = Paragraph(spans; wrap = wrap_mode)
        detail_title = " $(ifc.tool_name) (running) "
        p.block = Block(
            title = detail_title,
            border_style = _pane_border(m, 3, 2),
            title_style = _pane_title(m, 3, 2),
        )
        render(p, panes[2], buf)
        # Don't cache the paragraph — it changes every frame
        m.detail_paragraph = nothing
        m._detail_for_result = -1
    else
        r = m.tool_results[m.selected_result]

        # (Re)build the Paragraph when selection or wrap mode changes
        if m._detail_for_result != m.selected_result || m.detail_paragraph === nothing
            spans = Span[]
            _detail_span!(
                spans,
                r.success ? "✓ Success" : "✗ Failed",
                r.success ? :success : :error,
                "Status:   ",
            )
            _detail_span!(spans, r.duration_str, :text, "Duration: ")
            _detail_span!(spans, Dates.format(r.timestamp, "HH:MM:SS"), :text, "Time:     ")
            sess_name = _session_display_name(r.session_key)
            if !isempty(sess_name)
                _detail_span!(
                    spans,
                    "$sess_name ($(r.session_key))",
                    :secondary,
                    "Session:  ",
                )
            end
            push!(spans, Span("\n", tstyle(:text)))
            push!(spans, Span("── Arguments ──\n", tstyle(:text_dim)))
            try
                args_dict = JSON.parse(r.args_json)
                for (k, v) in args_dict
                    val_str = v isa AbstractString ? repr(v) : JSON.json(v)
                    push!(spans, Span("  $k: $val_str\n", tstyle(:text)))
                end
            catch
                push!(spans, Span("  $(r.args_json)\n", tstyle(:text)))
            end
            push!(spans, Span("\n", tstyle(:text)))
            push!(spans, Span("── Result ──\n", tstyle(:text_dim)))
            for ln in split(r.result_text, '\n')
                push!(spans, Span("  " * string(ln) * "\n", tstyle(:text)))
            end
            wrap_mode = m.result_word_wrap ? word_wrap : no_wrap
            m.detail_paragraph = Paragraph(spans; wrap = wrap_mode)
            m._detail_for_result = m.selected_result
        end

        # Update wrap mode if toggled without selection change
        target_wrap = m.result_word_wrap ? word_wrap : no_wrap
        if m.detail_paragraph.wrap != target_wrap
            m.detail_paragraph.wrap = target_wrap
            m.detail_paragraph.scroll_offset = 0
        end

        # Compute scroll info for title
        pane_inner_h = panes[2].height - 2
        pane_inner_w = panes[2].width - 2
        total_lines = paragraph_line_count(m.detail_paragraph, pane_inner_w)
        offset = m.detail_paragraph.scroll_offset
        has_scroll = total_lines > pane_inner_h

        wrap_hint = m.result_word_wrap ? "w:on" : "w:off"
        detail_title = if has_scroll
            top_line = offset + 1
            bot_line = min(offset + pane_inner_h, total_lines)
            " $(r.tool_name) [$top_line-$bot_line/$total_lines] $wrap_hint "
        else
            " $(r.tool_name) $wrap_hint "
        end

        m.detail_paragraph.block = Block(
            title = detail_title,
            border_style = _pane_border(m, 3, 2),
            title_style = _pane_title(m, 3, 2),
        )

        render(m.detail_paragraph, panes[2], buf)
    end

    # Render the draggable divider between panes
    render_resize_handles!(buf, m.activity_layout)
end

"""Build a labeled detail line as Spans: label in dim, value in given style."""
function _detail_span!(
    spans::Vector{Span},
    value::String,
    style_name::Symbol,
    label::String,
)
    push!(spans, Span(label, tstyle(:text_dim)))
    push!(spans, Span(value * "\n", tstyle(style_name)))
end

# ── Server Tab ────────────────────────────────────────────────────────────────

function view_server(m::MCPReplModel, area::Rect, buf::Buffer)
    rows = split_layout(m.server_layout, area)
    length(rows) < 2 && return
    render_resize_handles!(buf, m.server_layout)

    # ── Top: Server status panel ──
    status_block = Block(
        title = " Server Status ",
        border_style = _pane_border(m, 1, 1),
        title_style = _pane_title(m, 1, 1),
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

    # ── Bottom: Server log (ScrollPane) ──
    wrap_hint = m.log_word_wrap ? "wrap:on" : "wrap:off"
    _ensure_log_pane!(m)
    pane = m.log_pane::ScrollPane
    pane.block = Block(
        title = " Server Log ($(length(m.server_log))) [$wrap_hint] ",
        border_style = _pane_border(m, 1, 2),
        title_style = _pane_title(m, 1, 2),
    )
    _sync_log_pane!(m, rows[2].width - 2)  # -2 for border
    render(pane, rows[2], buf)
end

# ── Config Tab ────────────────────────────────────────────────────────────────

function view_config(m::MCPReplModel, area::Rect, buf::Buffer)
    view_config_base(m, area, buf)
    if m.config_flow != FLOW_IDLE
        view_config_flow(m, area, buf)
    end
end

function view_config_base(m::MCPReplModel, area::Rect, buf::Buffer)
    cols = split_layout(m.config_layout, area)
    length(cols) < 2 && return
    render_resize_handles!(buf, m.config_layout)

    # ── Left column: Server + Actions ──
    left_rows = split_layout(m.config_left_layout, cols[1])
    length(left_rows) < 2 && return
    render_resize_handles!(buf, m.config_left_layout)

    # Server info
    srv_block = Block(
        title = " Server ",
        border_style = _pane_border(m, 4, 1),
        title_style = _pane_title(m, 4, 1),
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
        border_style = _pane_border(m, 4, 2),
        title_style = _pane_title(m, 4, 2),
    )
    act = render(act_block, left_rows[2], buf)
    if act.width >= 4
        y = act.y
        x = act.x + 1
        set_string!(buf, x, y, "[o]", tstyle(:accent, bold = true))
        set_string!(buf, x + 4, y, "Onboard project (bridge setup)", tstyle(:text))
        y += 1
        set_string!(buf, x, y, "[i]", tstyle(:accent, bold = true))
        set_string!(buf, x + 4, y, "Install MCP client config", tstyle(:text))
        y += 1
        set_string!(buf, x, y, "[m]", tstyle(:accent, bold = true))
        set_string!(buf, x + 4, y, "Mirror host REPL output", tstyle(:text))
        y += 1
        mirror_status = m.bridge_mirror_repl ? "enabled" : "disabled"
        mirror_style = m.bridge_mirror_repl ? tstyle(:success) : tstyle(:text_dim)
        set_string!(buf, x + 4, y, "status: $mirror_status", mirror_style)
    end

    # ── Right column: MCP Client Status ──
    client_block = Block(
        title = " MCP Clients ",
        border_style = _pane_border(m, 4, 3),
        title_style = _pane_title(m, 4, 3),
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
        set_string!(buf, x, y, "Press [i] to configure a client", tstyle(:text_dim))
    end
end

# ── Config Flow Overlay ──────────────────────────────────────────────────────

function view_config_flow(m::MCPReplModel, area::Rect, buf::Buffer)
    flow = m.config_flow

    # Dim background
    _dim_area!(buf, area)

    if flow == FLOW_ONBOARD_PATH
        if m.path_input !== nothing
            m.path_input.tick = m.tick
        end
        _render_text_input_modal(
            buf,
            area,
            " Add Project ",
            "Enter project path:",
            m.path_input,
            "[Enter] confirm  [Esc] cancel";
            tick = m.tick,
        )

    elseif flow == FLOW_ONBOARD_SCOPE
        _render_selection_modal(
            buf,
            area,
            " Scope ",
            SCOPE_LABELS,
            m.flow_selected,
            "[↑↓] select  [Enter] confirm  [Esc] cancel";
            tick = m.tick,
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
                tick = m.tick,
            ),
            area,
            buf,
        )

    elseif flow == FLOW_ONBOARD_RESULT
        _render_result_modal(buf, area, m.flow_success, m.flow_message; tick = m.tick)

    elseif flow == FLOW_CLIENT_SELECT
        _render_selection_modal(
            buf,
            area,
            " Select Client ",
            CLIENT_LABELS,
            m.flow_selected,
            "[↑↓] select  [Enter] confirm  [Esc] cancel";
            tick = m.tick,
        )

    elseif flow == FLOW_CLIENT_CONFIRM
        client_label = CLIENT_LABELS[findfirst(==(m.client_target), CLIENT_OPTIONS)]
        # Check if already configured
        configured = any(p -> p.first == client_label && p.second, m.client_statuses)
        status_text = configured ? "● configured" : "○ not configured"
        status_style = configured ? tstyle(:success) : tstyle(:text_dim)

        w = min(44, area.width - 4)
        h = 8
        rect = center(area, w, h)
        border_s = tstyle(:accent, bold = true)
        inner = if animations_enabled()
            border_shimmer!(buf, rect, border_s.fg, m.tick; box = BOX_HEAVY, intensity = 0.12)
            if rect.width > 4
                set_string!(buf, rect.x + 2, rect.y, " $client_label ", border_s)
            end
            Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
        else
            render(
                Block(
                    title = " $client_label ",
                    border_style = border_s,
                    title_style = border_s,
                    box = BOX_HEAVY,
                ),
                rect,
                buf,
            )
        end
        if inner.width >= 4
            for row = inner.y:bottom(inner)
                for col = inner.x:right(inner)
                    set_char!(buf, col, row, ' ', Style())
                end
            end
            y = inner.y
            x = inner.x + 1
            set_string!(buf, x, y, "Status: ", tstyle(:text_dim))
            set_string!(buf, x + 8, y, status_text, status_style)
            y += 1
            set_string!(buf, x, y, "Scope:  user-level (global)", tstyle(:text_dim))
            y += 2
            set_string!(
                buf,
                x,
                y,
                configured ? "[Enter] Update" : "[Enter] Install",
                tstyle(:accent),
            )
            if configured
                set_string!(buf, x + 24, y, "[r] Remove", tstyle(:error))
            end
            y += 1
            set_string!(buf, x, y, "[Esc] Cancel", tstyle(:text_dim))
        end

    elseif flow == FLOW_CLIENT_RESULT
        _render_result_modal(buf, area, m.flow_success, m.flow_message; tick = m.tick)
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
    hint::String;
    tick::Union{Int,Nothing} = nothing,
)
    w = min(60, area.width - 4)
    h = 7
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    inner = if tick !== nothing && animations_enabled()
        border_shimmer!(buf, rect, border_s.fg, tick; box = BOX_HEAVY, intensity = 0.12)
        if !isempty(title) && rect.width > 4
            set_string!(buf, rect.x + 2, rect.y, " $title ", tstyle(:accent, bold = true))
        end
        Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
    else
        render(
            Block(
                title = title,
                border_style = border_s,
                title_style = border_s,
                box = BOX_HEAVY,
            ),
            rect,
            buf,
        )
    end
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
    hint::String;
    tick::Union{Int,Nothing} = nothing,
)
    w = min(50, area.width - 4)
    h = length(options) + 5
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    inner = if tick !== nothing && animations_enabled()
        border_shimmer!(buf, rect, border_s.fg, tick; box = BOX_HEAVY, intensity = 0.12)
        if !isempty(title) && rect.width > 4
            set_string!(buf, rect.x + 2, rect.y, " $title ", tstyle(:accent, bold = true))
        end
        Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
    else
        render(
            Block(
                title = title,
                border_style = border_s,
                title_style = border_s,
                box = BOX_HEAVY,
            ),
            rect,
            buf,
        )
    end
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

function _render_result_modal(
    buf::Buffer,
    area::Rect,
    success::Bool,
    message::String;
    tick::Union{Int,Nothing} = nothing,
)
    lines = Base.split(message, '\n')
    w = min(max(maximum(length.(lines); init = 20) + 6, 30), area.width - 4)
    h = length(lines) + 5
    rect = center(area, w, h)

    border_style = success ? tstyle(:success, bold = true) : tstyle(:error, bold = true)
    title = success ? " Success " : " Error "
    inner = if tick !== nothing && animations_enabled()
        border_shimmer!(buf, rect, border_style.fg, tick; box = BOX_HEAVY, intensity = 0.12)
        if rect.width > 4
            set_string!(buf, rect.x + 2, rect.y, " $title ", border_style)
        end
        Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
    else
        render(
            Block(
                title = title,
                border_style = border_style,
                title_style = border_style,
                box = BOX_HEAVY,
            ),
            rect,
            buf,
        )
    end
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

# ── Advanced Tab: Stress Test Runner ─────────────────────────────────────────
# StressAgentResult, _write_stress_script, _STRESS_SCRIPT_SOURCE,
# _parse_stress_kv, and _parse_stress_results live in stress_test.jl

"""Launch the stress test process."""
function _launch_stress_test!(m::MCPReplModel)
    m.stress_state == STRESS_RUNNING && return

    # Get session info
    sessions = m.conn_mgr !== nothing ? connected_sessions(m.conn_mgr) : []
    if isempty(sessions)
        m.stress_state = STRESS_ERROR
        lock(m.stress_output_lock) do
            push!(
                m.stress_output,
                "ERROR agent=0 elapsed=0.0 message=no_connected_sessions",
            )
        end
        return
    end

    idx = clamp(m.stress_session_idx, 1, length(sessions))
    sess = sessions[idx]
    sess_key = short_key(sess)

    code = m.stress_code
    n_agents = tryparse(Int, m.stress_agents)
    n_agents === nothing && (n_agents = 5)
    stagger_val = tryparse(Float64, m.stress_stagger)
    stagger_val === nothing && (stagger_val = 0.0)
    timeout_val = tryparse(Int, m.stress_timeout)
    timeout_val === nothing && (timeout_val = 30)

    # Reset state
    lock(m.stress_output_lock) do
        empty!(m.stress_output)
    end
    m.stress_scroll_pane = ScrollPane(
        Vector{Span}[];
        following = true,
        reverse = false,
        block = nothing,
        show_scrollbar = true,
    )
    m.stress_result_file = ""
    m.stress_state = STRESS_RUNNING

    script_path = _write_stress_script()
    project_dir = pkgdir(@__MODULE__)
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project_dir $script_path $(m.server_port) $sess_key $code $n_agents $stagger_val $timeout_val`

    Threads.@spawn try
        process = open(cmd, "r")
        m.stress_process = process
        while !eof(process)
            line = readline(process; keep = false)
            isempty(line) && continue
            lock(m.stress_output_lock) do
                push!(m.stress_output, line)
            end
        end
        # Process finished
        exit_code = try
            wait(process)
            process.exitcode
        catch
            -1
        end
        m.stress_process = nothing

        # Write results file
        _write_stress_results!(m, code, sess_key, n_agents, stagger_val, timeout_val)

        # Check actual results — did any agents fail?
        all_output = lock(m.stress_output_lock) do
            copy(m.stress_output)
        end
        agents = _parse_stress_results(all_output)
        has_failures = any(a -> a.status == :fail, agents)

        if exit_code != 0
            m.stress_state = STRESS_ERROR
        elseif has_failures
            m.stress_state = STRESS_ERROR
        else
            m.stress_state = STRESS_COMPLETE
        end
    catch e
        m.stress_process = nothing
        lock(m.stress_output_lock) do
            push!(
                m.stress_output,
                "ERROR agent=0 elapsed=0.0 message=$(sprint(showerror, e))",
            )
        end
        m.stress_state = STRESS_ERROR
    end
end

"""Cancel a running stress test."""
function _cancel_stress_test!(m::MCPReplModel)
    m.stress_state != STRESS_RUNNING && return
    proc = m.stress_process
    if proc !== nothing
        try
            kill(proc)
        catch
        end
        m.stress_process = nothing
    end
    lock(m.stress_output_lock) do
        push!(m.stress_output, "CANCELLED")
    end
    m.stress_state = STRESS_IDLE
end

"""Write stress test results to a file (delegates to shared _write_stress_results_to_file)."""
function _write_stress_results!(m::MCPReplModel, code, sess_key, n_agents, stagger, timeout)
    all_output = lock(m.stress_output_lock) do
        copy(m.stress_output)
    end
    path = _write_stress_results_to_file(
        all_output,
        code,
        sess_key,
        n_agents,
        stagger,
        timeout,
    )
    if path !== nothing
        m.stress_result_file = path
    end
end

"""Drain buffered stress output lines into the ScrollPane each frame."""
function _drain_stress_output!(m::MCPReplModel)
    m.stress_scroll_pane === nothing && return
    pane = m.stress_scroll_pane::ScrollPane
    new_lines = lock(m.stress_output_lock) do
        if isempty(m.stress_output)
            return String[]
        end
        # Return lines that haven't been synced to pane yet
        # We track by comparing lengths
        total = length(m.stress_output)
        synced = length(pane.content)
        if total > synced
            return m.stress_output[synced+1:total]
        end
        return String[]
    end
    for line in new_lines
        push_line!(pane, _stress_line_spans(line, m.tick))
    end
end

"""Convert a stress output line to styled Spans."""
function _stress_line_spans(line::String, tick::Int)::Vector{Span}
    if startswith(line, "INIT ")
        kv = _parse_stress_kv(line)
        aid = get(kv, "agent", "?")
        sid = get(kv, "session", "?")
        return Span[
            Span("[Agent $aid] ", tstyle(:secondary)),
            Span("initialized ", tstyle(:text_dim)),
            Span("session=$sid", tstyle(:text_dim)),
        ]
    elseif startswith(line, "SEND ")
        kv = _parse_stress_kv(line)
        aid = get(kv, "agent", "?")
        return Span[
            Span("[Agent $aid] ", tstyle(:secondary)),
            Span("SENDING tool call...", tstyle(:accent)),
        ]
    elseif startswith(line, "SEND_ALL ")
        kv = _parse_stress_kv(line)
        n = get(kv, "count", "?")
        return Span[
            Span(">>> ", tstyle(:accent, bold = true)),
            Span("Firing $n tool calls concurrently", tstyle(:accent, bold = true)),
        ]
    elseif startswith(line, "PROGRESS ")
        kv = _parse_stress_kv(line)
        aid = get(kv, "agent", "?")
        elapsed = get(kv, "elapsed", "?")
        step = get(kv, "step", "?")
        msg = get(kv, "message", "")
        return Span[
            Span("[Agent $aid] ", tstyle(:secondary)),
            Span("(+$(elapsed)s) ", tstyle(:text_dim)),
            Span("PROGRESS #$step ", tstyle(:warning)),
            Span(msg, tstyle(:text)),
        ]
    elseif startswith(line, "RESULT ")
        kv = _parse_stress_kv(line)
        aid = get(kv, "agent", "?")
        elapsed = get(kv, "elapsed", "?")
        ok = get(kv, "ok", "false")
        is_ok = ok == "true"
        result_text = get(kv, "result", "")
        return Span[
            Span("[Agent $aid] ", tstyle(:secondary)),
            Span("(+$(elapsed)s) ", tstyle(:text_dim)),
            Span(is_ok ? "OK " : "FAIL ", tstyle(is_ok ? :success : :error, bold = true)),
            Span(result_text, tstyle(:text)),
        ]
    elseif startswith(line, "ERROR ")
        kv = _parse_stress_kv(line)
        aid = get(kv, "agent", "?")
        elapsed = get(kv, "elapsed", "?")
        msg = get(kv, "message", "unknown")
        return Span[
            Span("[Agent $aid] ", tstyle(:secondary)),
            Span("(+$(elapsed)s) ", tstyle(:text_dim)),
            Span("ERROR: ", tstyle(:error, bold = true)),
            Span(msg, tstyle(:error)),
        ]
    elseif startswith(line, "SUMMARY ")
        kv = _parse_stress_kv(line)
        tt = get(kv, "total_time", "?")
        succ = get(kv, "succeeded", "?")
        fail = get(kv, "failed", "?")
        return Span[
            Span("SUMMARY ", tstyle(:accent, bold = true)),
            Span("$(tt)s total  ", tstyle(:text)),
            Span("$succ ok  ", tstyle(:success, bold = true)),
            Span("$fail failed", tstyle(parse(Int, fail) > 0 ? :error : :text_dim)),
        ]
    elseif startswith(line, "START ")
        kv = _parse_stress_kv(line)
        n = get(kv, "agents", "?")
        return Span[
            Span(">>> ", tstyle(:accent, bold = true)),
            Span("Stress test: $n agents", tstyle(:accent, bold = true)),
        ]
    elseif line == "DONE"
        return Span[Span(">>> Complete", tstyle(:success, bold = true))]
    elseif line == "CANCELLED"
        return Span[Span(">>> Cancelled by user", tstyle(:warning, bold = true))]
    else
        return Span[Span(line, tstyle(:text))]
    end
end

"""Handle all key events while a stress form field is in edit mode.
This intercepts ALL input (including numbers, letters) so global shortcuts don't fire."""
function _handle_stress_field_edit!(m::MCPReplModel, evt::KeyEvent)
    fi = m.stress_field_idx

    if fi == 1 && m.stress_code_area !== nothing
        # Code field — full CodeEditor editing
        if evt.key == :escape
            m.stress_code = Tachikoma.text(m.stress_code_area)
            m.stress_editing = false
            return
        end
        m.stress_code_area.tick = m.tick
        handle_key!(m.stress_code_area, evt)
    elseif fi == 2
        # Session selector — left/right to cycle, Enter/Escape to close
        if evt.key in (:escape, :enter)
            m.stress_editing = false
        elseif evt.key == :left
            sessions = m.conn_mgr !== nothing ? connected_sessions(m.conn_mgr) : []
            n = max(1, length(sessions))
            m.stress_session_idx = mod1(m.stress_session_idx - 1, n)
        elseif evt.key == :right
            sessions = m.conn_mgr !== nothing ? connected_sessions(m.conn_mgr) : []
            n = max(1, length(sessions))
            m.stress_session_idx = mod1(m.stress_session_idx + 1, n)
        end
    else
        # Inline text fields (Agents, Stagger, Timeout)
        if evt.key == :escape || evt.key == :enter
            m.stress_editing = false
        elseif evt.key == :char
            if fi == 3
                m.stress_agents *= evt.char
            elseif fi == 4
                m.stress_stagger *= evt.char
            elseif fi == 5
                m.stress_timeout *= evt.char
            end
        elseif evt.key == :backspace
            if fi == 3
                m.stress_agents = _stress_backspace(m.stress_agents)
            elseif fi == 4
                m.stress_stagger = _stress_backspace(m.stress_stagger)
            elseif fi == 5
                m.stress_timeout = _stress_backspace(m.stress_timeout)
            end
        end
    end
end

"""Handle char key events on the Advanced tab (when NOT in field edit mode)."""
function _handle_stress_key!(m::MCPReplModel, evt::KeyEvent)
    # Nothing to do for char events when not editing — form navigation is
    # handled by up/down in _handle_scroll!, and Enter opens edit mode.
end

"""Handle Enter on the Advanced tab — open field for editing or run."""
function _handle_stress_enter!(m::MCPReplModel)
    m.stress_state == STRESS_RUNNING && return

    fp = get(m.focused_pane, 5, 1)
    if fp == 1
        fi = m.stress_field_idx
        if fi == 1
            # Code field: open the CodeEditor (syntax highlighting + line numbers)
            m.stress_code_area =
                CodeEditor(text = m.stress_code, focused = true, tick = m.tick)
            m.stress_editing = true
        elseif fi == 6
            # Run button: launch the test
            _launch_stress_test!(m)
        else
            # Fields 2-5: enter edit mode for this field
            m.stress_editing = true
        end
    end
end

"""Handle left/right arrow keys on the Advanced tab (not in edit mode)."""
function _handle_stress_arrow!(m::MCPReplModel, evt::KeyEvent)
    # Left/right do nothing outside of edit mode
end

"""Delete the last character from a string."""
function _stress_backspace(s::String)::String
    isempty(s) ? s : s[1:prevind(s, lastindex(s))]
end


# ── Advanced Tab View ────────────────────────────────────────────────────────

function view_advanced(m::MCPReplModel, area::Rect, buf::Buffer)
    panes = split_layout(m.advanced_layout, area)
    length(panes) < 2 && return

    # ── Top pane: Configuration form ──
    _view_stress_form(m, panes[1], buf)

    # ── Bottom pane: Output with live agent visualization ──
    _view_stress_output(m, panes[2], buf)

    render_resize_handles!(buf, m.advanced_layout)
end

"""Render the stress test configuration form."""
function _view_stress_form(m::MCPReplModel, area::Rect, buf::Buffer)
    is_running = m.stress_state == STRESS_RUNNING
    fp = get(m.focused_pane, 5, 1)
    form_focused = fp == 1

    # If code editor is open, render it as an overlay instead of the form
    if m.stress_editing && m.stress_field_idx == 1 && m.stress_code_area !== nothing
        _view_stress_code_editor(m, area, buf)
        return
    end

    # Animated border when running
    if is_running && animations_enabled()
        border_shimmer!(
            buf,
            area,
            tstyle(:warning).fg,
            m.tick;
            box = BOX_HEAVY,
            intensity = 0.2,
        )
        if area.width > 4
            si = mod1(m.tick ÷ 2, length(SPINNER_BRAILLE))
            title = " $(SPINNER_BRAILLE[si]) Stress Test Running... "
            set_string!(buf, area.x + 2, area.y, title, tstyle(:warning, bold = true))
        end
        inner =
            Rect(area.x + 1, area.y + 1, max(0, area.width - 2), max(0, area.height - 2))
    else
        title_style = form_focused ? tstyle(:accent, bold = true) : tstyle(:text_dim)
        border_style = form_focused ? tstyle(:accent) : tstyle(:border)
        block = Block(
            title = " Stress Test Configuration ",
            border_style = border_style,
            title_style = title_style,
        )
        inner = render(block, area, buf)
    end
    inner.width < 10 && return

    # Clear interior
    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style())
        end
    end

    x = inner.x + 1
    y = inner.y
    label_w = 10
    fi = m.stress_field_idx

    sessions = m.conn_mgr !== nothing ? connected_sessions(m.conn_mgr) : []
    sess_name = if !isempty(sessions)
        idx = clamp(m.stress_session_idx, 1, length(sessions))
        sessions[idx].name
    else
        "(no sessions)"
    end

    # ── Field 1: Code (multiline preview, Enter to edit) ──
    is_code_active = !is_running && form_focused && fi == 1
    set_string!(buf, x, y, rpad("Code:", label_w), tstyle(:text_dim))
    vx = x + label_w
    vw = inner.width - label_w - 2
    # Show first line of code as preview
    code_lines = Base.split(m.stress_code, '\n')
    preview = first(code_lines)
    n_extra = length(code_lines) - 1
    suffix = n_extra > 0 ? " (+$(n_extra) lines)" : ""
    if is_code_active
        set_string!(
            buf,
            vx,
            y,
            first(string(preview), max(1, vw - length(suffix))),
            tstyle(:accent, bold = true),
        )
        set_string!(
            buf,
            vx + min(length(preview), vw - length(suffix)),
            y,
            suffix,
            tstyle(:text_dim),
        )
        # Hint
        hint = " [Enter] edit"
        hint_x = right(inner) - length(hint)
        if hint_x > vx + length(preview) + length(suffix)
            set_string!(buf, hint_x, y, hint, tstyle(:accent))
        end
    else
        display = first(string(preview) * suffix, vw)
        set_string!(buf, vx, y, display, tstyle(:text))
    end
    y += 1

    # ── Fields 2-5: Session, Agents, Stagger, Timeout ──
    inline_fields = [
        ("Session:", sess_name, 2),
        ("Agents:", m.stress_agents, 3),
        ("Stagger:", m.stress_stagger, 4),
        ("Timeout:", m.stress_timeout, 5),
    ]

    for (label, value, idx) in inline_fields
        y > bottom(inner) - 2 && break
        is_focused = !is_running && form_focused && fi == idx
        is_editing_this = is_focused && m.stress_editing

        set_string!(buf, x, y, rpad(label, label_w), tstyle(:text_dim))

        display_val = if idx == 2
            n = length(sessions)
            n > 1 ? "◂ $value ▸" : value
        else
            value
        end

        if is_editing_this
            # In edit mode — bright highlight + cursor
            field_text = length(display_val) > vw ? first(display_val, vw) : display_val
            set_string!(buf, vx, y, field_text, tstyle(:accent, bold = true))
            if idx != 2  # text cursor on text fields
                cursor_x = vx + min(length(display_val), vw)
                if cursor_x <= right(inner) && m.tick % 30 < 20
                    set_char!(buf, cursor_x, y, '▎', tstyle(:accent))
                end
            end
            # Hints for editing mode
            hint = idx == 2 ? " [◂▸] cycle  [Esc/Enter] done" : " [Esc/Enter] done"
            hint_x = right(inner) - length(hint)
            if hint_x > vx + length(display_val)
                set_string!(buf, hint_x, y, hint, tstyle(:text_dim))
            end
        elseif is_focused
            # Focused but not editing — dim highlight + Enter hint
            field_text = length(display_val) > vw ? first(display_val, vw) : display_val
            set_string!(buf, vx, y, field_text, tstyle(:accent))
            hint = " [Enter] edit"
            hint_x = right(inner) - length(hint)
            if hint_x > vx + length(display_val)
                set_string!(buf, hint_x, y, hint, tstyle(:text_dim))
            end
        else
            set_string!(buf, vx, y, first(display_val, vw), tstyle(:text))
        end
        y += 1
    end

    # ── Field 6: Run / Cancel button ──
    y += 1
    if y <= bottom(inner)
        if is_running
            cancel_label = "[ Cancel (Esc) ]"
            if animations_enabled()
                p = pulse(m.tick; period = 40, lo = 0.5, hi = 1.0)
                base = to_rgb(tstyle(:error).fg)
                pulsed = brighten(base, (1.0 - p) * 0.3)
                set_string!(buf, x + 2, y, cancel_label, Style(fg = pulsed, bold = true))
            else
                set_string!(buf, x + 2, y, cancel_label, tstyle(:error, bold = true))
            end
        else
            run_label = "[ Run Stress Test ]"
            btn_x = x + 2
            btn_focused = form_focused && fi == 6
            if btn_focused
                if animations_enabled()
                    p = pulse(m.tick; period = 60, lo = 0.0, hi = 0.25)
                    base = to_rgb(tstyle(:accent).fg)
                    pulsed = brighten(base, p)
                    set_string!(buf, btn_x, y, run_label, Style(fg = pulsed, bold = true))
                else
                    set_string!(buf, btn_x, y, run_label, tstyle(:accent, bold = true))
                end
                hint_x = btn_x + length(run_label) + 2
                if hint_x + 10 <= right(inner)
                    set_string!(buf, hint_x, y, "[Enter] run", tstyle(:text_dim))
                end
            else
                set_string!(buf, btn_x, y, run_label, tstyle(:text_dim))
            end
        end
    end

    # ── Bottom hint bar ──
    y += 1
    if y <= bottom(inner) && !is_running
        set_string!(
            buf,
            x,
            y,
            "[↑↓] navigate  [Tab] switch pane  [Enter] interact",
            tstyle(:text_dim),
        )
    end
end

"""Render the code editor overlay (TextArea in a bordered panel)."""
function _view_stress_code_editor(m::MCPReplModel, area::Rect, buf::Buffer)
    ce = m.stress_code_area
    ce.tick = m.tick

    # Shimmer border for the editor
    if animations_enabled()
        border_shimmer!(
            buf,
            area,
            tstyle(:accent).fg,
            m.tick;
            box = BOX_HEAVY,
            intensity = 0.12,
        )
        if area.width > 4
            set_string!(
                buf,
                area.x + 2,
                area.y,
                " Code Editor ",
                tstyle(:accent, bold = true),
            )
        end
        inner =
            Rect(area.x + 1, area.y + 1, max(0, area.width - 2), max(0, area.height - 2))
    else
        block = Block(
            title = " Code Editor ",
            border_style = tstyle(:accent, bold = true),
            title_style = tstyle(:accent, bold = true),
            box = BOX_HEAVY,
        )
        inner = render(block, area, buf)
    end
    inner.width < 4 && return

    # Clear interior
    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style())
        end
    end

    # Render the CodeEditor in the main area, leaving 1 row for the hint
    editor_h = max(1, inner.height - 1)
    render(ce, Rect(inner.x, inner.y, inner.width, editor_h), buf)

    # Hint bar at bottom
    hint_y = inner.y + editor_h
    if hint_y <= bottom(inner)
        set_string!(
            buf,
            inner.x + 1,
            hint_y,
            "[Esc] save and close  [Tab] indent",
            tstyle(:text_dim),
        )
        # Show line count
        n_lines = length(ce.lines)
        line_info = "$(ce.cursor_row):$(ce.cursor_col) ($(n_lines) lines)"
        info_x = right(inner) - length(line_info)
        if info_x > inner.x + 36
            set_string!(buf, info_x, hint_y, line_info, tstyle(:text_dim))
        end
    end
end

"""Render the stress test output pane with live agent visualization."""
function _view_stress_output(m::MCPReplModel, area::Rect, buf::Buffer)
    fp = get(m.focused_pane, 5, 1)
    horde_focused = fp == 2
    log_focused = fp == 3

    all_output = lock(m.stress_output_lock) do
        copy(m.stress_output)
    end
    agents = _parse_stress_results(all_output)

    # If we have agent data and enough space, split into visualization + log
    has_agents = !isempty(agents)
    show_viz = has_agents && area.height > 8 && area.width > 30

    if show_viz
        # Split: left side for agent horde visualization, right side for log
        viz_w = min(max(area.width ÷ 3, 24), 40)
        log_w = area.width - viz_w

        viz_area = Rect(area.x, area.y, viz_w, area.height)
        log_area = Rect(area.x + viz_w, area.y, log_w, area.height)

        _view_agent_horde(m, viz_area, buf, agents, horde_focused)
        _view_stress_log(m, log_area, buf, log_focused)
    else
        _view_stress_log(m, area, buf, log_focused)
    end
end

"""Render the scrollable log output."""
function _view_stress_log(m::MCPReplModel, area::Rect, buf::Buffer, focused::Bool)
    # Build title
    title = if m.stress_state == STRESS_RUNNING
        si = mod1(m.tick ÷ 2, length(SPINNER_BRAILLE))
        " $(SPINNER_BRAILLE[si]) Output "
    elseif m.stress_state == STRESS_COMPLETE
        result_hint = isempty(m.stress_result_file) ? "" : " saved "
        " Output (complete$result_hint) "
    elseif m.stress_state == STRESS_ERROR
        " Output (error) "
    else
        " Output "
    end

    # Ensure scroll pane exists
    if m.stress_scroll_pane === nothing
        m.stress_scroll_pane = ScrollPane(
            Vector{Span}[];
            following = true,
            reverse = false,
            block = nothing,
            show_scrollbar = true,
        )
    end
    pane = m.stress_scroll_pane::ScrollPane
    pane.block = Block(
        title = title,
        border_style = focused ? tstyle(:accent) : tstyle(:border),
        title_style = focused ? tstyle(:accent, bold = true) : tstyle(:text_dim),
    )

    render(pane, area, buf)
end

"""Render the agent horde visualization — a live view of all agents' status."""
function _view_agent_horde(
    m::MCPReplModel,
    area::Rect,
    buf::Buffer,
    agents::Vector{StressAgentResult},
    focused::Bool = false,
)
    n = length(agents)
    n == 0 && return

    is_running = m.stress_state == STRESS_RUNNING
    is_complete = m.stress_state in (STRESS_COMPLETE, STRESS_ERROR)
    has_failures = any(a -> a.status == :fail, agents)

    # Compute content height to clamp scroll
    w_est = max(1, max(0, area.width - 4))
    cell_w_est = max(8, min(12, w_est ÷ max(1, min(n, 5))))
    grid_cols_est = max(1, w_est ÷ cell_w_est)
    rows_needed_est = cld(n, grid_cols_est)
    # Total content: 2 rows for gauge + rows_needed*3 for agent cells + 6 for sparkline
    content_h = 2 + rows_needed_est * 3 + (is_complete ? 6 : 0)
    viewport_h = max(0, area.height - 2)  # inner height
    max_scroll = max(0, content_h - viewport_h)
    m.stress_horde_scroll = clamp(m.stress_horde_scroll, 0, max_scroll)
    scroll_off = m.stress_horde_scroll

    # Scroll indicator suffix for title
    scroll_hint = if max_scroll > 0
        top_row = scroll_off + 1
        bot_row = min(content_h, scroll_off + viewport_h)
        " [$top_row-$bot_row/$content_h]"
    else
        ""
    end

    # Border with shimmer when running
    if is_running && animations_enabled()
        border_shimmer!(
            buf,
            area,
            focused ? tstyle(:accent).fg : tstyle(:border).fg,
            m.tick;
            box = BOX_HEAVY,
            intensity = focused ? 0.3 : 0.2,
        )
        if area.width > 4
            set_string!(
                buf,
                area.x + 2,
                area.y,
                " Agent Horde$scroll_hint ",
                tstyle(:accent, bold = true),
            )
        end
        inner =
            Rect(area.x + 1, area.y + 1, max(0, area.width - 2), max(0, area.height - 2))
    elseif is_complete && animations_enabled()
        border_color = has_failures ? tstyle(:warning).fg : tstyle(:success).fg
        border_shimmer!(
            buf,
            area,
            focused ? border_color : tstyle(:border).fg,
            m.tick;
            box = BOX_HEAVY,
            intensity = focused ? 0.2 : 0.1,
        )
        if area.width > 4
            n_ok = count(a -> a.status == :ok, agents)
            title =
                has_failures ? " Horde ($n_ok/$n)$scroll_hint " :
                " Horde (all passed)$scroll_hint "
            set_string!(
                buf,
                area.x + 2,
                area.y,
                title,
                tstyle(has_failures ? :warning : :success, bold = true),
            )
        end
        inner =
            Rect(area.x + 1, area.y + 1, max(0, area.width - 2), max(0, area.height - 2))
    else
        block = Block(
            title = " Agent Horde$scroll_hint ",
            border_style = focused ? tstyle(:accent) : tstyle(:border),
            title_style = focused ? tstyle(:accent, bold = true) : tstyle(:text_dim),
        )
        inner = render(block, area, buf)
    end
    inner.width < 6 && return

    # Animated noise background while running
    if is_running && animations_enabled()
        fill_noise!(
            buf,
            inner,
            tstyle(:border).fg,
            tstyle(:text_dim).fg,
            m.tick;
            scale = 0.3,
            speed = 0.02,
        )
    else
        for row = inner.y:bottom(inner)
            for col = inner.x:right(inner)
                set_char!(buf, col, row, ' ', Style())
            end
        end
    end

    x = inner.x + 1
    y_base = inner.y  # top of the viewport
    w = inner.width - 2
    y_bottom = bottom(inner)

    # All content is rendered at virtual y positions, then shifted by -scroll_off.
    # We only draw cells that fall within the viewport.
    vy = 0  # virtual y offset from content top

    # Summary stats
    n_ok = count(a -> a.status == :ok, agents)
    n_fail = count(a -> a.status == :fail, agents)
    n_active = count(a -> a.status in (:sending, :running), agents)

    if is_complete
        # Completion gauge with shimmer
        screen_y = y_base + vy - scroll_off
        if screen_y >= y_base && screen_y <= y_bottom
            ratio = n > 0 ? n_ok / n : 0.0
            gauge = Gauge(
                ratio;
                label = "$(n_ok)/$(n) passed",
                filled_style = tstyle(:success),
                empty_style = n_fail > 0 ? tstyle(:error) : tstyle(:text_dim),
                tick = m.tick,
            )
            render(gauge, Rect(x, screen_y, w, 1), buf)
        end
        vy += 2
    elseif is_running
        # Animated running progress bar
        screen_y = y_base + vy - scroll_off
        if screen_y >= y_base && screen_y <= y_bottom
            done_count = n_ok + n_fail
            ratio = n > 0 ? done_count / n : 0.0
            si = mod1(m.tick ÷ 2, length(SPINNER_BRAILLE))
            gauge = Gauge(
                ratio;
                label = "$(SPINNER_BRAILLE[si]) $(done_count)/$(n) ($n_active active)",
                filled_style = tstyle(:accent),
                empty_style = tstyle(:text_dim),
                tick = m.tick,
            )
            render(gauge, Rect(x, screen_y, w, 1), buf)
        end
        vy += 2
    end

    # Agent grid — each agent as a compact cell with animated effects
    cell_w = max(8, min(12, w ÷ max(1, min(n, 5))))
    grid_cols = max(1, w ÷ cell_w)
    rows_needed = cld(n, grid_cols)

    # Color wave palette for active agents
    wave_colors = [tstyle(:accent).fg, tstyle(:primary).fg, tstyle(:secondary).fg]

    for (i, agent) in enumerate(agents)
        ci = mod1(i, grid_cols) - 1
        ri = (i - 1) ÷ grid_cols
        ax = x + ci * cell_w
        ay_virtual = vy + ri * 3  # virtual y position for this agent cell

        # Convert to screen coordinates
        ay = y_base + ay_virtual - scroll_off

        # Skip if entirely above viewport
        ay + 2 < y_base && continue
        # Stop if entirely below viewport
        ay > y_bottom && break

        # Agent icon and status with per-agent animation
        icon, icon_style = if agent.status == :ok
            "●", tstyle(:success, bold = true)
        elseif agent.status == :fail
            "✗", tstyle(:error, bold = true)
        elseif agent.status == :running
            si = mod1(m.tick ÷ 2 + i * 3, length(SPINNER_BRAILLE))
            if animations_enabled()
                wave_fg = color_wave(m.tick, i, wave_colors; speed = 0.06, spread = 0.12)
                "$(SPINNER_BRAILLE[si])", Style(fg = wave_fg, bold = true)
            else
                "$(SPINNER_BRAILLE[si])", tstyle(:accent)
            end
        elseif agent.status == :sending
            si = mod1(m.tick ÷ 3 + i * 5, length(SPINNER_BRAILLE))
            if animations_enabled()
                p = breathe(m.tick + i * 11; period = 45)
                base = to_rgb(tstyle(:warning).fg)
                "$(SPINNER_BRAILLE[si])", Style(fg = brighten(base, p * 0.3), bold = true)
            else
                "$(SPINNER_BRAILLE[si])", tstyle(:warning)
            end
        elseif agent.status == :init
            "◐", tstyle(:text_dim)
        else
            "○", tstyle(:text_dim)
        end

        # Row 1: icon + agent id (only if on screen)
        if ay >= y_base && ay <= y_bottom
            set_string!(buf, ax, ay, icon, icon_style)
            id_style = if agent.status in (:running, :sending) && animations_enabled()
                f = flicker(m.tick, i; intensity = 0.15, speed = 0.1)
                base = to_rgb(tstyle(:text).fg)
                Style(fg = brighten(base, (1.0 - f) * 0.2))
            else
                tstyle(:text)
            end
            set_string!(buf, ax + 2, ay, "A$(agent.agent_id)", id_style)
        end

        # Row 2: elapsed time or status text
        if ay + 1 >= y_base && ay + 1 <= y_bottom
            if agent.elapsed > 0
                time_str = "$(round(agent.elapsed, digits=1))s"
                time_style = if agent.status == :ok
                    tstyle(:success)
                elseif agent.status == :fail
                    tstyle(:error)
                else
                    tstyle(:text_dim)
                end
                set_string!(buf, ax, ay + 1, time_str, time_style)
            else
                status_str = string(agent.status)
                set_string!(
                    buf,
                    ax,
                    ay + 1,
                    first(status_str, cell_w - 1),
                    tstyle(:text_dim),
                )
            end
        end

        # Row 3: animated progress bar
        if ay + 2 >= y_base && ay + 2 <= y_bottom
            bar_w = min(cell_w - 1, 8)
            if agent.status in (:running, :sending)
                if animations_enabled()
                    scan_pos = mod(m.tick ÷ 2 + i * 3, bar_w * 2)
                    for bx = 0:bar_w-1
                        dist =
                            abs(bx - (scan_pos < bar_w ? scan_pos : bar_w * 2 - scan_pos))
                        brightness = max(0.0, 1.0 - dist / 3.0)
                        ch =
                            brightness > 0.6 ? '█' :
                            brightness > 0.3 ? '▓' : brightness > 0.1 ? '░' : ' '
                        base = to_rgb(tstyle(:accent).fg)
                        fg = dim_color(base, 1.0 - brightness * 0.8)
                        set_char!(buf, ax + bx, ay + 2, ch, Style(fg = fg))
                    end
                else
                    set_string!(buf, ax, ay + 2, repeat("░", bar_w), tstyle(:text_dim))
                end
            elseif agent.progress > 0 || agent.events > 0
                max_ev = max(agent.events, agent.progress, 1)
                filled = min(bar_w, cld(agent.progress * bar_w, max_ev))
                bar = repeat("█", filled) * repeat("░", bar_w - filled)
                set_string!(
                    buf,
                    ax,
                    ay + 2,
                    bar,
                    tstyle(agent.status == :ok ? :success : :accent),
                )
            end
        end
    end

    # Bottom section: sparkline chart for completed tests
    if is_complete && !isempty(agents)
        times = [a.elapsed for a in agents if a.elapsed > 0]
        if !isempty(times)
            spark_vy = vy + rows_needed * 3 + 1
            spark_y = y_base + spark_vy - scroll_off
            spark_h = y_bottom - spark_y + 1
            if spark_h >= 2 && spark_y >= y_base && spark_y <= y_bottom
                sparkline = Sparkline(
                    times;
                    block = Block(
                        title = " Response Times ",
                        border_style = tstyle(:border),
                        title_style = tstyle(:text_dim),
                    ),
                    style = tstyle(:accent),
                )
                render(sparkline, Rect(x, spark_y, w, min(spark_h, 5)), buf)
            end
        end
    end
end

# ── Client Status Detection ──────────────────────────────────────────────────

"""Check if any of the given files contain "julia-repl"."""
function _detect_in_files(paths::String...)
    for p in paths
        isfile(p) || continue
        try
            occursin("julia-repl", read(p, String)) && return true
        catch
        end
    end
    return false
end

function _dict_has_julia_repl_server(x)::Bool
    if x isa AbstractDict
        if haskey(x, "mcpServers")
            servers = x["mcpServers"]
            if servers isa AbstractDict
                for k in keys(servers)
                    occursin("julia-repl", lowercase(string(k))) && return true
                end
            end
        end
        for v in values(x)
            _dict_has_julia_repl_server(v) && return true
        end
    elseif x isa AbstractVector
        for v in x
            _dict_has_julia_repl_server(v) && return true
        end
    end
    return false
end

function _detect_claude_configured()::Bool
    # Check CLI first (most authoritative).
    if Sys.which("claude") !== nothing
        try
            out = read(pipeline(`claude mcp list`; stderr = devnull), String)
            for ln in split(out, '\n')
                s = strip(lowercase(ln))
                startswith(s, "julia-repl:") && return true
            end
            return false
        catch
            # Fall through to file checks if CLI invocation fails.
        end
    end

    # Fallback: file-based detection.
    paths = (
        joinpath(homedir(), ".claude", "settings.json"),
        joinpath(homedir(), ".claude", "settings.local.json"),
        joinpath(pwd(), ".mcp.json"),
        joinpath(pwd(), ".claude", "settings.local.json"),
    )
    for p in paths
        isfile(p) || continue
        try
            cfg = JSON.parsefile(p)
            _dict_has_julia_repl_server(cfg) && return true
        catch
        end
        try
            occursin("julia-repl", read(p, String)) && return true
        catch
        end
    end
    return false
end

# Client detection runs as independent async tasks via Tachikoma TaskQueue.
# Each check spawns separately so fast file checks return immediately
# while slower CLI checks (e.g. `claude mcp list`) don't block anything.

function _refresh_client_status_async!(m::MCPReplModel)
    q = m._task_queue

    # Claude Code — may shell out to `claude mcp list`, so gets its own task
    spawn_task!(q, :client_status) do
        "Claude Code" => _detect_claude_configured()
    end

    # Gemini
    spawn_task!(q, :client_status) do
        "Gemini CLI" => _detect_in_files(
            joinpath(homedir(), ".gemini", "settings.json"),
            joinpath(pwd(), ".gemini", "settings.json"),
        )
    end

    # Codex
    spawn_task!(q, :client_status) do
        "OpenAI Codex" => _detect_in_files(joinpath(homedir(), ".codex", "config.toml"))
    end

    # Copilot
    spawn_task!(q, :client_status) do
        "GitHub Copilot" =>
            _detect_in_files(joinpath(homedir(), ".copilot", "mcp-config.json"))
    end

    # VS Code
    vscode_user_dir = if Sys.isapple()
        joinpath(homedir(), "Library", "Application Support", "Code", "User")
    elseif Sys.iswindows()
        joinpath(get(ENV, "APPDATA", joinpath(homedir(), "AppData", "Roaming")), "Code", "User")
    else
        joinpath(get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")), "Code", "User")
    end
    spawn_task!(q, :client_status) do
        "VS Code" => _detect_in_files(
            joinpath(vscode_user_dir, "mcp.json"),
            joinpath(pwd(), ".vscode", "mcp.json"),
        )
    end

    # KiloCode
    spawn_task!(q, :client_status) do
        "KiloCode" => _detect_in_files(joinpath(_kilo_settings_dir(), "mcp_settings.json"))
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

"""KiloCode settings directory inside VS Code's globalStorage."""
function _kilo_settings_dir()
    gs = if Sys.isapple()
        joinpath(homedir(), "Library", "Application Support", "Code", "User", "globalStorage")
    elseif Sys.iswindows()
        joinpath(
            get(ENV, "APPDATA", joinpath(homedir(), "AppData", "Roaming")),
            "Code",
            "User",
            "globalStorage",
        )
    else
        joinpath(
            get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")),
            "Code",
            "User",
            "globalStorage",
        )
    end
    joinpath(gs, "kilocode.kilo-code", "settings")
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
# ── Tests Tab ─────────────────────────────────────────────────────────────────

function view_tests(m::MCPReplModel, area::Rect, buf::Buffer)
    panes = split_layout(m.tests_layout, area)
    length(panes) < 2 && return

    # ── Left pane: test runs list ──
    _view_test_runs_list(m, panes[1], buf)

    # ── Right pane: results or raw output ──
    _view_test_detail(m, panes[2], buf)

    render_resize_handles!(buf, m.tests_layout)
end

"""Render the list of test runs in the left pane (newest first)."""
function _view_test_runs_list(m::MCPReplModel, area::Rect, buf::Buffer)
    runs = m.test_runs
    items = ListItem[]

    # Display newest first (reversed)
    for i in reverse(eachindex(runs))
        run = runs[i]
        project_name = basename(run.project_path)
        elapsed = if run.finished_at !== nothing
            dt = Dates.value(run.finished_at - run.started_at) / 1000.0
            "$(round(dt, digits=1))s"
        else
            dt = Dates.value(now() - run.started_at) / 1000.0
            "$(round(dt, digits=0))s..."
        end

        text, style = if run.status == RUN_RUNNING
            si = mod1(m.tick ÷ 3, length(SPINNER_BRAILLE))
            ("$(SPINNER_BRAILLE[si]) $project_name $elapsed", tstyle(:accent))
        elseif run.status == RUN_PASSED
            (". $project_name $(run.total_pass) pass $elapsed", tstyle(:success))
        elseif run.status == RUN_FAILED
            (
                "X $project_name $(run.total_pass) pass, $(run.total_fail) fail $elapsed",
                tstyle(:error),
            )
        elseif run.status == RUN_ERROR
            ("! $project_name error $elapsed", tstyle(:error))
        elseif run.status == RUN_CANCELLED
            ("- $project_name cancelled", tstyle(:text_dim))
        else
            ("  $project_name", tstyle(:text))
        end

        push!(items, ListItem(text, style))
    end

    if isempty(items)
        push!(
            items,
            ListItem("  No test runs yet. Press [r] to run tests.", tstyle(:text_dim)),
        )
    end

    # Map selected_test_run (1-based index into runs) to reversed display position
    n = length(runs)
    display_selected = if m.selected_test_run >= 1 && m.selected_test_run <= n
        n - m.selected_test_run + 1
    else
        0
    end

    follow_str = m.test_follow ? "[F]ollow:on" : "[F]ollow:off"
    render(
        SelectableList(
            items;
            selected = display_selected,
            block = Block(
                title = " Test Runs ($n) $follow_str ",
                border_style = _pane_border(m, 6, 1),
                title_style = _pane_title(m, 6, 1),
            ),
            highlight_style = tstyle(:accent, bold = true),
            tick = m.tick,
        ),
        area,
        buf,
    )
end

"""Render the test detail view (results table or raw output)."""
function _view_test_detail(m::MCPReplModel, area::Rect, buf::Buffer)
    sel = m.selected_test_run
    if sel < 1 || sel > length(m.test_runs)
        render(
            Block(
                title = " Results ",
                border_style = _pane_border(m, 6, 2),
                title_style = _pane_title(m, 6, 2),
            ),
            area,
            buf,
        )
        return
    end

    run = m.test_runs[sel]
    mode_str = m.test_view_mode == :results ? "Results" : "Output"
    title = " $mode_str [o]toggle "

    if m.test_view_mode == :output
        # Raw output scroll pane
        _view_test_raw_output(m, run, area, buf, title)
    else
        # Structured results view
        _view_test_results(m, run, area, buf, title)
    end
end

"""Render structured test results as a table with failure details."""
function _view_test_results(
    m::MCPReplModel,
    run::TestRun,
    area::Rect,
    buf::Buffer,
    title::String,
)
    # Build content lines for a ScrollPane
    if m.test_output_pane === nothing || m._test_output_synced == 0
        lines = Vector{Span}[]

        # Status header
        status_style = if run.status == RUN_PASSED
            tstyle(:success)
        elseif run.status in (RUN_FAILED, RUN_ERROR)
            tstyle(:error)
        elseif run.status == RUN_RUNNING
            tstyle(:accent)
        else
            tstyle(:text_dim)
        end
        status_str = uppercase(string(run.status))[5:end]  # strip "RUN_"
        push!(
            lines,
            [
                Span("Status: ", tstyle(:text)),
                Span(status_str, status_style),
                Span("  Pass: $(run.total_pass)", tstyle(:success)),
                Span(
                    "  Fail: $(run.total_fail)",
                    run.total_fail > 0 ? tstyle(:error) : tstyle(:text),
                ),
                Span(
                    "  Error: $(run.total_error)",
                    run.total_error > 0 ? tstyle(:error) : tstyle(:text),
                ),
            ],
        )
        push!(lines, Span[])

        # Testset results
        if !isempty(run.results)
            push!(lines, [Span("Testsets:", tstyle(:text, bold = true))])
            for r in run.results
                indent = "  "^(r.depth + 1)
                marker_style =
                    (r.fail_count > 0 || r.error_count > 0) ? tstyle(:error) :
                    tstyle(:success)
                marker = (r.fail_count > 0 || r.error_count > 0) ? "X" : "."
                counts = "$(r.pass_count)p"
                r.fail_count > 0 && (counts *= " $(r.fail_count)f")
                r.error_count > 0 && (counts *= " $(r.error_count)e")
                push!(
                    lines,
                    [
                        Span("$indent[$marker] ", marker_style),
                        Span(r.name, tstyle(:text)),
                        Span("  $counts", marker_style),
                    ],
                )
            end
        end

        # Failure details
        if !isempty(run.failures)
            push!(lines, Span[])
            push!(lines, [Span("Failures:", tstyle(:error, bold = true))])
            push!(lines, [Span("-"^50, tstyle(:border))])
            for (i, f) in enumerate(run.failures)
                push!(
                    lines,
                    [
                        Span("  $i) ", tstyle(:error)),
                        Span("$(f.file):$(f.line)", tstyle(:text)),
                    ],
                )
                !isempty(f.testset) &&
                    push!(lines, [Span("     Testset: $(f.testset)", tstyle(:text_dim))])
                !isempty(f.expression) &&
                    push!(lines, [Span("     Expr: $(f.expression)", tstyle(:warning))])
                !isempty(f.evaluated) &&
                    push!(lines, [Span("     Eval: $(f.evaluated)", tstyle(:warning))])
                if !isempty(f.backtrace)
                    for bt_line in first(split(f.backtrace, "\n"), 3)
                        push!(lines, [Span("     $bt_line", tstyle(:text_dim))])
                    end
                end
                push!(lines, Span[])
            end
        end

        # If running and no results yet, show progress from raw output
        if run.status == RUN_RUNNING && isempty(run.results)
            n_lines = length(run.raw_output)
            push!(lines, [Span("Running... ($n_lines lines of output)", tstyle(:accent))])
            # Show last few lines of raw output
            for line in last(run.raw_output, min(10, n_lines))
                push!(lines, [Span(line, tstyle(:text_dim))])
            end
        end

        m.test_output_pane = ScrollPane(
            lines;
            following = run.status == RUN_RUNNING,
            reverse = false,
            block = Block(
                title = title,
                border_style = _pane_border(m, 6, 2),
                title_style = _pane_title(m, 6, 2),
            ),
            show_scrollbar = true,
        )
        m._test_output_synced = length(run.raw_output)
    else
        # Check if new output arrived — rebuild pane
        if length(run.raw_output) > m._test_output_synced
            m._test_output_synced = 0
            m.test_output_pane = nothing
            _view_test_results(m, run, area, buf, title)
            return
        end
    end

    m.test_output_pane !== nothing && render(m.test_output_pane, area, buf)
end

"""Render raw test output in a ScrollPane."""
function _view_test_raw_output(
    m::MCPReplModel,
    run::TestRun,
    area::Rect,
    buf::Buffer,
    title::String,
)
    if m.test_output_pane === nothing || m._test_output_synced == 0
        lines = Vector{Span}[]
        for line in run.raw_output
            style = if startswith(line, "TEST_RUNNER:")
                tstyle(:accent)
            elseif contains(line, "Error") ||
                   contains(line, "FAILED") ||
                   contains(line, "FAIL")
                tstyle(:error)
            elseif contains(line, "Pass") || contains(line, "PASSED")
                tstyle(:success)
            else
                tstyle(:text)
            end
            push!(lines, [Span(line, style)])
        end

        m.test_output_pane = ScrollPane(
            lines;
            following = run.status == RUN_RUNNING,
            reverse = false,
            block = Block(
                title = title,
                border_style = _pane_border(m, 6, 2),
                title_style = _pane_title(m, 6, 2),
            ),
            show_scrollbar = true,
        )
        m._test_output_synced = length(run.raw_output)
    else
        # New output — append to pane
        if length(run.raw_output) > m._test_output_synced
            pane = m.test_output_pane
            if pane !== nothing
                for i = (m._test_output_synced+1):length(run.raw_output)
                    line = run.raw_output[i]
                    style = if contains(line, "Error") || contains(line, "FAIL")
                        tstyle(:error)
                    elseif contains(line, "Pass")
                        tstyle(:success)
                    else
                        tstyle(:text)
                    end
                    push_line!(pane, [Span(line, style)])
                end
                m._test_output_synced = length(run.raw_output)
            end
        end
    end

    m.test_output_pane !== nothing && render(m.test_output_pane, area, buf)
end

"""Handle char keys on the Tests tab."""
function _handle_tests_key!(m::MCPReplModel, evt::KeyEvent)
    if evt.char == 'r'
        # Trigger a new test run
        _start_test_run_from_tui!(m)
    elseif evt.char == 'o'
        # Toggle results/output view
        m.test_view_mode = m.test_view_mode == :results ? :output : :results
        m.test_output_pane = nothing
        m._test_output_synced = 0
    elseif evt.char == 'F'
        # Toggle follow mode
        m.test_follow = !m.test_follow
    elseif evt.char == 'x'
        # Cancel running test
        sel = m.selected_test_run
        if sel >= 1 && sel <= length(m.test_runs)
            run = m.test_runs[sel]
            if run.status == RUN_RUNNING
                cancel_test_run!(run)
            end
        end
    end
end

"""Handle escape on the Tests tab — cancel running test."""
function _handle_tests_escape!(m::MCPReplModel)
    sel = m.selected_test_run
    if sel >= 1 && sel <= length(m.test_runs)
        run = m.test_runs[sel]
        if run.status == RUN_RUNNING
            cancel_test_run!(run)
            return
        end
    end
    # If no running test, do nothing (don't quit)
end

"""Start a test run from the TUI using the first connected bridge session."""
function _start_test_run_from_tui!(m::MCPReplModel)
    mgr = m.conn_mgr
    mgr === nothing && return

    conns = connected_sessions(mgr)
    isempty(conns) && return

    # Use first connected session (or could prompt for selection)
    conn = conns[1]
    project_path = conn.project_path

    runtests_path = joinpath(project_path, "test", "runtests.jl")
    if !isfile(runtests_path)
        _push_log!(:warn, "No test/runtests.jl found in $project_path")
        return
    end

    run = spawn_test_run(project_path)
    push!(m.test_runs, run)
    m.selected_test_run = length(m.test_runs)
    m.test_output_pane = nothing
    m._test_output_synced = 0
end

function tui(; port::Int = 2828, theme_name::Symbol = :kokaku)
    if Threads.nthreads() < 2
        @warn """MCPRepl TUI running with only 1 thread — UI may be unresponsive.
                 Start Julia with: julia -t auto
                 Or set: JULIA_NUM_THREADS=auto"""
    end
    set_theme!(theme_name)
    model = MCPReplModel(server_port = port)
    app(model; fps = 30)
end
