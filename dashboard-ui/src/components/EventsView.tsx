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
                                {event.data.description || event.data.tool || event.data.method || JSON.stringify(event.data)}
                            </div>
                        </div>
                    ))}
            </div>
        </div>
    );
};
