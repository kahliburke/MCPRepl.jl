import React, { useEffect, useState, useRef } from 'react';
import { fetchSessions, fetchEvents, subscribeToEvents, fetchTools, callTool, fetchLogs, shutdownSession, restartSession, listStaleSessions, killStaleSessions, ToolSchema, ToolsResponse } from './api';
import { Session, SessionEvent } from './types';
import { SessionCard } from './components/SessionCard';

import { SessionHistory } from './components/SessionHistory';
import { OverviewView } from './components/OverviewView';
import { EventsView } from './components/EventsView';
import { TerminalView } from './components/TerminalView';
import { LogsView } from './components/LogsView';
import { ToolsView } from './components/ToolsView';
import { Analytics } from './components/Analytics';
import { ErrorsModal } from './components/ErrorsModal';
import { ErrorModal } from './components/ErrorModal';
import { StaleSessionsModal } from './components/StaleSessionsModal';
import { QuickStartModal } from './components/QuickStartModal';
import { EventDetailsModal } from './components/EventDetailsModal';
import { ToolDetailsModal } from './components/ToolDetailsModal';

import './App.css';
import './quick-start.css';

export const App: React.FC = () => {
    const [sessions, setSessions] = useState<Record<string, Session>>({});
    const [events, setEvents] = useState<SessionEvent[]>([]);
    const [selectedSession, setSelectedSession] = useState<string | null>(null);
    const [activeTab, setActiveTab] = useState<'overview' | 'events' | 'terminal' | 'tools' | 'logs' | 'history' | 'analytics'>('overview');
    const [eventFilter, setEventFilter] = useState<string>('interesting');
    const [selectedEvent, setSelectedEvent] = useState<SessionEvent | null>(null);
    const logsViewerRef = useRef<HTMLDivElement>(null);
    const [showServerModal, setShowServerModal] = useState(false);
    const [showShutdownConfirm, setShowShutdownConfirm] = useState(false);
    const [proxyPid, setProxyPid] = useState<number | null>(null);
    const [proxyPort, setProxyPort] = useState<number | null>(null);
    const [proxyVersion, setProxyVersion] = useState<string>('loading...');
    const [tools, setTools] = useState<ToolsResponse | null>(null);
    const [selectedToolSession, setSelectedToolSession] = useState<string | null>(null);
    const [selectedTool, setSelectedTool] = useState<ToolSchema | null>(null);
    const [logContent, setLogContent] = useState<string>('');
    const [logSessionId, setLogSessionId] = useState<string | null>(null);
    const [autoRefreshLogs, setAutoRefreshLogs] = useState(false);
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
    const [errorMessage, setErrorMessage] = useState<string | null>(null);

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
            setErrorMessage(`Failed to shutdown session: ${error}`);
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
                setErrorMessage(`Failed to restart session: Session not found or disconnected`);
            }
        } catch (error) {
            console.error('Failed to restart session:', error);
            const errorMsg = error instanceof Error ? error.message : String(error);
            setErrorMessage(`Failed to restart session: ${errorMsg}`);
        } finally {
            setConfirmSessionAction(null);
        }
    };

    const handleQuickStart = async () => {
        if (!quickStartPath) {
            setErrorMessage('Please enter a project path');
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
            setErrorMessage(`Failed to start session: ${String(error)}`);
        } finally {
            setQuickStartLoading(false);
        }
    };

    const handleKillStaleSessions = async (force: boolean = false) => {
        try {
            const result = await killStaleSessions(force);
            setErrorMessage(result);
            // Refresh stale sessions list
            const updated = await listStaleSessions();
            setStaleSessions(updated.sessions);
            setStaleSessionCount(updated.sessions.filter((s: any) => s.is_stale).length);
        } catch (error) {
            console.error('Failed to kill stale sessions:', error);
            setErrorMessage(`Failed to kill stale sessions: ${error}`);
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
                                Are you sure you want to {confirmSessionAction.action} session <strong>{sessions[confirmSessionAction.sessionId]?.name || confirmSessionAction.sessionId}</strong>?
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
                <ErrorsModal
                    events={events}
                    onClose={() => setShowErrorsModal(false)}
                />
            )}

            {showStaleSessionsModal && (
                <StaleSessionsModal
                    staleSessions={staleSessions}
                    onClose={() => setShowStaleSessionsModal(false)}
                    onKillStale={() => handleKillStaleSessions(false)}
                    onKillAll={() => handleKillStaleSessions(true)}
                />
            )}

            {showQuickStartModal && (
                <QuickStartModal
                    quickStartPath={quickStartPath}
                    setQuickStartPath={setQuickStartPath}
                    quickStartName={quickStartName}
                    setQuickStartName={setQuickStartName}
                    quickStartLoading={quickStartLoading}
                    onClose={() => setShowQuickStartModal(false)}
                    onStart={handleQuickStart}
                />
            )}

            <ErrorModal
                error={errorMessage}
                onClose={() => setErrorMessage(null)}
            />

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
                                            setErrorMessage(`Failed to start: ${e}`);
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
                <ToolDetailsModal
                    tool={selectedTool}
                    selectedToolSession={selectedToolSession}
                    onClose={() => setSelectedTool(null)}
                />
            )}

            {selectedEvent && (
                <EventDetailsModal
                    event={selectedEvent}
                    sessions={sessions}
                    onClose={() => setSelectedEvent(null)}
                />
            )}
        </div>
    );
};
