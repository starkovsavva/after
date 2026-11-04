import { useEffect, useRef, useState } from 'react';
import { api } from './api';
import type { Copy } from './i18n';
import type { SpeechModelConfiguration } from './types';

export function SpeechModelPanel({ t }: { t: Copy }) {
  const [configuration, setConfiguration] = useState<SpeechModelConfiguration | null>(null);
  const [initialized, setInitialized] = useState(false);
  const [busy, setBusy] = useState(false);
  const [selecting, setSelecting] = useState(false);
  const [error, setError] = useState(false);
  const alive = useRef(true);
  const epoch = useRef(0);
  const acting = useRef(false);
  useEffect(() => {
    alive.current = true;
    const generation = epoch.current;
    void api.getSpeechModelConfiguration().then(value => {
      if (alive.current && generation === epoch.current) { setConfiguration(value); setInitialized(true); }
    }).catch(() => { if (alive.current && generation === epoch.current) setError(true); });
    return () => { alive.current = false; epoch.current++; };
  }, []);
  const action = async (select: boolean) => {
    if (acting.current || (select && (!initialized || !configuration?.candidate))) return;
    acting.current = true; setBusy(true); setSelecting(select); setError(false);
    const generation = ++epoch.current;
    try {
      const value = select ? {
        candidate: configuration!.candidate,
        selection: await api.selectManagedSpeechModel(configuration!.candidate!.generation, configuration!.selection.revision),
      } : await api.getSpeechModelConfiguration();
      if (alive.current && generation === epoch.current) { setConfiguration(value); setInitialized(true); }
    } catch {
      if (alive.current && generation === epoch.current) { setError(true); setInitialized(false); }
    } finally {
      acting.current = false;
      if (alive.current && generation === epoch.current) setBusy(false);
    }
  };
  return <section className="port-notice speech-model" aria-label={t.modelSelectionTitle}>
    <h3>{t.modelSelectionTitle}</h3><p>{t.modelSelectionHint}</p>
    <p role="status">{busy ? selecting ? t.modelSelectionBusy : t.modelSelectionLoading : !initialized ? t.modelSelectionLoading : configuration?.selection.local ? t.modelSelectionLocal : t.modelSelectionOther}</p>
    {initialized && <p>{configuration?.candidate ? t.modelSelectionCandidate : t.modelSelectionMissing}</p>}
    {error && <p role="alert">{t.modelSelectionError}</p>}
    <div className="dialog-actions">
      <button className="button" disabled={busy} onClick={() => void action(false)}>{t.modelSelectionRefresh}</button>
      <button className="button primary" disabled={busy || !initialized || !configuration?.candidate} onClick={() => void action(true)}>{t.modelSelectionUse}</button>
    </div>
  </section>;
}
