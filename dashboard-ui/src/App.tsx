import React, { useEffect, useState, useRef } from 'react';
import { fetchSessions, fetchEvents, subscribeToEvents, fetchTools, callTool, fetchLogs, fetchDirectories, shutdownSession, restartSession, listStaleSessions, killStaleSessions, ToolSchema, ToolsResponse } from './api';
import { Session, SessionEvent } from './types';
import { SessionCard } from './components/SessionCard';

import { SessionHistory } from './components/SessionHistory';
import { OverviewView } from './components/OverviewView';
import { EventsView } from './components/EventsView';
import { TerminalView } from './components/TerminalView';
import { LogsView } from './components/LogsView';
import { ToolsView } from './components/ToolsView';
import { Analytics } from './components/Analytics';
import { JsonViewer } from '@textea/json-viewer';
import './App.css';
import './quick-start.css';

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

export const App: React.FC = () => {
    const [sessions, setSessions] = useState<Record<string, Session>>({});
    const [events, setEvents] = useState<SessionEvent[]>([]);
    const [selectedSession, setSelectedSession] = useState<string | null>(null);
    const [activeTab, setActiveTab] = useState<'overview' | 'events' | 'terminal' | 'tools' | 'logs' | 'history' | 'analytics'>('overview');
    const [eventFilter, setEventFilter] = useState<string>('interesting');
    const [selectedEvent, setSelectedEvent] = useState<SessionEvent | null>(null);
    const terminalRef = useRef<HTMLDivElement>(null);
    const terminalBottomRef = useRef<HTMLDivElement>(null);
    const [isNearBottom, setIsNearBottom] = useState(true);
    const logsViewerRef = useRef<HTMLDivElement>(null);
    const [terminalSearch, setTerminalSearch] = useState('');
    const [showServerModal, setShowServerModal] = useState(false);
    const [showShutdownConfirm, setShowShutdownConfirm] = useState(false);
    const [proxyPid, setProxyPid] = useState<number | null>(null);
    const [proxyPort, setProxyPort] = useState<number | null>(null);
    const [proxyVersion, setProxyVersion] = useState<string>('loading...');
    const [tools, setTools] = useState<ToolsResponse | null>(null);
    const [selectedToolSession, setSelectedToolSession] = useState<string | null>(null);
    const [selectedTool, setSelectedTool] = useState<ToolSchema | null>(null);
    const [toolParams, setToolParams] = useState<Record<string, any>>({});
    const [toolResult, setToolResult] = useState<any>(null);
    const [toolExecuting, setToolExecuting] = useState(false);
    const [logContent, setLogContent] = useState<string>('');
    const [logSessionId, setLogSessionId] = useState<string | null>(null);
    const [autoRefreshLogs, setAutoRefreshLogs] = useState(false);
    const [pathSuggestions, setPathSuggestions] = useState<string[]>([]);
    const [isJuliaProject, setIsJuliaProject] = useState<boolean>(false);
    const [staleSessions, setStaleSessions] = useState<any[]>([]);
    const [staleSessionCount, setStaleSessionCount] = useState(0);
    const [showStaleSessionsModal, setShowStaleSessionsModal] = useState(false);
    const [showErrorsModal, setShowErrorsModal] = useState(false);
    const [showQuickStartModal, setShowQuickStartModal] = useState(false);
    const [quickStartLoading, setQuickStartLoading] = useState(false);
    const [quickStartPath, setQuickStartPath] = useState('');
    const [quickStartName, setQuickStartName] = useState('');
    const [recentSessions, setRecentSessions] = useState<Array<{ path: string, name: string, timestamp: number }>>([]);
    const [recentSessionLoading, setRecentSessionLoading] = useState<string | null>(null);
    const [confirmSessionAction, setConfirmSessionAction] = useState<{ action: 'shutdown' | 'restart', sessionId: string } | null>(null);
    const [activeProgress, setActiveProgress] = useState<Record<string, { token: string, progress: number, total?: number, message: string }>>({});

    useEffect(() => {
        if (autoRefreshLogs && activeTab === 'logs' && logSessionId) {
            const interval = setInterval(() => {
                fetchLogs(logSessionId).then(data => {
                    if (data.content) {
                        setLogContent(data.content);
                        // Scroll to bottom after content updates
                        setTimeout(() => {
                            if (logsViewerRef.current) {
                                logsViewerRef.current.scrollTop = logsViewerRef.current.scrollHeight;
                            }
                        }, 0);
                    }
                });
            }, 2000);
            return () => clearInterval(interval);
        }
    }, [autoRefreshLogs, activeTab, logSessionId]);

    useEffect(() => {
        // DISABLED: Periodically check for stale sessions (was causing hang)
        // TODO: Re-enable with proper implementation that doesn't hang
        /*
        const checkStale = async () => {
            try {
                const result = await listStaleSessions();
                setStaleSessionCount(result.sessions.filter(s => s.is_stale).length);
                setStaleSessions(result.sessions);
            } catch (e) {
                console.error('Failed to check stale sessions:', e);
            }
        };

        checkStale();
        const interval = setInterval(checkStale, 10000); // Every 10 seconds
        return () => clearInterval(interval);
        */
    }, []);

    useEffect(() => {
        // Load recent sessions from localStorage
        const stored = localStorage.getItem('mcprepl_recent_sessions');
        if (stored) {
            try {
                setRecentSessions(JSON.parse(stored));
            } catch (e) {
                console.error('Failed to load recent sessions:', e);
            }
        }
    }, []);

    useEffect(() => {
        const loadInitialData = async () => {
            try {
                const [sessionsData, eventsData] = await Promise.all([
                    fetchSessions(),
                    fetchEvents(undefined, 1000)
                ]);
                setSessions(sessionsData);
                setEvents(eventsData);

                // Fetch proxy info
                const proxyInfoRes = await fetch('/dashboard/api/proxy-info');
                if (proxyInfoRes.ok) {
                    const proxyInfo = await proxyInfoRes.json();
                    setProxyPid(proxyInfo.pid);
                    setProxyPort(proxyInfo.port);
                    setProxyVersion(proxyInfo.version || 'unknown');
                }

                // Fetch tools
                const toolsData = await fetchTools();
                setTools(toolsData);
            } catch (error) {
                console.error('Failed to load initial data:', error);
            }
        };

        loadInitialData();

        // Poll for agents updates to catch status changes
        const agentsInterval = setInterval(async () => {
            try {
                const sessionsData = await fetchSessions();
                setSessions(sessionsData);
            } catch (error) {
                // Silently fail during startup/restart
                if (error instanceof TypeError && error.message.includes('Load failed')) {
                    // Server not ready yet, will retry
                } else {
                    console.error('Failed to refresh agents:', error);
                }
            }
        }, 5000); // Poll every 5 seconds

        // Subscribe to event stream
        const unsubscribe = subscribeToEvents((newEvent) => {
            // Handle progress events separately
            if (newEvent.type === 'PROGRESS' && newEvent.data.notification?.params) {
                const params = newEvent.data.notification.params;
                const token = params.progressToken;
                const progress = params.progress;
                const total = params.total;
                const message = params.message || '';

                setActiveProgress(prev => {
                    // If progress is complete (progress >= total when total is defined), remove it
                    if (total !== undefined && progress >= total) {
                        const next = { ...prev };
                        delete next[newEvent.id];
                        return next;
                    }

                    // Otherwise update or add the progress
                    return {
                        ...prev,
                        [newEvent.id]: { token, progress, total, message }
                    };
                });
            }

            setEvents(prev => {
                // Check if event already exists
                const exists = prev.some(e =>
                    e.timestamp === newEvent.timestamp &&
                    e.id === newEvent.id &&
                    e.type === newEvent.type
                );
                if (exists) return prev;

                // Add new event and keep last 1000
                return [...prev, newEvent].slice(-1000);
            });
        });

        return () => {
            clearInterval(agentsInterval);
            unsubscribe();
        };
    }, []);

    // Autoscroll to bottom when new events arrive (only if near bottom)
    useEffect(() => {
        if (activeTab === 'terminal' && terminalBottomRef.current && isNearBottom) {
            const timer = setTimeout(() => {
                terminalBottomRef.current?.scrollIntoView({ behavior: 'auto', block: 'end' });
            }, 50);
            return () => clearTimeout(timer);
        }
    }, [events, isNearBottom]);

    // Track scroll position to detect if user is near bottom
    const handleTerminalScroll = () => {
        if (terminalRef.current) {
            const { scrollTop, scrollHeight, clientHeight } = terminalRef.current;
            const threshold = 100; // pixels from bottom
            const nearBottom = scrollHeight - scrollTop - clientHeight <= threshold;
            setIsNearBottom(nearBottom);
        }
    };

    const sessionCount = Object.keys(sessions).length;
    const eventCount = events.filter(e => e.type !== 'HEARTBEAT').length;
    const [startTime] = React.useState(new Date());
    const [uptime, setUptime] = React.useState('0s');

    React.useEffect(() => {
        const interval = setInterval(() => {
            const seconds = Math.floor((Date.now() - startTime.getTime()) / 1000);
            const hours = Math.floor(seconds / 3600);
            const mins = Math.floor((seconds % 3600) / 60);
            const secs = seconds % 60;
            setUptime(hours > 0 ? `${hours}h ${mins}m ${secs}s` : mins > 0 ? `${mins}m ${secs}s` : `${secs}s`);
        }, 1000);
        return () => clearInterval(interval);
    }, [startTime]);

    const handleRestart = async () => {
        try {
            await fetch('/dashboard/api/restart', { method: 'POST' });
            // Page will reload automatically when server comes back
            setTimeout(() => window.location.reload(), 2000);
        } catch (error) {
            console.error('Failed to restart proxy:', error);
        }
    };

    const handleShutdown = async () => {
        setShowServerModal(false);
        setShowShutdownConfirm(false);
        try {
            await fetch('/dashboard/api/shutdown', { method: 'POST' });
        } catch (error) {
            console.error('Failed to shutdown proxy:', error);
        }
    };

    const handleSessionShutdown = (sessionId: string) => {
        setConfirmSessionAction({ action: 'shutdown', sessionId });
    };

    const executeSessionShutdown = async (sessionId: string) => {
        try {
            const result = await shutdownSession(sessionId);
            if (result.success) {
                // Remove from local state
                setSessions(prev => {
                    const newSessions = { ...prev };
                    delete newSessions[sessionId];
                    return newSessions;
                });
                // Clear selection if this was selected
                if (selectedSession === sessionId) {
                    setSelectedSession(null);
                    setLogContent('');
                    setLogSessionId(null);
                }
            }
        } catch (error) {
            console.error('Failed to shutdown session:', error);
            alert(`Failed to shutdown session: ${error}`);
        } finally {
            setConfirmSessionAction(null);
        }
    };

    const handleSessionRestart = (sessionId: string) => {
        setConfirmSessionAction({ action: 'restart', sessionId });
    };

    const executeSessionRestart = async (sessionId: string) => {
        try {
            const result = await restartSession(sessionId);
            if (result.success) {
                // Session will reconnect automatically
                // Optionally refresh the session list
                setTimeout(() => {
                    fetchSessions().then(setSessions);
                }, 1000);
            } else {
                alert(`Failed to restart session: Session not found or disconnected`);
            }
        } catch (error) {
            console.error('Failed to restart session:', error);
            const errorMsg = error instanceof Error ? error.message : String(error);
            alert(`Failed to restart session: ${errorMsg}`);
        } finally {
            setConfirmSessionAction(null);
        }
    };

    const handleQuickStart = async () => {
        if (!quickStartPath) {
            alert('Please enter a project path');
            return;
        }

        setQuickStartLoading(true);

        try {
            // Use callTool like the Tools page does
            const result = await callTool({
                tool: 'start_julia_session',
                arguments: {
                    project_path: quickStartPath,
                    session_name: quickStartName || undefined
                }
            });

            if (result.error) {
                throw new Error(result.error);
            }

            // Save to recent sessions
            const newRecent = [
                { path: quickStartPath, name: quickStartName || quickStartPath, timestamp: Date.now() },
                ...recentSessions.filter(r => r.path !== quickStartPath).slice(0, 9) // Keep last 10
            ];
            setRecentSessions(newRecent);
            localStorage.setItem('mcprepl_recent_sessions', JSON.stringify(newRecent));

            // Success - close modal and clear form
            setQuickStartPath('');
            setQuickStartName('');
            setShowQuickStartModal(false);

            // Refresh sessions list
            setTimeout(() => {
                fetchSessions().then(setSessions);
            }, 1000);

        } catch (error) {
            console.error('Failed to start session:', error);
            alert(`Failed to start session: ${String(error)}`);
        } finally {
            setQuickStartLoading(false);
        }
    };

    const handleKillStaleSessions = async (force: boolean = false) => {
        try {
            const result = await killStaleSessions(force);
            alert(result);
            // Refresh stale sessions list
            const updated = await listStaleSessions();
            setStaleSessions(updated.sessions);
            setStaleSessionCount(updated.sessions.filter((s: any) => s.is_stale).length);
        } catch (error) {
            console.error('Failed to kill stale sessions:', error);
            alert(`Failed to kill stale sessions: ${error}`);
        }
    };

    return (
        <div className="app">
            <header className="header">
                <div className="header-brand">
                    <div className="logo" onClick={() => setShowServerModal(true)}>⚡</div>
                    <h1>MCPRepl Dashboard</h1>
                </div>
                <div className="header-stats">
                    <div className="stat">
                        <span className="stat-label">AGENTS</span>
                        <span className="stat-value" id="header-agents">{sessionCount}</span>
                    </div>
                    <div className="stat">
                        <span className="stat-label">EVENTS</span>
                        <span className="stat-value" id="header-events">{eventCount}</span>
                    </div>
                </div>
            </header>

            {showServerModal && (
                <div className="modal-overlay" onClick={() => setShowServerModal(false)}>
                    <div className="modal-content" onClick={(e) => e.stopPropagation()}>
                        <div className="modal-header">
                            <h2>⚡ Proxy Server</h2>
                            <button className="modal-close" onClick={() => setShowServerModal(false)}>✕</button>
                        </div>
                        <div className="modal-body">
                            <div className="server-info">
                                <div className="info-row">
                                    <span className="info-label">Status</span>
                                    <span className="info-value status-running">● Running</span>
                                </div>
                                <div className="info-row">
                                    <span className="info-label">PID</span>
                                    <span className="info-value">{proxyPid ?? 'Loading...'}</span>
                                </div>
                                <div className="info-row">
                                    <span className="info-label">Port</span>
                                    <span className="info-value">{proxyPort ?? 'Loading...'}</span>
                                </div>
                                <div className="info-row">
                                    <span className="info-label">Uptime</span>
                                    <span className="info-value">{uptime}</span>
                                </div>
                                <div className="info-row">
                                    <span className="info-label">Active Agents</span>
                                    <span className="info-value">{Object.values(sessions).filter(a => a.status === 'ready').length} / {sessionCount}</span>
                                </div>
                                <div className="info-row">
                                    <span className="info-label">Total Events</span>
                                    <span className="info-value">{eventCount}</span>
                                </div>
                                <div className="info-row">
                                    <span className="info-label">Version</span>
                                    <span className="info-value">MCPRepl {proxyVersion}</span>
                                </div>
                            </div>
                        </div>
                        <div className="modal-footer">
                            <button className="modal-button secondary" onClick={() => setShowServerModal(false)}>Close</button>
                            <button className="modal-button warning" onClick={() => { setShowServerModal(false); handleRestart(); }}>🔄 Restart Server</button>
                            <button className="modal-button danger" onClick={() => setShowShutdownConfirm(true)}>⏻ Shutdown Server</button>
                        </div>
                    </div>
                </div>
            )}

            {showShutdownConfirm && (
                <div className="modal-overlay" onClick={() => setShowShutdownConfirm(false)}>
                    <div className="modal-content confirm-dialog" onClick={(e) => e.stopPropagation()}>
                        <div className="modal-header">
                            <h2>⚠️ Confirm Shutdown</h2>
                        </div>
                        <div className="modal-body">
                            <p className="confirm-message">
                                Are you sure you want to shut down the proxy server? All active session connections will be terminated.
                            </p>
                        </div>
                        <div className="modal-footer">
                            <button className="modal-button secondary" onClick={() => setShowShutdownConfirm(false)}>Cancel</button>
                            <button className="modal-button danger" onClick={handleShutdown}>Shutdown</button>
                        </div>
                    </div>
                </div>
            )}

            {confirmSessionAction && (
                <div className="modal-overlay" onClick={() => setConfirmSessionAction(null)}>
                    <div className="modal-content confirm-dialog" onClick={(e) => e.stopPropagation()}>
                        <div className="modal-header">
                            <h2>⚠️ Confirm {confirmSessionAction.action === 'shutdown' ? 'Shutdown' : 'Restart'}</h2>
                        </div>
                        <div className="modal-body">
                            <p className="confirm-message">
                                Are you sure you want to {confirmSessionAction.action} session <strong>{confirmSessionAction.sessionId}</strong>?
                            </p>
                        </div>
                        <div className="modal-footer">
                            <button className="modal-button secondary" onClick={() => setConfirmSessionAction(null)}>Cancel</button>
                            <button
                                className="modal-button danger"
                                onClick={() => {
                                    if (confirmSessionAction.action === 'shutdown') {
                                        executeSessionShutdown(confirmSessionAction.sessionId);
                                    } else {
                                        executeSessionRestart(confirmSessionAction.sessionId);
                                    }
                                }}
                            >
                                {confirmSessionAction.action === 'shutdown' ? 'Shutdown' : 'Restart'}
                            </button>
                        </div>
                    </div>
                </div>
            )}

            {showErrorsModal && (
                <div className="modal-overlay" onClick={() => setShowErrorsModal(false)}>
                    <div className="modal-content" onClick={(e) => e.stopPropagation()}>
                        <div className="modal-header">
                            <h2>⚠️ Errors ({events.filter(e => e.type === 'ERROR').length})</h2>
                            <button className="modal-close" onClick={() => setShowErrorsModal(false)}>✕</button>
                        </div>
                        <div className="modal-body" style={{ maxHeight: '500px', overflow: 'auto' }}>
                            {events.filter(e => e.type === 'ERROR').length === 0 ? (
                                <p>No errors found! 🎉</p>
                            ) : (
                                <div className="error-list">
                                    {events.filter(e => e.type === 'ERROR').map((event, idx) => (
                                        <div key={idx} className="error-item">
                                            <div className="error-time">{new Date(event.timestamp).toLocaleTimeString()}</div>
                                            <div className="error-message">{event.data.message || JSON.stringify(event.data)}</div>
                                        </div>
                                    ))}
                                </div>
                            )}
                        </div>
                        <div className="modal-footer">
                            <button className="modal-button secondary" onClick={() => setShowErrorsModal(false)}>Close</button>
                        </div>
                    </div>
                </div>
            )}

            {showStaleSessionsModal && (
                <div className="modal-overlay" onClick={() => setShowStaleSessionsModal(false)}>
                    <div className="modal-content" onClick={(e) => e.stopPropagation()}>
                        <div className="modal-header">
                            <h2>🧹 Stale Sessions ({staleSessionCount})</h2>
                            <button className="modal-close" onClick={() => setShowStaleSessionsModal(false)}>✕</button>
                        </div>
                        <div className="modal-body">
                            {staleSessions.length === 0 ? (
                                <p>No stale sessions found! ✅</p>
                            ) : (
                                <div className="stale-sessions-list">
                                    {staleSessions.map((session: any, idx: number) => (
                                        <div key={idx} className={`stale-session-item ${session.is_stale ? 'stale' : 'active'}`}>
                                            <div className="stale-session-icon">{session.is_stale ? '❌' : '✅'}</div>
                                            <div className="stale-session-info">
                                                <div className="stale-session-name">{session.session_name}</div>
                                                <div className="stale-session-pid">PID: {session.pid}</div>
                                            </div>
                                            <div className="stale-session-status">
                                                {session.is_stale ? 'Stale' : 'Active'}
                                            </div>
                                        </div>
                                    ))}
                                </div>
                            )}
                        </div>
                        <div className="modal-footer">
                            <button className="modal-button secondary" onClick={() => setShowStaleSessionsModal(false)}>Close</button>
                            {staleSessionCount > 0 && (
                                <button className="modal-button warning" onClick={() => handleKillStaleSessions(false)}>
                                    Kill Stale Sessions
                                </button>
                            )}
                            {staleSessions.length > 0 && (
                                <button className="modal-button danger" onClick={() => handleKillStaleSessions(true)}>
                                    Kill All Sessions
                                </button>
                            )}
                        </div>
                    </div>
                </div>
            )}

            {showQuickStartModal && (
                <div className="modal-overlay" onClick={() => setShowQuickStartModal(false)}>
                    <div className="modal-content" onClick={(e) => e.stopPropagation()}>
                        <div className="modal-header">
                            <h2>🚀 Quick Start Session</h2>
                            <button className="modal-close" onClick={() => setShowQuickStartModal(false)}>✕</button>
                        </div>
                        <div className="modal-body">
                            <div className="form-group">
                                <label>Project Path *</label>
                                <input
                                    type="text"
                                    value={quickStartPath}
                                    onChange={async (e) => {
                                        const value = e.target.value;
                                        setQuickStartPath(value);

                                        // Fetch directory suggestions
                                        if (value.length > 0) {
                                            try {
                                                const result = await fetchDirectories(value);
                                                setPathSuggestions(result.directories || []);
                                                setIsJuliaProject(result.is_julia_project || false);
                                            } catch (err) {
                                                console.error('Failed to fetch directories:', err);
                                            }
                                        } else {
                                            setPathSuggestions([]);
                                            setIsJuliaProject(false);
                                        }
                                    }}
                                    onBlur={async (e) => {
                                        // Auto-populate session name if this is a Julia project
                                        const value = e.target.value;
                                        if (value && !quickStartName) {
                                            try {
                                                const result = await fetchDirectories(value);
                                                if (result.is_julia_project) {
                                                    let projectName = value.split('/').filter(p => p.length > 0).pop() || '';
                                                    if (projectName.endsWith('.jl')) {
                                                        projectName = projectName.slice(0, -3);
                                                    }
                                                    if (projectName) {
                                                        setQuickStartName(projectName);
                                                    }
                                                }
                                            } catch (err) {
                                                console.error('Failed to verify Julia project:', err);
                                            }
                                        }
                                    }}
                                    onKeyDown={async (e) => {
                                        if (e.key === 'Tab') {
                                            e.preventDefault();

                                            // Complete to first suggestion
                                            if (pathSuggestions.length > 0) {
                                                const firstSuggestion = pathSuggestions[0];
                                                setQuickStartPath(firstSuggestion + '/');

                                                // Fetch next level
                                                try {
                                                    const result = await fetchDirectories(firstSuggestion + '/');
                                                    setPathSuggestions(result.directories || []);
                                                    setIsJuliaProject(result.is_julia_project || false);

                                                    // Auto-populate session name if completed path is Julia project
                                                    if (result.is_julia_project && !quickStartName) {
                                                        let projectName = firstSuggestion.split('/').filter(p => p.length > 0).pop() || '';
                                                        if (projectName.endsWith('.jl')) {
                                                            projectName = projectName.slice(0, -3);
                                                        }
                                                        if (projectName) {
                                                            setQuickStartName(projectName);
                                                        }
                                                    }
                                                } catch (err) {
                                                    console.error('Failed to fetch directories:', err);
                                                }
                                            }
                                        }
                                    }}
                                    placeholder="/path/to/project"
                                    className={`modal-input ${isJuliaProject ? 'julia-project-valid' : ''}`}
                                    list="quickstart-path-suggestions"
                                />
                                <datalist id="quickstart-path-suggestions">
                                    {pathSuggestions.map((dir, idx) => (
                                        <option key={idx} value={dir} />
                                    ))}
                                </datalist>
                                {pathSuggestions.length > 0 && (
                                    <div className="path-suggestions-hint">
                                        Press Tab to complete • {pathSuggestions.length} matches
                                    </div>
                                )}
                            </div>
                            <div className="form-group">
                                <label>Session Name (optional)</label>
                                <input
                                    type="text"
                                    value={quickStartName}
                                    onChange={(e) => setQuickStartName(e.target.value)}
                                    placeholder="my-session"
                                    className="modal-input"
                                />
                            </div>
                        </div>
                        <div className="modal-footer">
                            <button
                                className="modal-button secondary"
                                onClick={() => setShowQuickStartModal(false)}
                                disabled={quickStartLoading}
                            >
                                Cancel
                            </button>
                            <button
                                className="modal-button primary"
                                onClick={handleQuickStart}
                                disabled={quickStartLoading}
                            >
                                {quickStartLoading ? '🚀 Starting...' : 'Start Session'}
                            </button>
                        </div>
                    </div>
                </div>
            )}

            <div className="main-container">
                <aside className="sidebar">
                    <div className="sidebar-header">
                        <h2>Sessions</h2>
                        <span className="session-count">{sessionCount}</span>
                    </div>
                    <button
                        className="quick-start-btn"
                        onClick={() => setShowQuickStartModal(true)}
                        title="Start a new session"
                    >
                        + Quick Start
                    </button>
                    {recentSessions.length > 0 && (
                        <div className="recent-sessions">
                            <div className="recent-header">Recent Sessions</div>
                            {recentSessions.slice(0, 3).map((recent, idx) => (
                                <div
                                    key={idx}
                                    className={`recent-item ${recentSessionLoading === recent.path ? 'loading' : ''}`}
                                    onClick={async () => {
                                        if (recentSessionLoading) return; // Prevent double-click
                                        setRecentSessionLoading(recent.path);
                                        try {
                                            await callTool({
                                                tool: 'start_julia_session',
                                                arguments: {
                                                    project_path: recent.path,
                                                    session_name: recent.name
                                                }
                                            });
                                            setTimeout(() => fetchSessions().then(setSessions), 1000);
                                        } catch (e) {
                                            alert(`Failed to start: ${e}`);
                                        } finally {
                                            setRecentSessionLoading(null);
                                        }
                                    }}
                                    title={recent.path}
                                >
                                    <span className="recent-name">
                                        {recentSessionLoading === recent.path ? '🚀 ' : ''}{recent.name}
                                    </span>
                                    <span className="recent-time">
                                        {recentSessionLoading === recent.path ? 'Starting...' : new Date(recent.timestamp).toLocaleDateString()}
                                    </span>
                                </div>
                            ))}
                        </div>
                    )}
                    <div className="session-list">
                        {Object.entries(sessions).map(([id, session]) => (
                            <SessionCard
                                key={id}
                                session={session}
                                isSelected={selectedSession === id}
                                progress={activeProgress[id]}
                                onClick={() => {
                                    setSelectedSession(id);
                                    setActiveTab('logs');
                                    setLogSessionId(id);
                                    fetchLogs(id).then(data => {
                                        if (data.content) setLogContent(data.content);
                                        else if (data.error) setLogContent(`Error: ${data.error}`);
                                    });
                                }}
                                onRestart={handleSessionRestart}
                                onShutdown={handleSessionShutdown}
                            />
                        ))}
                    </div>
                </aside>

                <main className="content">
                    <div className="tabs">
                        <button
                            className={`tab ${activeTab === 'overview' ? 'active' : ''}`}
                            onClick={() => setActiveTab('overview')}
                        >
                            Overview
                        </button>
                        <button
                            className={`tab ${activeTab === 'events' ? 'active' : ''}`}
                            onClick={() => setActiveTab('events')}
                        >
                            Events
                        </button>
                        <button
                            className={`tab ${activeTab === 'terminal' ? 'active' : ''}`}
                            onClick={() => setActiveTab('terminal')}
                        >
                            Terminal
                        </button>
                        <button
                            className={`tab ${activeTab === 'tools' ? 'active' : ''}`}
                            onClick={() => {
                                setActiveTab('tools');
                                if (!tools) {
                                    fetchTools().then(setTools);
                                }
                            }}
                        >
                            🛠️ Tools
                        </button>
                        <button
                            className={`tab ${activeTab === 'logs' ? 'active' : ''}`}
                            onClick={() => {
                                setActiveTab('logs');
                                if (!logSessionId && selectedSession) {
                                    setLogSessionId(selectedSession);
                                    fetchLogs(selectedSession).then(data => {
                                        if (data.content) setLogContent(data.content);
                                    });
                                }
                            }}
                        >
                            📋 Logs
                        </button>
                        <button
                            className={`tab ${activeTab === 'history' ? 'active' : ''}`}
                            onClick={() => setActiveTab('history')}
                        >
                            🕐 History
                        </button>
                        <button
                            className={`tab ${activeTab === 'analytics' ? 'active' : ''}`}
                            onClick={() => setActiveTab('analytics')}
                        >
                            📊 Analytics
                        </button>
                    </div>

                    <div className="view-container">
                        {activeTab === 'overview' && (
                            <OverviewView
                                sessionCount={sessionCount}
                                sessions={sessions}
                                eventCount={eventCount}
                                events={events}
                                staleSessionCount={staleSessionCount}
                                setActiveTab={setActiveTab}
                                setEventFilter={setEventFilter}
                                setShowErrorsModal={setShowErrorsModal}
                                setShowStaleSessionsModal={setShowStaleSessionsModal}
                            />
                        )}

                        {activeTab === 'events' && (
                            <EventsView
                                events={events}
                                eventFilter={eventFilter}
                                setEventFilter={setEventFilter}
                                setSelectedEvent={setSelectedEvent}
                            />
                        )}

                        {activeTab === 'terminal' && (
                            <TerminalView
                                events={events}
                                selectedSession={selectedSession}
                                terminalSearch={terminalSearch}
                                setTerminalSearch={setTerminalSearch}
                                terminalRef={terminalRef}
                                terminalBottomRef={terminalBottomRef}
                                handleTerminalScroll={handleTerminalScroll}
                            />
                        )}

                        {activeTab === 'logs' && (
                            <LogsView
                                sessions={sessions}
                                logSessionId={logSessionId}
                                setLogSessionId={setLogSessionId}
                                logContent={logContent}
                                setLogContent={setLogContent}
                                autoRefreshLogs={autoRefreshLogs}
                                setAutoRefreshLogs={setAutoRefreshLogs}
                                logsViewerRef={logsViewerRef}
                                fetchLogs={fetchLogs}
                                convertAnsiToHtml={convertAnsiToHtml}
                            />
                        )}

                        {activeTab === 'tools' && (
                            <ToolsView
                                sessions={sessions}
                                tools={tools}
                                selectedToolSession={selectedToolSession}
                                setSelectedToolSession={setSelectedToolSession}
                                setTools={setTools}
                                setSelectedTool={setSelectedTool}
                                fetchTools={fetchTools}
                            />
                        )}

                        {activeTab === 'analytics' && (
                            <Analytics sessionId={selectedSession} />
                        )}

                        {activeTab === 'history' && (
                            <div className="view active" id="history-view">
                                <SessionHistory sessionId={selectedSession} />
                            </div>
                        )}
                    </div>
                </main>
            </div>

            {selectedTool && (
                <div className="modal-overlay" onClick={() => { setSelectedTool(null); setToolParams({}); setToolResult(null); }}>
                    <div className="modal" onClick={(e) => e.stopPropagation()}>
                        <div className="modal-header">
                            <h2>Tool Details: {selectedTool.name}</h2>
                            <button className="modal-close" onClick={() => { setSelectedTool(null); setToolParams({}); setToolResult(null); }}>×</button>
                        </div>
                        <div className="modal-content">
                            <div className="detail-row">
                                <span className="detail-label">Name:</span>
                                <span className="detail-value"><code>{selectedTool.name}</code></span>
                            </div>
                            <div className="detail-row">
                                <span className="detail-label">Description:</span>
                                <span className="detail-value">{selectedTool.description}</span>
                            </div>

                            {selectedTool.inputSchema?.properties && Object.keys(selectedTool.inputSchema.properties).length > 0 && (
                                <div className="tool-test-section">
                                    <h3>Test Tool</h3>
                                    <div className="tool-params-form">
                                        {Object.entries(selectedTool.inputSchema.properties).map(([name, schema]: [string, any]) => (
                                            <div key={name} className="param-input-group">
                                                <label>
                                                    {name}
                                                    {selectedTool.inputSchema.required?.includes(name) && <span className="required">*</span>}
                                                    <span className="param-type">({schema.type})</span>
                                                </label>
                                                {schema.description && <p className="param-help">{schema.description}</p>}
                                                {schema.type === 'boolean' ? (
                                                    <select
                                                        value={toolParams[name] ?? ''}
                                                        onChange={(e) => setToolParams({ ...toolParams, [name]: e.target.value === 'true' })}
                                                        className="param-input"
                                                    >
                                                        <option value="">Select...</option>
                                                        <option value="true">true</option>
                                                        <option value="false">false</option>
                                                    </select>
                                                ) : schema.type === 'number' || schema.type === 'integer' ? (
                                                    <input
                                                        type="number"
                                                        value={toolParams[name] ?? ''}
                                                        onChange={(e) => setToolParams({ ...toolParams, [name]: e.target.valueAsNumber })}
                                                        className="param-input"
                                                        placeholder={`Enter ${name}...`}
                                                    />
                                                ) : name === 'project_path' || name.includes('path') || name.includes('directory') || name.includes('dir') ? (
                                                    <>
                                                        <input
                                                            type="text"
                                                            value={toolParams[name] ?? ''}
                                                            onChange={async (e) => {
                                                                const value = e.target.value;
                                                                setToolParams({ ...toolParams, [name]: value });

                                                                // Fetch directory suggestions and check if Julia project
                                                                if (value.length > 0) {
                                                                    try {
                                                                        const result = await fetchDirectories(value);
                                                                        setPathSuggestions(result.directories || []);
                                                                        setIsJuliaProject(result.is_julia_project || false);
                                                                    } catch (err) {
                                                                        console.error('Failed to fetch directories:', err);
                                                                    }
                                                                } else {
                                                                    setIsJuliaProject(false);
                                                                }
                                                            }}
                                                            onBlur={async (e) => {
                                                                // Auto-populate session_name when project_path loses focus
                                                                // Only if it's a valid Julia project (has Project.toml)
                                                                if (name === 'project_path' && selectedTool?.name === 'start_julia_session') {
                                                                    const value = e.target.value;
                                                                    if (value && !toolParams['session_name']) {
                                                                        // Re-check if this is actually a Julia project before populating
                                                                        try {
                                                                            const result = await fetchDirectories(value);
                                                                            if (result.is_julia_project) {
                                                                                let projectName = value.split('/').filter(p => p.length > 0).pop() || '';
                                                                                // Strip .jl extension if present
                                                                                if (projectName.endsWith('.jl')) {
                                                                                    projectName = projectName.slice(0, -3);
                                                                                }
                                                                                if (projectName) {
                                                                                    setToolParams({ ...toolParams, [name]: value, 'session_name': projectName });
                                                                                }
                                                                            }
                                                                        } catch (err) {
                                                                            console.error('Failed to verify Julia project:', err);
                                                                        }
                                                                    }
                                                                }
                                                            }}
                                                            onKeyDown={async (e) => {
                                                                if (e.key === 'Tab') {
                                                                    e.preventDefault();

                                                                    // If we have suggestions, complete to first suggestion
                                                                    if (pathSuggestions.length > 0) {
                                                                        const firstSuggestion = pathSuggestions[0];
                                                                        const newParams = { ...toolParams, [name]: firstSuggestion + '/' };

                                                                        setToolParams(newParams);

                                                                        // Fetch next level of suggestions
                                                                        try {
                                                                            const result = await fetchDirectories(firstSuggestion + '/');
                                                                            setPathSuggestions(result.directories || []);
                                                                            setIsJuliaProject(result.is_julia_project || false);

                                                                            // Only auto-populate session_name if this completed path is a Julia project
                                                                            if (name === 'project_path' && selectedTool?.name === 'start_julia_session' && result.is_julia_project && !toolParams['session_name']) {
                                                                                let projectName = firstSuggestion.split('/').filter(p => p.length > 0).pop() || '';
                                                                                // Strip .jl extension if present
                                                                                if (projectName.endsWith('.jl')) {
                                                                                    projectName = projectName.slice(0, -3);
                                                                                }
                                                                                if (projectName) {
                                                                                    setToolParams({ ...newParams, 'session_name': projectName });
                                                                                }
                                                                            }
                                                                        } catch (err) {
                                                                            console.error('Failed to fetch directories:', err);
                                                                        }
                                                                    }
                                                                }
                                                            }}
                                                            className={`param-input ${isJuliaProject ? 'julia-project-valid' : ''}`}
                                                            placeholder={`Enter ${name}...`}
                                                            list={`${name}-suggestions`}
                                                        />
                                                        <datalist id={`${name}-suggestions`}>
                                                            {pathSuggestions.map((dir, idx) => (
                                                                <option key={idx} value={dir} />
                                                            ))}
                                                        </datalist>
                                                        {pathSuggestions.length > 0 && (
                                                            <div className="path-suggestions-hint">
                                                                Press Tab to complete • {pathSuggestions.length} matches
                                                            </div>
                                                        )}
                                                    </>
                                                ) : (
                                                    <input
                                                        type="text"
                                                        value={toolParams[name] ?? ''}
                                                        onChange={(e) => setToolParams({ ...toolParams, [name]: e.target.value })}
                                                        className="param-input"
                                                        placeholder={`Enter ${name}...`}
                                                    />
                                                )}
                                            </div>
                                        ))}
                                    </div>
                                    <button
                                        className="tool-execute-btn"
                                        disabled={toolExecuting}
                                        onClick={async () => {
                                            setToolExecuting(true);
                                            setToolResult(null);
                                            try {
                                                const result = await callTool({
                                                    tool: selectedTool.name,
                                                    arguments: toolParams,
                                                    sessionId: selectedToolSession ?? undefined
                                                });
                                                setToolResult(result);
                                            } catch (error) {
                                                setToolResult({ error: String(error) });
                                            } finally {
                                                setToolExecuting(false);
                                            }
                                        }}
                                    >
                                        {toolExecuting ? 'Executing...' : '▶ Try it'}
                                    </button>
                                </div>
                            )}

                            {!selectedTool.inputSchema?.properties || Object.keys(selectedTool.inputSchema.properties).length === 0 && (
                                <div className="tool-test-section">
                                    <h3>Test Tool</h3>
                                    <p className="param-help">This tool takes no parameters.</p>
                                    <button
                                        className="tool-execute-btn"
                                        disabled={toolExecuting}
                                        onClick={async () => {
                                            setToolExecuting(true);
                                            setToolResult(null);
                                            try {
                                                const result = await callTool({
                                                    tool: selectedTool.name,
                                                    arguments: {},
                                                    sessionId: selectedToolSession ?? undefined
                                                });
                                                setToolResult(result);
                                            } catch (error) {
                                                setToolResult({ error: String(error) });
                                            } finally {
                                                setToolExecuting(false);
                                            }
                                        }}
                                    >
                                        {toolExecuting ? 'Executing...' : '▶ Try it'}
                                    </button>
                                </div>
                            )}

                            {toolResult && (
                                <div className="tool-result-section">
                                    <h3>{toolResult.error ? '❌ Error' : '✓ Result'}</h3>
                                    {toolResult.error ? (
                                        <div className="json-tree">
                                            <JsonViewer
                                                value={toolResult.error}
                                                theme="dark"
                                                defaultInspectDepth={3}
                                                displayDataTypes={false}
                                                rootName="error"
                                            />
                                        </div>
                                    ) : toolResult.result?.content ? (
                                        <>
                                            {toolResult.result.content.map((item: any, idx: number) => (
                                                <div key={idx} className="result-content">
                                                    {item.type === 'text' ? (
                                                        <pre className="result-text">{item.text}</pre>
                                                    ) : (
                                                        <div className="json-tree">
                                                            <JsonViewer
                                                                value={item}
                                                                theme="dark"
                                                                defaultInspectDepth={3}
                                                                displayDataTypes={false}
                                                                rootName={`content[${idx}]`}
                                                            />
                                                        </div>
                                                    )}
                                                </div>
                                            ))}
                                            <details className="raw-response">
                                                <summary>Show raw response</summary>
                                                <div className="json-tree">
                                                    <JsonViewer
                                                        value={toolResult}
                                                        theme="dark"
                                                        defaultInspectDepth={3}
                                                        displayDataTypes={false}
                                                        rootName="response"
                                                    />
                                                </div>
                                            </details>
                                        </>
                                    ) : (
                                        <div className="json-tree">
                                            <JsonViewer
                                                value={toolResult}
                                                theme="dark"
                                                defaultInspectDepth={3}
                                                displayDataTypes={false}
                                                rootName="response"
                                            />
                                        </div>
                                    )}
                                </div>
                            )}

                            {selectedTool.inputSchema && (
                                <div className="detail-row detail-data">
                                    <span className="detail-label">Input Schema:</span>
                                    <div className="detail-value json-tree">
                                        <JsonViewer
                                            value={selectedTool.inputSchema}
                                            theme="dark"
                                            defaultInspectDepth={2}
                                            displayDataTypes={true}
                                            rootName="inputSchema"
                                        />
                                    </div>
                                </div>
                            )}
                        </div>
                    </div>
                </div>
            )}

            {selectedEvent && (
                <div className="modal-overlay" onClick={() => setSelectedEvent(null)}>
                    <div className="modal" onClick={(e) => e.stopPropagation()}>
                        <div className="modal-header">
                            <h2>Event Details</h2>
                            <button className="modal-close" onClick={() => setSelectedEvent(null)}>×</button>
                        </div>
                        <div className="modal-content">
                            <div className="detail-row">
                                <span className="detail-label">Type:</span>
                                <span className={`detail-value event-badge event-${selectedEvent.type.toLowerCase()}`}>{selectedEvent.type}</span>
                            </div>
                            <div className="detail-row">
                                <span className="detail-label">Agent ID:</span>
                                <span className="detail-value">{selectedEvent.id}</span>
                            </div>
                            <div className="detail-row">
                                <span className="detail-label">Timestamp:</span>
                                <span className="detail-value">{selectedEvent.timestamp}</span>
                            </div>
                            {selectedEvent.duration_ms && (
                                <div className="detail-row">
                                    <span className="detail-label">Duration:</span>
                                    <span className="detail-value">{selectedEvent.duration_ms.toFixed(2)} ms</span>
                                </div>
                            )}
                            {selectedEvent.data.tool && (
                                <div className="detail-row">
                                    <span className="detail-label">Tool:</span>
                                    <span className="detail-value">{selectedEvent.data.tool}</span>
                                </div>
                            )}
                            {selectedEvent.data.arguments && Object.keys(selectedEvent.data.arguments).length > 0 && (
                                <div className="detail-row detail-data">
                                    <span className="detail-label">Arguments:</span>
                                    <div className="detail-value json-tree">
                                        <JsonViewer
                                            value={selectedEvent.data.arguments}
                                            theme="dark"
                                            defaultInspectDepth={2}
                                            displayDataTypes={false}
                                            rootName="arguments"
                                        />
                                    </div>
                                </div>
                            )}
                            {selectedEvent.data.result && (
                                <div className="detail-row detail-data">
                                    <span className="detail-label">Result:</span>
                                    <div className="detail-value json-tree">
                                        <JsonViewer
                                            value={selectedEvent.data.result}
                                            theme="dark"
                                            defaultInspectDepth={2}
                                            displayDataTypes={false}
                                            rootName="result"
                                        />
                                    </div>
                                </div>
                            )}
                            {selectedEvent.data.error && (
                                <div className="detail-row detail-data">
                                    <span className="detail-label">Error:</span>
                                    <div className="detail-value json-tree error-tree">
                                        <JsonViewer
                                            value={selectedEvent.data.error}
                                            theme="dark"
                                            defaultInspectDepth={2}
                                            displayDataTypes={false}
                                            rootName="error"
                                        />
                                    </div>
                                </div>
                            )}
                            <div className="detail-row detail-data">
                                <span className="detail-label">Raw Data:</span>
                                <div className="detail-value json-tree">
                                    <JsonViewer
                                        value={selectedEvent.data}
                                        theme="dark"
                                        defaultInspectDepth={1}
                                        displayDataTypes={false}
                                        rootName="data"
                                    />
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            )}
        </div>
    );
};
