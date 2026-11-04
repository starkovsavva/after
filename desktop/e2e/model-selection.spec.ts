import { test, expect } from '@playwright/test';

async function openSettings(page: import('@playwright/test').Page, extra = '') {
  await page.goto(`/?demo=1&modelSelection=1&speech=1${extra}`);
  await page.getByRole('button', { name: 'Settings', exact: true }).first().click();
  return page.getByRole('region', { name: 'Local speech model', exact: true });
}

test('model selection is explicit and never starts preflight or inference', async ({ page }) => {
  const panel = await openSettings(page);
  const check = page.getByRole('region', { name: 'Local speech check', exact: true });
  await expect(panel.getByRole('status')).toHaveText('Local speech mode is not selected');
  await expect(check.getByRole('status')).toHaveText('Not checked in this session');
  await page.waitForTimeout(1400);
  await expect(panel.getByRole('status')).toHaveText('Local speech mode is not selected');
  await panel.getByRole('button', { name: 'Use Parakeet v3', exact: true }).click();
  await expect(panel.getByRole('status')).toHaveText('Local speech mode is selected');
  await expect(check.getByRole('status')).toHaveText('Not checked in this session');
  await page.getByRole('button', { name: 'Done', exact: true }).click();
  await page.getByRole('button', { name: 'Settings', exact: true }).first().click();
  await expect(panel.getByRole('status')).toHaveText('Local speech mode is selected');
});

test('unknown selection acknowledgement requires a read before further mutations', async ({ page }) => {
  const panel = await openSettings(page, '&modelLostAck=1&modelReadDelay=1');
  const use = panel.getByRole('button', { name: 'Use Parakeet v3', exact: true });
  await expect(use).toBeDisabled();
  await expect(use).toBeEnabled();
  await use.click();
  await expect(panel.getByRole('alert')).toContainText('Refresh its status');
  await expect(use).toBeDisabled();
  await panel.getByRole('button', { name: 'Refresh model selection', exact: true }).click();
  await expect(panel.getByRole('status')).toHaveText('Local speech mode is selected');
  await expect(use).toBeEnabled();
  await expect(page.getByRole('region', { name: 'Local speech check', exact: true }).getByRole('status')).toHaveText('Not checked in this session');
});

test('missing model is distinct from readiness and Russian settings fit a narrow window', async ({ page }) => {
  const panel = await openSettings(page, '&modelMissing=1');
  await expect(panel.getByText('No model installation was found. Install Parakeet v3 before selecting it.')).toBeVisible();
  await expect(panel.getByRole('button', { name: 'Use Parakeet v3', exact: true })).toBeDisabled();
  await page.getByLabel('Interface language', { exact: true }).selectOption('ru');
  await page.setViewportSize({ width: 800, height: 620 });
  const russian = page.getByRole('region', { name: 'Модель локального распознавания', exact: true });
  await expect(russian).toBeVisible();
  expect(await russian.evaluate(element => element.scrollWidth <= element.clientWidth)).toBeTruthy();
  expect(await page.getByRole('dialog').evaluate(element => element.scrollWidth <= element.clientWidth)).toBeTruthy();
  await page.screenshot({ path: '../.build/desktop-e2e/model-selection-ru.png', fullPage: true });
});
