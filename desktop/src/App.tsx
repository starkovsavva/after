import { useCallback, useEffect, useRef, useState } from 'react';
import type { FormEvent, ReactNode } from 'react';
import { api, connected, demoMode, featureCommand } from './api';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { convertFileSrc } from '@tauri-apps/api/core';
import { copy, resolveLanguage } from './i18n';
import type { LanguagePreference } from './i18n';
import { draftFromNote, errorMessage, formatDate, formatDuration, isDirty, noteInput } from './model';
import type { Draft } from './model';
import type { Folder, MeetingDetail, Note, RecordingStatus, RecoverableRecording, SearchResult, Workspace } from './types';
import Icon from './Icon';
import { isPrimaryShortcut } from './shortcuts';
import TasksView from './TasksView';
import CardsView from './CardsView';

function usePreference<T extends string>(key: string, fallback: T, allowed: readonly T[]) {
  const [value, setValue] = useState<T>(() => {
    try { const stored = localStorage.getItem(key); return allowed.includes(stored as T) ? stored as T : fallback; }
    catch { return fallback; }
  });
  const change = (next: T) => { setValue(next); try { localStorage.setItem(key, next); } catch { /* Interface preferences are optional. */ } };
  return [value, change] as const;
}
type Section = 'meetings' | 'notes' | 'tasks' | 'cards';
type Selection = { kind: 'meeting' | 'note'; id: string } | null;
type FolderEditor = { folder?: Folder; name: string };

function Dialog({ title, children, close, closeLabel = 'Close', wide = false }: { title: string; children: ReactNode; close?: () => void; closeLabel?: string; wide?: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const closeRef = useRef(close);
  closeRef.current = close;
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    const dialog = ref.current;
    const focusable = () => Array.from(dialog?.querySelectorAll<HTMLElement>('button:not(:disabled), input, select, textarea, [tabindex="0"]') || []);
    const controls = focusable(); (controls.find(item => item.matches('input')) || controls[0] || dialog)?.focus();
    const trap = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && closeRef.current) { event.preventDefault(); event.stopPropagation(); closeRef.current(); }
      if (event.key !== 'Tab') return;
      const items = focusable(); const first = items[0]; const last = items.at(-1);
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    };
    dialog?.addEventListener('keydown', trap);
    return () => { dialog?.removeEventListener('keydown', trap); previous?.focus(); };
  }, []);
  return <div className="modal-scrim"><div ref={ref} role="dialog" aria-modal="true" aria-label={title} tabIndex={-1} className={`dialog${wide ? ' dialog-wide' : ''}`}>
    <div className="dialog-heading"><h2>{title}</h2>{close && <button type="button" className="icon-button" onClick={close} aria-label={closeLabel}><Icon name="close" /></button>}</div>
    {children}
  </div></div>;
}
function EmptyState({ icon, title, hint, action }: { icon: 'meetings' | 'notes' | 'search'; title: string; hint: string; action?: ReactNode }) {
  return <div className="empty-state"><Icon name={icon} size={34}/><h2>{title}</h2><p>{hint}</p>{action}</div>;
}

export default function App() {
  const [languagePreference, setLanguagePreference] = usePreference<LanguagePreference>('posle.ui.language', 'system', ['system', 'en', 'ru']);
  const [appearance, setAppearance] = usePreference('posle.ui.appearance', 'system', ['system', 'light', 'dark'] as const);
  const [foldersPreference, setFoldersPreference] = usePreference('posle.ui.folders', 'shown', ['shown', 'hidden'] as const);
  const [systemLanguages, setSystemLanguages] = useState<readonly string[]>(navigator.languages);
  const language = resolveLanguage(languagePreference, systemLanguages); const t = copy(language);
  const copyRef = useRef(t); copyRef.current = t;
  const workspaceSequence = useRef(0);
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [folderId, setFolderId] = useState<string | undefined>();
  const [section, setSection] = useState<Section>('meetings');
  const [selection, setSelection] = useState<Selection>(null);
  const [detail, setDetail] = useState<MeetingDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [detailError, setDetailError] = useState(false);
  const [mediaError, setMediaError] = useState(false);
  const [detailRetry, setDetailRetry] = useState(0);
  const [tab, setTab] = useState<'notes' | 'summary' | 'transcript'>('summary');
  const [draft, setDraft] = useState<Draft | null>(null);
  const [original, setOriginal] = useState<Draft | null>(null);
  const [saving, setSaving] = useState(false);
  const [importing, setImporting] = useState(false);
  const [recordDialog, setRecordDialog] = useState(false);
  const [recordTitle, setRecordTitle] = useState(() => { try { return sessionStorage.getItem('posle.recording.title') || ''; } catch { return ''; } });
  const [recordMode, setRecordMode] = useState<'microphone' | 'microphone_and_system'>('microphone_and_system');
  const [recording, setRecording] = useState<RecordingStatus | null>(null);
  const [recordingBusy, setRecordingBusy] = useState(false);
  const [recordingMessage, setRecordingMessage] = useState<string | null>(null);
  const [recoverable, setRecoverable] = useState<RecoverableRecording[]>([]);
  const [recoveryOpen, setRecoveryOpen] = useState(false);
  const [featureDirty, setFeatureDirty] = useState(false);
  const [featureBusy, setFeatureBusy] = useState(false);
  const [recordingSyncing, setRecordingSyncing] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [pendingAction, setPendingAction] = useState<(() => void) | null>(null);
  const [folderEditor, setFolderEditor] = useState<FolderEditor | null>(null);
  const [folderSaving, setFolderSaving] = useState(false);
  const [folderError, setFolderError] = useState<string | null>(null);
  const [folderCloseConfirm, setFolderCloseConfirm] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [search, setSearch] = useState('');
  const [searchResults, setSearchResults] = useState<SearchResult[]>([]);
  const [searchLoading, setSearchLoading] = useState(false);
  const [searchError, setSearchError] = useState(false);
  const [searchTruncated, setSearchTruncated] = useState(false);
  const searchRef = useRef<HTMLInputElement>(null);
  const titleRef = useRef<HTMLInputElement>(null);
  const detailSequence = useRef(0);
  const dirty = isDirty(draft, original);
  const folderDirty = !!folderEditor && folderEditor.name !== (folderEditor.folder?.name || '');
  const recordingActive = !!recording?.sessionId;
  const closeState = useRef({ dirty, saving, folderDirty, folderSaving, importing, recordingActive, recordingBusy, recordingSyncing, featureDirty, featureBusy });
  closeState.current = { dirty, saving, folderDirty, folderSaving, importing, recordingActive, recordingBusy, recordingSyncing, featureDirty, featureBusy };
  const allowClose = useRef(false);
  const editorState = useRef({ draft, dirty });
  editorState.current = { draft, dirty };
  const activeFolder = workspace?.folders.find(folder => folder.id === folderId);
  const meetings = workspace?.meetings.filter(item => !folderId || item.folderId === folderId) || [];
  const notes = workspace?.notes.filter(item => !folderId || item.folderId === folderId) || [];

  useEffect(() => {
    document.documentElement.lang = language; document.title = t.appName;
    document.documentElement.dataset.appearance = appearance;
  }, [language, appearance, t.appName]);
  useEffect(() => { const update = () => setSystemLanguages([...navigator.languages]); window.addEventListener('languagechange', update); return () => window.removeEventListener('languagechange', update); }, []);
  const loadWorkspace = useCallback(async () => {
    const sequence = ++workspaceSequence.current;
    if (!connected) { setLoading(false); setError(null); return; }
    setLoading(true); setError(null);
    try {
      const data = await api.getWorkspace();
      if (workspaceSequence.current !== sequence) return;
      setWorkspace(data);
      const editor = editorState.current;
      if (editor.draft?.id && !editor.dirty) {
        const note = data.notes.find(item => item.id === editor.draft?.id);
        if (note) { const value = draftFromNote(note); setDraft(value); setOriginal(value); }
      }
      setDetailRetry(value => value + 1);
    }
    catch { if (workspaceSequence.current === sequence) setError(copyRef.current.loadFailed); }
    finally { if (workspaceSequence.current === sequence) setLoading(false); }
  }, []);
  useEffect(() => { void loadWorkspace(); return () => { workspaceSequence.current++; }; }, [loadWorkspace]);
  useEffect(() => {
    const guard = (event: BeforeUnloadEvent) => { if (!allowClose.current && (dirty || folderDirty || saving || folderSaving || importing || recordingActive || recordingBusy || recordingSyncing || featureDirty || featureBusy)) { event.preventDefault(); event.returnValue = ''; } };
    window.addEventListener('beforeunload', guard); return () => window.removeEventListener('beforeunload', guard);
  }, [dirty, folderDirty, saving, folderSaving, importing, recordingActive, recordingBusy, recordingSyncing, featureDirty, featureBusy]);
  useEffect(() => {
    // A real Tauri window provides metadata; a browser test bridge does not own a native window.
    const internals = (window as unknown as { __TAURI_INTERNALS__?: { metadata?: { currentWindow?: unknown } } }).__TAURI_INTERNALS__;
    if (!internals?.metadata?.currentWindow) return;
    let disposed = false; let unlisten: (() => void) | undefined;
    getCurrentWindow().onCloseRequested(event => {
      if (allowClose.current) return;
      if (!closeState.current.dirty && !closeState.current.saving && !closeState.current.folderDirty && !closeState.current.folderSaving && !closeState.current.importing && !closeState.current.recordingActive && !closeState.current.recordingBusy && !closeState.current.recordingSyncing && !closeState.current.featureDirty && !closeState.current.featureBusy) return;
      event.preventDefault();
      if (closeState.current.recordingActive || closeState.current.recordingBusy || closeState.current.recordingSyncing) { setRecordingMessage(copyRef.current.closeRecording); return; }
      if (closeState.current.featureBusy) return;
      if (closeState.current.featureDirty) {
        if (window.confirm(copyRef.current.discardFeature)) { allowClose.current = true; void getCurrentWindow().close(); }
        return;
      }
      if (closeState.current.saving || closeState.current.folderSaving || closeState.current.importing) return;
      if (closeState.current.folderDirty) { setFolderCloseConfirm(true); return; }
      setPendingAction(() => () => { allowClose.current = true; void getCurrentWindow().close(); });
    }).then(remove => { if (disposed) remove(); else unlisten = remove; }).catch(() => {
      // Browser beforeunload still protects drafts if native event registration is unavailable.
    });
    return () => { disposed = true; unlisten?.(); };
  }, []);
  const refreshRecovery = useCallback(async () => {
    try { setRecoverable(await api.recoverableRecordings()); } catch { /* Recording errors are shown when the user tries to recover. */ }
  }, []);
  useEffect(() => {
    if (!workspace?.capabilities.recording) return;
    let active = true;
    setRecordingSyncing(true);
    void api.recordingStatus().then(status => { if (active) setRecording(status.sessionId ? status : null); })
      .catch(() => { if (active) setRecordingMessage(copyRef.current.recordingFailed); })
      .finally(() => { if (active) setRecordingSyncing(false); });
    void refreshRecovery();
    return () => { active = false; };
  }, [workspace?.capabilities.recording, refreshRecovery]);
  useEffect(() => {
    if (!workspace?.capabilities.recording || recordingBusy || recordingSyncing) return;
    let active = true;
    const timer = setInterval(() => { void api.recordingStatus().then(value => { if (active) setRecording(value.sessionId ? value : null); }).catch(() => { if (active) setRecordingMessage(copyRef.current.recordingFailed); }); }, 1000);
    return () => { active = false; clearInterval(timer); };
  }, [workspace?.capabilities.recording, recordingBusy, recordingSyncing]);
  useEffect(() => {
    const shortcut = (event: KeyboardEvent) => {
      if (isPrimaryShortcut(event, 'k', navigator.platform)) {
        event.preventDefault();
        if (document.querySelector('[role=dialog][aria-modal=true]')) return; setSearchOpen(true); requestAnimationFrame(() => searchRef.current?.focus());
      }
    };
    window.addEventListener('keydown', shortcut); return () => window.removeEventListener('keydown', shortcut);
  }, []);
  const selectedMeetingId = selection?.kind === 'meeting' ? selection.id : null;
  useEffect(() => {
    const sequence = ++detailSequence.current;
    setMediaError(false);
    if (!selectedMeetingId) { setDetail(null); setDetailLoading(false); setDetailError(false); return; }
    setDetail(null); setDetailLoading(true); setDetailError(false);
    api.getMeeting(selectedMeetingId).then(value => {
      if (detailSequence.current === sequence) setDetail(value);
    }).catch(() => { if (detailSequence.current === sequence) setDetailError(true); })
      .finally(() => { if (detailSequence.current === sequence) setDetailLoading(false); });
    return () => { detailSequence.current++; };
  }, [selectedMeetingId, detailRetry]);
  useEffect(() => {
    if (!searchOpen || !search.trim()) { setSearchResults([]); setSearchLoading(false); setSearchError(false); setSearchTruncated(false); return; }
    let active = true; setSearchLoading(true); setSearchError(false);
    const timer = setTimeout(() => { api.searchLibrary(search.trim(), folderId).then(result => {
      if (active) { setSearchResults(result.hits); setSearchTruncated(result.truncated); }
    }).catch(() => { if (active) setSearchError(true); }).finally(() => { if (active) setSearchLoading(false); }); }, 180);
    return () => { active = false; clearTimeout(timer); };
  }, [searchOpen, search, folderId]);

  const requestNavigation = (action: () => void) => {
    if (saving || featureBusy) return;
    if (featureDirty && !window.confirm(t.discardFeature)) return;
    if (dirty) setPendingAction(() => action); else action();
  };
  const importMeeting = () => requestNavigation(() => {
    if (importing) return;
    setImporting(true); setError(null);
    void (async () => {
      try {
        const meeting = await api.chooseAndImport();
        if (!meeting) return; // The system file chooser was cancelled.
        setFolderId(undefined); setSection('meetings'); setSearchOpen(false); setSearch('');
        setDraft(null); setOriginal(null); setSelection({ kind: 'meeting', id: meeting.id }); setTab('summary');
        await loadWorkspace();
      } catch {
        // A timeout can happen after the engine published the meeting; refresh
        // before the user retries so an existing result is not hidden.
        await loadWorkspace(); setError(copyRef.current.importFailed);
      } finally { setImporting(false); }
    })();
  });
  const startRecording = async () => {
    if (recordingBusy || recordingActive) return;
    setRecordingBusy(true); setRecordingMessage(null);
    try {
      const status = await api.startRecording(recordMode);
      setRecording(status); setRecordDialog(false);
    } catch {
      try { const status = await api.recordingStatus(); setRecording(status.sessionId ? status : null); } catch { /* The original error is shown below. */ }
      setRecordingMessage(t.recordingFailed); setRecordDialog(false); await refreshRecovery();
    } finally { setRecordingBusy(false); }
  };
  const stopRecording = async () => {
    if (recordingBusy || !recordingActive) return;
    setRecordingBusy(true); setRecordingMessage(null);
    try {
      const saved = await api.stopRecording(recordTitle.trim() || t.recordingName);
      setRecording(null);
      try { sessionStorage.removeItem('posle.recording.title'); } catch { /* Optional draft metadata. */ }
      setRecordTitle('');
      setRecordingMessage(saved.interrupted ? t.recordingSavedInterrupted : t.recordingSaved);
      await loadWorkspace(); await refreshRecovery();
    } catch {
      try { const status = await api.recordingStatus(); setRecording(status.sessionId ? status : null); } catch { setRecordingMessage(t.closeRecording); }
      setRecordingMessage(t.recordingFailed);
      await loadWorkspace(); await refreshRecovery();
    } finally { setRecordingBusy(false); }
  };
  const recoverRecording = async (sessionId: string) => {
    if (recordingBusy) return;
    setRecordingBusy(true); setRecordingMessage(null);
    try {
      await api.recoverRecording(sessionId); setRecoveryOpen(false);
      await loadWorkspace(); await refreshRecovery(); setRecordingMessage(t.recordingSavedInterrupted);
    } catch { setRecordingMessage(t.recordingFailed); await loadWorkspace(); await refreshRecovery(); }
    finally { setRecordingBusy(false); }
  };
  const clearEditor = () => { setDraft(null); setOriginal(null); setSaveError(null); };
  const chooseFolder = (id?: string) => requestNavigation(() => {
    setFolderId(id); setSelection(null); clearEditor(); setSearchOpen(false); setSearch('');
  });
  const chooseSection = (next: Section) => requestNavigation(() => {
    setSection(next); setSelection(null); clearEditor(); setSearchOpen(false); setSearch('');
  });
  const openMeeting = (id: string, searchResult = false) => requestNavigation(() => {
    if (searchResult) { setFolderId(undefined); setSearchOpen(false); setSearch(''); }
    setSection('meetings'); setSelection({ kind: 'meeting', id }); clearEditor(); setTab('summary');
  });
  const openNote = (note: Note, searchResult = false) => requestNavigation(() => {
    if (searchResult) { setFolderId(undefined); setSearchOpen(false); setSearch(''); }
    setSection('notes'); setSelection({ kind: 'note', id: note.id });
    const value = draftFromNote(note); setDraft(value); setOriginal(value); setSaveError(null);
  });
  const newNote = (meetingId?: string) => requestNavigation(() => {
    const targetMeeting = meetingId ? workspace?.meetings.find(item => item.id === meetingId) : undefined;
    setSection('notes'); setSelection(null); setSearchOpen(false); setSearch('');
    setDraft({ title: '', text: '', folderId: targetMeeting?.folderId || folderId, meetingId }); setOriginal(null); setSaveError(null);
    requestAnimationFrame(() => titleRef.current?.focus());
  });
  const saveNote = async (): Promise<boolean> => {
    if (!draft || saving) return false;
    if (!draft.title.trim()) { setSaveError(t.requiredTitle); titleRef.current?.focus(); return false; }
    workspaceSequence.current++; setLoading(false);
    setSaving(true); setSaveError(null);
    try {
      const note = await api.saveNote(noteInput(draft, original));
      setWorkspace(current => current ? { ...current, notes: [note, ...current.notes.filter(item => item.id !== note.id)] } : current);
      const value = draftFromNote(note); setDraft(value); setOriginal(value); setSelection({ kind: 'note', id: note.id });
      if (note.meetingId) setDetail(current => current && current.meeting.id === note.meetingId ? { ...current, notes: [note, ...current.notes.filter(item => item.id !== note.id)] } : current);
      return true;
    } catch (cause) { setSaveError(errorMessage(cause, t)); return false; }
    finally { setSaving(false); }
  };
  const saveFolder = async (event?: FormEvent): Promise<boolean> => {
    event?.preventDefault(); if (!folderEditor || folderSaving) return false;
    if (!folderEditor.name.trim()) { setFolderError(t.requiredFolder); return false; }
    workspaceSequence.current++; setLoading(false);
    setFolderSaving(true); setFolderError(null);
    let saved = false;
    try {
      const folder = await api.saveFolder({ id: folderEditor.folder?.id, name: folderEditor.name.trim(), expectedRevision: folderEditor.folder?.revision });
      saved = true;
      // Renaming a folder also revises canonical notes carrying its label. Refresh those revisions before editing.
      const refreshed = await api.getWorkspace();
      setWorkspace(refreshed);
      if (draft?.id && !dirty) {
        const current = refreshed.notes.find(note => note.id === draft.id);
        if (current) { const value = draftFromNote(current); setDraft(value); setOriginal(value); }
      }
      setFolderEditor(null);
      if (!folderEditor.folder) chooseFolder(folder.id);
      return true;
    } catch (cause) {
      if (saved) { setFolderEditor(null); setError(t.refreshFailed); }
      else setFolderError(errorMessage(cause, t));
      return false;
    } finally { setFolderSaving(false); }
  };
  const showFolderEditor = (folder?: Folder) => requestNavigation(() => { setFolderEditor({ folder, name: folder?.name || '' }); setFolderError(null); });
  const chooseSearchResult = (result: SearchResult) => {
    if (result.noteId || result.kind === 'note') {
      const id = result.noteId || result.id; const note = workspace?.notes.find(item => item.id === id);
      if (note) openNote(note, true); else setError(t.errorNotFound);
    } else openMeeting(result.meetingId || result.id, true);
  };
  const folderOptions = <><option value="">{t.allFolders}</option>{workspace?.folders.map(folder => <option key={folder.id} value={folder.id}>{folder.name}</option>)}</>;
  const selectionTitle = section === 'meetings' ? t.meetings : t.notes;

  return <div className="app-shell">
    <header className="titlebar">
      <div className="brand"><img src="/logo.svg" alt=""/><span>{t.appName}</span><span className="demo-label" title={demoMode ? t.demoHint : t.previewHint}>{demoMode ? t.demo : t.preview}</span></div>
      <div className="titlebar-context"><Icon name="folder" size={16}/><select aria-label={t.activeFolder} value={folderId || ''} onChange={event => chooseFolder(event.target.value || undefined)} disabled={!workspace || saving}>{folderOptions}</select></div>
      {workspace?.capabilities.import && <button className="button" onClick={importMeeting} disabled={importing || saving} title={t.importMeeting}><Icon name="import" size={16}/>{t.importMeeting}</button>}
      {workspace?.capabilities.recording && (recordingActive
        ? <button className="button primary" onClick={() => void stopRecording()} disabled={recordingBusy || recordingSyncing}>{t.stopRecording} · {formatDuration((recording?.elapsedMs || 0) / 1000)}</button>
        : <button className="button primary" onClick={() => setRecordDialog(true)} disabled={recordingBusy || recordingSyncing || importing}>{t.record}</button>)}
      <button className="icon-button" onClick={() => requestNavigation(() => { void loadWorkspace(); })} disabled={loading || saving || !connected} aria-label={t.refreshLibrary} title={t.refreshLibrary}><Icon name="refresh"/></button>
      <button className="icon-button" onClick={() => setSettingsOpen(true)} aria-label={t.settings} title={t.settings}><Icon name="settings"/></button>
    </header>
    {(recordingActive || recordingBusy || recordingMessage || recoverable.length > 0) && <div className="recording-banner" role="status">
      {recordingActive && <><strong>{recording?.phase === 'starting' ? t.startingRecording : recording?.phase === 'recording' ? t.recording : t.recordingStopped} · {formatDuration((recording?.elapsedMs || 0) / 1000)}</strong>{recording?.phase === 'interrupted' && <span>{t.recordingInterrupted}</span>}</>}
      {recordingBusy && <span>{recordingActive ? t.savingRecording : t.startingRecording}</span>}
      {recordingMessage && <span>{recordingMessage}</span>}
      {recoverable.length > 0 && !recordingBusy && <button className="text-button" onClick={() => setRecoveryOpen(true)}>{t.recoverRecordings} ({recoverable.length})</button>}
    </div>}
    <div className="workspace">
      <aside className="sidebar" aria-label={t.library}>
        <button className={`search-trigger ${searchOpen ? 'is-active' : ''}`} onClick={() => { setSearchOpen(true); requestAnimationFrame(() => searchRef.current?.focus()); }} disabled={!workspace}><Icon name="search"/><span>{t.keyboardSearch}</span><kbd>{navigator.platform.includes('Mac') ? '⌘K' : 'Ctrl K'}</kbd></button>
        <nav className="sections" aria-label={t.library}>
          <button aria-label={t.meetings} className={`nav-row ${section === 'meetings' && !searchOpen ? 'is-active' : ''}`} aria-current={section === 'meetings' && !searchOpen ? 'page' : undefined} onClick={() => chooseSection('meetings')}><Icon name="meetings"/><span>{t.meetings}</span><span className="count">{meetings.length || ''}</span></button>
          <button aria-label={t.notes} className={`nav-row ${section === 'notes' && !searchOpen ? 'is-active' : ''}`} aria-current={section === 'notes' && !searchOpen ? 'page' : undefined} onClick={() => chooseSection('notes')}><Icon name="notes"/><span>{t.notes}</span></button>
          {workspace?.capabilities.tasks && <button className={`nav-row ${section === 'tasks' ? 'is-active' : ''}`} aria-current={section === 'tasks' ? 'page' : undefined} onClick={() => chooseSection('tasks')}><Icon name="check"/><span>{t.tasks}</span></button>}
          {workspace?.capabilities.cards && <button className={`nav-row ${section === 'cards' ? 'is-active' : ''}`} aria-current={section === 'cards' ? 'page' : undefined} onClick={() => chooseSection('cards')}><Icon name="notes"/><span>{t.cards}</span></button>}
        </nav>
        <div className="folder-heading"><button className="folder-disclosure" onClick={() => setFoldersPreference(foldersPreference === 'shown' ? 'hidden' : 'shown')} aria-expanded={foldersPreference === 'shown'} aria-controls="folder-list" title={foldersPreference === 'shown' ? t.hideFolders : t.showFolders}><span className={foldersPreference === 'shown' ? 'chevron expanded' : 'chevron'}><Icon name="chevron" size={12}/></span>{t.folders}</button><button className="icon-button small" onClick={() => showFolderEditor()} disabled={!workspace} aria-label={t.newFolder} title={t.newFolder}><Icon name="plus" size={16}/></button></div>
        {foldersPreference === 'shown' && <nav className="folder-list" id="folder-list" aria-label={t.folders}>
          <button className={`nav-row ${!folderId ? 'is-active' : ''}`} onClick={() => chooseFolder()} aria-current={!folderId ? 'true' : undefined}><Icon name="all"/><span>{t.allFolders}</span></button>
          {workspace?.folders.map(folder => <div className={`folder-row ${folderId === folder.id ? 'is-active' : ''}`} key={folder.id}><button className="nav-row" onClick={() => chooseFolder(folder.id)} onDoubleClick={() => showFolderEditor(folder)} aria-current={folderId === folder.id ? 'true' : undefined}><Icon name="folder"/><span>{folder.name}</span></button><button className="folder-rename icon-button small" onClick={() => showFolderEditor(folder)} aria-label={`${t.renameFolder}: ${folder.name}`} title={t.renameFolder}><Icon name="edit" size={14}/></button></div>)}
          {!workspace?.folders.length && <button className="nav-row subtle" onClick={() => showFolderEditor()} disabled={!workspace}><Icon name="plus"/><span>{t.newFolder}</span></button>}
        </nav>}
        <div className="sidebar-footer"><button className="nav-row subtle" onClick={() => setSettingsOpen(true)}><Icon name="settings"/><span>{t.settings}</span></button></div>
      </aside>
      {section === 'tasks' || section === 'cards' ? <div className="feature-container">{section === 'tasks' ? <TasksView invoke={featureCommand} language={language} onDirtyChange={setFeatureDirty} onBusyChange={setFeatureBusy}/> : <CardsView invoke={featureCommand} language={language} onDirtyChange={setFeatureDirty} onBusyChange={setFeatureBusy}/>}</div> : <><section className="library-list" aria-label={searchOpen ? t.searchResults : selectionTitle}>
        <div className="list-heading"><div><h1>{searchOpen ? t.searchResults : selectionTitle}</h1><span className="scope-name">{activeFolder?.name || t.allFolders}</span></div>{section === 'notes' && !searchOpen && <button className="icon-button" aria-label={t.newNote} title={t.newNote} onClick={() => newNote()} disabled={!workspace || saving}><Icon name="plus"/></button>}</div>
        {searchOpen && <div className="search-field"><Icon name="search" size={16}/><input ref={searchRef} type="search" placeholder={t.searchPlaceholder} aria-label={t.search} value={search} onChange={event => setSearch(event.target.value)}/><button className="icon-button small" aria-label={t.close} onClick={() => { setSearchOpen(false); setSearch(''); }}><Icon name="close" size={14}/></button></div>}
        <div className="list-content" aria-busy={loading || searchLoading}>
          {loading && <p className="list-message" role="status">{t.loading}</p>}
          {!loading && searchOpen && <>{searchLoading ? <p className="list-message" role="status">{t.loading}</p> : searchError ? <p className="list-message error-text" role="alert">{t.errorUnavailable}</p> : searchResults.map(result => <button className="list-item" key={`${result.kind}:${result.id}`} onClick={() => chooseSearchResult(result)}><span className="item-title">{result.title}</span><span className="item-meta">{result.kind === 'note' ? t.notes : result.kind === 'transcript' ? t.transcript : result.kind === 'summary' ? t.summary : t.meetings}</span>{result.excerpt && <span className="item-excerpt">{result.excerpt}</span>}</button>)}
            {!searchLoading && !searchError && search.trim() && !searchResults.length && <div className="list-empty"><Icon name="search" size={25}/><strong>{t.noResults}</strong><p>{t.noResultsHint}</p>{folderId && <button className="text-button" onClick={() => setFolderId(undefined)}>{t.searchAll}</button>}</div>}
            {searchTruncated && !searchLoading && <p className="list-message">{language === 'ru' ? 'Показаны первые результаты. Уточните запрос.' : 'Showing the first results. Refine your search.'}</p>}
          </>}
          {!loading && !searchOpen && section === 'meetings' && meetings.map(meeting => <button key={meeting.id} className={`list-item ${selection?.kind === 'meeting' && selection.id === meeting.id ? 'is-active' : ''}`} onClick={() => openMeeting(meeting.id)} aria-current={selection?.id === meeting.id ? 'true' : undefined}><span className="item-title">{meeting.title}</span><span className="item-meta"><span>{formatDate(meeting.startedAt, language) || t.noDate}</span><span>{formatDuration(meeting.durationSeconds)}</span></span></button>)}
          {!loading && !searchOpen && section === 'notes' && notes.map(note => <button key={note.id} className={`list-item ${selection?.kind === 'note' && selection.id === note.id ? 'is-active' : ''}`} onClick={() => openNote(note)} aria-current={selection?.id === note.id ? 'true' : undefined}><span className="item-title">{note.title}</span><span className="item-meta">{formatDate(note.updatedAt, language)}{note.meetingId && <Icon name="meetings" size={12}/>}</span><span className="item-excerpt">{note.text}</span></button>)}
          {!loading && !searchOpen && !(section === 'meetings' ? meetings : notes).length && <div className="list-empty"><Icon name={section} size={25}/><strong>{section === 'meetings' ? t.noMeetings : t.noNotes}</strong>{section === 'notes' && <button className="text-button" onClick={() => newNote()} disabled={!workspace}>{t.newNote}</button>}</div>}
        </div>
        <div className="list-footer">{searchOpen ? searchResults.length : section === 'meetings' ? meetings.length : notes.length} {t.itemCount}</div>
      </section>
      <main className="detail-pane">
        {error && workspace && <div className="error-banner" role="alert"><Icon name="alert"/><span>{error}</span><button className="text-button" onClick={() => void loadWorkspace()}>{t.retry}</button></div>}
        {!connected ? <EmptyState icon="notes" title={t.connectionRequired} hint={t.connectionHint}/> : error && !workspace ? <EmptyState icon="notes" title={error} hint={t.errorUnavailable} action={<button className="button" onClick={() => void loadWorkspace()}>{t.retry}</button>}/> : loading && !workspace ? <div className="detail-loading" role="status">{t.loading}</div> : draft ? <div className="note-editor" onKeyDown={event => { if (isPrimaryShortcut(event.nativeEvent, 's', navigator.platform)) { event.preventDefault(); void saveNote(); } }}>
          <div className="editor-toolbar"><span className={dirty ? 'save-status changed' : 'save-status'}>{saving ? t.saving : dirty ? t.unsaved : original ? t.saved : t.newNote}</span><button className="button primary" onClick={() => void saveNote()} disabled={saving || (!dirty && !!original)}>{saving ? t.saving : t.save}</button></div>
          {saveError && <div className="error-banner" role="alert"><Icon name="alert"/><span>{saveError}</span></div>}
          <div className="editor-body"><input ref={titleRef} className="note-title" aria-label={t.noteTitle} placeholder={t.untitled} value={draft.title} onChange={event => setDraft({ ...draft, title: event.target.value })} disabled={saving} maxLength={500}/><div className="note-metadata">{draft.id && <span>{formatDate(workspace?.notes.find(note => note.id === draft.id)?.updatedAt, language)}</span>}{draft.meetingId && <span><Icon name="meetings" size={14}/>{workspace?.meetings.find(item => item.id === draft.meetingId)?.title || t.relatedMeeting}</span>}</div><textarea aria-label={t.noteText} className="note-text" placeholder={t.writeSomething} value={draft.text} onChange={event => setDraft({ ...draft, text: event.target.value })} disabled={saving}/></div>
          <div className="editor-footer"><Icon name="folder" size={16}/><select aria-label={t.folder} value={draft.folderId || ''} disabled={saving} onChange={event => setDraft({ ...draft, folderId: event.target.value || null })}><option value="">{draft.meetingId ? t.sameAsMeeting : t.noFolder}</option>{workspace?.folders.map(folder => <option key={folder.id} value={folder.id}>{folder.name}</option>)}</select></div>
        </div> : selectedMeetingId ? detailLoading ? <div className="detail-loading" role="status">{t.loading}</div> : detailError ? <EmptyState icon="meetings" title={t.errorUnavailable} hint="" action={<button className="button" onClick={() => setDetailRetry(value => value + 1)}>{t.retry}</button>}/> : detail && <article className="meeting-detail"><header className="meeting-header"><h1>{detail.meeting.title}</h1><div className="meeting-metadata"><span><Icon name="calendar" size={15}/>{formatDate(detail.meeting.startedAt, language) || t.noDate}</span><span><Icon name="clock" size={15}/>{formatDuration(detail.meeting.durationSeconds)}</span>{detail.meeting.folderId && <span><Icon name="folder" size={15}/>{workspace?.folders.find(folder => folder.id === detail.meeting.folderId)?.name}</span>}</div>
          {detail.meeting.hasMedia && '__TAURI_INTERNALS__' in window && <div className="meeting-player">{detail.meeting.mediaKind === 'video' ? <video controls preload="metadata" aria-label={t.playRecording} src={convertFileSrc(detail.meeting.id, 'after-media')} onError={() => setMediaError(true)}/> : <audio controls preload="metadata" aria-label={t.playRecording} src={convertFileSrc(detail.meeting.id, 'after-media')} onError={() => setMediaError(true)}/>} {mediaError && <p role="alert">{t.mediaUnavailable}</p>}</div>}
          <div className="segmented" role="tablist" aria-label={detail.meeting.title}>{(['notes','summary','transcript'] as const).map(value => <button key={value} id={`tab-${value}`} role="tab" aria-controls={`panel-${value}`} aria-selected={tab === value} tabIndex={tab === value ? 0 : -1} onKeyDown={event => { if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); const tabs = ['notes','summary','transcript'] as const; const next = tabs[(tabs.indexOf(value) + (event.key === 'ArrowRight' ? 1 : 2)) % 3]; setTab(next); document.getElementById(`tab-${next}`)?.focus(); } }} onClick={() => setTab(value)}>{value === 'notes' ? t.notes : value === 'summary' ? t.summary : t.transcript}</button>)}</div></header>
          <section className={`meeting-content ${tab}`} role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} tabIndex={0}>
            {tab === 'summary' && (detail.summary ? <div className="summary-text">{detail.summary}</div> : <EmptyState icon="notes" title={t.noSummary} hint={t.noSummaryHint}/>)}
            {tab === 'transcript' && (detail.transcript.length ? <div className="transcript-list">{detail.transcript.map((segment, index) => <div className="transcript-segment" key={`${segment.start}-${index}`}><time>{formatDuration(segment.start)}</time><div><div className="speaker"><span className="speaker-dot"/>{segment.speaker || t.unknownSpeaker}</div><p>{segment.text}</p></div></div>)}</div> : <EmptyState icon="meetings" title={t.noTranscript} hint={t.noTranscriptHint}/>)}
            {tab === 'notes' && <>{detail.notes.length ? <><div className="content-actions"><button className="button" onClick={() => newNote(detail.meeting.id)}><Icon name="plus" size={16}/>{t.newNote}</button></div>{detail.notes.map(note => <button className="meeting-note" key={note.id} onClick={() => openNote(note)}><strong>{note.title}</strong><span>{note.text}</span></button>)}</> : <EmptyState icon="notes" title={t.noMeetingNotes} hint={t.noMeetingNotesHint} action={<button className="button primary" onClick={() => newNote(detail.meeting.id)}><Icon name="plus" size={16}/>{t.newNote}</button>}/>}</>}
          </section></article> : <EmptyState icon={section} title={section === 'meetings' ? (meetings.length ? t.chooseMeeting : t.noMeetings) : (notes.length ? t.chooseNote : t.noNotes)} hint={section === 'meetings' ? (meetings.length ? t.chooseMeetingHint : t.noMeetingsHint) : t.noNotesHint} action={workspace && (section === 'notes' || !meetings.length) ? <button className="button primary" onClick={() => newNote()}><Icon name="plus" size={16}/>{t.newNote}</button> : undefined}/>}
      </main></>}
    </div>
    {importing && <Dialog title={t.importing}><p className="dialog-description" role="status">{t.importHint}</p></Dialog>}
    {recordDialog && <Dialog title={t.record} close={recordingBusy ? undefined : () => setRecordDialog(false)} closeLabel={t.close}>
      <form onSubmit={event => { event.preventDefault(); void startRecording(); }}>
        <label className="field-label" htmlFor="record-title">{t.recordTitle}</label><input id="record-title" className="text-input" value={recordTitle} onChange={event => { const title = event.target.value; setRecordTitle(title); try { sessionStorage.setItem('posle.recording.title', title); } catch { /* Optional draft metadata. */ } }} placeholder={t.recordingName} maxLength={200} disabled={recordingBusy}/>
        <label className="field-label" htmlFor="record-mode">{t.recordMode}</label><select id="record-mode" className="text-input" value={recordMode} onChange={event => setRecordMode(event.target.value as typeof recordMode)} disabled={recordingBusy}><option value="microphone_and_system">{t.microphoneSystem}</option><option value="microphone">{t.microphoneOnly}</option></select>
        <div className="dialog-actions"><button type="button" className="button" onClick={() => setRecordDialog(false)} disabled={recordingBusy}>{t.cancel}</button><button type="submit" className="button primary" disabled={recordingBusy}>{recordingBusy ? t.startingRecording : t.startRecording}</button></div>
      </form>
    </Dialog>}
    {recoveryOpen && <Dialog title={t.recoverRecordings} close={recordingBusy ? undefined : () => setRecoveryOpen(false)} closeLabel={t.close}><p className="dialog-description">{t.recoveryHint}</p>{recoverable.map(item => <div className="recovery-row" key={item.sessionId}><span>{item.sessionId.slice(0, 8)} · {(item.bytes / 1_048_576).toFixed(1)} MB</span><button className="button" disabled={recordingBusy} onClick={() => void recoverRecording(item.sessionId)}>{t.recoverRecording}</button></div>)}</Dialog>}
    {folderEditor && <Dialog title={folderEditor.folder ? t.renameFolder : t.newFolder}><form onSubmit={event => void saveFolder(event)}><label className="field-label" htmlFor="folder-name">{t.folderName}</label><input id="folder-name" className="text-input" value={folderEditor.name} onChange={event => setFolderEditor({ ...folderEditor, name: event.target.value })} disabled={folderSaving} maxLength={200}/>{folderError && <p className="form-error" role="alert">{folderError}</p>}<div className="dialog-actions"><button type="button" className="button" onClick={() => setFolderEditor(null)} disabled={folderSaving}>{t.cancel}</button><button className="button primary" type="submit" disabled={folderSaving || !folderEditor.name.trim()}>{folderSaving ? t.saving : folderEditor.folder ? t.rename : t.create}</button></div></form></Dialog>}
    {pendingAction && <Dialog title={t.unsavedTitle}><p className="dialog-description">{t.unsavedHint}</p>{saveError && <p className="form-error" role="alert">{saveError}</p>}<div className="dirty-actions"><button className="button" onClick={() => setPendingAction(null)} disabled={saving}>{t.keepEditing}</button><button className="button danger-quiet" onClick={() => { const action = pendingAction; setPendingAction(null); clearEditor(); action(); }} disabled={saving}>{t.discard}</button><button className="button primary" onClick={() => { void saveNote().then(success => { if (success) { const action = pendingAction; setPendingAction(null); action(); } }); }} disabled={saving}>{saving ? t.saving : t.saveAndContinue}</button></div></Dialog>}
    {folderCloseConfirm && <Dialog title={t.unsavedFolderTitle}><p className="dialog-description">{t.unsavedHint}</p>{folderError && <p className="form-error" role="alert">{folderError}</p>}<div className="dirty-actions"><button className="button" onClick={() => setFolderCloseConfirm(false)} disabled={folderSaving}>{t.keepEditing}</button><button className="button danger-quiet" onClick={() => { allowClose.current = true; void getCurrentWindow().close(); }} disabled={folderSaving}>{t.discard}</button><button className="button primary" onClick={() => { void saveFolder().then(success => { if (success) { allowClose.current = true; void getCurrentWindow().close(); } }); }} disabled={folderSaving}>{folderSaving ? t.saving : t.saveAndContinue}</button></div></Dialog>}
    {settingsOpen && <Dialog title={t.settings} close={() => setSettingsOpen(false)} closeLabel={t.close} wide><div className="preferences"><div className="preference-row"><label htmlFor="interface-language">{t.language}</label><select id="interface-language" value={languagePreference} onChange={event => setLanguagePreference(event.target.value as LanguagePreference)}><option value="system">{t.systemLanguage}</option><option value="ru">{t.russian}</option><option value="en">{t.english}</option></select></div><div className="preference-row"><label htmlFor="appearance">{t.appearance}</label><select id="appearance" value={appearance} onChange={event => setAppearance(event.target.value as typeof appearance)}><option value="system">{t.systemAppearance}</option><option value="light">{t.light}</option><option value="dark">{t.dark}</option></select></div><p className="preference-hint">{t.preferencesHint}</p><div className="port-notice"><h3>{t.aboutPort}</h3><p>{t.aboutPortHint}</p></div>{demoMode && <div className="port-notice demo-notice"><h3>{t.demo}</h3><p>{t.demoHint}</p></div>}</div><div className="dialog-actions"><button className="button primary" onClick={() => setSettingsOpen(false)}>{t.done}</button></div></Dialog>}
  </div>;
}
