import { useCallback, useEffect, useRef, useState } from 'react';
import { api } from './api';
import { copy, type Language } from './i18n';
import type { ImportHistory, ImportHistoryCursor, ImportHistoryEntry } from './types';

export function ImportHistoryPanel({ language, onResume, onOpen }: {
  language: Language;
  onResume(job: ImportHistoryEntry): void;
  onOpen(operationId: string): void;
}) {
  const t = copy(language);
  const [history, setHistory] = useState<ImportHistory | null>(null);
  const [busy, setBusy] = useState(true);
  const [failed, setFailed] = useState(false);
  const active = useRef(false);
  const sequence = useRef(0);
  const load = useCallback(async (after?: ImportHistoryCursor) => {
    const current = ++sequence.current;
    setBusy(true); setFailed(false);
    try {
      const result = await api.importHistory(after);
      if (active.current && current === sequence.current) setHistory(previous => {
        if (!after) return result;
        const jobs = new Map((previous?.jobs ?? []).map(job => [job.jobId, job]));
        result.jobs.forEach(job => jobs.set(job.jobId, job));
        return { ...result, jobs: [...jobs.values()] };
      });
    }
    catch { if (active.current && current === sequence.current) { if (!after) setHistory(null); setFailed(true); } }
    finally { if (active.current && current === sequence.current) setBusy(false); }
  }, []);
  useEffect(() => { active.current = true; void load(); return () => { active.current = false; }; }, [load]);
  const cancel = async (job: ImportHistoryEntry) => {
    setBusy(true); setFailed(false);
    try { await api.cancelQueuedImport(job.jobId, job.attempt); await load(); }
    catch { if (active.current) { setHistory(null); setFailed(true); setBusy(false); } }
  };
  const labels = {
    queued: t.importQueued, running: t.importRunning, succeeded: t.importSucceeded,
    failed: t.importFailedState, cancelled: t.importCancelled, interrupted: t.importInterrupted,
    blocked: t.importBlocked,
  };
  return <div className="import-history" aria-busy={busy}>
    <p className="dialog-description">{t.importHistoryHint}</p>
    <button className="button" disabled={busy} onClick={() => void load()}>{t.refreshImports}</button>
    {busy && <p role="status">{t.loading}</p>}
    {failed && <p role="alert">{t.importHistoryFailed}</p>}
    {!busy && history?.total === 0 && <p>{t.noImports}</p>}
    {!!history?.jobs.length && <p>{t.importHistoryLimited} ({history.jobs.length}/{history.total})</p>}
    <ul className="import-history-list">
      {history?.jobs.map(job => <li key={job.jobId}>
        <div><strong>{t.importItem} {job.jobId.slice(0, 8)}</strong><p>{labels[job.state]} · {t.importAttempt} {job.attempt}</p></div>
        <progress aria-label={`${t.importItem} ${job.jobId.slice(0, 8)}`} max={1} value={job.progress}/>
        <div className="import-history-actions">
          {['queued', 'failed', 'interrupted', 'cancelled'].includes(job.state) && <button className="button" disabled={busy} onClick={() => onResume(job)}>{t.resumeImport}</button>}
          {['queued', 'interrupted', 'blocked'].includes(job.state) && <button className="button" disabled={busy} onClick={() => void cancel(job)}>{t.cancel}</button>}
          {job.state === 'succeeded' && <button className="button" disabled={busy} onClick={() => onOpen(job.operationId)}>{t.openImport}</button>}
        </div>
      </li>)}
    </ul>
    {history?.hasMore && history.nextCursor && <button className="button" disabled={busy} onClick={() => void load(history.nextCursor!)}>{t.moreImports}</button>}
  </div>;
}
