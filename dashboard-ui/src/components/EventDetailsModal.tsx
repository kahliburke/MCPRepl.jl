import React from 'react';
import { JsonViewer } from '@textea/json-viewer';
import { SessionEvent } from '../types';

interface EventDetailsModalProps {
    event: SessionEvent;
    onClose: () => void;
}

export const EventDetailsModal: React.FC<EventDetailsModalProps> = ({ event, onClose }) => {
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
                        <span className="detail-label">Agent ID:</span>
                        <span className="detail-value">{event.id}</span>
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
                    {event.data.tool && (
                        <div className="detail-row">
                            <span className="detail-label">Tool:</span>
                            <span className="detail-value">{event.data.tool}</span>
                        </div>
                    )}
                    {event.data.arguments && Object.keys(event.data.arguments).length > 0 && (
                        <div className="detail-row detail-data">
                            <span className="detail-label">Arguments:</span>
                            <div className="detail-value json-tree">
                                <JsonViewer
                                    value={event.data.arguments}
                                    theme="dark"
                                    defaultInspectDepth={2}
                                    displayDataTypes={false}
                                    rootName="arguments"
                                />
                            </div>
                        </div>
                    )}
                    {event.data.result && (
                        <div className="detail-row detail-data">
                            <span className="detail-label">Result:</span>
                            <div className="detail-value json-tree">
                                <JsonViewer
                                    value={event.data.result}
                                    theme="dark"
                                    defaultInspectDepth={2}
                                    displayDataTypes={false}
                                    rootName="result"
                                />
                            </div>
                        </div>
                    )}
                    {event.data.error && (
                        <div className="detail-row detail-data">
                            <span className="detail-label">Error:</span>
                            <div className="detail-value json-tree error-tree">
                                <JsonViewer
                                    value={event.data.error}
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
                                value={event.data}
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
