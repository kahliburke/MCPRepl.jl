# Session Reconstruction

MCPRepl now captures **every interaction** that occurs during a session, enabling complete reconstruction and replay of any conversation between clients and REPL backends.

## What Gets Logged

### Interactions Table
Complete message content for full reconstruction:
- **Inbound Requests**: Every MCP request from clients (what the agent/client said)
- **Outbound Responses**: Every response sent back (what the REPL/proxy replied)
- **Full Content**: Complete JSON message bodies stored as text
- **Metadata**: Request ID, method, timestamp, message type, direction
- **Size Tracking**: Content size in bytes for analytics

### Events Table
High-level lifecycle and execution tracking:
- Tool call start/complete with duration
- REPL registration/unregistration
- Session initialization
- Request errors and failures
- All with timestamps and structured data

## Basic Usage

```julia
using MCPRepl.Database

# Initialize the database (usually done automatically by proxy)
init_db!("mcprepl-events.db")

# Get all sessions
sessions = get_all_sessions()

# Get summary for a specific session
summary = get_session_summary("my-repl-id")
println("Total interactions: ", summary["total_interactions"])
println("Total events: ", summary["total_events"])
println("Data captured: ", summary["total_data_bytes"], " bytes")

# Reconstruct complete session timeline
timeline = reconstruct_session("my-repl-id")

# View the timeline
for row in eachrow(timeline)
    println("$(row.timestamp) [$(row.type)]")
    if row.type == "interaction"
        println("  $(row.direction) $(row.message_type)")
        println("  Method: $(row.method)")
        # Parse and pretty-print the content
        content = JSON.parse(row.content)
        println("  ", JSON.json(content, 2))
    else
        println("  Event: $(row.event_type)")
        if !ismissing(row.duration_ms)
            println("  Duration: $(row.duration_ms)ms")
        end
    end
    println()
end
```

## Advanced Queries

### Get All Request/Response Pairs

```julia
# Get all interactions for a session, grouped by request_id
interactions = get_interactions(session_id="my-repl-id")

# Group by request_id to see request/response pairs
using DataFrames
grouped = groupby(filter(row -> !ismissing(row.request_id), interactions), :request_id)

for group in grouped
    println("Request ID: ", group.request_id[1])
    for row in eachrow(group)
        println("  $(row.direction): $(row.message_type)")
    end
end
```

### Analyze Tool Execution

```julia
# Get all tool execution events with timing
events = get_events(session_id="my-repl-id", event_type="tool.call.complete")

# Calculate statistics
using Statistics
durations = filter(!ismissing, events.duration_ms)
println("Mean execution time: ", mean(durations), "ms")
println("Median execution time: ", median(durations), "ms")
println("Max execution time: ", maximum(durations), "ms")
```

### Find Errors in a Session

```julia
# Get all error events
errors = get_events(session_id="my-repl-id", event_type="request.error")

for row in eachrow(errors)
    data = JSON.parse(row.data)
    println("Error at $(row.timestamp):")
    println("  Type: $(data["error_type"])")
    println("  Message: $(data["error_message"])")
end
```

### Export Session to JSON

```julia
# Export complete session for external analysis
timeline = reconstruct_session("my-repl-id")

# Convert to JSON
using JSON
export_data = Dict(
    "session_id" => "my-repl-id",
    "summary" => get_session_summary("my-repl-id"),
    "timeline" => [Dict(
        "timestamp" => row.timestamp,
        "type" => row.type,
        "direction" => row.direction,
        "message_type" => row.message_type,
        "event_type" => row.event_type,
        "content" => row.content,
        "request_id" => row.request_id,
        "method" => row.method,
        "duration_ms" => row.duration_ms
    ) for row in eachrow(timeline)]
)

open("session-export.json", "w") do io
    JSON.print(io, export_data, 2)
end
```

## Session Reconstruction Use Cases

1. **Debugging**: Trace exactly what happened in a failed session
2. **Replay**: Re-run tool calls or requests to reproduce issues
3. **Analytics**: Analyze tool usage patterns, execution times, error rates
4. **Audit**: Complete audit trail of all system interactions
5. **Testing**: Generate test cases from real session data
6. **Performance**: Identify slow operations and bottlenecks
7. **Training**: Create training data from successful interactions

## Database Schema

### interactions
| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Auto-incrementing primary key |
| session_id | TEXT | Session identifier (REPL ID) |
| timestamp | DATETIME | When interaction occurred |
| direction | TEXT | "inbound" or "outbound" |
| message_type | TEXT | "request", "response", "error", etc. |
| request_id | TEXT | RPC request ID for correlation |
| method | TEXT | RPC method name |
| content | TEXT | Full message content (JSON) |
| content_size | INTEGER | Size in bytes |

### events
| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Auto-incrementing primary key |
| session_id | TEXT | Session identifier |
| event_type | TEXT | Type of event |
| timestamp | DATETIME | When event occurred |
| duration_ms | REAL | Execution duration if applicable |
| data | TEXT | Event data (JSON) |

### sessions
| Column | Type | Description |
|--------|------|-------------|
| session_id | TEXT | Primary key |
| start_time | DATETIME | Session start |
| last_activity | DATETIME | Last interaction time |
| status | TEXT | active/inactive/stopped |
| metadata | TEXT | Additional metadata (JSON) |

## Performance Considerations

- Interactions are logged asynchronously and don't block request handling
- Database writes use safe wrappers that won't crash the proxy if DB is unavailable
- Indices on session_id and timestamp enable fast queries
- Content size is tracked to monitor storage usage
- Use `limit` parameter on queries to avoid loading massive datasets

## Privacy & Security

- All message content is stored in the database including potentially sensitive data
- Database file should be protected with appropriate file permissions
- Consider implementing retention policies to delete old sessions
- Use `cleanup_old_events!()` to remove events older than a specified date

## Future Enhancements

- Session replay tools to re-execute captured interactions
- Real-time streaming of session data to dashboard
- Automatic anomaly detection based on historical patterns
- Export to standard formats (OpenTelemetry, etc.)
- Encryption of sensitive content in database
