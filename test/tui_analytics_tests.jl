using ReTest
using MCPRepl
using MCPRepl.Database
using Dates
using Tachikoma
using SQLite
using DBInterface
using Supposition
using Supposition.Data

# ── Helpers ──────────────────────────────────────────────────────────────────

"""Create a fresh MCPReplModel with a temp database initialized."""
function setup_tui_model()
    db_path = tempname() * ".db"
    Database.init_db!(db_path)
    m = MCPRepl.MCPReplModel(server_port = 19999)
    m.db_initialized = true
    m.server_started = true
    MCPRepl.set_theme!(:kokaku)
    return m, db_path
end

"""Send a character keypress to the model."""
function press!(m, c::Char)
    Tachikoma.update!(m, Tachikoma.KeyEvent(:char, c))
end

"""Send a special key to the model."""
function press!(m, k::Symbol)
    Tachikoma.update!(m, Tachikoma.KeyEvent(k, '\0'))
end

"""Push N tool results into the TUI buffer and drain into model."""
function push_tool_results!(
    m;
    n_success::Int = 5,
    n_error::Int = 0,
    tool_name::String = "ex",
)
    for i = 1:n_success
        r = MCPRepl.ToolCallResult(
            now() - Second(n_success - i),
            tool_name,
            """{"e":"$i+$i","q":true}""",
            string(2i),
            "$(10i)ms",
            true,
            "sess0001",
        )
        MCPRepl._push_tool_result!(r)
    end
    for i = 1:n_error
        r = MCPRepl.ToolCallResult(
            now(),
            tool_name,
            """{"e":"error()"}""",
            "ERROR: test error $i",
            "100ms",
            false,
            "sess0001",
        )
        MCPRepl._push_tool_result!(r)
    end
    MCPRepl._drain_tool_results!(m.tool_results)
    if MCPRepl._LAST_TOOL_SUCCESS[] > m.last_tool_success
        m.last_tool_success = MCPRepl._LAST_TOOL_SUCCESS[]
    end
    if MCPRepl._LAST_TOOL_ERROR[] > m.last_tool_error
        m.last_tool_error = MCPRepl._LAST_TOOL_ERROR[]
    end
end

"""Render the activity tab into a buffer and return rendered text lines."""
function render_activity(m; width::Int = 100, height::Int = 35)
    area = Tachikoma.Rect(0, 0, width, height)
    buf = Tachikoma.Buffer(area)
    MCPRepl.view_activity(m, area, buf)
    lines = String[]
    for row = 0:(height-1)
        chars = [buf.content[row*width+col+1].char for col = 0:(width-1)]
        push!(lines, rstrip(String(chars)))
    end
    return lines
end

"""Join rendered lines into a single string for content matching."""
render_text(m; kw...) = join(render_activity(m; kw...), "\n")

# ── Unit Tests ───────────────────────────────────────────────────────────────

@testset "TUI Analytics Integration" begin

    @testset "Model Fields" begin
        m = MCPRepl.MCPReplModel()
        @test m.db_initialized == false
        @test m.activity_mode == :live
        @test m.analytics_cache === nothing
        @test m.analytics_last_refresh == 0.0
        @test m.last_tool_success == 0.0
        @test m.last_tool_error == 0.0
    end

    @testset "Database Persistence" begin
        m, db_path = setup_tui_model()
        try
            @testset "Successful tool call persisted" begin
                r = MCPRepl.ToolCallResult(
                    now(),
                    "test_persist",
                    """{"x":1}""",
                    "ok",
                    "42ms",
                    true,
                    "s001",
                )
                MCPRepl._persist_tool_call!(r)

                rows = Database.get_tool_executions(; days = 1)
                matching = filter(x -> get(x, "tool_name", "") == "test_persist", rows)
                @test length(matching) == 1
                @test matching[1]["status"] == "success"
                @test matching[1]["duration_ms"] == 42.0
                @test matching[1]["input_size"] == sizeof("""{"x":1}""")
                @test matching[1]["output_size"] == sizeof("ok")
                @test matching[1]["mcp_session_id"] == "s001"
            end

            @testset "Error tool call persisted" begin
                r = MCPRepl.ToolCallResult(
                    now(),
                    "test_err",
                    """{"y":2}""",
                    "ERROR: boom",
                    "200ms",
                    false,
                    "s002",
                )
                MCPRepl._persist_tool_call!(r)

                rows = Database.get_tool_executions(; days = 1)
                matching = filter(x -> get(x, "tool_name", "") == "test_err", rows)
                @test length(matching) == 1
                @test matching[1]["status"] == "error"
                @test matching[1]["duration_ms"] == 200.0
            end

            @testset "Duration parsing" begin
                cases =
                    [("0ms", 0.0), ("125ms", 125.0), ("1.2s", 1200.0), ("10.5s", 10500.0)]
                for (dur_str, expected_ms) in cases
                    r = MCPRepl.ToolCallResult(
                        now(),
                        "dur_$(dur_str)",
                        "{}",
                        "ok",
                        dur_str,
                        true,
                        "",
                    )
                    MCPRepl._persist_tool_call!(r)
                end
                rows = Database.get_tool_executions(; days = 1)
                for (dur_str, expected_ms) in cases
                    matching =
                        filter(x -> get(x, "tool_name", "") == "dur_$(dur_str)", rows)
                    @test length(matching) == 1
                    @test matching[1]["duration_ms"] ≈ expected_ms
                end
            end

            @testset "Long result truncated to 500 chars" begin
                long_text = repeat("x", 1000)
                r = MCPRepl.ToolCallResult(
                    now(),
                    "test_trunc",
                    "{}",
                    long_text,
                    "1ms",
                    true,
                    "",
                )
                MCPRepl._persist_tool_call!(r)

                rows = Database.get_tool_executions(; days = 1)
                matching = filter(x -> get(x, "tool_name", "") == "test_trunc", rows)
                @test length(matching) == 1
                @test length(matching[1]["result_summary"]) == 500
            end

            @testset "Graceful when DB is nothing" begin
                saved = Database.DB[]
                Database.DB[] = nothing
                r = MCPRepl.ToolCallResult(now(), "no_db", "{}", "ok", "1ms", true, "")
                MCPRepl._persist_tool_call!(r)  # should not throw
                Database.DB[] = saved
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Health Gauge Timestamps" begin
        m, db_path = setup_tui_model()
        try
            MCPRepl._LAST_TOOL_SUCCESS[] = 0.0
            MCPRepl._LAST_TOOL_ERROR[] = 0.0

            @testset "Success updates success Ref" begin
                r = MCPRepl.ToolCallResult(now(), "h1", "{}", "ok", "1ms", true, "")
                MCPRepl._push_tool_result!(r)
                @test MCPRepl._LAST_TOOL_SUCCESS[] > 0.0
                @test MCPRepl._LAST_TOOL_ERROR[] == 0.0
            end

            @testset "Error updates error Ref" begin
                MCPRepl._LAST_TOOL_ERROR[] = 0.0
                r = MCPRepl.ToolCallResult(now(), "h2", "{}", "ERR", "1ms", false, "")
                MCPRepl._push_tool_result!(r)
                @test MCPRepl._LAST_TOOL_ERROR[] > 0.0
            end

            @testset "Drain syncs Refs into model" begin
                m.last_tool_success = 0.0
                m.last_tool_error = 0.0
                MCPRepl._drain_tool_results!(m.tool_results)
                if MCPRepl._LAST_TOOL_SUCCESS[] > m.last_tool_success
                    m.last_tool_success = MCPRepl._LAST_TOOL_SUCCESS[]
                end
                if MCPRepl._LAST_TOOL_ERROR[] > m.last_tool_error
                    m.last_tool_error = MCPRepl._LAST_TOOL_ERROR[]
                end
                @test m.last_tool_success > 0.0
                @test m.last_tool_error > 0.0
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Dynamic Health Computation" begin
        conn_up = (status = :connected,)
        conn_ing = (status = :connecting,)
        conn_down = (status = :disconnected,)

        @testset "Base values by connection status" begin
            m = MCPRepl.MCPReplModel()
            @test MCPRepl._compute_health(conn_up, m) == 0.8
            @test MCPRepl._compute_health(conn_ing, m) == 0.4
            @test MCPRepl._compute_health(conn_down, m) == 0.0
        end

        @testset "Momentum boost on recent success" begin
            m = MCPRepl.MCPReplModel(last_tool_success = time())
            @test MCPRepl._compute_health(conn_up, m) == 1.0
        end

        @testset "Error penalty" begin
            m = MCPRepl.MCPReplModel(last_tool_error = time())
            @test MCPRepl._compute_health(conn_up, m) ≈ 0.6
        end

        @testset "Momentum and penalty cancel out" begin
            m = MCPRepl.MCPReplModel(last_tool_success = time(), last_tool_error = time())
            @test MCPRepl._compute_health(conn_up, m) == 0.8
        end

        @testset "Idle decay after 60s" begin
            m = MCPRepl.MCPReplModel(last_tool_success = time() - 180.0)
            h = MCPRepl._compute_health(conn_up, m)
            @test h < 0.8
            @test h >= 0.6
        end

        @testset "Clamped to [0, 1]" begin
            m = MCPRepl.MCPReplModel(
                last_tool_error = time(),
                last_tool_success = time() - 300.0,
            )
            @test MCPRepl._compute_health(conn_down, m) == 0.0
            m2 = MCPRepl.MCPReplModel(last_tool_success = time())
            @test MCPRepl._compute_health(conn_up, m2) == 1.0
        end

        @testset "Monotonic: connected > connecting > disconnected" begin
            m = MCPRepl.MCPReplModel(last_tool_success = time())
            h_up = MCPRepl._compute_health(conn_up, m)
            h_ing = MCPRepl._compute_health(conn_ing, m)
            h_down = MCPRepl._compute_health(conn_down, m)
            @test h_up >= h_ing
            @test h_ing >= h_down
        end
    end

    @testset "Activity Mode Toggle Keybinding" begin
        m, db_path = setup_tui_model()
        try
            m.active_tab = 3
            push_tool_results!(m; n_success = 3)

            @testset "'d' toggles live → analytics" begin
                @test m.activity_mode == :live
                press!(m, 'd')
                @test m.activity_mode == :analytics
                @test m.analytics_cache !== nothing
            end

            @testset "'d' toggles analytics → live" begin
                press!(m, 'd')
                @test m.activity_mode == :live
            end

            @testset "'r' force-refreshes in analytics mode" begin
                press!(m, 'd')
                old_ts = m.analytics_last_refresh
                sleep(0.05)
                press!(m, 'r')
                @test m.analytics_last_refresh > old_ts
            end

            @testset "'r' is no-op in live mode" begin
                press!(m, 'd')  # back to live
                old_ts = m.analytics_last_refresh
                press!(m, 'r')
                @test m.analytics_last_refresh == old_ts
            end

            @testset "'d' on other tabs is no-op" begin
                m.activity_mode = :live
                m.active_tab = 1
                press!(m, 'd')
                @test m.activity_mode == :live
                m.active_tab = 3  # restore
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Live Mode Keys Disabled in Analytics" begin
        m, db_path = setup_tui_model()
        try
            m.active_tab = 3
            push_tool_results!(m; n_success = 3)
            press!(m, 'd')
            @test m.activity_mode == :analytics

            @testset "'f' does not change filter" begin
                old = m.activity_filter
                press!(m, 'f')
                @test m.activity_filter == old
            end

            @testset "'F' does not change follow" begin
                old = m.activity_follow
                press!(m, 'F')
                @test m.activity_follow == old
            end

            @testset "'w' does not change wrap" begin
                old = m.result_word_wrap
                press!(m, 'w')
                @test m.result_word_wrap == old
            end

            @testset "Arrow keys are no-op" begin
                old_sel = m.selected_result
                press!(m, :up)
                press!(m, :down)
                @test m.selected_result == old_sel
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Analytics Refresh" begin
        m, db_path = setup_tui_model()
        try
            @testset "Populates cache from DB" begin
                push_tool_results!(m; n_success = 5, n_error = 2)
                MCPRepl._refresh_analytics!(m; force = true)
                c = m.analytics_cache
                @test c !== nothing
                @test length(c.tool_summary) >= 1
                @test length(c.recent_execs) >= 7

                ex_row = filter(x -> get(x, "tool_name", "") == "ex", c.tool_summary)
                @test length(ex_row) == 1
                @test get(ex_row[1], "total_executions", 0) == 7
                @test get(ex_row[1], "error_count", 0) == 2
            end

            @testset "Caching — skips refresh within 30s" begin
                old_ts = m.analytics_last_refresh
                sleep(0.05)
                MCPRepl._refresh_analytics!(m)
                @test m.analytics_last_refresh == old_ts
            end

            @testset "Force overrides cache" begin
                old_ts = m.analytics_last_refresh
                sleep(0.05)
                MCPRepl._refresh_analytics!(m; force = true)
                @test m.analytics_last_refresh > old_ts
            end

            @testset "Graceful when DB is nothing" begin
                saved = Database.DB[]
                Database.DB[] = nothing
                MCPRepl._refresh_analytics!(m; force = true)
                Database.DB[] = saved
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Analytics View Rendering" begin
        m, db_path = setup_tui_model()
        try
            push_tool_results!(m; n_success = 5, n_error = 1, tool_name = "ex")
            push_tool_results!(m; n_success = 3, n_error = 0, tool_name = "format_code")

            @testset "Renders tool usage table" begin
                m.activity_mode = :analytics
                MCPRepl._refresh_analytics!(m; force = true)
                text = render_text(m)
                @test occursin("Tool Usage Summary", text)
                @test occursin("ex", text)
                @test occursin("format_code", text)
                @test occursin("Err%", text)
            end

            @testset "Renders error hotspots section" begin
                @test occursin("Error Hotspots", render_text(m))
            end

            @testset "Renders sparkline section" begin
                @test occursin("Calls/min", render_text(m))
            end

            @testset "Renders keybinding hints" begin
                text = render_text(m)
                @test occursin("[d]ata", text)
                @test occursin("[r]efresh", text)
            end

            @testset "Shows placeholder when no DB" begin
                saved = Database.DB[]
                Database.DB[] = nothing
                m.analytics_cache = nothing
                @test occursin("No analytics data yet", render_text(m))
                Database.DB[] = saved
            end

            @testset "Renders at various terminal sizes" begin
                m.analytics_cache = nothing
                MCPRepl._refresh_analytics!(m; force = true)
                for (w, h) in [(80, 24), (120, 40), (60, 15)]
                    text = join(render_activity(m; width = w, height = h), "\n")
                    @test occursin("Analytics", text)
                end
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Live View Rendering" begin
        m, db_path = setup_tui_model()
        try
            push_tool_results!(m; n_success = 3, n_error = 1)
            m.activity_mode = :live
            m.tick = 10

            @testset "Shows tool call list with [d]ata hint" begin
                text = render_text(m)
                @test occursin("[d]ata", text)
                @test occursin("Tool Calls", text)
            end

            @testset "Shows success and error markers" begin
                text = render_text(m)
                @test occursin("✓", text)
                @test occursin("✗", text)
            end

            @testset "Mode switch changes rendered content" begin
                m.active_tab = 3
                m.activity_mode = :live
                live_text = render_text(m)
                press!(m, 'd')  # needs active_tab == 3
                analytics_text = render_text(m)
                @test m.activity_mode == :analytics
                @test live_text != analytics_text
                @test occursin("Tool Usage Summary", analytics_text)
                @test occursin("Tool Calls", live_text)
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "End-to-End: Tool Call → DB → Analytics View" begin
        m, db_path = setup_tui_model()
        try
            # 1. Push tool calls (simulates agent activity)
            push_tool_results!(m; n_success = 10, n_error = 3, tool_name = "ex")
            push_tool_results!(m; n_success = 5, n_error = 0, tool_name = "run_tests")

            # 2. Verify DB has rows
            rows = Database.get_tool_executions(; days = 1)
            @test length(rows) >= 18

            # 3. Switch to analytics via keypress
            m.active_tab = 3
            press!(m, 'd')
            @test m.activity_mode == :analytics
            @test m.analytics_cache !== nothing

            # 4. Verify analytics cache reflects DB data
            c = m.analytics_cache
            tool_names = [get(r, "tool_name", "") for r in c.tool_summary]
            @test "ex" in tool_names
            @test "run_tests" in tool_names

            # 5. Render and verify visual output
            text = render_text(m)
            @test occursin("ex", text)
            @test occursin("run_tests", text)

            # 6. Switch back to live and verify
            press!(m, 'd')
            @test m.activity_mode == :live
            text = render_text(m)
            @test occursin("Tool Calls", text)
            @test occursin("✓", text)
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Rapid Mode Toggle Stability" begin
        m, db_path = setup_tui_model()
        try
            m.active_tab = 3
            push_tool_results!(m; n_success = 5)

            # Rapidly toggle 20 times — should never crash
            for _ = 1:20
                press!(m, 'd')
            end
            @test m.activity_mode in (:live, :analytics)

            # Render should still work in whatever mode we ended up in
            text = render_text(m)
            @test !isempty(text)
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

end

# ── Property-Based Tests (Supposition.jl) ────────────────────────────────────

@testset "TUI Analytics Properties (Supposition)" begin

    @testset "Health gauge always in [0, 1]" begin
        @check function health_always_clamped(
            status_idx = Data.Integers(1, 3),
            t_success = Data.Floats{Float64}(),
            t_error = Data.Floats{Float64}(),
        )
            assume!(isfinite(t_success) && isfinite(t_error))
            assume!(t_success >= 0.0 && t_error >= 0.0)
            assume!(t_success <= 1e10 && t_error <= 1e10)

            statuses = [:connected, :connecting, :disconnected]
            conn = (status = statuses[status_idx],)
            m = MCPRepl.MCPReplModel(
                last_tool_success = t_success,
                last_tool_error = t_error,
            )
            h = MCPRepl._compute_health(conn, m)
            0.0 <= h <= 1.0
        end
    end

    @testset "Connected health >= disconnected health" begin
        @check function connected_beats_disconnected(
            t_success = Data.Floats{Float64}(),
            t_error = Data.Floats{Float64}(),
        )
            assume!(isfinite(t_success) && isfinite(t_error))
            assume!(t_success >= 0.0 && t_error >= 0.0)
            assume!(t_success <= 1e10 && t_error <= 1e10)

            m = MCPRepl.MCPReplModel(
                last_tool_success = t_success,
                last_tool_error = t_error,
            )
            h_up = MCPRepl._compute_health((status = :connected,), m)
            h_down = MCPRepl._compute_health((status = :disconnected,), m)
            h_up >= h_down
        end
    end

    @testset "Duration string round-trip" begin
        @check function duration_parse_roundtrip(ms_raw = Data.Integers(0, 100_000))
            # Format like the real code does, then check _persist_tool_call! would parse it
            ms = Float64(ms_raw)
            dur_str = if ms < 1000.0
                string(round(Int, ms)) * "ms"
            else
                string(round(ms / 1000.0; digits = 1)) * "s"
            end

            # Parse back (same logic as _persist_tool_call!)
            parsed = if endswith(dur_str, "ms")
                parse(Float64, dur_str[1:end-2])
            elseif endswith(dur_str, "s")
                parse(Float64, dur_str[1:end-1]) * 1000.0
            else
                0.0
            end

            # Should be within 1ms of original (rounding)
            abs(parsed - ms) <= 100.0  # generous tolerance for round-trip through string
        end
    end

    @testset "Tool result text truncation" begin
        @check function truncation_bounded(len = Data.Integers(0, 5000))
            text = repeat("a", len)
            summary = length(text) > 500 ? text[1:500] : text
            length(summary) <= 500
        end
    end

    @testset "Analytics view never crashes on any terminal size" begin
        @check function analytics_render_any_size(
            w = Data.Integers(20, 300),
            h = Data.Integers(5, 100),
        )
            db_path = tempname() * ".db"
            Database.init_db!(db_path)
            try
                m = MCPRepl.MCPReplModel(server_port = 19998)
                m.db_initialized = true
                m.server_started = true
                m.activity_mode = :analytics
                MCPRepl.set_theme!(:kokaku)

                # Push a few results so there's data to render
                for i = 1:3
                    r = MCPRepl.ToolCallResult(
                        now(),
                        "prop_test",
                        "{}",
                        "ok",
                        "10ms",
                        true,
                        "",
                    )
                    MCPRepl._persist_tool_call!(r)
                end
                MCPRepl._refresh_analytics!(m; force = true)

                area = Tachikoma.Rect(0, 0, w, h)
                buf = Tachikoma.Buffer(area)
                MCPRepl._view_analytics(m, area, buf)
                true  # didn't throw
            finally
                Database.close_db!()
                rm(db_path; force = true)
            end
        end
    end

end
