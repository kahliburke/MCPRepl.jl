export interface Session {
    uuid: string;
    name: string;
    port: number;
    pid: number;
    status: 'ready' | 'busy' | 'error' | 'stopped';
    last_heartbeat?: string;
    created_at?: string;
    last_event?: string;
}

export type EventType =
    | 'SESSION_START'
    | 'SESSION_STOP'
    | 'TOOL_CALL'
    | 'CODE_EXECUTION'
    | 'OUTPUT'
    | 'ERROR'
    | 'HEARTBEAT'
    | 'PROGRESS';

export interface SessionEvent {
    id: string;
    type: EventType;
    timestamp: string;
    data: Record<string, any>;
    duration_ms?: number | null;
}

export interface DashboardData {
    sessions: Record<string, Session>;
    events: SessionEvent[];
}
