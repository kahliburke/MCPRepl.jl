import React from 'react';
import { fetchDirectories } from '../api';

interface QuickStartModalProps {
    quickStartPath: string;
    setQuickStartPath: (path: string) => void;
    quickStartName: string;
    setQuickStartName: (name: string) => void;
    quickStartLoading: boolean;
    pathSuggestions: string[];
    setPathSuggestions: (suggestions: string[]) => void;
    isJuliaProject: boolean;
    setIsJuliaProject: (isProject: boolean) => void;
    onClose: () => void;
    onStart: () => void;
}

export const QuickStartModal: React.FC<QuickStartModalProps> = ({
    quickStartPath,
    setQuickStartPath,
    quickStartName,
    setQuickStartName,
    quickStartLoading,
    pathSuggestions,
    setPathSuggestions,
    isJuliaProject,
    setIsJuliaProject,
    onClose,
    onStart
}) => {
    return (
        <div className="modal-overlay" onClick={onClose}>
            <div className="modal-content" onClick={(e) => e.stopPropagation()}>
                <div className="modal-header">
                    <h2>🚀 Quick Start Session</h2>
                    <button className="modal-close" onClick={onClose}>✕</button>
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
                        onClick={onClose}
                        disabled={quickStartLoading}
                    >
                        Cancel
                    </button>
                    <button
                        className="modal-button primary"
                        onClick={onStart}
                        disabled={quickStartLoading}
                    >
                        {quickStartLoading ? '🚀 Starting...' : 'Start Session'}
                    </button>
                </div>
            </div>
        </div>
    );
};
