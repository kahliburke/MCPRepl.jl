import React from 'react';

interface StaleSession {
    session_name: string;
    pid: number;
    is_stale: boolean;
}

interface StaleSessionsModalProps {
    staleSessions: StaleSession[];
    onClose: () => void;
    onKillStale: () => void;
    onKillAll: () => void;
}

export const StaleSessionsModal: React.FC<StaleSessionsModalProps> = ({
    staleSessions,
    onClose,
    onKillStale,
    onKillAll
}) => {
    const staleCount = staleSessions.filter(s => s.is_stale).length;

    return (
        <div className="modal-overlay" onClick={onClose}>
            <div className="modal-content" onClick={(e) => e.stopPropagation()}>
                <div className="modal-header">
                    <h2>🧹 Stale Sessions ({staleCount})</h2>
                    <button className="modal-close" onClick={onClose}>✕</button>
                </div>
                <div className="modal-body">
                    {staleSessions.length === 0 ? (
                        <p>No stale sessions found! ✅</p>
                    ) : (
                        <div className="stale-sessions-list">
                            {staleSessions.map((session, idx) => (
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
                    <button className="modal-button secondary" onClick={onClose}>Close</button>
                    {staleCount > 0 && (
                        <button className="modal-button warning" onClick={onKillStale}>
                            Kill Stale Sessions
                        </button>
                    )}
                    {staleSessions.length > 0 && (
                        <button className="modal-button danger" onClick={onKillAll}>
                            Kill All Sessions
                        </button>
                    )}
                </div>
            </div>
        </div>
    );
};
