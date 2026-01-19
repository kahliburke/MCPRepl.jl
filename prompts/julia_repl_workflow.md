# Julia REPL Workflow Guide

**Start here:** `ex()` is the primary tool. Use it for almost everything.

**New to MCPRepl?** → `usage_quiz()` then `usage_quiz(show_sols=true)` to self-grade

## ⚠️ CRITICAL: Shared REPL Model

**User sees everything you execute in real-time.** You share the same REPL.

**Implications:**
1. **NO `println` to communicate** - User already sees execution. Use TEXT responses.
2. **Default to `q=true` (quiet mode)** - Saves 70-90% tokens by suppressing return values
3. **Use `q=false` ONLY when you need the return value for a decision**

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

Most users should use the proxy (it enables session management and survives restarts), but you can run the MCP server directly.

- Set `bypass_proxy=true` in your security config, or set `MCPREPL_BYPASS_PROXY=true` in the environment.
- In standalone mode, `ex`/tools still work normally; proxy-only features (registration/heartbeat/multi-session) are disabled.

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