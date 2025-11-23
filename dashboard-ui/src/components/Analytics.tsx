import React, { useEffect, useState } from 'react';
import {
    fetchToolSummary,
    fetchErrorHotspots,
    fetchETLStatus,
    fetchToolExecutions,
    fetchAnalyticsErrors,
    runETL,
    ToolSummary,
    ErrorHotspot,
    ETLStatus,
    ToolExecution,
    AnalyticsError
} from '../api';
import './Analytics.css';

interface AnalyticsProps {
    sessionId: string | null;
}

export const Analytics: React.FC<AnalyticsProps> = ({ sessionId }) => {
    const [toolSummary, setToolSummary] = useState<ToolSummary[]>([]);
    const [errorHotspots, setErrorHotspots] = useState<ErrorHotspot[]>([]);
    const [etlStatus, setETLStatus] = useState<ETLStatus | null>(null);
    const [recentExecutions, setRecentExecutions] = useState<ToolExecution[]>([]);
    const [recentErrors, setRecentErrors] = useState<AnalyticsError[]>([]);
    const [loading, setLoading] = useState(true);
    const [activeView, setActiveView] = useState<'overview' | 'tools' | 'errors' | 'executions'>('overview');
    const [selectedTool, setSelectedTool] = useState<string | null>(null);
    const [etlRunning, setEtlRunning] = useState(false);

    const loadData = async () => {
        setLoading(true);
        try {
            const [summary, hotspots, status, executions, errors] = await Promise.all([
                fetchToolSummary({ session_id: sessionId || undefined, days: 7 }),
                fetchErrorHotspots(),
                fetchETLStatus(),
                fetchToolExecutions({ session_id: sessionId || undefined, limit: 20 }),
                fetchAnalyticsErrors({ session_id: sessionId || undefined, resolved: false, limit: 20 })
            ]);

            setToolSummary(summary);
            setErrorHotspots(hotspots);
            setETLStatus(status);
            setRecentExecutions(executions);
            setRecentErrors(errors);
        } catch (error) {
            console.error('Failed to load analytics:', error);
        } finally {
            setLoading(false);
        }
    };

    useEffect(() => {
        loadData();
        const interval = setInterval(loadData, 30000); // Refresh every 30s
        return () => clearInterval(interval);
    }, [sessionId]);

    const handleRunETL = async () => {
        setEtlRunning(true);
        try {
            const result = await runETL();
            console.log('ETL result:', result);
            await loadData(); // Reload data after ETL
        } catch (error) {
            console.error('Failed to run ETL:', error);
        } finally {
            setEtlRunning(false);
        }
    };

    const formatDuration = (ms: number | null) => {
        if (ms === null) return 'N/A';
        if (ms < 1000) return `${ms.toFixed(0)}ms`;
        return `${(ms / 1000).toFixed(2)}s`;
    };

    const formatTimestamp = (ts: string) => {
        const date = new Date(ts);
        return date.toLocaleString();
    };

    if (loading) {
        return (
            <div className="analytics-container">
                <div className="loading">Loading analytics...</div>
            </div>
        );
    }

    return (
        <div className="analytics-container">
            <div className="analytics-header">
                <h2>📊 Analytics Dashboard</h2>
                {sessionId && <div className="session-filter">Session: {sessionId}</div>}
                {etlStatus && (
                    <div className="etl-status">
                        <span>Last ETL: {etlStatus.last_run_time ? formatTimestamp(etlStatus.last_run_time) : 'Never'}</span>
                        <span className={`status-badge ${etlStatus.last_run_status}`}>
                            {etlStatus.last_run_status || 'unknown'}
                        </span>
                        <button
                            onClick={handleRunETL}
                            disabled={etlRunning}
                            className="run-etl-button"
                        >
                            {etlRunning ? '⏳ Running...' : '🔄 Run ETL Now'}
                        </button>
                    </div>
                )}
            </div>

            <div className="analytics-tabs">
                <button
                    className={`analytics-tab ${activeView === 'overview' ? 'active' : ''}`}
                    onClick={() => setActiveView('overview')}
                >
                    Overview
                </button>
                <button
                    className={`analytics-tab ${activeView === 'tools' ? 'active' : ''}`}
                    onClick={() => setActiveView('tools')}
                >
                    Tools ({toolSummary.length})
                </button>
                <button
                    className={`analytics-tab ${activeView === 'errors' ? 'active' : ''}`}
                    onClick={() => setActiveView('errors')}
                >
                    Errors ({recentErrors.length})
                </button>
                <button
                    className={`analytics-tab ${activeView === 'executions' ? 'active' : ''}`}
                    onClick={() => setActiveView('executions')}
                >
                    Recent Executions ({recentExecutions.length})
                </button>
            </div>

            {activeView === 'overview' && (
                <div className="analytics-overview">
                    <div className="metrics-grid">
                        <div className="metric-card">
                            <div className="metric-label">Total Tools</div>
                            <div className="metric-value">{toolSummary.length}</div>
                        </div>
                        <div className="metric-card">
                            <div className="metric-label">Total Executions</div>
                            <div className="metric-value">
                                {toolSummary.reduce((sum, t) => sum + t.total_executions, 0)}
                            </div>
                        </div>
                        <div className="metric-card">
                            <div className="metric-label">Total Errors</div>
                            <div className="metric-value error">
                                {toolSummary.reduce((sum, t) => sum + t.total_errors, 0)}
                            </div>
                        </div>
                        <div className="metric-card">
                            <div className="metric-label">Avg Duration</div>
                            <div className="metric-value">
                                {formatDuration(
                                    toolSummary.reduce((sum, t) => sum + (t.avg_duration_ms || 0), 0) / toolSummary.length
                                )}
                            </div>
                        </div>
                    </div>

                    <div className="section">
                        <h3>🔥 Top Tools by Usage</h3>
                        <div className="tool-list">
                            {toolSummary.slice(0, 10).map(tool => (
                                <div key={tool.tool_name} className="tool-item" onClick={() => {
                                    setSelectedTool(tool.tool_name);
                                    setActiveView('tools');
                                }}>
                                    <div className="tool-name">{tool.tool_name}</div>
                                    <div className="tool-stats">
                                        <span className="executions">{tool.total_executions} calls</span>
                                        <span className="duration">{formatDuration(tool.avg_duration_ms)}</span>
                                        {tool.total_errors > 0 && (
                                            <span className="errors">{tool.total_errors} errors</span>
                                        )}
                                    </div>
                                </div>
                            ))}
                        </div>
                    </div>

                    {errorHotspots.length > 0 && (
                        <div className="section">
                            <h3>⚠️ Error Hotspots (Unresolved)</h3>
                            <div className="hotspot-list">
                                {errorHotspots.slice(0, 5).map((hotspot, idx) => (
                                    <div key={idx} className="hotspot-item">
                                        <div className="hotspot-header">
                                            <span className="tool-name">{hotspot.tool_name || 'Unknown'}</span>
                                            <span className="error-badge">{hotspot.error_category}</span>
                                        </div>
                                        <div className="hotspot-stats">
                                            <span>{hotspot.error_count} occurrences</span>
                                            <span>{hotspot.affected_sessions} sessions</span>
                                            <span className="timestamp">{formatTimestamp(hotspot.last_occurrence)}</span>
                                        </div>
                                    </div>
                                ))}
                            </div>
                        </div>
                    )}
                </div>
            )}

            {activeView === 'tools' && (
                <div className="tools-view">
                    <div className="tools-table">
                        <table>
                            <thead>
                                <tr>
                                    <th>Tool Name</th>
                                    <th>Executions</th>
                                    <th>Avg Duration</th>
                                    <th>Min/Max</th>
                                    <th>Errors</th>
                                    <th>Error Rate</th>
                                </tr>
                            </thead>
                            <tbody>
                                {toolSummary.map(tool => (
                                    <tr
                                        key={tool.tool_name}
                                        className={selectedTool === tool.tool_name ? 'selected' : ''}
                                        onClick={() => setSelectedTool(tool.tool_name)}
                                    >
                                        <td className="tool-name">{tool.tool_name}</td>
                                        <td>{tool.total_executions}</td>
                                        <td>{formatDuration(tool.avg_duration_ms)}</td>
                                        <td>
                                            {formatDuration(tool.min_duration_ms)} / {formatDuration(tool.max_duration_ms)}
                                        </td>
                                        <td className={tool.total_errors > 0 ? 'error' : ''}>
                                            {tool.total_errors}
                                        </td>
                                        <td>
                                            {tool.avg_error_rate_pct !== null
                                                ? `${tool.avg_error_rate_pct.toFixed(1)}%`
                                                : 'N/A'
                                            }
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                </div>
            )}

            {activeView === 'errors' && (
                <div className="errors-view">
                    <div className="errors-list">
                        {recentErrors.map(error => (
                            <div key={error.id} className="error-item">
                                <div className="error-header">
                                    <span className="error-type">{error.error_type}</span>
                                    <span className="error-category">{error.error_category}</span>
                                    {error.error_code && (
                                        <span className="error-code">Code: {error.error_code}</span>
                                    )}
                                    <span className="timestamp">{formatTimestamp(error.timestamp)}</span>
                                </div>
                                {error.tool_name && (
                                    <div className="error-tool">Tool: {error.tool_name}</div>
                                )}
                                <div className="error-message">{error.message}</div>
                                {error.stack_trace && (
                                    <details className="error-stack">
                                        <summary>Stack Trace</summary>
                                        <pre>{error.stack_trace}</pre>
                                    </details>
                                )}
                            </div>
                        ))}
                    </div>
                </div>
            )}

            {activeView === 'executions' && (
                <div className="executions-view">
                    <div className="executions-list">
                        {recentExecutions.map(exec => (
                            <div key={exec.id} className={`execution-item ${exec.status}`}>
                                <div className="execution-header">
                                    <span className="tool-name">{exec.tool_name}</span>
                                    <span className={`status-badge ${exec.status}`}>{exec.status}</span>
                                    <span className="duration">{formatDuration(exec.duration_ms)}</span>
                                    <span className="timestamp">{formatTimestamp(exec.request_time)}</span>
                                </div>
                                <div className="execution-stats">
                                    <span>In: {exec.input_size} bytes</span>
                                    <span>Out: {exec.output_size} bytes</span>
                                    <span>Args: {exec.argument_count}</span>
                                </div>
                                {exec.result_summary && (
                                    <div className="execution-result">
                                        {exec.result_summary}
                                    </div>
                                )}
                            </div>
                        ))}
                    </div>
                </div>
            )}
        </div>
    );
};
