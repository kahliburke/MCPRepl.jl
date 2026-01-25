# Julia REPL Workflow Guide

## 🌟 POWERFUL TOOLS - USE THESE INSTEAD OF GREP/SHELL

**MCPRepl gives you Julia-native code discovery tools that are far superior to grep, find, or shell commands:**

### 🔍 Semantic Code Search (Use Instead of Grep)
- **`qdrant_search_code(query="...")`** - Find code by *meaning*, not keywords
  - Example: `"function that handles HTTP routing"` finds relevant handlers even without those exact words
  - Example: `"parse command line arguments"` finds CLI parsing code
  - **Why better than grep:** Understands code semantics, finds conceptually related code, works across different naming conventions

### 🔬 Deep Type Introspection (Use Instead of Manual Inspection)
- **`type_info("Type")`** - Complete type information: fields, hierarchy, properties, subtypes
  - Example: `type_info("Vector{Int}")` shows all fields, supertype chain, direct subtypes
  - **Why better than manual:** Instant complete picture of any type's structure

### 🎯 Method Discovery (Use Instead of Searching Files)
- **`search_methods("function")`** - Find all methods/overloads of a function or type
  - Example: `search_methods("println")` shows all println signatures
  - Example: `search_methods("String")` shows all methods accepting String
  - **Why better than grep:** Shows actual signatures with types, finds all overloads

### 📚 Symbol Discovery (Use Instead of Tab Completion)
- **`list_names("Module")`** - List all exported (or all) names in a module
  - Example: `list_names("Base")` shows all Base exports
  - Example: `list_names("MyPackage", all=true)` shows all symbols including internal
  - **Why better than manual:** Instant overview of available functionality

### 🧭 LSP Navigation (Use Instead of File Searching)
- **`lsp_goto_definition(file, line, col)`** - Jump to where symbol is defined
- **`lsp_find_references(file, line, col)`** - Find all usages of a symbol
- **`lsp_workspace_symbols(query)`** - Search for symbols across entire workspace
- **Why better than grep:** Understands code structure, follows imports, ignores comments/strings

---

## ⚡ Primary Execution Tool

**`ex()`** is your primary tool for running code, tests, docs, loading packages - use it for almost everything.

**New to MCPRepl?** → `usage_quiz()` then `usage_quiz(show_sols=true)` to self-grade

## ⚠️ CRITICAL: Shared REPL Model

**User sees everything you execute in real-time.** You share the same REPL.

**🚨 DON'T USE `println` - IT'S ALWAYS STRIPPED**

Want to see a value? Use **`q=false`** with the value as the final expression:
```julia
# ❌ WRONG - println is always stripped (never works)
ex(e="println('Result: ', x)")

# ✅ CORRECT - Use q=false with final expression
ex(e="x", q=false)                         # Single value
ex(e="(x, y, z)", q=false)                 # Multiple values
ex(e="(length(data), typeof(data))", q=false)  # Summary
```

**Key points:**
1. **`println` is ALWAYS stripped** - Never use it
2. **Default to `q=true`** - Saves 70-90% tokens by suppressing return values
3. **Use `q=false`** ONLY when YOU need the return value for a decision
4. **`@show` works with `q=false`** for debugging (stripped with `q=true`)

### `s` (silent mode) — keep `s=false` by default

`ex` supports `s` (silent mode) which **suppresses the `agent>` prompt and real-time REPL echo**.

- **Default:** `s=false` (recommended)
- **Use `s=true` only in rare cases** where you intentionally expect very large printed output and want to avoid spamming the user's REPL.
- Even with `q=true`, **errors must still be returned** to the agent/tool result.

Examples:
```julia
ex(e="undefined_var + 1", q=true, s=false)  # ✅ default: you see the error
ex(e="println(join(1:100000, '\n'))", q=false, s=true)  # ⚠️ rare: huge output, don't live-spam
```

**When to use `q=false`:**
```julia
ex(e="length(result) == 5", q=false)     # ✅ Need boolean to decide next step
ex(e="(actual, expected)", q=false)      # ✅ Need values to compare
ex(e="methods(my_func)", q=false)        # ✅ Need to inspect signatures
```

**Never use `q=false` for:**
```julia
ex(e="x = 42", q=false)                  # ❌ Assignments
ex(e="using Pkg", q=false)               # ❌ Imports
ex(e="function f() ... end", q=false)    # ❌ Definitions
```
---
## Token Efficiency Best Practices

**Batch operations:** `ex("x = 1; y = 2; z = 3")`
**Avoid large outputs:** `ex("result = big_calc(); (length(result), typeof(result))", q=false)`
**Use let blocks:** Keeps workspace clean, only returns final value
**Testing:** `@test` and `@testset` work fine, output is minimal

**Don't:**
- `Pkg.add()` → use `pkg_add(packages=["Name"])`
- `Pkg.activate()` → Never change project
- Display huge arrays with q=false

## Environment & Packages

**Revise.jl** auto-tracks changes in `src/`. If it fails (rare): `restart_repl()`, wait 5-10s, `ping()`
**Session start:** `investigate_environment()` to see packages, dev status, Revise status
**Add packages:** `pkg_add(packages=["Name"])`

## Running without the proxy (standalone)

MCPRepl can run in standalone/proxy-compatible mode when the proxy is not available.

**How to enable:**
- Set `bypass_proxy=true` in your security config, or
- Set `MCPREPL_BYPASS_PROXY=true` in the environment, or
- The proxy auto-detects and falls back to standalone if not running

**Standalone mode features:**
- ✅ **HTTP JSON-RPC**: Full MCP protocol at `/` or `/mcp` endpoints
- ✅ **Dashboard UI**: React dashboard at `http://localhost:<port>/`
- ✅ **WebSocket Updates**: Real-time event streaming at `/ws`
- ✅ **All MCP Tools**: Complete tool registry accessible via HTTP
- ❌ **Multi-session**: No proxy routing (single REPL session only)
- ❌ **Session Management**: No registration/heartbeat with proxy

**When to use standalone mode:**
- Single-session development without proxy overhead
- Testing and debugging MCP integrations
- Simplified deployment scenarios
- Direct HTTP client access to Julia REPL

In standalone mode, `ex`/tools work normally; proxy-only features (multi-session routing, 
registration, heartbeat) are disabled.

## Tool Discovery

**Primary:** `ex()` - Run code, tests, docs, load packages (use for almost everything)

**Julia introspection (DON'T use Read/Grep for these):**
`list_names("Module")`, `type_info("Type")`, `search_methods(func)`

**Semantic search (fastest for “what does this do?”):**
`qdrant_search_code(query="...")` and `qdrant_list_collections()`

**LSP navigation (best-of):** `lsp_goto_definition()`, `lsp_find_references()`, `lsp_document_symbols()`, `lsp_workspace_symbols()`

**Utilities:** `format_code(path)`, `ping()`, `investigate_environment()`

## Demo‑Fast Loop (Recommended)

1. **Run code / inspect state:** `ex()` (q=true by default)
2. **Clarify types/methods:** `type_info()`, `search_methods()`
3. **Semantic search:** `qdrant_search_code()` for meaning-based lookup

> If `qdrant_search_code` errors about embeddings, ensure Ollama is running with the embedding model (default: `nomic-embed-text`).

**Need help with a tool?** → `tool_help("tool_name")` or `tool_help("tool_name", extended=true)`

## Common Workflows

**Session start:** `investigate_environment()` → check packages → work
**Revise fails:** `restart_repl()` → wait 5-10s → `ping()`
**Testing:** Use `ex()` with `@test` / `@testset`
## Quick Reference

**Code Discovery (Use these, not grep!):**
- `qdrant_search_code(query="...")` - Semantic search by meaning  
- `type_info("Type")` - Deep type inspection
- `search_methods("func")` - Find all method signatures
- `list_names("Module")` - Discover available symbols
- `lsp_goto_definition()`, `lsp_find_references()`, `lsp_workspace_symbols()` - Navigate code

**Execution & Environment:**
- `ex(e="code")` - Run Julia code (primary tool, use for almost everything)
- `investigate_environment()` - Check packages, Revise status
- `pkg_add(packages=["Name"])` - Add packages
- `restart_repl()` - Restart if needed (rare)

**Utilities:**
- `format_code(path)` - Format Julia files
- `ping()` - Check server status
- `tool_help("name")` - Get help on any tool

> **Note:** If `qdrant_search_code` errors about embeddings, ensure Ollama is running with model `nomic-embed-text`.
