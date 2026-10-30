import test from 'node:test';
import assert from 'node:assert/strict';
import { draftFromNote, formatDate, formatDuration, isDirty, noteInput, errorMessage } from './model.ts';
import { copy, resolveLanguage } from './i18n.ts';
import { isPrimaryShortcut } from './shortcuts.ts';

test('system language follows supported preference order and explicit choice wins', () => {
  assert.equal(resolveLanguage('system', ['de-DE', 'ru-RU', 'en']), 'ru');
  assert.equal(resolveLanguage('system', ['en-US', 'ru']), 'en');
  assert.equal(resolveLanguage('system', ['fr']), 'en');
  assert.equal(resolveLanguage('en', ['ru']), 'en');
});
test('draft keeps original content, scope, and revision exactly', () => {
  const note = { id: 'n1', title: 'Тест', text: '  Original\nbody  ', folderId: 'f1', meetingId: 'm1', revision: 17 };
  const draft = draftFromNote(note);
  assert.equal(isDirty(draft, draft), false);
  assert.equal(isDirty({ ...draft, text: draft.text + '\n' }, draft), true);
  assert.deepEqual(noteInput(draft), { id: 'n1', title: 'Тест', text: note.text, folderId: 'f1', meetingId: 'm1', expectedRevision: 17 });
  assert.equal(isDirty({ title: '', text: '' }, null), false);
  assert.equal(isDirty({ title: '', text: 'useful draft' }, null), true);
});
test('moving a note is a dirty edit and clearing its folder is explicit null', () => {
  const original = draftFromNote({ id: 'n', title: 'Title', text: 'Text', folderId: 'f', revision: 1 });
  const draft = { ...original, folderId: null };
  assert.equal(isDirty(draft, original), true);
  assert.equal(noteInput(draft, original).folderId, null);
});
test('dates support canonical epoch seconds and invalid input stays empty', () => {
  assert.ok(formatDate(1793103240, 'en').includes('2026'));
  assert.equal(formatDate('bad', 'ru'), '');
  assert.equal(formatDuration(961.9), '16:01');
  assert.equal(formatDuration(-10), '00:00');
});
test('errors disclose neither raw engine messages nor filesystem paths', () => {
  const t = copy('en');
  assert.equal(errorMessage({ code: 'conflict', message: '/private/secret' }, t), t.errorConflict);
  assert.equal(errorMessage({ code: 'ENGINE_TIMEOUT', message: 'sensitive' }, t), t.errorUnavailable);
  assert.equal(errorMessage(new Error('/Users/person/private'), t), t.errorGeneric);
});

test('editing note text preserves inherited folder and meeting metadata by omission', () => {
  const original = draftFromNote({ id: 'n', title: 'Title', text: 'Text', folderId: 'inherited', meetingId: 'meeting', revision: 9 });
  const input = noteInput({ ...original, text: 'Changed text' }, original);
  assert.equal(Object.hasOwn(input, 'folderId'), false);
  assert.equal(Object.hasOwn(input, 'meetingId'), false);
  assert.equal(input.expectedRevision, 9);
  assert.equal(input.text, 'Changed text');
});


test('primary shortcuts use the host modifier without consuming Windows AltGr or alternate commands', () => {
  const event = {key:'k',ctrlKey:true,metaKey:false,altKey:false,shiftKey:false};
  assert.equal(isPrimaryShortcut(event, 'k', 'Win32'), true);
  assert.equal(isPrimaryShortcut(event, 'k', 'Linux x86_64'), true);
  assert.equal(isPrimaryShortcut({...event,altKey:true}, 'k', 'Win32'), false);
  assert.equal(isPrimaryShortcut({...event,shiftKey:true}, 'k', 'Win32'), false);
  assert.equal(isPrimaryShortcut({...event,ctrlKey:false,metaKey:true}, 'k', 'Win32'), false);
  assert.equal(isPrimaryShortcut(event, 'k', 'MacIntel'), false);
  assert.equal(isPrimaryShortcut({...event,ctrlKey:false,metaKey:true}, 'k', 'MacIntel'), true);
  assert.equal(isPrimaryShortcut({...event,key:'л',code:'KeyK'}, 'k', 'Win32'), true);
  assert.equal(isPrimaryShortcut({...event,key:'ы',code:'KeyS'}, 's', 'Win32'), true);
  assert.equal(isPrimaryShortcut({...event,key:'л',code:'KeyK',altKey:true}, 'k', 'Win32'), false);
  assert.equal(isPrimaryShortcut({...event,key:'л',code:'KeyK',isComposing:true}, 'k', 'Win32'), false);
});
