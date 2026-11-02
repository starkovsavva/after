import { invoke } from '@tauri-apps/api/core';
import type { Folder, FolderInput, ImportHistory, ImportHistoryCursor, LibraryAPI, Meeting, MeetingDetail, Note, NoteInput, SearchResponse, Workspace } from './types';

export const demoMode = import.meta.env.DEV && new URLSearchParams(location.search).get('demo') === '1';
const native = '__TAURI_INTERNALS__' in window;
const httpBridge = import.meta.env.DEV && import.meta.env.VITE_POSLE_BRIDGE === 'http';
export const connected = native || demoMode || httpBridge;

async function command<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  if (native) return invoke<T>(name, args);
  if (httpBridge) {
    const response = await fetch(`/__posle_bridge/${name}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(args),
    });
    const result: unknown = await response.json();
    if (!response.ok) throw result;
    return result as T;
  }
  throw { code: 'BROWSER_UNCONNECTED', message: 'Desktop bridge is unavailable.' };
}
const features = new Set(['list_tasks', 'get_task', 'create_task', 'update_task', 'list_cards', 'save_card', 'delete_card', 'suspend_card', 'preview_card_review', 'review_card', 'undo_card_review']);
export function featureCommand<T>(operation: string, args: Record<string, unknown>): Promise<T> {
  if (!features.has(operation)) return Promise.reject({ code: 'invalid_request' });
  return command<T>('feature_operation', { operation, args });
}
// Share only an in-flight read: StrictMode/startup and the history dialog may
// request the same leased snapshot together. Never cache completed history.
const historyRequests = new Map<string, Promise<ImportHistory>>();
function importHistory(after?: ImportHistoryCursor): Promise<ImportHistory> {
  const key = after ? JSON.stringify([after.createdAt, after.id]) : 'initial';
  let request = historyRequests.get(key);
  if (!request) {
    request = command<ImportHistory>('import_history', { after: after ?? null }).finally(() => { historyRequests.delete(key); });
    historyRequests.set(key, request);
  }
  return request;
}
const desktop: LibraryAPI = {
  getWorkspace: () => command<Workspace>('get_workspace'),
  getMeeting: meetingId => command<MeetingDetail>('get_meeting', { meetingId }),
  chooseAndImport: () => command<Meeting | null>('choose_and_import'),
  importStatus: () => command('import_status'),
  cancelImport: (operationId, controlId) => command('cancel_import', { operationId, controlId }),
  importHistory,
  resumeImport: (jobId, expectedAttempt) => command('resume_import', { jobId, expectedAttempt }),
  cancelQueuedImport: (jobId, expectedAttempt) => command('cancel_queued_import', { jobId, expectedAttempt }),
  startRecording: mode => command('start_recording', { mode }),
  recordingStatus: () => command('recording_status'),
  stopRecording: title => command('stop_recording', { title }),
  recoverableRecordings: () => command('recoverable_recordings'),
  recoverRecording: sessionId => command('recover_recording', { sessionId }),
  saveNote: (input: NoteInput) => command<Note>('save_note', { input }),
  saveFolder: (input: FolderInput) => command<Folder>('save_folder', { input }),
  searchLibrary: (query, folderId) => command<SearchResponse>('search_library', { query, folderId }),
};
export const api: LibraryAPI = demoMode ? (await import('./fixture')).fixtureAPI : desktop;
