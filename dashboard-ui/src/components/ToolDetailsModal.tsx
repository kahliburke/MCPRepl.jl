import React, { useState } from 'react';
import { JsonViewer } from '@textea/json-viewer';
import { ToolSchema, callTool, fetchDirectories } from '../api';

interface ToolDetailsModalProps {
    tool: ToolSchema;
    selectedToolSession: string | null;
    onClose: () => void;
}

export const ToolDetailsModal: React.FC<ToolDetailsModalProps> = ({
    tool,
    selectedToolSession,
    onClose
}) => {
    const [toolParams, setToolParams] = useState<Record<string, any>>({});
    const [toolResult, setToolResult] = useState<any>(null);
    const [toolExecuting, setToolExecuting] = useState(false);
    const [pathSuggestions, setPathSuggestions] = useState<string[]>([]);
    const [isJuliaProject, setIsJuliaProject] = useState(false);

    const handleClose = () => {
        setToolParams({});
        setToolResult(null);
        onClose();
    };

    const handleExecute = async () => {
        setToolExecuting(true);
        setToolResult(null);
        try {
            const result = await callTool({
                tool: tool.name,
                arguments: toolParams,
                sessionId: selectedToolSession ?? undefined
            });
            setToolResult(result);
        } catch (error) {
            setToolResult({ error: String(error) });
        } finally {
            setToolExecuting(false);
        }
    };

    const handleKeyDown = (e: React.KeyboardEvent) => {
        if (e.shiftKey && e.key === 'Enter' && !toolExecuting) {
            e.preventDefault();
            handleExecute();
        }
    };

    return (
        <div className="modal-overlay" onClick={handleClose} onKeyDown={handleKeyDown}>
            <div className="modal" onClick={(e) => e.stopPropagation()}>
                <div className="modal-header">
                    <h2>Tool Details: {tool.name}</h2>
                    <button className="modal-close" onClick={handleClose}>×</button>
                </div>
                <div className="modal-content">
                    <div className="detail-row">
                        <span className="detail-label">Name:</span>
                        <span className="detail-value"><code>{tool.name}</code></span>
                    </div>
                    <div className="detail-row">
                        <span className="detail-label">Description:</span>
                        <span className="detail-value">{tool.description}</span>
                    </div>

                    {tool.inputSchema?.properties && Object.keys(tool.inputSchema.properties).length > 0 && (
                        <div className="tool-test-section">
                            <h3>Test Tool</h3>
                            <div className="tool-params-form">
                                {Object.entries(tool.inputSchema.properties).map(([name, schema]: [string, any]) => {
                                    const isRequired = tool.inputSchema.required?.includes(name);
                                    return (
                                    <div key={name} className={`param-input-group ${isRequired ? 'param-required' : 'param-optional'}`}>
                                        <label>
                                            <span className="param-name-text">{name}</span>
                                            <span className="param-type">({schema.type})</span>
                                            <span className={`param-badge ${isRequired ? 'badge-required' : 'badge-optional'}`}>
                                                {isRequired ? 'required' : 'optional'}
                                            </span>
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
                                                        const value = e.target.value;
                                                        if (name === 'project_path' && tool.name === 'start_julia_session' && value && !toolParams['session_name']) {
                                                            try {
                                                                const result = await fetchDirectories(value);
                                                                if (result.is_julia_project) {
                                                                    let projectName = value.split('/').filter(p => p.length > 0).pop() || '';
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
                                                    }}
                                                    onKeyDown={async (e) => {
                                                        if (e.key === 'Tab') {
                                                            e.preventDefault();

                                                            if (pathSuggestions.length > 0) {
                                                                const firstSuggestion = pathSuggestions[0];
                                                                const newParams = { ...toolParams, [name]: firstSuggestion + '/' };
                                                                setToolParams(newParams);

                                                                try {
                                                                    const result = await fetchDirectories(firstSuggestion + '/');
                                                                    setPathSuggestions(result.directories || []);
                                                                    setIsJuliaProject(result.is_julia_project || false);

                                                                    if (name === 'project_path' && tool.name === 'start_julia_session' && result.is_julia_project && !toolParams['session_name']) {
                                                                        let projectName = firstSuggestion.split('/').filter(p => p.length > 0).pop() || '';
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
                                    );
                                })}
                            </div>
                            <button
                                className="tool-execute-btn"
                                disabled={toolExecuting}
                                onClick={handleExecute}
                                title="Shift+Enter"
                            >
                                {toolExecuting ? 'Executing...' : '▶ Try it'}
                            </button>
                        </div>
                    )}

                    {!tool.inputSchema?.properties || Object.keys(tool.inputSchema.properties).length === 0 && (
                        <div className="tool-test-section">
                            <h3>Test Tool</h3>
                            <p className="param-help">This tool takes no parameters.</p>
                            <button
                                className="tool-execute-btn"
                                disabled={toolExecuting}
                                onClick={handleExecute}
                                title="Shift+Enter"
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

                    {tool.inputSchema && (
                        <div className="detail-row detail-data">
                            <span className="detail-label">Input Schema:</span>
                            <div className="detail-value json-tree">
                                <JsonViewer
                                    value={tool.inputSchema}
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
    );
};
