import React from 'react';
import { Session } from '../types';
import { ToolSchema } from '../api';

interface ToolsViewProps {
    sessions: Record<string, Session>;
    tools: {
        proxy_tools: ToolSchema[];
        session_tools: Record<string, ToolSchema[]>;
    } | null;
    selectedToolSession: string | null;
    setSelectedToolSession: (sessionId: string | null) => void;
    setTools: (tools: any) => void;
    setSelectedTool: (tool: ToolSchema | null) => void;
    fetchTools: (sessionId?: string) => Promise<any>;
}

export const ToolsView: React.FC<ToolsViewProps> = ({
    sessions,
    tools,
    selectedToolSession,
    setSelectedToolSession,
    setTools,
    setSelectedTool,
    fetchTools
}) => {
    return (
        <div className="view active" id="tools-view">
            <h2>🛠️ Tools Explorer</h2>
            <p className="view-description">Browse and learn about available MCP tools</p>

            <div className="tools-selector">
                <button
                    className={`tools-tab ${selectedToolSession === null ? 'active' : ''}`}
                    onClick={() => {
                        setSelectedToolSession(null);
                        fetchTools().then(setTools);
                    }}
                >
                    Proxy Tools
                </button>
                {Object.keys(sessions).map(sessionId => (
                    <button
                        key={sessionId}
                        className={`tools-tab ${selectedToolSession === sessionId ? 'active' : ''}`}
                        onClick={() => {
                            setSelectedToolSession(sessionId);
                            fetchTools(sessionId).then(setTools);
                        }}
                        title={`UUID: ${sessionId}`}
                    >
                        {sessions[sessionId].name} Tools
                    </button>
                ))}
            </div>

            {tools && (
                <div className="tools-grid">
                    {selectedToolSession === null ? (
                        // Show proxy tools
                        tools.proxy_tools?.length > 0 ? tools.proxy_tools.map((tool: ToolSchema) => (
                            <div key={tool.name} className="tool-card" onClick={() => setSelectedTool(tool)}>
                                <div className="tool-header">
                                    <h3 className="tool-name">🔧 {tool.name}</h3>
                                    <span className="tool-badge proxy-badge">Proxy</span>
                                </div>
                                <p className="tool-description">{tool.description}</p>

                                {tool.inputSchema?.properties && Object.keys(tool.inputSchema.properties).length > 0 && (
                                    <div className="tool-params">
                                        <h4>Parameters:</h4>
                                        <ul>
                                            {Object.entries(tool.inputSchema.properties).map(([name, schema]: [string, any]) => (
                                                <li key={name}>
                                                    <code className="param-name">{name}</code>
                                                    {tool.inputSchema.required?.includes(name) && <span className="required">*</span>}
                                                    {schema.type && <span className="param-type">({schema.type})</span>}
                                                    {schema.description && <p className="param-desc">{schema.description}</p>}
                                                </li>
                                            ))}
                                        </ul>
                                    </div>
                                )}
                            </div>
                        )) : <p>No proxy tools available</p>
                    ) : (
                        // Show agent tools
                        tools.session_tools[selectedToolSession]?.length > 0 ? tools.session_tools[selectedToolSession].map((tool: ToolSchema) => (
                            <div key={tool.name} className="tool-card" onClick={() => setSelectedTool(tool)}>
                                <div className="tool-header">
                                    <h3 className="tool-name">⚡ {tool.name}</h3>
                                    <span className="tool-badge agent-badge">Julia</span>
                                </div>
                                <p className="tool-description">{tool.description}</p>

                                {tool.inputSchema?.properties && Object.keys(tool.inputSchema.properties).length > 0 && (
                                    <div className="tool-params">
                                        <h4>Parameters:</h4>
                                        <ul>
                                            {Object.entries(tool.inputSchema.properties).map(([name, schema]: [string, any]) => (
                                                <li key={name}>
                                                    <code className="param-name">{name}</code>
                                                    {tool.inputSchema.required?.includes(name) && <span className="required">*</span>}
                                                    {schema.type && <span className="param-type">({schema.type})</span>}
                                                    {schema.description && <p className="param-desc">{schema.description}</p>}
                                                </li>
                                            ))}
                                        </ul>
                                    </div>
                                )}
                            </div>
                        )) : <p>No tools available for session "{sessions[selectedToolSession]?.name || selectedToolSession}"</p>
                    )}
                </div>
            )}
        </div>
    );
};
