import React from 'react';
import { SessionEvent } from '../types';

interface ErrorsModalProps {
    events: SessionEvent[];
    onClose: () => void;
}

export const ErrorsModal: React.FC<ErrorsModalProps> = ({ events, onClose }) => {
    const errors = events.filter(e => e.type === 'ERROR');

    return (
        <div className="modal-overlay" onClick={onClose}>
            <div className="modal-content" onClick={(e) => e.stopPropagation()}>
                <div className="modal-header">
                    <h2>⚠️ Errors ({errors.length})</h2>
                    <button className="modal-close" onClick={onClose}>✕</button>
                </div>
                <div className="modal-body" style={{ maxHeight: '500px', overflow: 'auto' }}>
                    {errors.length === 0 ? (
                        <p>No errors found! 🎉</p>
                    ) : (
                        <div className="error-list">
                            {errors.map((event, idx) => (
                                <div key={idx} className="error-item">
                                    <div className="error-time">{new Date(event.timestamp).toLocaleTimeString()}</div>
                                    <div className="error-message">{event.data.message || JSON.stringify(event.data)}</div>
                                </div>
                            ))}
                        </div>
                    )}
                </div>
                <div className="modal-footer">
                    <button className="modal-button secondary" onClick={onClose}>Close</button>
                </div>
            </div>
        </div>
    );
};
