import type { BridgeError, Note, NoteInput } from './types.ts';
import type { Copy, Language } from './i18n.ts';
export interface Draft {
  id?: string;
  title: string;
  text: string;
  folderId?: string | null;
  meetingId?: string | null;
  expectedRevision?: number;
}
export function draftFromNote(note: Note): Draft {
  return { id: note.id, title: note.title, text: note.text, folderId: note.folderId,
    meetingId: note.meetingId, expectedRevision: note.revision };
}
export function isDirty(draft: Draft | null, original: Draft | null): boolean {
  if (!draft) return false;
  if (!original) return !!(draft.title.trim() || draft.text.trim());
  return draft.title !== original.title || draft.text !== original.text || draft.folderId !== original.folderId;
}
export function noteInput(draft: Draft, original: Draft | null = null): NoteInput {
  const input: NoteInput = { id: draft.id, title: draft.title.trim(), text: draft.text, expectedRevision: draft.expectedRevision };
  // DTO folders can be inherited from a meeting. Omit unchanged metadata so the core preserves that relationship.
  if (!original || draft.folderId !== original.folderId) input.folderId = draft.folderId;
  if (!original || draft.meetingId !== original.meetingId) input.meetingId = draft.meetingId;
  return input;
}
export function errorMessage(error: unknown, text: Copy): string {
  const code = typeof error === 'object' && error !== null && 'code' in error ? String((error as BridgeError).code).toUpperCase() : '';
  if (code === 'CONFLICT') return text.errorConflict;
  if (['INVALID_INPUT', 'INVALID_REQUEST', 'DUPLICATE_NAME', 'CONTENT_TOO_LARGE'].includes(code)) return text.errorInput;
  if (code === 'NOT_FOUND') return text.errorNotFound;
  if (['ENGINE_UNAVAILABLE', 'ENGINE_TIMEOUT', 'ENGINE_FAILURE', 'INVALID_RESPONSE', 'BROWSER_UNCONNECTED'].includes(code)) return text.errorUnavailable;
  return text.errorGeneric;
}
export function formatDate(date: string | number | undefined, language: Language): string {
  if (date === undefined) return '';
  const value = new Date(typeof date === 'number' ? date * 1000 : date);
  return Number.isNaN(value.getTime()) ? '' : new Intl.DateTimeFormat(language === 'ru' ? 'ru-RU' : 'en-US', {day:'numeric',month:'short',year:'numeric'}).format(value);
}
export function formatDuration(seconds: number | null | undefined): string {
  if (seconds == null || !Number.isFinite(seconds)) return '';
  const value = Math.max(0, Math.floor(seconds));
  return `${Math.floor(value / 60).toString().padStart(2, '0')}:${(value % 60).toString().padStart(2, '0')}`;
}
