import { test, expect } from '@playwright/test';

test('opening settings never starts inference; explicit check can cancel and reconnect to its state', async ({ page }) => {
  await page.goto('/?demo=1&speech=1&speechSlow=1&speechReadDelay=1');
  await page.getByRole('button', { name: 'Settings', exact: true }).first().click();
  const panel = page.getByRole('region', { name: 'Local speech check', exact: true });
  await expect(panel.getByRole('status')).toHaveText('Not checked in this session');
  await page.waitForTimeout(1300);
  await expect(panel.getByRole('status')).toHaveText('Not checked in this session');
  await panel.getByRole('button', { name: 'Check local speech', exact: true }).click();
  await expect(panel.getByRole('status')).toHaveText('Checking local speech…');
  await page.getByRole('button', { name: 'Done', exact: true }).click();
  await page.getByRole('button', { name: 'Settings', exact: true }).first().click();
  await expect(panel.getByRole('status')).toHaveText('Checking local speech…');
  await page.waitForTimeout(600); // A deferred status read is now in flight.
  await panel.getByRole('button', { name: 'Cancel check', exact: true }).click();
  await expect(panel.getByRole('status')).toHaveText('Check cancelled');
  await page.waitForTimeout(1100);
  await expect(panel.getByRole('status')).toHaveText('Check cancelled');
});

test('completed check is shown as a historical result and fits narrow Russian settings', async ({ page }) => {
  await page.goto('/?demo=1&speech=1');
  await page.getByRole('button', { name: 'Settings', exact: true }).first().click();
  const panel = page.getByRole('region', { name: 'Local speech check', exact: true });
  await panel.getByRole('button', { name: 'Check local speech', exact: true }).click();
  await expect(panel.getByRole('status')).toHaveText('Local speech check passed');
  await expect(panel.getByText('This result describes the last check. Components are verified again when speech processing starts.')).toBeVisible();
  await page.getByLabel('Interface language', { exact: true }).selectOption('ru');
  await page.setViewportSize({ width: 800, height: 620 });
  await expect(page.getByRole('region', { name: 'Проверка локального распознавания', exact: true })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBeTruthy();
  expect(await page.getByRole('dialog').evaluate(dialog => dialog.scrollWidth <= dialog.clientWidth)).toBeTruthy();
});
