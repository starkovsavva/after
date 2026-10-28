#!/usr/bin/env node
/** Browser UI → real canonical engine. Synthetic data only; not a native WebView test. */
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile, writeFile, mkdir, mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, extname, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const engine = resolve(process.env.AFTER_TEST_ENGINE_PATH || resolve(repo, '.build/rust/debug/posle-engine'));
const dist = resolve(repo, 'desktop/dist');
const artifacts = resolve(repo, '.build/desktop-e2e');
const fixture = await mkdtemp(resolve(tmpdir(), 'after-browser-'));
const token = randomBytes(32).toString('hex');
const commands = new Set(['get_workspace', 'get_meeting', 'save_note', 'save_folder', 'search_library']);
const { chromium, expect } = await import(pathToFileURL(resolve(repo, 'desktop/node_modules/@playwright/test/index.mjs')).href);
let browser, server, origin;
function invoke(command, args = {}) {
  assert(commands.has(command), 'Only typed desktop commands are available');
  return new Promise((accept, reject) => {
    const child = spawn(engine, ['desktop-bridge', '--root', fixture], { stdio: ['pipe', 'pipe', 'pipe'] });
    const output = []; let bytes = 0, settled = false;
    const timer = setTimeout(() => { child.kill(); reject(new Error('Engine timeout')); }, 12_000);
    const fail = error => { if (!settled) { settled = true; clearTimeout(timer); child.kill(); reject(error); } };
    child.on('error', fail);
    child.stdin.on('error', fail);
    child.stdout.on('data', chunk => { bytes += chunk.length; if (bytes > 8 * 1024 * 1024) fail(new Error('Engine output bound')); else output.push(chunk); });
    child.stderr.resume();
    child.on('close', code => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      if (code !== 0) { reject(new Error(`Engine exited ${code}`)); return; }
      try {
        const envelope = JSON.parse(Buffer.concat(output).toString());
        if (envelope.ok === true) accept(envelope.result);
        else reject(Object.assign(new Error(envelope.error?.message || 'Engine error'), { code: envelope.error?.code || 'engine_failure' }));
      } catch (error) { reject(error); }
    });
    child.stdin.end(JSON.stringify({ command, arguments: args }));
  });
}
async function meeting(id, title, start) {
  const directory = resolve(fixture, 'meetings', id);
  await mkdir(directory, { recursive: true });
  for (const [name, data] of Object.entries({
    'meta.json': { id, title, createdAt: start, duration: 152, source: 'synthetic.mp3', speakerNames: { speaker_2: 'Сергей' } },
    'transcript.json': { segments: [{ id: 1, start: 12, end: 16, speaker: 'speaker_2', text: `Real saved transcript: ${title}` }] },
    'summary.json': { overview: `Real saved summary: ${title}`, items: [], cards: [], generatedAt: start },
  })) await writeFile(resolve(directory, name), JSON.stringify(data), { mode: 0o600 });
}
try {
  await stat(engine); await stat(resolve(dist, 'index.html')); await mkdir(artifacts, { recursive: true });
  const english = await invoke('save_folder', { input: { name: 'Английский' } });
  const work = await invoke('save_folder', { input: { name: 'Работа' } });
  const initial = await invoke('save_note', { input: { title: 'Phrasal verbs', text: 'Original English. Исходный русский.', folderId: english.id } });
  await invoke('save_note', { input: { title: 'Migration review', text: 'Work-only synthetic context.', folderId: work.id } });
  await meeting('team-sync', 'Синк с командой', 1_793_184_000);
  await meeting('english-lesson', 'Английский · первый урок', 1_793_097_600);

  server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url, origin);
      if (url.pathname === '/__test/invoke') {
        if (request.method !== 'POST' || request.headers.host !== new URL(origin).host || request.headers['x-after-test'] !== token || (request.headers.origin && request.headers.origin !== origin)) {
          response.writeHead(403).end(); return;
        }
        const chunks = []; let size = 0;
        for await (const chunk of request) { size += chunk.length; if (size > 256 * 1024) throw new Error('Request bound'); chunks.push(chunk); }
        const { command, args } = JSON.parse(Buffer.concat(chunks));
        if (!commands.has(command)) { response.writeHead(400).end(); return; }
        try {
          const result = await invoke(command, args);
          // Deliberately reverse response order to exercise stale UI request protection.
          if (command === 'get_meeting') await new Promise(done => setTimeout(done, args.meetingId === 'team-sync' ? 250 : 10));
          response.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }).end(JSON.stringify({ ok: true, result }));
        } catch (error) { response.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ ok: false, error: { code: error.code || 'engine_failure', message: error.message } })); }
        return;
      }
      if (request.method !== 'GET') { response.writeHead(405).end(); return; }
      const filename = resolve(dist, '.' + decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname));
      if (!filename.startsWith(dist + sep)) { response.writeHead(403).end(); return; }
      const bytes = await readFile(filename);
      const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' }[extname(filename)] || 'application/octet-stream';
      response.writeHead(200, { 'Content-Type': mime, 'Cache-Control': 'no-store' }).end(bytes);
    } catch { if (!response.headersSent) response.writeHead(500); response.end(); }
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch();
  const page = await browser.newPage({ locale: 'en-US', viewport: { width: 1280, height: 820 } });
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  await page.addInitScript(({ token }) => {
    // Only native invoke is replaced. Production UI + real engine/domain/storage are used.
    window.__TAURI_INTERNALS__ = { invoke: async (command, args = {}) => {
      const response = await fetch('/__test/invoke', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-After-Test': token }, body: JSON.stringify({ command, args }) });
      const envelope = await response.json();
      if (!envelope.ok) throw envelope.error;
      return envelope.result;
    }};
  }, { token });
  await page.goto(origin);
  await expect(page.getByText('Demo library', { exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: /Синк с командой/ }).click();
  await page.getByRole('button', { name: /Английский · первый урок/ }).click();
  await expect(page.getByText('Real saved summary: Английский · первый урок', { exact: true })).toBeVisible();
  await page.waitForTimeout(350);
  await expect(page.getByText('Real saved summary: Английский · первый урок', { exact: true })).toBeVisible();
  await page.getByRole('tab', { name: 'Transcript', exact: true }).click();
  await expect(page.getByText('Real saved transcript: Английский · первый урок', { exact: true })).toBeVisible();
  await expect(page.getByText('Сергей', { exact: true })).toBeVisible();
  await page.screenshot({ path: resolve(artifacts, 'meeting-light.png') });

  await page.getByLabel('Active folder', { exact: true }).selectOption(english.id);
  await page.getByRole('button', { name: 'Notes', exact: true }).click();
  await expect(page.getByRole('button', { name: /Migration review/ })).toHaveCount(0);
  await page.getByRole('button', { name: 'New note', exact: true }).first().click();
  await page.getByRole('textbox', { name: 'Note title', exact: true }).fill('Travel practice');
  const content = 'Follow up on phrasal verbs.\nНе переводить мои заметки.';
  await page.getByRole('textbox', { name: 'Note text', exact: true }).fill(content);
  await page.getByRole('button', { name: 'Meetings', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Save changes to this note?' })).toBeVisible();
  await page.getByRole('button', { name: 'Keep editing', exact: true }).click();
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.getByText('Saved', { exact: true })).toBeVisible();
  let workspace = await invoke('get_workspace');
  const created = workspace.notes.find(note => note.title === 'Travel practice');
  assert.equal(created.text, content); assert.equal(created.folderId, english.id);
  await page.reload();
  await page.getByRole('button', { name: 'Notes', exact: true }).click();
  await page.getByRole('button', { name: /Travel practice/ }).click();
  await expect(page.getByRole('textbox', { name: 'Note text', exact: true })).toHaveValue(content);

  // Folder rename changes canonical note revisions. The open clean editor must reconcile them.
  await page.getByRole('button', { name: 'Rename folder: Английский', exact: true }).click();
  await page.getByLabel('Folder name', { exact: true }).fill('English practice');
  await page.getByRole('button', { name: 'Rename', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Rename folder', exact: true })).toHaveCount(0);
  await page.getByRole('textbox', { name: 'Note text', exact: true }).fill(content + '\nEdited after folder rename.');
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.getByText('Saved', { exact: true })).toBeVisible();
  workspace = await invoke('get_workspace');
  const current = workspace.notes.find(note => note.id === created.id);
  assert(current.revision > created.revision);
  assert.equal(current.text, content + '\nEdited after folder rename.');

  // An external canonical write must not be overwritten by this stale draft.
  await invoke('save_note', { input: { id: current.id, title: current.title, text: 'External canonical revision', expectedRevision: current.revision } });
  await page.getByRole('textbox', { name: 'Note text', exact: true }).fill('My draft must survive a conflict');
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.getByText(/This item changed elsewhere/)).toBeVisible();
  await expect(page.getByRole('textbox', { name: 'Note text', exact: true })).toHaveValue('My draft must survive a conflict');
  workspace = await invoke('get_workspace');
  assert.equal(workspace.notes.find(note => note.id === created.id).text, 'External canonical revision');
  await page.getByRole('button', { name: 'Meetings', exact: true }).click();
  await page.getByRole('button', { name: 'Discard changes', exact: true }).click();

  // Search respects the current folder before limiting and opens a real item.
  await page.getByLabel('Active folder', { exact: true }).selectOption(english.id);
  await page.keyboard.press('Control+k');
  await page.getByRole('searchbox', { name: 'Search library', exact: true }).fill('phrasal');
  await page.getByRole('button', { name: /Phrasal verbs/ }).click();
  await expect(page.getByRole('textbox', { name: 'Note text', exact: true })).toHaveValue(initial.text);
  await page.getByRole('button', { name: 'Settings', exact: true }).first().click();
  await page.getByLabel('Interface language', { exact: true }).selectOption('ru');
  await page.getByLabel('Оформление', { exact: true }).selectOption('dark');
  await page.getByRole('button', { name: 'Готово', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Текст заметки', exact: true })).toHaveValue(initial.text);
  await expect(page.locator('html')).toHaveAttribute('lang', 'ru');
  await page.screenshot({ path: resolve(artifacts, 'note-dark-ru.png') });
  await page.setViewportSize({ width: 800, height: 620 });
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'No horizontal page overflow');
  await page.screenshot({ path: resolve(artifacts, 'note-narrow.png') });
  assert.deepEqual(errors, []);
  console.log('PASS: production UI → real Rust/SQLite: meeting, stale response, folder scope, create/save/reopen, dirty guard, conflict, search, language, narrow layout.');
  console.log(`Synthetic screenshots: ${artifacts}`);
} finally {
  await browser?.close();
  await new Promise(done => server ? server.close(done) : done());
  await rm(fixture, { recursive: true, force: true });
}
