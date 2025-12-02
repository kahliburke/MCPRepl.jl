import React, { useEffect, useRef, useState } from 'react';
import { Line, ReferenceLine } from 'recharts';
import { LineChart, ResponsiveContainer, XAxis, YAxis } from 'recharts';
import { subscribeToEvents } from '../api';
import type { EventType, SessionEvent } from '../types';

interface HeartbeatChartProps {
    sessionId: string;
}

interface DataPoint {
    time: number;
    value: number;
}

interface EventMarker {
    time: number;
    type: EventType;
    label: string;
    color: string;
}

// Get marker color and label based on event type
function getMarkerStyle(type: EventType): { color: string; label: string } {
    switch (type) {
        case 'TOOL_CALL':
        case 'tool.call.start':
            return { color: '#f59e0b', label: 'T' }; // amber
        case 'tool.call.complete':
            return { color: '#22c55e', label: '✓' }; // green
        case 'CODE_EXECUTION':
            return { color: '#a855f7', label: 'C' }; // purple
        case 'ERROR':
            return { color: '#ef4444', label: '!' }; // red
        case 'OUTPUT':
            return { color: '#06b6d4', label: 'O' }; // cyan
        default:
            return { color: '#6b7280', label: '•' }; // gray
    }
}

// ECG-like waveform generator
// Returns a value based on progress (0-1) through the heartbeat cycle
function ecgWaveform(progress: number, amplitude: number): number {
    const baseline = 0.25;

    // P wave (small atrial depolarization bump)
    if (progress >= 0.0 && progress < 0.12) {
        const t = (progress - 0.0) / 0.12;
        return baseline + Math.sin(t * Math.PI) * amplitude * 0.15;
    }
    // PR segment (flat)
    if (progress >= 0.12 && progress < 0.18) {
        return baseline;
    }
    // Q wave (downward deflection before R)
    if (progress >= 0.18 && progress < 0.22) {
        const t = (progress - 0.18) / 0.04;
        return baseline - Math.sin(t * Math.PI) * amplitude * 0.25;
    }
    // R wave (sharp upward spike - the main peak)
    if (progress >= 0.22 && progress < 0.32) {
        const t = (progress - 0.22) / 0.10;
        return baseline + Math.sin(t * Math.PI) * amplitude * 1.0;
    }
    // S wave (sharp downward deflection below baseline)
    if (progress >= 0.32 && progress < 0.42) {
        const t = (progress - 0.32) / 0.10;
        return baseline - Math.sin(t * Math.PI) * amplitude * 0.45;
    }
    // ST segment (flat, slight elevation)
    if (progress >= 0.42 && progress < 0.52) {
        return baseline + amplitude * 0.02;
    }
    // T wave (ventricular repolarization - broader bump)
    if (progress >= 0.52 && progress < 0.74) {
        const t = (progress - 0.52) / 0.22;
        return baseline + Math.sin(t * Math.PI) * amplitude * 0.25;
    }
    // Return to baseline
    return baseline;
}

export const HeartbeatChart: React.FC<HeartbeatChartProps> = ({ sessionId }) => {
    const [data, setData] = useState<DataPoint[]>([]);
    const [markers, setMarkers] = useState<EventMarker[]>([]);
    const dataRef = useRef<DataPoint[]>([]);
    const markersRef = useRef<EventMarker[]>([]);
    const lastBeatRef = useRef<number>(0);
    const spikeStateRef = useRef<{ active: boolean; startTime: number; amplitude: number; duration: number }>({
        active: false,
        startTime: 0,
        amplitude: 0.68,
        duration: 800
    });

    useEffect(() => {
        // Initialize with baseline - 300 points to show 3-4 heartbeats in view
        const initialData: DataPoint[] = [];
        for (let i = 0; i < 300; i++) {
            initialData.push({
                time: i,
                value: 0.25 + (Math.random() - 0.5) * 0.04
            });
        }
        dataRef.current = initialData;
        setData(initialData);

        let frameCount = 0;

        // Event types that should create markers
        const markerEventTypes = ['TOOL_CALL', 'tool.call.start', 'tool.call.complete', 'CODE_EXECUTION', 'ERROR', 'OUTPUT'];

        // Subscribe to real-time events via SSE
        const unsubscribe = subscribeToEvents((event: SessionEvent) => {
            if (event.id === sessionId) {
                if (event.type === 'HEARTBEAT') {
                    const eventTime = new Date(event.timestamp).getTime();
                    const now = Date.now();

                    // Avoid duplicate spikes
                    if (eventTime > lastBeatRef.current) {
                        lastBeatRef.current = eventTime;
                        // Trigger spike with prominent amplitude, wider duration
                        spikeStateRef.current = {
                            active: true,
                            startTime: now,
                            amplitude: 0.65 + Math.random() * 0.08,
                            duration: 760 + Math.random() * 80
                        };
                    }
                } else if (markerEventTypes.includes(event.type)) {
                    // Add event marker at current time position
                    const currentTime = dataRef.current[dataRef.current.length - 1]?.time ?? 0;
                    const style = getMarkerStyle(event.type);
                    const newMarker: EventMarker = {
                        time: currentTime,
                        type: event.type,
                        label: style.label,
                        color: style.color
                    };
                    markersRef.current = [...markersRef.current, newMarker];
                }
            }
        }, sessionId);

        // Animate
        let animationId: number;
        const animate = () => {
            frameCount++;
            // Update every 3rd frame for slower scrolling (shows 3-4 heartbeats in view)
            if (frameCount % 6 !== 0) {
                animationId = requestAnimationFrame(animate);
                return;
            }

            const now = Date.now();
            const newData = [...dataRef.current];

            // Shift data left
            newData.shift();

            let newValue: number;
            const spike = spikeStateRef.current;
            const timeSinceSpike = now - spike.startTime;

            if (spike.active && timeSinceSpike < spike.duration) {
                // During heartbeat - use ECG waveform
                const progress = timeSinceSpike / spike.duration;
                newValue = ecgWaveform(progress, spike.amplitude);
            } else {
                // Normal baseline with subtle noise
                spike.active = false;
                newValue = 0.25 + (Math.random() - 0.5) * 0.04;
            }

            newData.push({
                time: newData[newData.length - 1].time + 1,
                value: newValue
            });

            dataRef.current = newData;
            setData(newData);

            // Update markers - filter out those that have scrolled off screen
            const minTime = newData[0]?.time ?? 0;
            const maxTime = newData[newData.length - 1]?.time ?? 0;
            const visibleMarkers = markersRef.current.filter(m => m.time >= minTime && m.time <= maxTime);
            markersRef.current = visibleMarkers;
            setMarkers(visibleMarkers);

            animationId = requestAnimationFrame(animate);
        };

        animationId = requestAnimationFrame(animate);

        return () => {
            cancelAnimationFrame(animationId);
            unsubscribe();
        };
    }, [sessionId]);

    return (
        <ResponsiveContainer width="100%" height="100%">
            <LineChart data={data} margin={{ top: 5, right: 5, bottom: 5, left: 5 }}>
                <defs>
                    <linearGradient id="ecgGradient" x1="0" y1="0" x2="0" y2="1">
                        {/* Top of chart (high values/spikes) = green */}
                        <stop offset="0%" stopColor="#4ade80" stopOpacity={0.95} />
                        <stop offset="45%" stopColor="#4ade80" stopOpacity={0.9} />
                        {/* Baseline zone (0.25 = 75% down) = blue */}
                        <stop offset="65%" stopColor="#7dd3fc" stopOpacity={0.75} />
                        <stop offset="80%" stopColor="#7dd3fc" stopOpacity={0.75} />
                        {/* Below baseline dips = green */}
                        <stop offset="90%" stopColor="#4ade80" stopOpacity={0.85} />
                        <stop offset="100%" stopColor="#4ade80" stopOpacity={0.9} />
                    </linearGradient>
                </defs>
                <XAxis dataKey="time" hide />
                <YAxis domain={[0, 1]} hide />
                <Line
                    type="monotone"
                    dataKey="value"
                    stroke="url(#ecgGradient)"
                    strokeWidth={1.5}
                    dot={false}
                    isAnimationActive={false}
                />
                {/* Event markers */}
                {markers.map((marker, idx) => (
                    <ReferenceLine
                        key={`${marker.time}-${idx}`}
                        x={marker.time}
                        stroke={marker.color}
                        strokeWidth={2}
                        strokeDasharray="3 3"
                        strokeOpacity={0.8}
                    />
                ))}
            </LineChart>
        </ResponsiveContainer>
    );
};
