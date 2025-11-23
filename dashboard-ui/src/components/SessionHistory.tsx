import React, { useEffect, useState } from 'react';
import { fetchSessionTimeline, fetchSessionSummary, fetchDBSessions, fetchSessions, TimelineItem, SessionSummary } from '../api';
import { Session } from '../types';
import { JsonViewer } from '@textea/json-viewer';
import './SessionHistory.css';

interface SessionHistoryProps {
    sessionId: string | null;
}

interface CombinedSession {
    session_id: string;
    start_time?: string;
    last_activity?: string;
    status: string;
    metadata?: string;
    isLive: boolean;
    liveSession?: Session;
}

export const SessionHistory: React.FC<SessionHistoryProps> = ({ sessionId: initialSessionId }) => {
    const [internalSessionId, setInternalSessionId] = useState<string | null>(initialSessionId);
    const [hasUserNavigated, setHasUserNavigated] = useState(false);
    const [timeline, setTimeline] = useState<TimelineItem[]>([]);
    const [summary, setSummary] = useState<SessionSummary | null>(null);
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [filter, setFilter] = useState<'all' | 'interactions' | 'events'>('all');
    const [directionFilter, setDirectionFilter] = useState<'all' | 'inbound' | 'outbound'>('all');
    const [selectedItem, setSelectedItem] = useState<TimelineItem | null>(null);
    const [searchTerm, setSearchTerm] = useState('');
    const [availableSessions, setAvailableSessions] = useState<CombinedSession[]>([]);
    const [loadingSessions, setLoadingSessions] = useState(false);

    // Use internal session ID if user has navigated, otherwise use parent's session
    const activeSessionId = hasUserNavigated ? internalSessionId : (internalSessionId || initialSessionId);

    // Update internal state when parent changes (e.g., when switching tabs)
    useEffect(() => {
        if (initialSessionId && !hasUserNavigated) {
            setInternalSessionId(initialSessionId);
        }
    }, [initialSessionId, hasUserNavigated]);

    // Load available sessions when no session is selected
    useEffect(() => {
        if (!activeSessionId) {
            setTimeline([]);
            setSummary(null);

            const loadSessions = async () => {
                setLoadingSessions(true);
                try {
                    // Fetch both live sessions and database sessions
                    const [liveSessions, dbSessions] = await Promise.all([
                        fetchSessions(),
                        fetchDBSessions(50)
                    ]);

                    // Combine them, prioritizing live sessions
                    const combined: CombinedSession[] = [];
                    const seen = new Set<string>();

                    // Add live sessions first
                    for (const [id, session] of Object.entries(liveSessions)) {
                        seen.add(id);
                        combined.push({
                            session_id: id,
                            status: 'connected',
                            isLive: true,
                            liveSession: session
                        });
                    }

                    // Add database sessions that aren't currently live
                    for (const dbSession of dbSessions) {
                        if (!seen.has(dbSession.session_id)) {
                            combined.push({
                                ...dbSession,
                                isLive: false
                            });
                        }
                    }

                    setAvailableSessions(combined);
                } catch (err) {
                    console.error('Failed to load sessions:', err);
                    setAvailableSessions([]);
                } finally {
                    setLoadingSessions(false);
                }
            };

            loadSessions();
            return;
        }

        const loadData = async () => {
            setLoading(true);
            setError(null);
            try {
                const [timelineData, summaryData] = await Promise.all([
                    fetchSessionTimeline(activeSessionId),
                    fetchSessionSummary(activeSessionId)
                ]);
                setTimeline(timelineData);
                setSummary(summaryData);
            } catch (err) {
                setError(err instanceof Error ? err.message : 'Failed to load session history');
                console.error('Failed to load session history:', err);
            } finally {
                setLoading(false);
            }
        };

        loadData();
    }, [activeSessionId]);

    const filteredTimeline = timeline.filter(item => {
        // Apply type filter
        if (filter === 'interactions' && item.type !== 'interaction') return false;
        if (filter === 'events' && item.type !== 'event') return false;

        // Apply direction filter for interactions
        if (directionFilter !== 'all' && item.direction && item.direction !== directionFilter) return false;

        // Apply search filter
        if (searchTerm) {
            const searchLower = searchTerm.toLowerCase();
            const contentMatch = item.content?.toLowerCase().includes(searchLower);
            const methodMatch = item.method?.toLowerCase().includes(searchLower);
            const eventTypeMatch = item.event_type?.toLowerCase().includes(searchLower);
            if (!contentMatch && !methodMatch && !eventTypeMatch) return false;
        }

        return true;
    });

    const formatTimestamp = (timestamp: string) => {
        return new Date(timestamp).toLocaleString();
    };

    const getItemIcon = (item: TimelineItem) => {
        if (item.type === 'interaction') {
            return item.direction === 'inbound' ? '📥' : '📤';
        }
        if (item.event_type?.includes('error')) return '❌';
        if (item.event_type?.includes('tool')) return '🔧';
        if (item.event_type?.includes('session')) return '🔄';
        return '📝';
    };

    const getItemTitle = (item: TimelineItem) => {
        if (item.type === 'interaction') {
            return `${item.direction === 'inbound' ? 'Request' : 'Response'}: ${item.method || item.message_type}`;
        }
        return item.event_type || 'Event';
    };

    const parseContent = (content: string) => {
        try {
            return JSON.parse(content);
        } catch {
            return content;
        }
    };

    if (!activeSessionId) {
        return (
            <div className="session-history empty">
                <div className="history-intro">
                    <h3>📋 Select a Session</h3>
                </div>
                {loadingSessions ? (
                    <div className="loading-sessions">
                        <div className="spinner"></div>
                        <p>Loading sessions...</p>
                    </div>
                ) : availableSessions.length === 0 ? (
                    <p className="no-sessions">No sessions found. Start a REPL session to see history.</p>
                ) : (
                    <div className="session-list">
                        <div className="session-cards">
                            {availableSessions.slice(0, 20).map(session => (
                                <div
                                    key={session.session_id}
                                    className={`session-card clickable ${session.isLive ? 'live' : 'archived'}`}
                                    onClick={() => {
                                        setInternalSessionId(session.session_id);
                                        setHasUserNavigated(true);
                                    }}
                                >
                                    <div className="session-card-header">
                                        <strong>{session.session_id}</strong>
                                        <span className={`status-badge ${session.status}`}>
                                            {session.isLive ? '🟢 Live' : session.status}
                                        </span>
                                    </div>
                                    <div className="session-card-details">
                                        {session.start_time && (
                                            <div className="detail-row">
                                                <span className="label">Started:</span>
                                                <span className="value">{new Date(session.start_time).toLocaleString()}</span>
                                            </div>
                                        )}
                                        {session.last_activity && (
                                            <div className="detail-row">
                                                <span className="label">Last Activity:</span>
                                                <span className="value">{new Date(session.last_activity).toLocaleString()}</span>
                                            </div>
                                        )}
                                        {session.isLive && session.liveSession && (
                                            <div className="detail-row">
                                                <span className="label">Connection:</span>
                                                <span className="value">Active</span>
                                            </div>
                                        )}
                                    </div>
                                </div>
                            ))}
                        </div>
                    </div>
                )}
            </div>
        );
    }

    if (loading) {
        return (
            <div className="session-history loading">
                <div className="spinner"></div>
                <p>Loading session history...</p>
            </div>
        );
    }

    if (error) {
        return (
            <div className="session-history error">
                <p>❌ {error}</p>
            </div>
        );
    }

    return (
        <div className="session-history">
            {/* Back Button */}
            <div className="history-header">
                <button
                    className="back-button"
                    onClick={() => {
                        setInternalSessionId(null);
                        setHasUserNavigated(true);
                    }}
                    title="Back to session list"
                >
                    ← Back to Sessions
                </button>
                <h3>Session: {activeSessionId}</h3>
            </div>

            {/* Summary Section */}
            {summary && (
                <div className="history-summary">
                    <h4>Summary</h4>
                    <div className="summary-stats">
                        <div className="stat">
                            <span className="stat-label">Total Interactions:</span>
                            <span className="stat-value">{summary.total_interactions}</span>
                        </div>
                        <div className="stat">
                            <span className="stat-label">Total Events:</span>
                            <span className="stat-value">{summary.total_events}</span>
                        </div>
                        <div className="stat">
                            <span className="stat-label">Request/Response Pairs:</span>
                            <span className="stat-value">{summary.complete_request_response_pairs}</span>
                        </div>
                        <div className="stat">
                            <span className="stat-label">Data Size:</span>
                            <span className="stat-value">{(summary.total_data_bytes / 1024).toFixed(2)} KB</span>
                        </div>
                    </div>
                </div>
            )}

            {/* Filters */}
            <div className="history-filters">
                <div className="filter-group">
                    <label>Type:</label>
                    <select value={filter} onChange={(e) => setFilter(e.target.value as any)}>
                        <option value="all">All</option>
                        <option value="interactions">Interactions Only</option>
                        <option value="events">Events Only</option>
                    </select>
                </div>
                <div className="filter-group">
                    <label>Direction:</label>
                    <select value={directionFilter} onChange={(e) => setDirectionFilter(e.target.value as any)}>
                        <option value="all">All</option>
                        <option value="inbound">Inbound</option>
                        <option value="outbound">Outbound</option>
                    </select>
                </div>
                <div className="filter-group">
                    <label>Search:</label>
                    <input
                        type="text"
                        placeholder="Search content, method, event type..."
                        value={searchTerm}
                        onChange={(e) => setSearchTerm(e.target.value)}
                    />
                </div>
                <div className="filter-info">
                    Showing {filteredTimeline.length} of {timeline.length} items
                </div>
            </div>

            {/* Timeline */}
            <div className="history-timeline">
                {filteredTimeline.map((item, index) => (
                    <div
                        key={index}
                        className={`timeline-item ${item.type} ${selectedItem === item ? 'selected' : ''}`}
                        onClick={() => setSelectedItem(selectedItem === item ? null : item)}
                    >
                        <div className="timeline-marker">
                            <span className="timeline-icon">{getItemIcon(item)}</span>
                        </div>
                        <div className="timeline-content">
                            <div className="timeline-header">
                                <span className="timeline-title">{getItemTitle(item)}</span>
                                <span className="timeline-timestamp">{formatTimestamp(item.timestamp)}</span>
                            </div>
                            {item.request_id && (
                                <div className="timeline-meta">Request ID: {item.request_id}</div>
                            )}
                            {item.duration_ms && (
                                <div className="timeline-meta">Duration: {item.duration_ms.toFixed(2)}ms</div>
                            )}
                            {selectedItem === item && (
                                <div className="timeline-details">
                                    <h4>Content:</h4>
                                    <JsonViewer
                                        value={parseContent(item.content)}
                                        defaultInspectDepth={2}
                                        theme="dark"
                                    />
                                </div>
                            )}
                        </div>
                    </div>
                ))}
            </div>

            {filteredTimeline.length === 0 && (
                <div className="empty-state">
                    <p>No items match the current filters</p>
                </div>
            )}
        </div>
    );
};
