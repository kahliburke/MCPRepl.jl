# MCPRepl.jl

I strongly believe that REPL-driven development is the best thing you can do in Julia, so AI Agents should learn it too!

MCPRepl.jl is a Julia package which exposes your REPL as an MCP server -- so that the agent can connect to it and execute code in your environment.
The code the Agent sends will show up in the REPL as well as your own commands. You're both working in the same state.


Ideally, this enables the Agent to, for example, execute and fix testsets interactively one by one, circumventing any time-to-first-plot issues.

## Showcase

https://github.com/user-attachments/assets/1c7546c4-23a3-4528-b222-fc8635af810d

## Installation

You can add the package using the Julia package manager:

```julia
pkg> add https://github.com/kahliburke/MCPRepl.jl
```
or for development:
```julia
pkg> dev https://github.com/kahliburke/MCPRepl.jl
```

## Usage

### First Time Setup

On first use, configure security settings:

```julia
julia> using MCPRepl
julia> MCPRepl.setup()  # Interactive setup wizard
```

### Starting the Server

Within Julia, call:
```julia
julia> using MCPRepl
julia> MCPRepl.start!()
```

This will start the MCP server using your configured security settings.

### Connecting from AI Clients

For Claude Desktop, you can run the following command to make it aware of the MCP server:

```sh
# With API key (strict/relaxed mode)
claude mcp add julia-repl http://localhost:3000 \
  --transport http \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "X-MCPRepl-Target: YOUR_PROJECT_NAME"

# Without API key (lax mode, localhost only)
claude mcp add julia-repl http://localhost:3000 \
  --transport http \
  -H "X-MCPRepl-Target: YOUR_PROJECT_NAME"
```

## Security

MCPRepl.jl includes a security layer to protect your REPL from unauthorized access. The package requires security configuration before starting and offers three security modes:

### Security Modes

- **`:strict` (default)** - Requires API key authentication AND IP allowlist. Most secure option for production use.
- **`:relaxed`** - Requires API key authentication but accepts connections from any IP address.
- **`:lax`** - Localhost-only mode (127.0.0.1, ::1) with no API key required. Suitable for local development.

### Security Management

```julia
# View current configuration
MCPRepl.security_status()

# Generate a new API key
MCPRepl.generate_key()

# Revoke an API key
MCPRepl.revoke_key("mcprepl_...")

# Add/remove IP addresses
MCPRepl.allow_ip("192.168.1.100")
MCPRepl.deny_ip("192.168.1.100")

# Change security mode
MCPRepl.set_security_mode(:relaxed)

# Reset configuration and start fresh
MCPRepl.reset()
```

### Disclaimer

This software executes code sent to it over the network. While the security layer protects against unauthorized access, you should still:

- Only use this on machines where you understand the security implications
- Keep your API keys confidential
- Monitor active connections and revoke compromised keys immediately
- Use firewall rules as an additional layer of defense

This software is provided "as is" without warranties. Use at your own risk.

## LSP Integration

MCPRepl.jl includes Language Server Protocol (LSP) integration, giving AI agents access to code navigation and refactoring capabilities.

### Available LSP Tools

**Navigation & Analysis:**
- **`lsp_goto_definition`** — Jump to where a function, type, or variable is defined
- **`lsp_find_references`** — Find all usages of a symbol throughout the codebase
- **`lsp_document_symbols`** — Get outline/structure of a file (all functions, types, etc.)
- **`lsp_workspace_symbols`** — Search for symbols across the entire workspace

**Refactoring & Formatting:**
- **`lsp_rename`** — Safely rename a symbol across the entire workspace
- **`lsp_code_actions`** — Get available quick fixes and refactorings for errors/warnings

> **Note for AI Agents:** For documentation and type information, use Julia's built-in introspection in the REPL:
> - `@doc function_name` — Get documentation
> - `methods(function_name)` — See all method signatures
> - `?function_name` — Interactive help

## Similar Packages
- [ModelContexProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) offers a way of defining your own servers. Since MCPRepl is using a HTTP server I decieded to not go with this package.

- [REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) is very similar, but the focus of MCPRepl.jl is to integrate with the user repl so you can see what your agent is doing.
