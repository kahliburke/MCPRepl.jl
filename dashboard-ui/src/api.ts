import { Session, SessionEvent } from './types';

const API_BASE = '/dashboard/api';

export async function fetchSessions(): Promise<Record<string, Session>> {
    const response = await fetch(`${API_BASE}/sessions`);
    if (!response.ok) throw new Error('Failed to fetch sessions');
    return response.json();
}

export async function fetchEvents(sessionId?: string, limit: number = 100): Promise<SessionEvent[]> {
    const params = new URLSearchParams();
    if (sessionId) params.set('id', sessionId);
    params.set('limit', limit.toString());

    const response = await fetch(`${API_BASE}/events?${params}`);
    if (!response.ok) throw new Error('Failed to fetch events');
    return response.json();
}

export function subscribeToEvents(
    onEvent: (event: SessionEvent) => void,
    sessionId?: string
): () => void {
    const params = new URLSearchParams();
    if (sessionId) params.set('id', sessionId);

    const eventSource = new EventSource(`${API_BASE}/events/stream?${params}`);

    eventSource.addEventListener('update', (e) => {
        try {
            const event = JSON.parse(e.data) as SessionEvent;
            onEvent(event);
        } catch (error) {
            console.error('Failed to parse event:', error);
        }
    });

    eventSource.onerror = (error) => {
        console.error('SSE error:', error);
    };

    // Return cleanup function
    return () => {
        eventSource.close();
    };
}

export interface ToolSchema {
    name: string;
    description: string;
    inputSchema: {
        type: string;
        properties?: Record<string, any>;
        required?: string[];
    };
}

export interface ToolsResponse {
    proxy_tools: ToolSchema[];
    session_tools: Record<string, ToolSchema[]>;
}

export async function fetchTools(sessionId?: string): Promise<ToolsResponse> {
    const headers: Record<string, string> = {};
    if (sessionId) {
        headers['X-Agent-Id'] = sessionId;
    }

    const response = await fetch(`${API_BASE}/tools`, { headers });
    if (!response.ok) throw new Error('Failed to fetch tools');
    return response.json();
}

export interface ToolCallRequest {
    tool: string;
    arguments: Record<string, any>;
    sessionId?: string;
}

export interface ToolCallResponse {
    result?: any;
    error?: any;
}

export async function callTool(request: ToolCallRequest): Promise<ToolCallResponse> {
    const mcpRequest = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
            name: request.tool,
            arguments: request.arguments
        }
    };

    const headers: Record<string, string> = {
        'Content-Type': 'application/json'
    };

    if (request.sessionId) {
        headers['X-MCPRepl-Target'] = request.sessionId;
    }

    const response = await fetch('/', {
        method: 'POST',
        headers,
        body: JSON.stringify(mcpRequest)
    });

    // Always try to parse the response body - even error responses may have useful info
    let data;
    try {
        data = await response.json();
    } catch {
        // If we can't parse JSON, throw a generic error
        if (!response.ok) {
            throw new Error(`Failed to call tool: HTTP ${response.status}`);
        }
        throw new Error('Failed to parse response');
    }

    // Throw if JSON-RPC error is present (check this first since proxy returns errors with non-200 status)
    if (data.error) {
        const errorMsg = data.error.message || JSON.stringify(data.error);
        throw new Error(errorMsg);
    }

    // Also check HTTP status in case there's no JSON-RPC error object
    if (!response.ok) {
        throw new Error(`Tool call failed: HTTP ${response.status}`);
    }

    return {
        result: data.result,
        error: undefined
    };
}

export interface LogFile {
    name: string;
    size: number;
    modified: string;
}

export interface LogsResponse {
    content?: string;
    file?: string;
    total_lines?: number;
    files?: LogFile[];
    error?: string;
}

export async function fetchLogs(sessionId?: string, lines: number = 500): Promise<LogsResponse> {
    const params = new URLSearchParams();
    if (sessionId) params.set('session_id', sessionId);
    params.set('lines', lines.toString());

    const response = await fetch(`${API_BASE}/logs?${params}`);
    if (!response.ok) throw new Error('Failed to fetch logs');
    return response.json();
}

export interface DirectoriesResponse {
    directories: string[];
    is_julia_project?: boolean;
    error?: string;
}

export async function fetchDirectories(path: string): Promise<DirectoriesResponse> {
    const params = new URLSearchParams();
    params.set('path', path);

    const response = await fetch(`${API_BASE}/directories?${params}`);
    if (!response.ok) throw new Error('Failed to fetch directories');
    return response.json();
}

export interface ShutdownSessionResponse {
    success: boolean;
    session_id: string;
}

export async function shutdownSession(sessionId: string): Promise<ShutdownSessionResponse> {
    const response = await fetch(`${API_BASE}/session/${sessionId}/shutdown`, {
        method: 'POST'
    });
    if (!response.ok) throw new Error('Failed to shutdown session');
    return response.json();
}

export async function restartSession(sessionId: string): Promise<ShutdownSessionResponse> {
    const response = await fetch(`${API_BASE}/session/${sessionId}/restart`, {
        method: 'POST'
    });
    if (!response.ok) {
        const text = await response.text();
        throw new Error(`Failed to restart session: ${response.status} ${text}`);
    }
    return response.json();
}

export interface StaleSession {
    pid: number;
    session_name: string;
    is_stale: boolean;
}

export interface StaleSessionsResponse {
    sessions: StaleSession[];
    count: number;
}

export async function listStaleSessions(): Promise<StaleSessionsResponse> {
    const mcpRequest = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
            name: "kill_stale_sessions",
            arguments: { dry_run: true }
        }
    };

    const response = await fetch(API_BASE, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(mcpRequest)
    });

    if (!response.ok) throw new Error('Failed to list stale sessions');
    const data = await response.json();

    // Parse the text response
    const text = data.result?.content?.[0]?.text || '';
    const sessions: StaleSession[] = [];

    const lines = text.split('\n');
    for (const line of lines) {
        const match = line.match(/PID (\d+): ([^\s]+) - (.*?)$/);
        if (match) {
            sessions.push({
                pid: parseInt(match[1]),
                session_name: match[2],
                is_stale: match[3].includes('STALE')
            });
        }
    }

    return { sessions, count: sessions.length };
}

export async function killStaleSessions(force: boolean = false): Promise<string> {
    const mcpRequest = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
            name: "kill_stale_sessions",
            arguments: { dry_run: false, force }
        }
    };

    const response = await fetch(API_BASE, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(mcpRequest)
    });

    if (!response.ok) throw new Error('Failed to kill stale sessions');
    const data = await response.json();
    return data.result?.content?.[0]?.text || 'Unknown result';
}

export interface ClearLogsResponse {
    success: boolean;
    message?: string;
    files?: string[];
    error?: string;
}

export async function clearLogs(sessionId: string): Promise<ClearLogsResponse> {
    const params = new URLSearchParams();
    params.set('session_id', sessionId);

    const response = await fetch(`${API_BASE}/clear-logs?${params}`, {
        method: 'POST'
    });

    if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.error || 'Failed to clear logs');
    }

    return response.json();
}

// Quick start now uses callTool() directly

// Database API

export interface Interaction {
    id: number;
    session_id: string;
    timestamp: string;
    direction: 'inbound' | 'outbound';
    message_type: string;
    request_id?: string;
    method?: string;
    content: string;
    content_size: number;
}

export interface TimelineItem {
    timestamp: string;
    type: 'interaction' | 'event';
    direction?: 'inbound' | 'outbound';
    message_type?: string;
    content: string;
    request_id?: string;
    method?: string;
    event_type?: string;
    duration_ms?: number;
}

export interface SessionSummary {
    session_id: string;
    session_info: any;
    total_interactions: number;
    total_events: number;
    total_data_bytes: number;
    complete_request_response_pairs: number;
}

export interface DBSession {
    session_id: string;
    start_time: string;
    last_activity: string;
    status: string;
    session_data: string;
}

export async function fetchInteractions(params: {
    session_id?: string;
    request_id?: string;
    direction?: 'inbound' | 'outbound';
    limit?: number;
}): Promise<Interaction[]> {
    const searchParams = new URLSearchParams();
    if (params.session_id) searchParams.set('session_id', params.session_id);
    if (params.request_id) searchParams.set('request_id', params.request_id);
    if (params.direction) searchParams.set('direction', params.direction);
    if (params.limit) searchParams.set('limit', params.limit.toString());

    const response = await fetch(`${API_BASE}/interactions?${searchParams}`);
    if (!response.ok) throw new Error('Failed to fetch interactions');
    return response.json();
}

export async function fetchSessionTimeline(sessionId: string, limit: number = 1000): Promise<TimelineItem[]> {
    const params = new URLSearchParams();
    params.set('session_id', sessionId);
    params.set('limit', limit.toString());

    const response = await fetch(`${API_BASE}/session-timeline?${params}`);
    if (!response.ok) throw new Error('Failed to fetch session timeline');
    return response.json();
}

export async function fetchSessionSummary(sessionId: string): Promise<SessionSummary> {
    const params = new URLSearchParams();
    params.set('session_id', sessionId);

    const response = await fetch(`${API_BASE}/session-summary?${params}`);
    if (!response.ok) throw new Error('Failed to fetch session summary');
    return response.json();
}

export async function fetchDBSessions(limit: number = 100): Promise<DBSession[]> {
    const params = new URLSearchParams();
    params.set('limit', limit.toString());

    const response = await fetch(`${API_BASE}/db-sessions?${params}`);
    if (!response.ok) throw new Error('Failed to fetch database sessions');
    return response.json();
}

// ============================================================================
// Analytics API - Structured analytics from ETL
// ============================================================================

export interface ToolExecution {
    id: number;
    session_id: string;
    request_id: string;
    tool_name: string;
    tool_method: string | null;
    request_time: string;
    response_time: string | null;
    duration_ms: number | null;
    input_size: number;
    output_size: number;
    argument_count: number;
    status: 'success' | 'error' | 'pending';
    result_type: string | null;
    result_summary: string | null;
}

export interface AnalyticsError {
    id: number;
    session_id: string;
    timestamp: string;
    error_type: string;
    error_code: number | null;
    error_category: string | null;
    tool_name: string | null;
    method: string | null;
    request_id: string | null;
    message: string;
    stack_trace: string | null;
    resolved: boolean;
}

export interface ToolSummary {
    tool_name: string;
    total_executions: number;
    avg_duration_ms: number | null;
    min_duration_ms: number | null;
    max_duration_ms: number | null;
    total_errors: number;
    avg_error_rate_pct: number | null;
}

export interface ErrorHotspot {
    tool_name: string | null;
    error_type: string;
    error_category: string;
    error_count: number;
    affected_sessions: number;
    last_occurrence: string;
}

export interface ETLStatus {
    last_processed_interaction_id: number;
    last_processed_event_id: number;
    last_run_time: string | null;
    last_run_status: string | null;
    last_error: string | null;
}

export async function fetchToolExecutions(filters?: {
    session_id?: string;
    tool_name?: string;
    status?: string;
    limit?: number;
}): Promise<ToolExecution[]> {
    const params = new URLSearchParams();
    if (filters?.session_id) params.set('session_id', filters.session_id);
    if (filters?.tool_name) params.set('tool_name', filters.tool_name);
    if (filters?.status) params.set('status', filters.status);
    params.set('limit', (filters?.limit || 100).toString());

    const response = await fetch(`${API_BASE}/analytics/tool-executions?${params}`);
    if (!response.ok) throw new Error('Failed to fetch tool executions');
    return response.json();
}

export async function fetchAnalyticsErrors(filters?: {
    session_id?: string;
    tool_name?: string;
    error_type?: string;
    resolved?: boolean;
    limit?: number;
}): Promise<AnalyticsError[]> {
    const params = new URLSearchParams();
    if (filters?.session_id) params.set('session_id', filters.session_id);
    if (filters?.tool_name) params.set('tool_name', filters.tool_name);
    if (filters?.error_type) params.set('error_type', filters.error_type);
    if (filters?.resolved !== undefined) params.set('resolved', filters.resolved.toString());
    params.set('limit', (filters?.limit || 100).toString());

    const response = await fetch(`${API_BASE}/analytics/errors?${params}`);
    if (!response.ok) throw new Error('Failed to fetch analytics errors');
    return response.json();
}

export async function fetchToolSummary(filters?: {
    session_id?: string;
    days?: number;
}): Promise<ToolSummary[]> {
    const params = new URLSearchParams();
    if (filters?.session_id) params.set('session_id', filters.session_id);
    if (filters?.days) params.set('days', filters.days.toString());

    const response = await fetch(`${API_BASE}/analytics/tool-summary?${params}`);
    if (!response.ok) throw new Error('Failed to fetch tool summary');
    return response.json();
}

export async function fetchErrorHotspots(): Promise<ErrorHotspot[]> {
    const response = await fetch(`${API_BASE}/analytics/error-hotspots`);
    if (!response.ok) throw new Error('Failed to fetch error hotspots');
    return response.json();
}

export async function runETL(): Promise<any> {
    const response = await fetch(`${API_BASE}/analytics/run-etl`);
    if (!response.ok) throw new Error('Failed to run ETL');
    return response.json();
}

export async function fetchETLStatus(): Promise<ETLStatus> {
    const response = await fetch(`${API_BASE}/analytics/etl-status`);
    if (!response.ok) throw new Error('Failed to fetch ETL status');
    return response.json();
}
