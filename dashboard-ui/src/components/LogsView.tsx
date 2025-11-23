import React from 'react';
import { Session } from '../types';

interface LogsViewProps {
    sessions: Record<string, Session>;
    logSessionId: string | null;
    setLogSessionId: (sessionId: string | null) => void;
    logContent: string;
    setLogContent: (content: string) => void;
    autoRefreshLogs: boolean;
    setAutoRefreshLogs: (autoRefresh: boolean) => void;
    logsViewerRef: React.RefObject<HTMLDivElement>;
    fetchLogs: (sessionId: string) => Promise<{ content?: string; error?: string }>;
    convertAnsiToHtml: (ansi: string) => string;
}

export const LogsView: React.FC<LogsViewProps> = ({
    sessions,
    logSessionId,
    setLogSessionId,
    logContent,
    setLogContent,
    autoRefreshLogs,
    setAutoRefreshLogs,
    logsViewerRef,
    fetchLogs,
    convertAnsiToHtml
}) => {
    return (
        <div className="view active" id="logs-view">
            <h2>📋 Session Logs</h2>
            <p className="view-description">
                View startup and runtime logs for Julia sessions. Click any session card to view its logs,
                or use the dropdown below to access logs from previously ended sessions.
            </p>

            <div className="logs-controls">
                <select
                    value={logSessionId || ''}
                    onChange={(e) => {
                        const sessionId = e.target.value;
                        setLogSessionId(sessionId);
                        if (sessionId) {
                            fetchLogs(sessionId).then(data => {
                                if (data.content) setLogContent(data.content);
                                else if (data.error) setLogContent(`Error: ${data.error}`);
                            });
                        }
                    }}
                    className="log-session-select"
                >
                    <option value="">Select a session...</option>
                    {Object.keys(sessions).map(sessionId => (
                        <option key={sessionId} value={sessionId}>{sessionId}</option>
                    ))}
                </select>
                <label className="auto-refresh-label">
                    <input
                        type="checkbox"
                        checked={autoRefreshLogs}
                        onChange={(e) => setAutoRefreshLogs(e.target.checked)}
                    />
                    Auto-refresh (2s)
                </label>

                <button
                    onClick={() => {
                        if (logSessionId) {
                            fetchLogs(logSessionId).then(data => {
                                if (data.content) {
                                    setLogContent(data.content);
                                    // Scroll to bottom after refresh
                                    setTimeout(() => {
                                        if (logsViewerRef.current) {
                                            logsViewerRef.current.scrollTop = logsViewerRef.current.scrollHeight;
                                        }
                                    }, 0);
                                }
                                else if (data.error) setLogContent(`Error: ${data.error}`);
                            });
                        }
                    }}
                    className="refresh-logs-btn"
                    disabled={!logSessionId}
                >
                    🔄 Refresh
                </button>
            </div>

            <div className="logs-viewer" ref={logsViewerRef}>
                <pre className="log-content" dangerouslySetInnerHTML={{
                    __html: logContent ? convertAnsiToHtml(logContent) : 'Select a session to view logs'
                }} />
            </div>
        </div>
    );
};
