import React from 'react';
import { Session } from '../types';

// Convert ANSI escape codes to HTML with colors
const convertAnsiToHtml = (text: string): string => {
    // Handle carriage returns (\r) - keep only the last segment on each line
    let html = text.split('\n').map(line => {
        const segments = line.split('\r');
        return segments[segments.length - 1]; // Keep only the final rewrite
    }).join('\n');

    // Remove cursor movement and clear codes
    html = html
        .replace(/\x1b\[K/g, '')
        .replace(/\x1b\[[0-9;]*[ABCDEFGJKST]/g, '');

    // ANSI color map
    const colors: Record<string, string> = {
        '30': '#000000', '31': '#cd3131', '32': '#0dbc79', '33': '#e5e510',
        '34': '#2472c8', '35': '#bc3fbc', '36': '#11a8cd', '37': '#e5e5e5',
        '90': '#666666', '91': '#f14c4c', '92': '#23d18b', '93': '#f5f543',
        '94': '#3b8eea', '95': '#d670d6', '96': '#29b8db', '97': '#ffffff',
    };

    // Handle basic ANSI codes
    html = html.replace(/\x1b\[([0-9;]+)m/g, (_match, codes) => {
        const parts = codes.split(';');
        let styles: string[] = [];

        for (const code of parts) {
            if (code === '0' || code === '') {
                return '</span>';
            } else if (code === '1') {
                styles.push('font-weight: bold');
            } else if (colors[code]) {
                styles.push(`color: ${colors[code]}`);
            } else if (code.startsWith('38;5;')) {
                // 256 color support
                const colorNum = parseInt(code.split(';')[2]);
                if (colorNum === 24) styles.push('color: #076678');
                else styles.push(`color: rgb(${colorNum}, ${colorNum}, ${colorNum})`);
            }
        }

        return styles.length > 0 ? `<span style="${styles.join('; ')}">` : '';
    });

    // Escape HTML but preserve our spans
    return html;
};

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
    fetchLogs
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
