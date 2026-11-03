import { test, expect } from '@playwright/test';

async function openSync(page: import('@playwright/test').Page, query = '') {
  await page.goto(`/?demo=1&transcription=1${query}`);
  await page.getByRole('button', { name: /Синк с командой/ }).click();
  return page.getByRole('region', { name: 'Local transcription', exact: true });
}

test('opening a meeting is passive and stale polling cannot undo cancellation', async ({ page }) => {
  const panel = await openSync(page, '&transcriptionSlow=1&transcriptionReadDelay=1');
  await expect(panel.getByRole('status')).toHaveText('No transcription job');
  await page.waitForTimeout(1000);
  await expect(panel.getByRole('status')).toHaveText('No transcription job');
  await panel.getByRole('button', { name: 'Transcribe locally', exact: true }).click();
  await expect(panel.getByText(/A successful transcription replaces/)).toBeVisible();
  await expect(panel.getByRole('status')).toHaveText('No transcription job');
  await panel.getByRole('button', { name: 'Confirm transcription', exact: true }).click();
  await expect(panel.getByRole('status')).toHaveText('Transcribing…');
  await page.waitForTimeout(650);
  await panel.getByRole('button', { name: 'Cancel transcription', exact: true }).click();
  await expect(panel.getByRole('status')).toHaveText('Transcription cancelled');
  await page.waitForTimeout(1000);
  await expect(panel.getByRole('status')).toHaveText('Transcription cancelled');
  await expect(panel.getByRole('button', { name: 'Continue saved transcription' })).toBeEnabled();
  await page.getByRole('button', { name: /Английский · первый урок/ }).click();
  await expect(panel.getByRole('status')).toHaveText('No transcription job');
  await page.getByRole('button', { name: /Синк с командой/ }).click();
  await expect(panel.getByRole('status')).toHaveText('Transcription cancelled');
});

test('interrupted work resumes only explicitly and publication refreshes transcript and summary', async ({ page }) => {
  const panel = await openSync(page, '&transcriptionState=interrupted');
  await expect(panel.getByRole('status')).toHaveText('Transcription interrupted. Continue explicitly.');
  await page.waitForTimeout(1400);
  await expect(panel.getByRole('status')).toHaveText('Transcription interrupted. Continue explicitly.');
  await expect(panel.getByRole('button', { name: 'Transcribe locally', exact: true })).toHaveCount(0);
  await panel.getByRole('button', { name: 'Continue saved transcription', exact: true }).click();
  await panel.getByRole('button', { name: 'Confirm transcription', exact: true }).click();
  await expect(panel.getByRole('status')).toHaveText('Transcription completed');
  await page.getByRole('tab', { name: 'Transcript', exact: true }).click();
  await expect(page.getByText('Synthetic local transcription result', { exact: true })).toBeVisible();
  await page.getByRole('tab', { name: 'Summary', exact: true }).click();
  await expect(page.getByText('No summary yet', { exact: true })).toBeVisible();
});

test('lost acknowledgement requires a status refresh before further actions', async ({ page }) => {
  const panel = await openSync(page, '&transcriptionLostAck=1&transcriptionSlow=1');
  await panel.getByRole('button', { name: 'Transcribe locally', exact: true }).click();
  await panel.getByRole('button', { name: 'Confirm transcription', exact: true }).click();
  await expect(panel.getByRole('alert')).toContainText('Refresh its status');
  await expect(panel.getByRole('button', { name: 'Transcribe locally', exact: true })).toBeDisabled();
  await panel.getByRole('button', { name: 'Refresh transcription', exact: true }).click();
  await expect(panel.getByRole('status')).toHaveText('Transcribing…');
  await expect(panel.getByRole('button', { name: 'Transcribe locally', exact: true })).toHaveCount(0);
  await panel.getByRole('button', { name: 'Cancel transcription', exact: true }).click();
  await expect(panel.getByRole('status')).toHaveText('Transcription cancelled');
});

test('Russian transcription controls fit a narrow meeting view', async ({ page }) => {
  await openSync(page, '&transcriptionState=queued');
  await page.getByRole('button', { name: 'Settings', exact: true }).first().click();
  await page.getByLabel('Interface language', { exact: true }).selectOption('ru');
  await page.getByRole('button', { name: 'Готово', exact: true }).click();
  await page.setViewportSize({ width: 800, height: 680 });
  const russian = page.getByRole('region', { name: 'Локальная транскрипция', exact: true });
  await expect(russian).toBeVisible();
  expect(await russian.evaluate(element => element.scrollWidth <= element.clientWidth)).toBeTruthy();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBeTruthy();
  await page.screenshot({ path: '../.build/desktop-e2e/transcription-ru.png', fullPage: true });
});
