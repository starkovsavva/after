import { useCallback, useEffect, useRef, useState } from 'react';
import type { FormEvent } from 'react';
import type { FeatureViewProps } from './TasksView';
import './FeatureViews.css';

interface Card { id: string; front: string; back: string; kind: 'phrase' | 'concept'; context: string }
interface CardEntry {
  meetingId: string; meetingTitle: string; card: Card; fingerprint: string; reviewFingerprint: string;
  review: { due?: string; count?: number } | null; suspended: boolean; sourceStale: boolean;
}
interface CardList { cards: CardEntry[]; errorCount: number }
interface ReviewOptions { options: { rating: number; due: string; intervalSeconds: number }[] }
interface ReviewReceipt { meetingID: string; undoID: string }
const isConflict = (error: unknown) => typeof error === 'object' && error !== null && 'code' in error && error.code === 'conflict';

export default function CardsView({ invoke, language, onDirtyChange, onBusyChange }: FeatureViewProps) {
  const ru = language === 'ru';
  const [items, setItems] = useState<CardEntry[]>([]);
  const [selected, setSelected] = useState<CardEntry | null>(null);
  const [front, setFront] = useState('');
  const [back, setBack] = useState('');
  const [kind, setKind] = useState<'phrase' | 'concept'>('phrase');
  const [deck, setDeck] = useState('');
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [readErrors, setReadErrors] = useState(0);
  const [options, setOptions] = useState<ReviewOptions['options']>([]);
  const [undo, setUndo] = useState<ReviewReceipt | null>(null);
  const [pendingSave, setPendingSave] = useState<{ meetingId: string; cardId: string } | null>(null);
  const dirty = selected ? front !== selected.card.front || back !== selected.card.back || kind !== selected.card.kind : !!(front || back || deck || kind !== 'phrase');
  const dirtyCallback = useRef(onDirtyChange);
  dirtyCallback.current = onDirtyChange;
  const busyCallback = useRef(onBusyChange);
  busyCallback.current = onBusyChange;
  useEffect(() => { onDirtyChange?.(dirty); }, [dirty, onDirtyChange]);
  useEffect(() => { onBusyChange?.(busy); }, [busy, onBusyChange]);
  useEffect(() => () => { dirtyCallback.current?.(false); }, []);
  useEffect(() => () => { busyCallback.current?.(false); }, []);
  const load = useCallback(async () => {
    const value = await invoke<CardList>('list_cards', {});
    setItems(value.cards); setReadErrors(value.errorCount); return value.cards;
  }, [invoke]);
  useEffect(() => {
    let active = true;
    invoke<CardList>('list_cards', {}).then(value => {
      if (active) { setItems(value.cards); setReadErrors(value.errorCount); }
    }).catch(() => { if (active) setError(ru ? 'Не удалось загрузить карточки.' : 'Could not load cards.'); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [invoke, ru]);
  const apply = (entry: CardEntry | null) => {
    setSelected(entry); setFront(entry?.card.front ?? ''); setBack(entry?.card.back ?? '');
    setKind(entry?.card.kind ?? 'phrase'); setDeck(''); setOptions([]); setUndo(null); setError('');
  };
  const choose = (entry: CardEntry | null) => {
    if (busy || pendingSave || (dirty && !window.confirm(ru ? 'Отменить несохранённые изменения?' : 'Discard unsaved changes?'))) return;
    apply(entry);
  };
  const fail = (failure: unknown) => setError(isConflict(failure)
    ? (ru ? 'Карточка или её история изменились. Черновик сохранён; откройте актуальную карточку перед повтором.' : 'The card or its review changed. Your draft is preserved; open the latest card before retrying.')
    : (ru ? 'Не удалось выполнить действие. Черновик сохранён.' : 'Could not complete the action. Your draft is preserved.'));
  const reference = () => selected && ({ meetingId: selected.meetingId, cardId: selected.card.id, expectedFingerprint: selected.fingerprint });
  const save = async (event: FormEvent) => {
    event.preventDefault();
    if (!front.trim() || !back.trim() || busy) return;
    setBusy(true); setError('');
    try {
      const saved = await invoke<{ meetingId: string; card: { id: string } }>('save_card', {
        front, back, kind, ...(selected ? { ...reference() } : { newDeckTitle: deck.trim() || (ru ? 'Мои карточки' : 'My cards') }),
      });
      setPendingSave({ meetingId: saved.meetingId, cardId: saved.card.id });
      const entries = await load();
      const next = entries.find(entry => entry.meetingId === saved.meetingId && entry.card.id === saved.card.id);
      if (next) { apply(next); setPendingSave(null); }
      else setError(ru ? 'Карточка сохранена, но её не удалось перечитать.' : 'The card was saved but could not be reloaded.');
    } catch (failure) { fail(failure); } finally { setBusy(false); }
  };
  const retryLoad = async () => {
    if (!pendingSave || busy) return;
    setBusy(true); setError('');
    try {
      const entries = await load();
      const next = entries.find(entry => entry.meetingId === pendingSave.meetingId && entry.card.id === pendingSave.cardId);
      if (next) { apply(next); setPendingSave(null); }
      else setError(ru ? 'Карточка сохранена, но её не удалось перечитать.' : 'The card was saved but could not be reloaded.');
    } catch { setError(ru ? 'Карточка сохранена, но обновить список не удалось.' : 'The card was saved but the list could not be refreshed.'); }
    finally { setBusy(false); }
  };
  const mutate = async (command: 'delete_card' | 'suspend_card') => {
    if (!selected || busy || dirty) return;
    if (command === 'delete_card' && !window.confirm(ru ? 'Удалить карточку?' : 'Delete this card?')) return;
    setBusy(true); setError('');
    try {
      await invoke(command, { ...reference(), ...(command === 'suspend_card' ? { suspended: !selected.suspended } : {}) });
      const entries = await load();
      apply(command === 'delete_card' ? null : entries.find(entry => entry.meetingId === selected.meetingId && entry.card.id === selected.card.id) ?? null);
    } catch (failure) { fail(failure); } finally { setBusy(false); }
  };
  const reviewArgs = () => ({ ...reference(), expectedReviewFingerprint: selected?.reviewFingerprint });
  const preview = async () => {
    if (!selected || busy || dirty || selected.suspended) return;
    setBusy(true); setError('');
    try { const response = await invoke<ReviewOptions>('preview_card_review', reviewArgs()); setOptions(response.options); }
    catch (failure) { fail(failure); } finally { setBusy(false); }
  };
  const grade = async (rating: number) => {
    if (!selected || busy || dirty) return;
    setBusy(true); setError('');
    try {
      const receipt = await invoke<ReviewReceipt>('review_card', { ...reviewArgs(), rating });
      const entries = await load();
      const updated = entries.find(entry => entry.meetingId === selected.meetingId && entry.card.id === selected.card.id);
      if (updated) { apply(updated); setUndo(receipt); }
      else setError(ru ? 'Повторение сохранено, но карточку не удалось перечитать.' : 'Review saved, but the card could not be reloaded.');
    } catch (failure) { fail(failure); } finally { setBusy(false); }
  };
  const undoReview = async () => {
    if (!selected || !undo || busy || dirty) return;
    setBusy(true); setError('');
    try {
      await invoke('undo_card_review', { meetingId: undo.meetingID, undoId: undo.undoID });
      const entries = await load();
      apply(entries.find(entry => entry.meetingId === selected.meetingId && entry.card.id === selected.card.id) ?? null);
    } catch (failure) { fail(failure); } finally { setBusy(false); }
  };
  return <div className="feature-view">
    <div className="feature-list"><header><h2>{ru ? 'Карточки' : 'Cards'}</h2><button className="button" onClick={() => choose(null)} disabled={busy}>{ru ? 'Новая' : 'New'}</button></header>
      {loading ? <p className="feature-muted">{ru ? 'Загрузка…' : 'Loading…'}</p> : items.length === 0 ? <p className="feature-muted">{ru ? 'Пока нет карточек.' : 'No cards yet.'}</p> :
        <ul>{items.map(item => <li key={item.meetingId + ':' + item.card.id}><button disabled={busy} className={selected?.meetingId === item.meetingId && selected.card.id === item.card.id ? 'feature-item selected' : 'feature-item'} onClick={() => choose(item)}><span>{item.card.front}</span><small>{item.meetingTitle}</small></button></li>)}</ul>}
      {readErrors > 0 && <p className="feature-muted">{ru ? 'Некоторые карточки не удалось прочитать.' : 'Some cards could not be read.'}</p>}
    </div>
    <form className="feature-detail" onSubmit={save}>
      <h2>{selected ? (ru ? 'Карточка' : 'Card') : (ru ? 'Новая карточка' : 'New card')}</h2>
      {error && <div className="feature-error" role="alert">{pendingSave ? (ru ? 'Карточка сохранена, но обновить список не удалось.' : 'The card was saved but the list could not be refreshed.') : error}</div>}
      {pendingSave && <button className="button" type="button" disabled={busy} onClick={() => void retryLoad()}>{ru ? 'Обновить список' : 'Refresh list'}</button>}
      {!selected && <label>{ru ? 'Колода' : 'Deck'}<input disabled={!!pendingSave} maxLength={512} value={deck} placeholder={ru ? 'Мои карточки' : 'My cards'} onChange={e => setDeck(e.target.value)}/></label>}
      <label>{ru ? 'Вопрос' : 'Front'}<textarea disabled={!!pendingSave} maxLength={100000} value={front} onChange={e => setFront(e.target.value)}/></label>
      <label>{ru ? 'Ответ' : 'Back'}<textarea disabled={!!pendingSave} maxLength={100000} value={back} onChange={e => setBack(e.target.value)}/></label>
      <label>{ru ? 'Тип' : 'Type'}<select disabled={!!pendingSave} value={kind} onChange={e => setKind(e.target.value as Card['kind'])}><option value="phrase">{ru ? 'Фраза' : 'Phrase'}</option><option value="concept">{ru ? 'Понятие' : 'Concept'}</option></select></label>
      {selected?.card.context && <p className="feature-muted">{selected.card.context}</p>}
      {selected?.sourceStale && <p className="feature-muted">{ru ? 'Источник карточки мог измениться.' : 'The source may have changed.'}</p>}
      <div className="feature-actions"><button className="button primary" type="submit" disabled={busy || !!pendingSave || !front.trim() || !back.trim() || !dirty}>{ru ? 'Сохранить' : 'Save'}</button>
        {selected && <><button className="button" type="button" disabled={busy || !!pendingSave || dirty || selected.suspended} onClick={() => void preview()}>{ru ? 'Повторить' : 'Review'}</button>
          <button className="button" type="button" disabled={busy || !!pendingSave || dirty} onClick={() => void mutate('suspend_card')}>{selected.suspended ? (ru ? 'Возобновить' : 'Resume') : (ru ? 'Приостановить' : 'Suspend')}</button>
          <button className="button" type="button" disabled={busy || !!pendingSave || dirty} onClick={() => void mutate('delete_card')}>{ru ? 'Удалить' : 'Delete'}</button></>}
      </div>
      {options.length > 0 && <div className="feature-review" aria-label={ru ? 'Оценка ответа' : 'Review rating'}>{options.map(option => <button className="button" type="button" key={option.rating} disabled={busy || !!pendingSave || dirty} onClick={() => void grade(option.rating)}>{(ru ? ['Снова', 'Сложно', 'Хорошо', 'Легко'] : ['Again', 'Hard', 'Good', 'Easy'])[option.rating - 1]}</button>)}</div>}
      {undo && <button className="button" type="button" disabled={busy || !!pendingSave || dirty} onClick={() => void undoReview()}>{ru ? 'Отменить повторение' : 'Undo review'}</button>}
    </form>
  </div>;
}
