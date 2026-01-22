# Standalone/Proxy-Compatible Mode Guide

## Overview

MCPRepl supports running in **standalone mode** (also called "proxy-compatible mode"), where the Julia REPL process itself runs a full-featured HTTP server that includes:

- **MCP JSON-RPC Protocol** - Standard MCP protocol over HTTP at `/` or `/mcp` endpoints
- **Dashboard UI** - Full React-based web interface served at root `/` or `/dashboard`
- **Dashboard API** - RESTful API at `/api/events` for programmatic access
- **WebSocket Streaming** - Real-time event updates at `/ws`
- **Complete Tool Registry** - All MCP tools accessible via HTTP
- **Security Layer** - Same API key, IP restrictions, and OAuth support as proxy mode

This mode is ideal when you don't need the multi-session routing capabilities of the proxy server but still want the full dashboard and HTTP capabilities.

## When to Use Standalone Mode

### ✅ Good Use Cases

- **Single-session development** - Working on one project at a time
- **Testing & debugging** - Simpler setup for troubleshooting
- **Simplified deployment** - No separate proxy process required
- **Direct HTTP access** - Custom clients connecting directly to Julia REPL
- **Resource-constrained environments** - Fewer processes to manage

### ❌ Not Ideal For

- **Multi-project workflows** - Need proxy to route between multiple REPLs
- **Production multi-tenancy** - Proxy provides session isolation
- **Zero-downtime restarts** - Proxy maintains connections during REPL restarts

## How to Enable

### Method 1: Start Function Parameter

```julia
using MCPRepl
MCPRepl.start!(register_with_proxy=false)
```

### Method 2: Security Configuration

Edit your `.mcprepl/security_config.json`:

```json
{
  "mode": "lax",
  "port": 3000,
  "bypass_proxy": true,
  ...
}
```

### Method 3: Environment Variable

```bash
export MCPREPL_BYPASS_PROXY=true
julia --project
```

```julia
using MCPRepl
MCPRepl.start!()  # Auto-detects bypass_proxy
```

### Method 4: Auto-Detection

If no proxy is running on port 3000, MCPRepl automatically falls back to standalone mode.

## Features Available

### HTTP JSON-RPC Endpoints

Both endpoints support the full MCP protocol:

- `POST /` - Primary JSON-RPC endpoint
- `POST /mcp` - Alternate endpoint (same functionality)

**Example request:**

```bash
curl -X POST http://localhost:4000/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "exec_repl",
      "arguments": {
        "expression": "2 + 2"
      }
    }
  }'
```

### Dashboard UI

Access the React dashboard at:

```
http://localhost:<port>/
http://localhost:<port>/dashboard
```

The dashboard provides:
- Real-time event log
- Session status monitoring
- Quick-start buttons for common tasks
- WebSocket-based live updates

### WebSocket Live Updates

Connect to WebSocket for real-time event streaming:

```javascript
const ws = new WebSocket('ws://localhost:4000/ws');
ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  console.log('Event:', data);
};
```

### API Endpoints

- `GET /api/events` - Retrieve recent events (JSON)
- `GET /ws` - WebSocket connection for live updates
- `GET /.well-known/oauth-authorization-server` - OAuth metadata (if security enabled)

## Startup Messages

When starting in standalone mode, you'll see:

```
✓ MCP REPL server started 🐉 (port 4000)

🔌 Standalone Mode (Proxy-Compatible)
   📊 Dashboard: http://localhost:4000/
   🔧 MCP JSON-RPC: http://localhost:4000/mcp
   💡 Tip: This server includes the full dashboard UI and accepts MCP calls via HTTP
```

Compare to proxy mode:

```
✓ MCP REPL server started 🐉 (port 4000)
📝 Registered with proxy as 'my-project'
```

## Architecture Comparison

### Proxy Mode (Default)

```
AI Client → Proxy (port 3000) → REPL Backend (port 4000+)
                ↓
           Dashboard (port 3001)
```

- Proxy routes requests to multiple REPL backends
- Dashboard runs separately via Vite dev server
- REPL can restart without breaking client connections
- Session management and multi-project routing

### Standalone Mode

```
AI Client → REPL (port 4000)
             ↓
           Dashboard (embedded)
```

- Single integrated HTTP server
- Dashboard served from REPL process
- Direct connection (no routing layer)
- Simpler architecture, fewer processes

## Security Considerations

Standalone mode respects all security settings:

- **`:strict`** - Requires API key + IP allowlist
- **`:relaxed`** - Requires API key only
- **`:lax`** - Localhost only, no API key (development)

All authentication and authorization work identically to proxy mode.

## Limitations

1. **Single session only** - Cannot route to multiple REPL instances
2. **No zero-downtime restarts** - Clients lose connection when REPL restarts
3. **No session management** - Proxy features (registration, heartbeat) disabled
4. **No multi-project routing** - One REPL per port

## Troubleshooting

### Dashboard not loading

**Symptom:** 404 errors on dashboard routes

**Solution:** Ensure dashboard UI is built:

```bash
cd dashboard-ui
npm install
npm run build
```

Or the dashboard will auto-download from GitHub releases.

### WebSocket connection fails

**Symptom:** Cannot connect to `/ws`

**Check:**
1. Security settings allow your IP
2. API key is valid (if required)
3. No firewall blocking WebSocket upgrades

### Port conflicts

**Symptom:** "Port already in use"

**Solution:** Use a different port:

```julia
MCPRepl.start!(port=4001, register_with_proxy=false)
```

## Performance

Standalone mode has **lower latency** than proxy mode since requests don't need routing:

- Proxy mode: ~2-5ms routing overhead
- Standalone mode: Direct to Julia (no overhead)

Memory usage is also slightly lower (one fewer process).

## Migration

### From Proxy to Standalone

1. Stop the proxy: `MCPRepl.stop_proxy()`
2. Update security config: `"bypass_proxy": true`
3. Restart REPL server: `MCPRepl.start!()`

### From Standalone to Proxy

1. Update security config: `"bypass_proxy": false`
2. Start proxy: `MCPRepl.start_proxy()`
3. Restart REPL server: `MCPRepl.start!()`

No code changes needed - same MCP protocol in both modes!

## Summary

Standalone mode provides a **self-contained MCP server** with integrated dashboard and WebSocket support, perfect for single-session workflows. It's the simplest deployment option while maintaining full protocol compatibility.

For multi-project workflows or production deployments requiring session management, use proxy mode instead.
