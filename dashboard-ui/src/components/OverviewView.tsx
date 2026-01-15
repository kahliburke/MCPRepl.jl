import React from 'react';
import { Session, SessionEvent } from '../types';
import { MetricCard } from './MetricCard';

interface OverviewViewProps {
    sessionCount: number;
    sessions: Record<string, Session>;
    eventCount: number;
    events: SessionEvent[];
    staleSessionCount: number;
    setActiveTab: React.Dispatch<React.SetStateAction<'overview' | 'events' | 'terminal' | 'tools' | 'logs' | 'history' | 'analytics'>>;
    setEventFilter: (filter: string) => void;
    setShowErrorsModal: (show: boolean) => void;
    setShowStaleSessionsModal: (show: boolean) => void;
}

export const OverviewView: React.FC<OverviewViewProps> = ({
    sessionCount,
    sessions,
    eventCount,
    events,
    staleSessionCount,
    setActiveTab,
    setEventFilter,
    setShowErrorsModal,
    setShowStaleSessionsModal
}) => {
    return (
        <div className="view active" id="overview-view">
            <h2>System Overview</h2>
            <div className="metrics-grid">
                <MetricCard
                    icon="👥"
                    label="Total Sessions Running"
                    value={sessionCount}
                />
                <MetricCard
                    icon="⚡"
                    label="Active Agents"
                    value={Object.values(sessions).filter(a => a.status === 'ready').length}
                />
                <MetricCard
                    icon="📊"
                    label="Total Events"
                    value={eventCount}
                    onClick={() => {
                        setActiveTab('events');
                        setEventFilter('interesting');
                    }}
                />
                <MetricCard
                    icon="🔥"
                    label="Events/min"
                    value={events.filter(e => {
                        const eventTime = new Date(e.timestamp);
                        const now = new Date();
                        return (now.getTime() - eventTime.getTime()) < 60000;
                    }).length}
                />
                <MetricCard
                    icon="⚠️"
                    label="Errors"
                    value={events.filter(e => e.type === 'ERROR').length}
                    valueColor="#ef4444"
                    onClick={() => setShowErrorsModal(true)}
                />
                <MetricCard
                    icon="🔧"
                    label="Tool Calls"
                    value={events.filter(e => e.type === 'TOOL_CALL').length}
                    valueColor="#7dd3fc"
                    onClick={() => {
                        setActiveTab('events');
                        setEventFilter('TOOL_CALL');
                    }}
                />
                <MetricCard
                    icon="🧹"
                    label="Stale Sessions"
                    value={staleSessionCount}
                    valueColor={staleSessionCount > 0 ? "#f59e0b" : "#10b981"}
                    onClick={() => setShowStaleSessionsModal(true)}
                />
            </div>
        </div>
    );
};
