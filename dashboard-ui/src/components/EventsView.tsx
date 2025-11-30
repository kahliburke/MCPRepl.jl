import React from 'react';
import { SessionEvent } from '../types';

interface EventsViewProps {
    events: SessionEvent[];
    eventFilter: string;
    setEventFilter: (filter: string) => void;
    setSelectedEvent: (event: SessionEvent | null) => void;
}

export const EventsView: React.FC<EventsViewProps> = ({
    events,
    eventFilter,
    setEventFilter,
    setSelectedEvent
}) => {
    const formatEventSummary = (event: SessionEvent): string => {
        const { type, data } = event;

        switch (type) {
            case 'SESSION_START':
                const port = data.port || data.metadata?.port;
                const name = data.name || data.metadata?.julia_session_name;
                const portStr = port ? `port ${port}` : 'session';
                return `Started ${portStr}${name ? ` (${name})` : ''}`;

            case 'SESSION_STOP':
                return data.name ? `Stopped: ${data.name}` : 'Session stopped';

            case 'TOOL_CALL':
                return `Tool: ${data.tool || 'unknown'}${data.arguments ? ` with ${Object.keys(data.arguments).length} args` : ''}`;

            case 'CODE_EXECUTION':
                return `Method: ${data.method || 'unknown'}`;

            case 'OUTPUT':
                const output = data.result?.content?.[0]?.text || data.result || '';
                const preview = typeof output === 'string' ? output.substring(0, 80) : JSON.stringify(output).substring(0, 80);
                return preview + (preview.length >= 80 ? '...' : '');

            case 'ERROR':
                return `Error: ${data.message || data.error_message || 'Unknown error'}`;

            case 'PROGRESS':
                const params = data.notification?.params;
                if (params) {
                    const progress = params.progress !== undefined ? `${params.progress}/${params.total || '?'}` : '';
                    return `${params.message || 'Progress'}${progress ? ` (${progress})` : ''}`;
                }
                return 'Progress update';

            case 'tool.call.start':
            case 'tool.call.complete':
                return `Tool: ${data.tool_name || 'unknown'}${data.is_proxy_tool ? ' (proxy)' : ''}`;

            case 'session.initialized':
                return `Client: ${data.client_name || 'unknown'}`;

            default:
                // Fallback: try common fields
                if (data.description) return data.description;
                if (data.tool) return `Tool: ${data.tool}`;
                if (data.method) return `Method: ${data.method}`;
                if (data.message) return data.message;

                // Last resort: show a few key fields
                const keys = Object.keys(data).slice(0, 3);
                if (keys.length > 0) {
                    return keys.map(k => `${k}: ${String(data[k]).substring(0, 20)}`).join(', ');
                }
                return 'No details available';
        }
    };

    return (
        <div className="view active" id="events-view">
            <div className="events-header">
                <h2>Recent Events</h2>
                <div className="event-filters">
                    {['interesting', 'TOOL_CALL', 'CODE_EXECUTION', 'OUTPUT', 'ERROR', 'all'].map(filter => (
                        <button
                            key={filter}
                            className={`filter-btn ${eventFilter === filter ? 'active' : ''}`}
                            onClick={() => setEventFilter(filter)}
                        >
                            {filter === 'interesting' ? 'Interesting' : filter === 'all' ? 'All' : filter.replace('_', ' ')}
                        </button>
                    ))}
                </div>
            </div>
            <div id="event-list" className="event-list">
                {events
                    .filter(e => {
                        if (eventFilter === 'interesting') return e.type !== 'HEARTBEAT';
                        if (eventFilter === 'all') return true;
                        return e.type === eventFilter;
                    })
                    .slice(0, 100)
                    .reverse()
                    .map((event, idx) => (
                        <div key={idx} className={`event event-${event.type.toLowerCase()}`} onClick={() => setSelectedEvent(event)}>
                            <div className="event-type">{event.type}</div>
                            <div className="event-header">
                                <span className="event-session">{event.id}</span>
                                <span className="event-time">{event.timestamp}</span>
                                {event.duration_ms && (
                                    <span className="event-duration">{event.duration_ms.toFixed(2)}ms</span>
                                )}
                            </div>
                            <div className="event-body">
                                {formatEventSummary(event)}
                            </div>
                        </div>
                    ))}
            </div>
        </div>
    );
};
