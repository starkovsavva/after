import { useEffect, useRef, useState } from 'react';
import { api } from './api';
import type { Copy } from './i18n';
import type { Transcription } from './types';

export function TranscriptionPanel({ meetingId, hasResult, t, onPublished }: {
  meetingId: string; hasResult: boolean; t: Copy; onPublished: () => void;
}) {
  const [job, setJob] = useState<Transcription | null>(null);
  const [initialized, setInitialized] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(false);
  const [confirm, setConfirm] = useState<'start' | 'resume' | null>(null);
  const epoch = useRef(0);
  const alive = useRef(true);
  const acting = useRef(false);
  const published = useRef('');
  const onPublishedRef = useRef(onPublished);
  onPublishedRef.current = onPublished;
  const active = job?.state === 'running' || job?.state === 'queued';
  const accept = (value: Transcription | null, notify: boolean) => {
    setJob(value); setInitialized(true); setError(false);
    if (value?.state === 'succeeded' && notify) {
      const key = `${value.id}:${value.attempt}`;
      if (published.current !== key) { published.current = key; onPublishedRef.current(); }
    }
  };
  useEffect(() => {
    alive.current = true;
    const generation = epoch.current;
    void api.transcriptionStatus(meetingId).then(value => {
      if (alive.current && generation === epoch.current) accept(value, false);
    }).catch(() => { if (alive.current && generation === epoch.current) setError(true); });
    return () => { alive.current = false; epoch.current++; };
  }, [meetingId]);
  useEffect(() => {
    if (!active) return;
    let disposed = false;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      if (acting.current) { timer = setTimeout(poll, 500); return; }
      const generation = epoch.current;
      try {
        const value = await api.transcriptionStatus(meetingId);
        if (!disposed && generation === epoch.current) accept(value, true);
      } catch {
        if (!disposed && generation === epoch.current) { setError(true); setInitialized(false); }
      }
      if (!disposed) timer = setTimeout(poll, 500);
    };
    timer = setTimeout(poll, 500);
    return () => { disposed = true; clearTimeout(timer); };
  }, [meetingId, job?.id, active]);
  const action = async (run: () => Promise<Transcription | null>) => {
    if (acting.current) return;
    acting.current = true; setBusy(true); setError(false); setConfirm(null);
    const generation = ++epoch.current;
    try { const value = await run(); if (alive.current && generation === epoch.current) accept(value, true); }
    catch { if (alive.current && generation === epoch.current) { setError(true); setInitialized(false); } }
    finally { acting.current = false; if (alive.current && generation === epoch.current) setBusy(false); }
  };
  const run = (kind: 'start' | 'resume') => {
    if (kind === 'resume' && !job) return;
    void action(() => kind === 'start' ? api.startTranscription(meetingId) : api.resumeTranscription(meetingId, job!.id, job!.attempt));
  };
  const request = (kind: 'start' | 'resume') => { if (hasResult) setConfirm(kind); else run(kind); };
  const labels = { queued: t.transcriptionQueued, running: t.transcriptionRunning, succeeded: t.transcriptionSucceeded,
    failed: t.transcriptionFailed, cancelled: t.transcriptionCancelled, interrupted: t.transcriptionInterrupted, blocked: t.transcriptionQueued };
  const canStart = !job || ['succeeded', 'failed', 'cancelled'].includes(job.state);
  const canResume = job && !['running', 'succeeded'].includes(job.state);
  return <section className="port-notice transcription-panel" aria-label={t.transcriptionTitle}>
    <h3>{t.transcriptionTitle}</h3><p>{t.transcriptionHint}</p>
    <p role="status">{!initialized ? t.transcriptionLoading : job?.cancelRequested && active ? t.transcriptionStopping : job ? labels[job.state] : t.transcriptionIdle}</p>
    {job?.state === 'running' && <progress aria-label={t.transcriptionTitle} value={job.progress} max={1}/>}
    {error && <p role="alert">{t.transcriptionError}</p>}
    {canResume && <p>{t.transcriptionSaved}</p>}
    {confirm ? <div className="transcription-confirm">
      <p>{t.transcriptionReplace}</p>
      <div className="dialog-actions">
        <button className="button" onClick={() => setConfirm(null)}>{t.transcriptionKeep}</button>
        <button className="button primary" disabled={busy || !initialized} onClick={() => run(confirm)}>{t.transcriptionConfirm}</button>
      </div>
    </div> : <div className="dialog-actions">
      <button className="button" disabled={busy} onClick={() => void action(() => api.transcriptionStatus(meetingId))}>{t.transcriptionRefresh}</button>
      {canStart && <button className="button primary" disabled={busy || !initialized} onClick={() => request('start')}>{job ? t.transcriptionNew : t.transcriptionStart}</button>}
      {canResume && <button className="button primary" disabled={busy || !initialized || (job.cancelRequested && active)} onClick={() => request('resume')}>{t.transcriptionResume}</button>}
      {active && job && <button className="button" disabled={busy || !initialized || job.cancelRequested} onClick={() => void action(() => api.cancelTranscription(meetingId, job.id, job.attempt))}>{t.transcriptionCancel}</button>}
      {job?.state === 'succeeded' && <button className="button" onClick={onPublished}>{t.transcriptionResult}</button>}
    </div>}
  </section>;
}
