import { invoke } from '@tauri-apps/api/core';
import type { Folder, FolderInput, LibraryAPI, MeetingDetail, Note, NoteInput, SearchResponse, Workspace } from './types';

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
const desktop: LibraryAPI = {
  getWorkspace: () => command<Workspace>('get_workspace'),
  getMeeting: meetingId => command<MeetingDetail>('get_meeting', { meetingId }),
  saveNote: (input: NoteInput) => command<Note>('save_note', { input }),
  saveFolder: (input: FolderInput) => command<Folder>('save_folder', { input }),
  searchLibrary: (query, folderId) => command<SearchResponse>('search_library', { query, folderId }),
};
export const api: LibraryAPI = demoMode ? (await import('./fixture')).fixtureAPI : desktop;
