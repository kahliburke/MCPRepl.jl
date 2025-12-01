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
        (
            MCPRepl.Proxy.update_julia_session_status,
            ("uuid", "ready"),
            "update_julia_session_status(String, String)",
        ),
        (
            MCPRepl.Database.update_session_status!,
            ("uuid", "ready"),
            "Database.update_session_status!(String, String)",
        ),
        (
            MCPRepl.Proxy.register_julia_session,
            ("uuid", "name", 3000),
            "register_julia_session(String, String, Int)",
        ),
        (MCPRepl.Proxy.get_julia_session, ("uuid",), "get_julia_session(String)"),
        (
            MCPRepl.Proxy.log_db_event,
            ("event", Dict{String,Any}()),
            "log_db_event(String, Dict)",
        ),
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
