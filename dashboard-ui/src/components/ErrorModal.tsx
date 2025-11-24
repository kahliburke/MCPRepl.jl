import React from 'react';

interface ErrorModalProps {
    error: string | null;
    onClose: () => void;
}

export const ErrorModal: React.FC<ErrorModalProps> = ({ error, onClose }) => {
    if (!error) return null;

    return (
        <div className="modal-overlay" onClick={onClose}>
            <div className="modal-content error-modal" onClick={(e) => e.stopPropagation()}>
                <div className="modal-header">
                    <h2>❌ Error</h2>
                    <button className="modal-close" onClick={onClose}>✕</button>
                </div>
                <div className="modal-body">
                    <pre className="error-message">{error}</pre>
                </div>
                <div className="modal-footer">
                    <button className="modal-button primary" onClick={onClose}>
                        OK
                    </button>
                </div>
            </div>
        </div>
    );
};
