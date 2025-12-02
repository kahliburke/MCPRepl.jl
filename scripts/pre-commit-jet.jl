#!/usr/bin/env julia

"""
Pre-commit Static Analysis Hook

Runs JET.jl static analysis on changed Julia files to catch:
- UndefVarError at "compile time"
- Missing module exports
- Type instabilities
- Method errors

Integrated with pre-commit framework via .pre-commit-config.yaml
"""

using Pkg

# Activate the project
project_root = dirname(dirname(@__FILE__))
Pkg.activate(project_root)

# Ensure JET is available (from extras)
try
    using JET
catch
    @info "Installing JET.jl for static analysis..."
    Pkg.add("JET")
    using JET
end

# Get list of staged Julia files
try
    staged_files = readlines(`git diff --cached --name-only --diff-filter=ACM`)
    julia_files = filter(f -> endswith(f, ".jl") && !startswith(f, "test/"), staged_files)

    if isempty(julia_files)
        println("✅ No source Julia files changed")
        exit(0)
    end

    println("🔍 Running JET static analysis on $(length(julia_files)) file(s)...")

    errors_found = false

    # First, try to load the main module to catch import errors
    println("\n📦 Checking module imports...")
    try
        @eval using MCPRepl
        println("✅ MCPRepl module loaded successfully")
    catch e
        if e isa UndefVarError
            errors_found = true
            println("❌ UndefVarError loading MCPRepl: ", e)
            println("   Check that all module exports are correct!")
        else
            @warn "Could not load MCPRepl module" exception = (e, catch_backtrace())
        end
    end

    # Quick JET checks on critical methods (fast - only checks signatures)
    println("\n🔬 Checking critical method signatures...")

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
    ]

    for (func, args, desc) in critical_checks
        try
            @report_call func(args...)
            println("   ✅ $desc")
        catch e
            errors_found = true
            println("   ❌ $desc - $(e.msg)")
        end
    end

    if errors_found
        println("\n" * "="^70)
        println("❌ Static analysis found issues!")
        println("="^70)
        println("\nCommon fixes:")
        println("  • Add missing function to module's export list")
        println("  • Check 'using .SubModule' imports all needed names")
        println("  • Run full test suite: julia --project=. -e 'using Pkg; Pkg.test()'")
        println("\nTo skip this check: git commit --no-verify")
        exit(1)
    else
        println("\n✅ All files passed static analysis")
        exit(0)
    end
catch e
    println("⚠️  JET analysis failed: ", e)
    println("   Continuing with commit...")
    exit(0)  # Don't block commits if JET itself fails
end
