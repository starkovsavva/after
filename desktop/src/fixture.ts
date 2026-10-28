// Explicit development preview only. Production builds cannot select this transport.
import type { Folder, LibraryAPI, MeetingDetail, Note, Workspace } from './types';
const storageKey = 'posle.demo.workspace.v1';
const capabilities = { library: true, recording: false, calendar: false, assistant: false, cards: false, tasks: false };
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
