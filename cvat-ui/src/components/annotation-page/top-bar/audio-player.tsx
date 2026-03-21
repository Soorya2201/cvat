// FILE: cvat-ui/src/components/annotation-page/top-bar/audio-player.tsx

import React, { useEffect, useRef, useState, useCallback } from 'react';
import { Button, Tooltip } from 'antd';
import { SoundOutlined, MutedOutlined, LoadingOutlined } from '@ant-design/icons';
import { Job } from 'cvat-core-wrapper';

interface Props {
    frameNumber: number;
    playing: boolean;
    jobInstance: Job;
}

type AudioStatus = 'idle' | 'loading' | 'ready' | 'no-audio' | 'error';

export default function AudioPlayer({ frameNumber, playing, jobInstance }: Props): JSX.Element | null {
    const audioRef = useRef<HTMLAudioElement>(null);
    const [isMuted, setIsMuted] = useState(false);
    const [audioStatus, setAudioStatus] = useState<AudioStatus>('idle');
    const [fps, setFps] = useState(25);

    const taskId = jobInstance?.taskId ?? null;

    // ── Fetch FPS from the job instance ──────────────────────────────────────
    useEffect(() => {
        if (!jobInstance) return;
        // CVAT Job instance exposes frameRate via the task's data object
        // Try reading it directly from the job; fall back to 25fps
        const frameRate = (jobInstance as any)?.frameRate
            ?? (jobInstance as any)?.task?.frameRate
            ?? 25;
        setFps(frameRate);
    }, [jobInstance]);

    // ── Load audio track when task changes ───────────────────────────────────
    useEffect(() => {
        if (!taskId || !audioRef.current) return;

        const audio = audioRef.current;
        setAudioStatus('loading');

        audio.src = `/api/tasks/${taskId}/audio/`;
        audio.load();

        const onCanPlay = (): void => setAudioStatus('ready');
        const onError = (): void => {
            // 204 No Content (no audio track) also triggers onerror on the audio element
            setAudioStatus('no-audio');
        };

        audio.addEventListener('canplaythrough', onCanPlay);
        audio.addEventListener('error', onError);

        return () => {
            audio.removeEventListener('canplaythrough', onCanPlay);
            audio.removeEventListener('error', onError);
            audio.src = '';
        };
    }, [taskId]);

    // ── Sync audio position to current frame ─────────────────────────────────
    useEffect(() => {
        if (!audioRef.current || audioStatus !== 'ready') return;
        const targetTime = frameNumber / fps;
        if (Math.abs(audioRef.current.currentTime - targetTime) > 0.15) {
            audioRef.current.currentTime = targetTime;
        }
    }, [frameNumber, fps, audioStatus]);

    // ── Mirror CVAT play / pause ──────────────────────────────────────────────
    useEffect(() => {
        if (!audioRef.current || audioStatus !== 'ready') return;
        if (playing) {
            audioRef.current.play().catch(() => {
                // Browser autoplay policy — silently ignore, user will hear audio
                // on their next interaction
            });
        } else {
            audioRef.current.pause();
        }
    }, [playing, audioStatus]);

    // ── Mute toggle ───────────────────────────────────────────────────────────
    const handleMuteToggle = useCallback(() => {
        if (!audioRef.current) return;
        const next = !isMuted;
        audioRef.current.muted = next;
        setIsMuted(next);
    }, [isMuted]);

    // Don't render the button at all if there's no audio in the video
    if (audioStatus === 'no-audio' || !taskId) return null;

    return (
        <>
            {/* Hidden audio element — zero visual footprint */}
            <audio ref={audioRef} style={{ display: 'none' }} preload='auto' />

            {/* Mute / unmute button sits in the top control bar */}
            <Tooltip title={isMuted ? 'Unmute audio (M)' : 'Mute audio (M)'}>
                <Button
                    type='text'
                    className='cvat-player-mute-button'
                    disabled={audioStatus === 'loading' || audioStatus === 'error'}
                    onClick={handleMuteToggle}
                    icon={
                        audioStatus === 'loading' ? <LoadingOutlined /> :
                            isMuted ? <MutedOutlined /> :
                                <SoundOutlined />
                    }
                    style={{ marginLeft: 4 }}
                />
            </Tooltip>
        </>
    );
}