import React, { useEffect, useState } from 'react';
import { fetchSessionTimeline, fetchSessionSummary, TimelineItem, SessionSummary } from '../api';
import { JsonViewer } from '@textea/json-viewer';
import './SessionHistory.css';

interface SessionHistoryProps {
    sessionId: string | null;
}

export const SessionHistory: React.FC<SessionHistoryProps> = ({ sessionId }) => {
    const [timeline, setTimeline] = useState<TimelineItem[]>([]);
    const [summary, setSummary] = useState<SessionSummary | null>(null);
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [filter, setFilter] = useState<'all' | 'interactions' | 'events'>('all');
    const [directionFilter, setDirectionFilter] = useState<'all' | 'inbound' | 'outbound'>('all');
    const [selectedItem, setSelectedItem] = useState<TimelineItem | null>(null);
    const [searchTerm, setSearchTerm] = useState('');

    useEffect(() => {
        if (!sessionId) {
            setTimeline([]);
            setSummary(null);
            return;
        }

        const loadData = async () => {
            setLoading(true);
            setError(null);
            try {
                const [timelineData, summaryData] = await Promise.all([
                    fetchSessionTimeline(sessionId),
                    fetchSessionSummary(sessionId)
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
    }, [sessionId]);

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

    if (!sessionId) {
        return (
            <div className="session-history empty">
                <p>Select a session to view its history</p>
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
            {/* Summary Section */}
            {summary && (
                <div className="history-summary">
                    <h3>Session Summary</h3>
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
                                        collapsed={2}
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
