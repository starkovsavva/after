import { useEffect, useRef, useState } from 'react';
import { api } from './api';
import type { Copy } from './i18n';
import type { SpeechCheck } from './types';

export function SpeechCheckPanel({ t }: { t: Copy }) {
  const [check, setCheck] = useState<SpeechCheck | null>(null);
  const [busy, setBusy] = useState(false);
  const [initialized, setInitialized] = useState(false);
  const [error, setError] = useState(false);
  const epoch = useRef(0);
  const acting = useRef(false);
  const alive = useRef(true);
  const active = check?.state === 'running' || check?.state === 'queued';
  useEffect(() => {
    alive.current = true;
    const generation = epoch.current;
    void api.speechCheckStatus().then(value => { if (alive.current && generation === epoch.current) { setCheck(value); setInitialized(true); } })
      .catch(() => { if (alive.current && generation === epoch.current) setError(true); });
    return () => { alive.current = false; epoch.current++; };
  }, []);
  useEffect(() => {
    if (!active) return;
    let disposed = false;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      if (acting.current) { timer = setTimeout(poll, 500); return; }
      const generation = epoch.current;
      try { const value = await api.speechCheckStatus(); if (!disposed && generation === epoch.current) { setCheck(value); setError(false); } }
      catch { if (!disposed && generation === epoch.current) setError(true); }
      if (!disposed) timer = setTimeout(poll, 500);
    };
    timer = setTimeout(poll, 500);
    return () => { disposed = true; clearTimeout(timer); };
  }, [check?.id, active]);
  const action = async (run: () => Promise<SpeechCheck | null>) => {
    if (acting.current) return;
    acting.current = true; setBusy(true); setError(false);
    const generation = ++epoch.current;
    try { const value = await run(); if (alive.current && generation === epoch.current) { setCheck(value); setInitialized(true); } }
    catch { if (alive.current && generation === epoch.current) setError(true); }
    finally { acting.current = false; if (alive.current && generation === epoch.current) setBusy(false); }
  };
  const labels = { queued: t.speechCheckQueued, running: t.speechCheckRunning, succeeded: t.speechCheckPassed,
    failed: t.speechCheckFailed, cancelled: t.speechCheckCancelled, interrupted: t.speechCheckInterrupted, blocked: t.speechCheckQueued };
  return <section className="port-notice speech-check" aria-label={t.speechCheckTitle}>
    <h3>{t.speechCheckTitle}</h3><p>{t.speechCheckHint}</p>
    <p role="status">{!initialized ? t.speechCheckLoading : check?.cancelRequested && active ? t.speechCheckStopping : check ? labels[check.state] : t.speechCheckIdle}</p>
    {check?.state === 'succeeded' && <p>{t.speechCheckHistorical}</p>}
    {check?.state === 'running' && <progress aria-label={t.speechCheckTitle} max={1} value={check.progress}/>}
    {error && <p role="alert">{t.speechCheckError}</p>}
    <div className="dialog-actions">
      <button className="button" disabled={busy} onClick={() => void action(() => api.speechCheckStatus())}>{t.speechCheckRefresh}</button>
      <button className="button primary" disabled={busy || !initialized || check?.state === 'running'} onClick={() => void action(() => api.startSpeechCheck())}>{check?.state === 'queued' ? t.speechCheckRunQueued : t.speechCheckStart}</button>
      {active && check && <button className="button" disabled={busy || check.cancelRequested} onClick={() => void action(() => api.cancelSpeechCheck(check.id, check.attempt))}>{t.speechCheckCancel}</button>}
    </div>
  </section>;
}
