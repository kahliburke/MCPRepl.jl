import React from 'react';
import { JsonViewer } from '@textea/json-viewer';
import { SessionEvent, Session } from '../types';

interface EventDetailsModalProps {
    event: SessionEvent;
    sessions: Record<string, Session>;
    onClose: () => void;
}

export const EventDetailsModal: React.FC<EventDetailsModalProps> = ({ event, sessions, onClose }) => {
    const sessionName = sessions[event.id]?.name || 'Unknown';
    const shortUuid = event.id.substring(0, 8) + '...';
    const safeData = event.data ?? {};
    return (
        <div className="modal-overlay" onClick={onClose}>
            <div className="modal" onClick={(e) => e.stopPropagation()}>
                <div className="modal-header">
                    <h2>Event Details</h2>
                    <button className="modal-close" onClick={onClose}>×</button>
                </div>
                <div className="modal-content">
                    <div className="detail-row">
                        <span className="detail-label">Type:</span>
                        <span className={`detail-value event-badge event-${event.type.toLowerCase()}`}>{event.type}</span>
                    </div>
                    <div className="detail-row">
                        <span className="detail-label">Session:</span>
                        <span className="detail-value" title={`UUID: ${event.id}`}>
                            {sessionName} <span style={{ color: '#64748b', fontSize: '0.85em' }}>({shortUuid})</span>
                        </span>
                    </div>
                    <div className="detail-row">
                        <span className="detail-label">Timestamp:</span>
                        <span className="detail-value">{event.timestamp}</span>
                    </div>
                    {event.duration_ms && (
                        <div className="detail-row">
                            <span className="detail-label">Duration:</span>
                            <span className="detail-value">{event.duration_ms.toFixed(2)} ms</span>
                        </div>
                    )}
                    {safeData.tool && (
                        <div className="detail-row">
                            <span className="detail-label">Tool:</span>
                            <span className="detail-value">{safeData.tool}</span>
                        </div>
                    )}
                    {safeData.arguments && Object.keys(safeData.arguments).length > 0 && (
                        <div className="detail-row detail-data">
                            <span className="detail-label">Arguments:</span>
                            <div className="detail-value json-tree">
                                <JsonViewer
                                    value={safeData.arguments}
                                    theme="dark"
                                    defaultInspectDepth={2}
                                    displayDataTypes={false}
                                    rootName="arguments"
                                />
                            </div>
                        </div>
                    )}
                    {safeData.result && (
                        <div className="detail-row detail-data">
                            <span className="detail-label">Result:</span>
                            <div className="detail-value json-tree">
                                <JsonViewer
                                    value={safeData.result}
                                    theme="dark"
                                    defaultInspectDepth={2}
                                    displayDataTypes={false}
                                    rootName="result"
                                />
                            </div>
                        </div>
                    )}
                    {safeData.error && (
                        <div className="detail-row detail-data">
                            <span className="detail-label">Error:</span>
                            <div className="detail-value json-tree error-tree">
                                <JsonViewer
                                    value={safeData.error}
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
                                value={safeData}
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
    );
};
