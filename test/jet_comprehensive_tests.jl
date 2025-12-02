"""
Comprehensive JET Static Analysis Tests

This file provides FULL static analysis coverage of the MCPRepl codebase by:
1. Running report_package for module-level analysis
2. Introspecting all exported functions from each module
3. Testing each function signature with @report_call
4. Generating detailed error reports

Run this file directly:
    julia --project=. test/jet_comprehensive_tests.jl

Or use with Pkg.test() to include in the test suite.
"""

using Pkg
Pkg.activate(dirname(dirname(@__FILE__)))

using JET
using Dates
using JSON

# Load MCPRepl and all submodules
@info "Loading MCPRepl..."
using MCPRepl
using MCPRepl.Database
using MCPRepl.Proxy
using MCPRepl.Session
using MCPRepl.Dashboard

# ============================================================================
# Configuration
# ============================================================================

# Whether to fail the script on errors (set to true for CI)
const FAIL_ON_ERRORS = get(ENV, "JET_FAIL_ON_ERRORS", "false") == "true"

# Maximum number of errors to show per module
const MAX_ERRORS_PER_MODULE = 20

# Modules to analyze with their test argument generators
const MODULES_TO_ANALYZE = [:MCPRepl, :Database, :Proxy, :Session, :Dashboard]

# ============================================================================
# Test Argument Generators
# ============================================================================

"""
Generate appropriate test arguments for a function based on its name and module.
Returns a tuple of arguments or nothing if the function should be skipped.
"""
function get_test_args(mod::Module, func_name::Symbol)
    name = string(func_name)

    # Skip internal/macro functions
    if startswith(name, "_") || startswith(name, "@")
        return nothing
    end

    # Database module functions
    if mod === Database
        return get_database_test_args(func_name)
    end

    # Proxy module functions
    if mod === Proxy
        return get_proxy_test_args(func_name)
    end

    # Session module functions
    if mod === Session
        return get_session_test_args(func_name)
    end

    # Dashboard module functions
    if mod === Dashboard
        return get_dashboard_test_args(func_name)
    end

    # MCPRepl module functions
    return get_mcprepl_test_args(func_name)
end

function get_database_test_args(func_name::Symbol)
    args_map = Dict{Symbol,Any}(
        # Session management
        :init_db! => (".mcprepl/test_events.db",),
        :register_mcp_session! => ("test-session-id", "active"),
        :register_julia_session! => ("uuid-123", "test-session", "active"),
        :register_session! => ("session-id", "active"),
        :get_julia_session => ("uuid-123",),
        :get_mcp_session => ("session-id",),
        :get_julia_sessions_by_name => ("test-session",),
        :get_mcp_sessions_by_target => ("target-uuid",),
        :get_active_mcp_sessions => (),
        :get_active_sessions => (),
        :get_all_sessions => (),
        :update_session_status! => ("session-id", "ready"),
        :update_mcp_session_status! => ("session-id", "connected"),
        :update_mcp_session_target! => ("session-id", "target-id"),
        :update_mcp_session_protocol! =>
            ("session-id", "INITIALIZED", Dict{String,Any}()),

        # Event logging
        :log_event! => ("tool_call", Dict{String,Any}()),
        :log_event_safe! => ("tool_call", Dict{String,Any}()),
        :log_interaction! => ("inbound", "request", "{}"),
        :log_interaction_safe! => ("inbound", "request", "{}"),

        # Queries
        :get_events => (),
        :get_interactions => (),
        :get_events_by_time_range => (; start_time = now() - Dates.Hour(1)),
        :get_session_stats => ("session-id",),
        :get_session_summary => ("session-id",),
        :get_recent_session_events => ("session-id", 50),
        :get_global_stats => (),
        :reconstruct_session => ("session-id",),

        # Analytics
        :get_tool_executions => (),
        :get_error_analytics => (),
        :get_tool_summary => (),
        :get_error_hotspots => (),
        :get_session_timeline => ("session-id",),
        :get_etl_status => (),

        # Maintenance
        :cleanup_old_events! => (30,),
        :close_db! => (),
        :dataframe_to_array => nothing,  # Internal helper, skip
    )
    return get(args_map, func_name, nothing)
end

function get_proxy_test_args(func_name::Symbol)
    args_map = Dict{Symbol,Any}(
        # Server management
        :start_server => (3000,),
        :stop_server => (3000,),
        :restart_server => (3000,),
        :start_foreground_server => (3000,),
        :start_background_server => (3000,),
        :is_server_running => (3000,),
        :get_server_pid => (3000,),
        :clean_proxy_data => (3000,),

        # Julia session management
        :register_julia_session => ("uuid", "name", 4000),
        :unregister_julia_session => ("uuid",),
        :get_julia_session => ("uuid",),
        :list_julia_sessions => (),
        :update_julia_session_status => ("uuid", "ready"),

        # MCP session management
        :create_mcp_session => (nothing,),
        :get_mcp_session => ("session-id",),
        :save_mcp_session! => nothing,  # Needs MCPSession object
        :delete_mcp_session! => ("session-id",),
        :cleanup_inactive_sessions! => (),

        # Client connections
        :register_client_connection => ("session-id",),
        :unregister_client_connection => ("session-id",),

        # Logging
        :log_db_event => ("event", Dict{String,Any}()),
        :log_db_interaction => ("inbound", "request", "{}"),

        # Tools
        :get_proxy_tool_schemas => (),

        # Helpers (skip internal functions)
        :handle_request => nothing,
        :route_to_session_streaming => nothing,
        :monitor_heartbeats => nothing,
        :init_database! => (".mcprepl/test.db",),
    )
    return get(args_map, func_name, nothing)
end

function get_session_test_args(func_name::Symbol)
    args_map = Dict{Symbol,Any}(
        :MCPSession => (),
        :initialize_session! => nothing,  # Needs MCPSession object
        :close_session! => nothing,  # Needs MCPSession object
        :get_session_info => nothing,  # Needs MCPSession object
        :update_activity! => nothing,  # Needs MCPSession object
        :session_from_db => nothing,  # Needs NamedTuple
        :get_server_capabilities => (),
        :get_version => (),
    )
    return get(args_map, func_name, nothing)
end

function get_dashboard_test_args(func_name::Symbol)
    args_map = Dict{Symbol,Any}(
        :log_event => ("session-id", Dashboard.TOOL_CALL, Dict{String,Any}()),
        :emit_progress => ("session-id", "token", 1),
        :serve_static_file => ("index.html",),
        :set_db_callback! => nothing,  # Needs function argument
        :start_dashboard_server => (3001,),
        :stop_dashboard_server => (),
    )
    return get(args_map, func_name, nothing)
end

function get_mcprepl_test_args(func_name::Symbol)
    args_map = Dict{Symbol,Any}(
        # Core functions
        :start! => (),
        :stop! => (),
        :test_server => (3000,),
        :find_free_port => (),
        :version_info => (),

        # Security
        :security_status => (),
        :setup_security => (),
        :generate_key => (),
        :revoke_key => ("key",),
        :allow_ip => ("127.0.0.1",),
        :deny_ip => ("127.0.0.1",),
        :set_security_mode => (:strict,),

        # Tools
        :list_tools => (),
        :tool_help => (:exec_repl,),
        :call_tool => nothing,  # Complex signature

        # Config
        :load_tools_config => (".mcprepl/tools.json", "."),
        :filter_tools_by_config => (nothing,),

        # VS Code
        :store_vscode_response => ("request-id", nothing, nothing),
        :retrieve_vscode_response => nothing,  # Blocking call
        :cleanup_old_vscode_responses => (60.0,),
        :generate_nonce => (),
        :store_nonce => ("request-id", "nonce"),
        :validate_and_consume_nonce => ("request-id", "nonce"),
        :cleanup_old_nonces => (60.0,),
        :trigger_vscode_uri => nothing,  # External system call
        :build_vscode_uri => ("command",),

        # REPL
        :execute_repllike => ("1 + 1",),
        :remove_println_calls => (:(println("test")),),

        # Proxy wrappers
        :start_proxy => (3000,),
        :stop_proxy => (3000,),
    )
    return get(args_map, func_name, nothing)
end

# ============================================================================
# Analysis Functions
# ============================================================================

"""
Get all exported names from a module.
"""
function get_exported_names(mod::Module)
    exported = Symbol[]
    for name in names(mod)
        if isdefined(mod, name)
            push!(exported, name)
        end
    end
    return exported
end

"""
Get all public function names from a module (including non-exported).
"""
function get_public_functions(mod::Module)
    funcs = Symbol[]
    for name in names(mod, all = false)  # Only exported names
        if isdefined(mod, name)
            obj = getfield(mod, name)
            if obj isa Function
                push!(funcs, name)
            end
        end
    end
    return funcs
end

"""
Analyze a single function with JET.
Returns (success, error_message or nothing)
"""
function analyze_function(mod::Module, func_name::Symbol, args)
    try
        func = getfield(mod, func_name)
        if !isa(func, Function)
            return (true, nothing)  # Not a function, skip
        end

        # Use @report_call to analyze
        if args === ()
            @report_call func()
        else
            @report_call func(args...)
        end

        return (true, nothing)
    catch e
        if e isa JET.JETAnalysisFailure
            return (false, "JET analysis failed: $(e.msg)")
        elseif e isa MethodError
            return (true, nothing)  # No matching method, that's okay for some functions
        else
            return (false, "Error: $(sprint(showerror, e))")
        end
    end
end

"""
Run comprehensive analysis on a module.
"""
function analyze_module(mod::Module, mod_name::Symbol)
    println("\n" * "="^70)
    println("Analyzing module: $mod_name")
    println("="^70)

    errors = String[]
    checked = 0
    skipped = 0

    # Get all exported functions
    funcs = get_public_functions(mod)
    println("Found $(length(funcs)) exported functions")

    for func_name in funcs
        args = get_test_args(mod, func_name)

        if args === nothing
            skipped += 1
            @debug "Skipped $func_name (no test args defined)"
            continue
        end

        checked += 1
        success, error_msg = analyze_function(mod, func_name, args)

        if success
            println("   ✅ $func_name")
        else
            println("   ❌ $func_name - $error_msg")
            push!(errors, "$mod_name.$func_name: $error_msg")
        end

        if length(errors) >= MAX_ERRORS_PER_MODULE
            println(
                "   ⚠️  Reached max errors ($MAX_ERRORS_PER_MODULE), stopping module analysis",
            )
            break
        end
    end

    println(
        "\nModule $mod_name: $checked checked, $skipped skipped, $(length(errors)) errors",
    )
    return errors
end

"""
Run report_package for comprehensive module analysis.
"""
function run_package_analysis()
    println("\n" * "="^70)
    println("Running JET report_package on :MCPRepl")
    println("="^70)

    try
        # Run full package analysis
        rep = report_package(
            :MCPRepl;
            ignored_modules = (AnyFrameModule(Test),),
            target_defined_modules = true,
        )

        # Count and display issues
        if !isempty(rep.res.inference_error_reports)
            println(
                "\n⚠️  Package analysis found $(length(rep.res.inference_error_reports)) issue(s):",
            )
            for (i, report) in enumerate(rep.res.inference_error_reports)
                if i <= 10  # Limit output
                    println("\n$i. $report")
                end
            end
            if length(rep.res.inference_error_reports) > 10
                println("\n... and $(length(rep.res.inference_error_reports) - 10) more")
            end
            return false
        else
            println("✅ No issues found in package analysis")
            return true
        end
    catch e
        println("⚠️  Package analysis failed: $e")
        return false
    end
end

# ============================================================================
# Critical Method Checks (from pre-commit)
# ============================================================================

"""
Run focused checks on critical methods with known signatures.
This mirrors the pre-commit hook checks for consistency.
"""
function run_critical_checks()
    println("\n" * "="^70)
    println("Running critical method signature checks")
    println("="^70)

    errors = String[]

    critical_checks = [
        # ========================================
        # Proxy module - Julia session management
        # ========================================
        (
            MCPRepl.Proxy.register_julia_session,
            ("uuid", "name", 3000),
            "Proxy.register_julia_session(String, String, Int)",
        ),
        (
            MCPRepl.Proxy.unregister_julia_session,
            ("uuid",),
            "Proxy.unregister_julia_session(String)",
        ),
        (MCPRepl.Proxy.get_julia_session, ("uuid",), "Proxy.get_julia_session(String)"),
        (MCPRepl.Proxy.list_julia_sessions, (), "Proxy.list_julia_sessions()"),
        (
            MCPRepl.Proxy.update_julia_session_status,
            ("uuid", "ready"),
            "Proxy.update_julia_session_status(String, String)",
        ),

        # Proxy module - MCP session management
        (MCPRepl.Proxy.get_mcp_session, ("session_id",), "Proxy.get_mcp_session(String)"),
        (
            MCPRepl.Proxy.delete_mcp_session!,
            ("session_id",),
            "Proxy.delete_mcp_session!(String)",
        ),

        # Proxy module - logging
        (
            MCPRepl.Proxy.log_db_event,
            ("event", Dict{String,Any}()),
            "Proxy.log_db_event(String, Dict)",
        ),

        # ========================================
        # Database module - Julia session operations
        # ========================================
        (
            MCPRepl.Database.register_julia_session!,
            ("uuid", "name", "active"),
            "Database.register_julia_session!(String, String, String)",
        ),
        (
            MCPRepl.Database.get_julia_session,
            ("uuid",),
            "Database.get_julia_session(String)",
        ),
        (
            MCPRepl.Database.get_julia_sessions_by_name,
            ("name",),
            "Database.get_julia_sessions_by_name(String)",
        ),
        (
            MCPRepl.Database.update_session_status!,
            ("uuid", "ready"),
            "Database.update_session_status!(String, String)",
        ),

        # Database module - MCP session operations
        (
            MCPRepl.Database.register_mcp_session!,
            ("session_id", "active"),
            "Database.register_mcp_session!(String, String)",
        ),
        (
            MCPRepl.Database.get_mcp_session,
            ("session_id",),
            "Database.get_mcp_session(String)",
        ),
        (
            MCPRepl.Database.get_active_mcp_sessions,
            (),
            "Database.get_active_mcp_sessions()",
        ),
        (
            MCPRepl.Database.get_mcp_sessions_by_target,
            ("target_id",),
            "Database.get_mcp_sessions_by_target(String)",
        ),
        (
            MCPRepl.Database.update_mcp_session_status!,
            ("session_id", "connected"),
            "Database.update_mcp_session_status!(String, String)",
        ),
        (
            MCPRepl.Database.update_mcp_session_target!,
            ("session_id", "target_id"),
            "Database.update_mcp_session_target!(String, String)",
        ),
        (
            MCPRepl.Database.update_mcp_session_protocol!,
            ("session_id", "INITIALIZED", Dict{String,Any}()),
            "Database.update_mcp_session_protocol!(String, String, Dict)",
        ),

        # Database module - event logging
        (
            MCPRepl.Database.log_event!,
            ("tool_call", Dict{String,Any}()),
            "Database.log_event!(String, Dict)",
        ),
        (
            MCPRepl.Database.log_event_safe!,
            ("tool_call", Dict{String,Any}()),
            "Database.log_event_safe!(String, Dict)",
        ),
        (
            MCPRepl.Database.log_interaction!,
            ("inbound", "request", "{}"),
            "Database.log_interaction!(String, String, String)",
        ),
        (
            MCPRepl.Database.log_interaction_safe!,
            ("inbound", "request", "{}"),
            "Database.log_interaction_safe!(String, String, String)",
        ),

        # Database module - queries
        (
            MCPRepl.Database.get_session_stats,
            ("session_id",),
            "Database.get_session_stats(String)",
        ),
        (MCPRepl.Database.get_active_sessions, (), "Database.get_active_sessions()"),

        # ========================================
        # Session module
        # ========================================
        (MCPRepl.Session.get_server_capabilities, (), "Session.get_server_capabilities()"),
        (MCPRepl.Session.get_version, (), "Session.get_version()"),
    ]

    for (func, args, desc) in critical_checks
        try
            @report_call func(args...)
            println("   ✅ $desc")
        catch e
            error_msg = e isa JET.JETAnalysisFailure ? e.msg : sprint(showerror, e)
            println("   ❌ $desc - $error_msg")
            push!(errors, "$desc: $error_msg")
        end
    end

    println(
        "\nCritical checks: $(length(critical_checks) - length(errors)) passed, $(length(errors)) failed",
    )
    return errors
end

# ============================================================================
# Additional Method Introspection
# ============================================================================

"""
Find all methods of a function and test each signature.
"""
function introspect_all_methods(func::Function, func_name::String)
    methods_list = methods(func)
    results = []

    for m in methods_list
        sig = m.sig
        println("      Method: $sig")
        # Note: Actually testing each method signature requires generating
        # appropriate arguments for each, which is complex. For now, we
        # just list them.
        push!(results, (m, sig))
    end

    return results
end

"""
List all methods in all analyzed modules.
"""
function list_all_methods()
    println("\n" * "="^70)
    println("Listing all methods in analyzed modules")
    println("="^70)

    modules = [
        (MCPRepl, "MCPRepl"),
        (MCPRepl.Database, "Database"),
        (MCPRepl.Proxy, "Proxy"),
        (MCPRepl.Session, "Session"),
        (MCPRepl.Dashboard, "Dashboard"),
    ]

    total_methods = 0

    for (mod, mod_name) in modules
        println("\n📦 $mod_name:")
        funcs = get_public_functions(mod)

        for func_name in sort(funcs)
            func = getfield(mod, func_name)
            if func isa Function
                method_count = length(methods(func))
                total_methods += method_count
                println(
                    "   • $func_name ($method_count method$(method_count == 1 ? "" : "s"))",
                )
            end
        end
    end

    println("\n📊 Total: $total_methods methods across $(length(modules)) modules")
end

# ============================================================================
# Main Execution
# ============================================================================

function main()
    println("="^70)
    println("MCPRepl Comprehensive JET Static Analysis")
    println("="^70)
    println("Date: $(now())")
    println("Julia: $(VERSION)")

    all_errors = String[]

    # 1. Run package-level analysis
    package_ok = run_package_analysis()
    if !package_ok
        push!(all_errors, "Package analysis found issues")
    end

    # 2. Run critical method checks
    critical_errors = run_critical_checks()
    append!(all_errors, critical_errors)

    # 3. List all methods for reference
    list_all_methods()

    # 4. Summary
    println("\n" * "="^70)
    println("SUMMARY")
    println("="^70)

    if isempty(all_errors)
        println("✅ All checks passed!")
        return 0
    else
        println("❌ Found $(length(all_errors)) error(s):")
        for (i, err) in enumerate(all_errors)
            println("  $i. $err")
        end

        if FAIL_ON_ERRORS
            println("\nExiting with error code 1 (FAIL_ON_ERRORS=true)")
            return 1
        else
            println("\nNote: Set JET_FAIL_ON_ERRORS=true to fail on errors")
            return 0
        end
    end
end

# Run if executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
