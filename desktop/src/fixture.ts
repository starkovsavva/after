// Explicit development preview only. Production builds cannot select this transport.
import type { Transcription, SpeechCheck, Folder, ImportStatus, LibraryAPI, MeetingDetail, Note, RecordingStatus, Workspace } from './types';
let importState: ImportStatus = { operationId: null, controlId: null, phase: 'idle', copiedBytes: 0, totalBytes: 0, cancelRequested: false };
const storageKey = 'posle.demo.workspace.v1';
let check: SpeechCheck | null = null;
let checkStarted = 0;
const capabilities = { speechTranscription: new URLSearchParams(location.search).get('transcription') === '1', speechChecks: new URLSearchParams(location.search).get('speech') === '1', library: true, import: true, recording: new URLSearchParams(location.search).get('recording') === '1', calendar: false, assistant: false, cards: false, tasks: false };
const sample: Workspace = {
  folders: [{ id: 'work', name: 'Работа', revision: 1 }, { id: 'english', name: 'Английский', revision: 1 }],
  meetings: [
    { id: 'sync', title: 'Синк с командой', startedAt: '2026-10-27T11:14:00Z', durationSeconds: 961, folderId: 'work', hasSummary: true, hasTranscript: true },
    { id: 'lesson', title: 'Английский · первый урок', startedAt: '2026-10-26T15:01:00Z', durationSeconds: 1139, folderId: 'english', hasSummary: true, hasTranscript: true },
  ],
  notes: [
    { id: 'pilot', title: 'План пилота', text: 'Решения\nНачинаем с пилота на 25 участников.\n\nСледующие шаги\n— Согласовать метрики пилота\n— Подготовить сценарий онбординга\n— Вернуться к плану в пятницу', folderId: 'work', revision: 1, updatedAt: '2026-10-27T12:00:00Z' },
    { id: 'phrases', title: 'Выражения со встречи', text: 'Let’s circle back to the onboarding flow on Friday.\nВернёмся к сценарию онбординга в пятницу.\n\nPut together a draft — подготовить черновик.', folderId: 'english', meetingId: 'lesson', revision: 1, updatedAt: '2026-10-26T16:00:00Z' },
  ], capabilities,
};
function initial(): Workspace {
  if (new URLSearchParams(location.search).get('fixture') === 'empty') return { folders: [], meetings: [], notes: [], capabilities };
  try {
    const saved: unknown = JSON.parse(localStorage.getItem(storageKey) || 'null');
    if (saved && typeof saved === 'object' && 'folders' in saved && 'notes' in saved) return saved as Workspace;
  } catch { /* Preview storage is optional. */ }
  return structuredClone(sample);
}
let workspace = initial();
if (capabilities.speechTranscription) {
  workspace.capabilities.speechTranscription = true;
  for (const meeting of workspace.meetings) meeting.hasMedia = true;
}
const transcriptions = new Map<string, Transcription>();
const transcriptionStarted = new Map<string, number>();
const transcriptionParams = new URLSearchParams(location.search);
const initialTranscriptionState = transcriptionParams.get('transcriptionState');
if (initialTranscriptionState === 'interrupted' || initialTranscriptionState === 'queued') {
  transcriptions.set('sync', { id: crypto.randomUUID(), meetingId: 'sync', state: initialTranscriptionState, progress: 0, attempt: initialTranscriptionState === 'queued' ? 0 : 1, cancelRequested: false, createdAt: 1 });
}
const idleStatus = (): RecordingStatus => ({ sessionId: null, phase: 'idle', mode: null, elapsedMs: 0, warning: null });
function fixtureRecording(): RecordingStatus { try { return JSON.parse(sessionStorage.getItem('posle.demo.recording') || 'null') || idleStatus(); } catch { return idleStatus(); } }
function persist() { try { localStorage.setItem(storageKey, JSON.stringify(workspace)); } catch { /* No real data is stored in preview. */ } }
function clone<T>(value: T): T { return structuredClone(value); }
const delay = (ms = 80) => new Promise<void>(resolve => setTimeout(resolve, ms));
const details: Record<string, Omit<MeetingDetail, 'meeting' | 'notes'>> = {
  sync: { summary: 'Обсудили пилот и запуск приложения. Решили начать с небольшой группы, проверить сценарий первой встречи и вернуться к результатам в пятницу.\n\nРешения\n• Пилот на 25 участников.\n• Сначала проверяем запись, затем конспект.\n\nСледующие шаги\nПодготовить сценарий онбординга и согласовать метрики.', transcript: [
    { start: 7, end: 13, speaker: 'Савва', text: 'Давайте начнём с небольшого пилота и проверим, как проходит первая встреча.' },
    { start: 14, end: 19, speaker: 'Сергей', text: 'Хорошо. Какие метрики возьмём, чтобы понять, что всё работает?' },
    { start: 21, end: 30, speaker: 'Савва', text: 'Сначала проверим успешную запись, потом насколько полезны конспект и поиск.' },
    { start: 33, end: 42, speaker: 'Сергей', text: 'Тогда вернёмся к результатам в пятницу и решим, что улучшить.' },
  ] },
  lesson: { summary: 'На первом уроке обсудили рабочие встречи, личный проект и полезные выражения для общения с командой.\n\nПрактика\nCircle back — вернуться к обсуждению.\nPut together a draft — подготовить черновик.', transcript: [
    { start: 5, end: 14, speaker: 'Анна', text: 'Could you tell me about the project you are working on?' },
    { start: 16, end: 26, speaker: 'Савва', text: 'I am building an app that helps me keep notes and remember what we discussed in meetings.' },
    { start: 29, end: 38, speaker: 'Анна', text: 'Great. Let’s put together a few phrases you can use at work.' },
  ] },
};
export const fixtureAPI: LibraryAPI = {
  async transcriptionStatus(meetingId) {
    let job = transcriptions.get(meetingId);
    if (job?.state === 'running' && !transcriptionParams.has('transcriptionSlow') && Date.now() - (transcriptionStarted.get(meetingId) || 0) > 1200) {
      job = { ...job, state: 'succeeded', progress: 1 }; transcriptions.set(meetingId, job);
      details[meetingId] = { transcript: [{ start: 0, end: 1, text: 'Synthetic local transcription result' }], summary: null };
      const meeting = workspace.meetings.find(value => value.id === meetingId);
      if (meeting) { meeting.hasTranscript = true; meeting.hasSummary = false; }
    }
    const observed = clone(job || null);
    if (transcriptionParams.has('transcriptionReadDelay')) await delay(800);
    return observed;
  },
  async startTranscription(meetingId) {
    const current = transcriptions.get(meetingId);
    if (current && ['running', 'queued', 'interrupted', 'blocked'].includes(current.state)) return clone(current);
    const job: Transcription = { id: crypto.randomUUID(), meetingId, state: 'running', progress: 0, attempt: 1, cancelRequested: false, createdAt: Date.now()/1000 };
    transcriptions.set(meetingId, job); transcriptionStarted.set(meetingId, Date.now());
    if (transcriptionParams.has('transcriptionLostAck')) throw { code: 'engine_timeout' };
    return clone(job);
  },
  async resumeTranscription(meetingId, jobId, expectedAttempt) {
    const job = transcriptions.get(meetingId);
    if (!job || job.id !== jobId || job.attempt !== expectedAttempt) throw { code: 'conflict' };
    const resumed: Transcription = { ...job, state: 'running', attempt: job.attempt + 1, cancelRequested: false };
    transcriptions.set(meetingId, resumed); transcriptionStarted.set(meetingId, Date.now()); return clone(resumed);
  },
  async cancelTranscription(meetingId, jobId, expectedAttempt) {
    const job = transcriptions.get(meetingId);
    if (!job || job.id !== jobId || job.attempt !== expectedAttempt) throw { code: 'conflict' };
    const cancelled: Transcription = { ...job, state: 'cancelled', cancelRequested: true };
    transcriptions.set(meetingId, cancelled); return clone(cancelled);
  },
  async speechCheckStatus() {
    if (check?.state === 'running' && !new URLSearchParams(location.search).has('speechSlow') && Date.now() - checkStarted > 1200) check = { ...check, state: 'succeeded', progress: 1 };
    const observed = clone(check);
    if (new URLSearchParams(location.search).has('speechReadDelay')) await delay(800);
    return observed;
  },
  async startSpeechCheck() { if (check?.state === 'running') throw { code: 'busy' }; checkStarted = Date.now(); check = { id: crypto.randomUUID(), state: 'running', progress: 0, attempt: 1, cancelRequested: false, createdAt: Date.now()/1000 }; return clone(check); },
  async cancelSpeechCheck(jobId, expectedAttempt) { if (check?.id !== jobId || check.attempt !== expectedAttempt) throw { code: 'conflict' }; check = { ...check, state: 'cancelled' }; return clone(check); },
  async startRecording(mode) { await delay(); const status: RecordingStatus = { sessionId: crypto.randomUUID(), phase: 'recording', mode, elapsedMs: 0, warning: null }; sessionStorage.setItem('posle.demo.recording', JSON.stringify(status)); return status; },
  async recordingStatus() { return fixtureRecording(); },
  async stopRecording(title) { await delay(); if (!fixtureRecording().sessionId) throw { code: 'recording_error' }; sessionStorage.removeItem('posle.demo.recording'); const meeting = { id: crypto.randomUUID(), title, startedAt: Date.now() / 1000, durationSeconds: 1, folderId: null, hasTranscript: false, hasSummary: false }; workspace.meetings = [meeting, ...workspace.meetings]; persist(); return { meeting, interrupted: false }; },
  async recoverableRecordings() { return []; },
  async recoverRecording() { throw { code: 'unsupported_platform' }; },
  async importHistory() { return { jobs: [], total: 0, hasMore: false, nextCursor: null }; },
  async resumeImport() { throw { code: 'invalid_request' }; },
  async cancelQueuedImport() { throw { code: 'invalid_request' }; },
  async importStatus() { return clone(importState); },
  async cancelImport(operationId, controlId) {
    if (importState.operationId !== operationId || importState.controlId !== controlId) throw { code: 'invalid_request' };
    importState.cancelRequested = true; return clone(importState);
  },
  async chooseAndImport() {
    const scenario = new URLSearchParams(location.search).get('import');
    importState = { operationId: crypto.randomUUID(), controlId: crypto.randomUUID(), phase: 'copying', copiedBytes: 10, totalBytes: 100, cancelRequested: false };
    await delay(scenario === 'slow' ? 500 : 80);
    if (importState.cancelRequested) { importState.phase = 'cancelled'; return null; }
    importState.phase = 'completed'; importState.copiedBytes = 100;
    if (scenario === 'fail') { importState.phase = 'failed'; throw { code: 'import_failed' }; }
    if (scenario !== 'success' && scenario !== 'slow') { importState.phase = 'cancelled'; return null; }
    const meeting = { id: crypto.randomUUID(), title: 'Imported fixture', startedAt: Date.now() / 1000, durationSeconds: 0, folderId: null, hasTranscript: false, hasSummary: false };
    workspace.meetings = [meeting, ...workspace.meetings]; persist(); return clone(meeting);
  },
  async getWorkspace() { await delay(); return clone(workspace); },
  async getMeeting(id) {
    await delay(id === 'sync' ? 250 : 60);
    const meeting = workspace.meetings.find(item => item.id === id);
    if (!meeting) throw { code: 'NOT_FOUND', message: 'Meeting not found' };
    return clone({ meeting, ...(details[id] || { summary: null, transcript: [] }), notes: workspace.notes.filter(note => note.meetingId === id) });
  },
  async saveNote(input) {
    await delay();
    if (!input.title.trim()) throw { code: 'INVALID_INPUT', message: 'A title is required' };
    const existing = input.id ? workspace.notes.find(note => note.id === input.id) : undefined;
    if (input.id && !existing) throw { code: 'NOT_FOUND', message: 'Note not found' };
    if (existing && existing.revision !== input.expectedRevision) throw { code: 'CONFLICT', message: 'Note changed' };
    const note: Note = { id: input.id || crypto.randomUUID(), title: input.title.trim(), text: input.text, folderId: Object.hasOwn(input, 'folderId') ? input.folderId : existing?.folderId, meetingId: Object.hasOwn(input, 'meetingId') ? input.meetingId : existing?.meetingId, revision: (existing?.revision || 0) + 1, updatedAt: new Date().toISOString() };
    workspace.notes = [note, ...workspace.notes.filter(item => item.id !== note.id)]; persist(); return clone(note);
  },
  async saveFolder(input) {
    await delay();
    if (!input.name.trim()) throw { code: 'INVALID_INPUT', message: 'A name is required' };
    const existing = input.id ? workspace.folders.find(folder => folder.id === input.id) : undefined;
    if (input.id && !existing) throw { code: 'NOT_FOUND', message: 'Folder not found' };
    if (existing && existing.revision !== input.expectedRevision) throw { code: 'CONFLICT', message: 'Folder changed' };
    const folder: Folder = { id: input.id || crypto.randomUUID(), name: input.name.trim(), revision: (existing?.revision || 0) + 1 };
    workspace.folders = [...workspace.folders.filter(item => item.id !== folder.id), folder];
    if (existing) workspace.notes = workspace.notes.map(note => note.folderId === folder.id ? { ...note, revision: note.revision + 1 } : note);
    persist(); return clone(folder);
  },
  async searchLibrary(query, folderId) {
    await delay(); const lower = query.toLocaleLowerCase();
    const hits = [
      ...workspace.meetings.filter(item => (!folderId || item.folderId === folderId) && (item.title + (details[item.id]?.summary || '')).toLocaleLowerCase().includes(lower)).map(item => ({ kind: 'meeting' as const, id: item.id, title: item.title, excerpt: details[item.id]?.summary?.slice(0, 150), folderId: item.folderId })),
      ...workspace.notes.filter(item => (!folderId || item.folderId === folderId) && (item.title + item.text).toLocaleLowerCase().includes(lower)).map(item => ({ kind: 'note' as const, id: item.id, title: item.title, excerpt: item.text.slice(0, 150), folderId: item.folderId })),
    ];
    return { hits, total: hits.length, truncated: false };
  },
};
