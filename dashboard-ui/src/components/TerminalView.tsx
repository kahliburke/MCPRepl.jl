import React, { useState, useRef, useEffect } from 'react';
import { SessionEvent } from '../types';

interface TerminalViewProps {
    events: SessionEvent[];
    selectedSession: string | null;
}

export const TerminalView: React.FC<TerminalViewProps> = ({
    events,
    selectedSession
}) => {
    const [terminalSearch, setTerminalSearch] = useState('');
    const [isNearBottom, setIsNearBottom] = useState(true);
    const terminalRef = useRef<HTMLDivElement>(null);
    const terminalBottomRef = useRef<HTMLDivElement>(null);

    // Autoscroll to bottom when new events arrive (only if near bottom)
    useEffect(() => {
        if (terminalBottomRef.current && isNearBottom) {
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
    return (
        <div className="view active terminal-view" id="terminal-view">
            <div className="terminal-controls">
                <input
                    type="text"
                    placeholder="Search terminal..."
                    className="terminal-search"
                    onChange={(e) => setTerminalSearch(e.target.value)}
                />
                <button onClick={() => terminalRef.current?.scrollTo({ top: 0, behavior: 'smooth' })} className="terminal-control-btn">↑ Top</button>
                <button onClick={() => terminalBottomRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' })} className="terminal-control-btn">↓ Bottom</button>
            </div>
            <div className="terminal">
                <div className="terminal-output" ref={terminalRef} onScroll={handleTerminalScroll}>
                    {selectedSession ? (
                        events
                            .filter(e => e.id === selectedSession && e.type !== 'HEARTBEAT')
                            .slice(-1000)
                            .filter(event => {
                                if (!terminalSearch) return true;
                                const searchLower = terminalSearch.toLowerCase();
                                const eventStr = JSON.stringify(event.data).toLowerCase();
                                return eventStr.includes(searchLower);
                            })
                            .map((event, idx) => {
                                const renderEvent = () => {
                                    switch (event.type) {
                                        case 'TOOL_CALL':
                                            // For ex tool, show the actual Julia expression
                                            if (event.data.tool === 'ex') {
                                                const expr = event.data.arguments?.e || '';
                                                return (
                                                    <>
                                                        <span className="terminal-prompt">julia&gt;</span>
                                                        <span className="terminal-code">{expr}</span>
                                                    </>
                                                );
                                            }
                                            // For other tools, show tool name and args
                                            return (
                                                <>
                                                    <span className="terminal-prompt">julia&gt;</span>
                                                    <span className="terminal-tool">{event.data.tool}</span>
                                                    <span className="terminal-args">({JSON.stringify(event.data.arguments).slice(0, 60)}...)</span>
                                                </>
                                            );
                                        case 'CODE_EXECUTION':
                                            return (
                                                <>
                                                    <span className="terminal-prompt">julia&gt;</span>
                                                    <span className="terminal-method">{event.data.method}</span>
                                                </>
                                            );
                                        case 'OUTPUT':
                                            // Extract the actual content from the result
                                            let output = '';
                                            if (event.data.result?.content) {
                                                // MCP result format with content array
                                                const contents = event.data.result.content;
                                                if (Array.isArray(contents)) {
                                                    output = contents.map((c: any) => c.text || '').join('\n');
                                                }
                                            } else if (event.data.result) {
                                                output = typeof event.data.result === 'string'
                                                    ? event.data.result
                                                    : JSON.stringify(event.data.result, null, 2);
                                            }

                                            return (
                                                <>
                                                    <span className="terminal-output-text">{output || '(no output)'}</span>
                                                    {event.duration_ms && <span className="terminal-duration"> [{event.duration_ms.toFixed(1)}ms]</span>}
                                                </>
                                            );
                                        case 'ERROR':
                                            return (
                                                <>
                                                    <span className="terminal-error">ERROR: {event.data.message || JSON.stringify(event.data)}</span>
                                                </>
                                            );
                                        case 'SESSION_START':
                                            return <span className="terminal-info">→ Session started on port {event.data.port}</span>;
                                        case 'SESSION_STOP':
                                            return <span className="terminal-info">→ Session stopped</span>;
                                        case 'PROGRESS':
                                            const progressData = event.data.notification?.params;
                                            if (progressData) {
                                                const { progress, total, message } = progressData;
                                                const progressText = total !== undefined
                                                    ? `${Math.round((progress / total) * 100)}%`
                                                    : `step ${progress}`;
                                                return (
                                                    <span className="terminal-info">
                                                        🔄 {message || 'Processing'} ({progressText})
                                                    </span>
                                                );
                                            }
                                            return <span className="terminal-default">{JSON.stringify(event.data)}</span>;
                                        default:
                                            return <span className="terminal-default">{JSON.stringify(event.data)}</span>;
                                    }
                                };

                                return (
                                    <div key={idx} className={`terminal-line terminal-${event.type.toLowerCase()}`}>
                                        <span className="terminal-time">{event.timestamp.split(' ')[1]}</span>
                                        {renderEvent()}
                                    </div>
                                );
                            })
                    ) : (
                        <div className="log-placeholder">← Select a session from the sidebar to view its REPL activity</div>
                    )}
                    <div ref={terminalBottomRef} />
                </div>
            </div>
        </div>
    );
};
