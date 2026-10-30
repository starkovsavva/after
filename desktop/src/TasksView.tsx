import { useCallback, useEffect, useRef, useState } from 'react';
import type { FormEvent } from 'react';
import './FeatureViews.css';

export type FeatureInvoke = <T>(command: string, arguments_: Record<string, unknown>) => Promise<T>;
export interface TaskEntry {
  id: string; title: string; text: string; status: 'todo' | 'doing' | 'blocked' | 'done';
  completed: boolean; owner: string; due: string; project: string; revision: number;
  sourceFingerprint: string; virtual: boolean; meetingId: string | null;
}
interface TaskList { tasks: TaskEntry[]; total: number; truncated: boolean }
interface TaskDraft { title: string; text: string; status: TaskEntry['status']; due: string; owner: string; project: string }
export interface FeatureViewProps { invoke: FeatureInvoke; language: 'ru' | 'en'; onDirtyChange?: (dirty: boolean) => void; onBusyChange?: (busy: boolean) => void }
const fresh = (): TaskDraft => ({ title: '', text: '', status: 'todo', due: '', owner: '', project: '' });
const draftOf = (t: TaskEntry): TaskDraft => ({ title: t.title, text: t.text, status: t.status, due: t.due, owner: t.owner, project: t.project });
const conflict = (error: unknown) => typeof error === 'object' && error !== null && 'code' in error && error.code === 'conflict';

export default function TasksView({ invoke, language, onDirtyChange, onBusyChange }: FeatureViewProps) {
  const ru = language === 'ru';
  const [items, setItems] = useState<TaskEntry[]>([]);
  const [selected, setSelected] = useState<TaskEntry | null>(null);
  const [draft, setDraft] = useState<TaskDraft>(fresh);
  const [operationId, setOperationId] = useState(() => crypto.randomUUID());
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [truncated, setTruncated] = useState(false);
  const statusLabel = (status: TaskEntry['status']) => ({
    todo: ru ? 'К выполнению' : 'To do', doing: ru ? 'В работе' : 'In progress',
    blocked: ru ? 'Ожидает' : 'Blocked', done: ru ? 'Готово' : 'Done',
  })[status];
  const dirty = selected ? JSON.stringify(draft) !== JSON.stringify(draftOf(selected)) : !!(draft.title || draft.text || draft.due || draft.owner || draft.project || draft.status !== 'todo');
  const dirtyCallback = useRef(onDirtyChange);
  dirtyCallback.current = onDirtyChange;
  const busyCallback = useRef(onBusyChange);
  busyCallback.current = onBusyChange;
  useEffect(() => { onDirtyChange?.(dirty); }, [dirty, onDirtyChange]);
  useEffect(() => { onBusyChange?.(busy); }, [busy, onBusyChange]);
  useEffect(() => () => { dirtyCallback.current?.(false); }, []);
  useEffect(() => () => { busyCallback.current?.(false); }, []);
  const edit = (patch: Partial<TaskDraft>) => { setDraft(current => ({ ...current, ...patch })); setOperationId(crypto.randomUUID()); };
  const load = useCallback(async () => {
    const value = await invoke<TaskList>('list_tasks', {});
    setItems(value.tasks); setTruncated(value.truncated);
  }, [invoke]);
  useEffect(() => {
    let active = true;
    invoke<TaskList>('list_tasks', {}).then(value => {
      if (active) { setItems(value.tasks); setTruncated(value.truncated); }
    }).catch(() => { if (active) setError(ru ? 'Не удалось загрузить задачи.' : 'Could not load tasks.'); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [invoke, ru]);
  const choose = async (entry: TaskEntry | null) => {
    if (busy || (dirty && !window.confirm(ru ? 'Отменить несохранённые изменения?' : 'Discard unsaved changes?'))) return;
    setError(''); setOperationId(crypto.randomUUID());
    if (!entry) { setSelected(null); setDraft(fresh()); return; }
    setBusy(true);
    try {
      const full = await invoke<TaskEntry>('get_task', { taskId: entry.id });
      setSelected(full); setDraft(draftOf(full));
    } catch { setError(ru ? 'Не удалось открыть задачу.' : 'Could not open the task.'); }
    finally { setBusy(false); }
  };
  const save = async (event: FormEvent) => {
    event.preventDefault();
    if (!draft.title.trim() || busy) return;
    setBusy(true); setError('');
    let saved = false;
    try {
      let result: TaskEntry;
      if (selected) {
        result = await invoke<TaskEntry>('update_task', { taskId: selected.id, expectedRevision: selected.revision,
          expectedSourceFingerprint: selected.sourceFingerprint, operationId, patch: draft });
      } else {
        result = await invoke<TaskEntry>('create_task', { title: draft.title, text: draft.text, operationId });
      }
      setSelected(result); setDraft(draftOf(result)); setOperationId(crypto.randomUUID());
      saved = true;
      await load();
    } catch (failure) {
      setError(saved ? (ru ? 'Задача сохранена, но обновить список не удалось.' : 'The task was saved but the list could not be refreshed.') : conflict(failure)
        ? (ru ? 'Задача изменилась в другом окне. Черновик сохранён; откройте актуальную версию перед повтором.' : 'This task changed in another window. Your draft is preserved; open the latest version before retrying.')
        : (ru ? 'Не удалось сохранить задачу. Черновик сохранён.' : 'Could not save the task. Your draft is preserved.'));
    } finally { setBusy(false); }
  };
  return <div className="feature-view">
    <div className="feature-list"><header><h2>{ru ? 'Задачи' : 'Tasks'}</h2><button className="button" onClick={() => void choose(null)} disabled={busy}>{ru ? 'Новая' : 'New'}</button></header>
      {loading ? <p className="feature-muted">{ru ? 'Загрузка…' : 'Loading…'}</p> : items.length === 0 ? <p className="feature-muted">{ru ? 'Пока нет задач.' : 'No tasks yet.'}</p> :
        <ul>{items.map(item => <li key={item.id}><button className={selected?.id === item.id ? 'feature-item selected' : 'feature-item'} onClick={() => void choose(item)} disabled={busy}>
          <span>{item.title}</span><small>{statusLabel(item.status)}</small></button></li>)}</ul>}
      {truncated && <p className="feature-muted">{ru ? 'Показаны первые 500 задач.' : 'Showing the first 500 tasks.'}</p>}
    </div>
    <form className="feature-detail" onSubmit={save}>
      <h2>{selected ? (ru ? 'Задача' : 'Task') : (ru ? 'Новая задача' : 'New task')}</h2>
      {error && <div className="feature-error" role="alert">{error}</div>}
      <label>{ru ? 'Название' : 'Title'}<input value={draft.title} maxLength={1024} onChange={e => edit({ title: e.target.value })}/></label>
      <label>{ru ? 'Описание' : 'Description'}<textarea value={draft.text} maxLength={100000} onChange={e => edit({ text: e.target.value })}/></label>
      <div className="feature-grid"><label>{ru ? 'Статус' : 'Status'}<select disabled={!selected} value={draft.status} onChange={e => edit({ status: e.target.value as TaskDraft['status'] })}>
        <option value="todo">{ru ? 'К выполнению' : 'To do'}</option><option value="doing">{ru ? 'В работе' : 'In progress'}</option><option value="blocked">{ru ? 'Ожидает' : 'Blocked'}</option><option value="done">{ru ? 'Готово' : 'Done'}</option></select></label>
        <label>{ru ? 'Срок' : 'Due'}<input disabled={!selected} value={draft.due} onChange={e => edit({ due: e.target.value })}/></label>
        <label>{ru ? 'Ответственный' : 'Owner'}<input disabled={!selected} value={draft.owner} onChange={e => edit({ owner: e.target.value })}/></label>
        <label>{ru ? 'Проект' : 'Project'}<input disabled={!selected} value={draft.project} onChange={e => edit({ project: e.target.value })}/></label></div>
      <div className="feature-actions"><button className="button primary" type="submit" disabled={busy || !draft.title.trim() || !dirty}>{ru ? 'Сохранить' : 'Save'}</button></div>
    </form>
  </div>;
}
