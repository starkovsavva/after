import { test, expect } from '@playwright/test';

test('empty library creates a folder and a real editable note, navigation protects drafts', async ({ page }) => {
  await page.goto('/?demo=1&fixture=empty');
  await expect(page.getByText('Demo library', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'New folder', exact: true }).first().click();
  await page.getByLabel('Folder name', { exact: true }).fill('Research');
  await page.getByRole('button', { name: 'Create', exact: true }).click();
  await expect(page.getByLabel('Active folder')).toHaveValue(/.+/);
  await page.getByRole('button', { name: 'Notes', exact: true }).click();
  await page.getByRole('button', { name: 'New note', exact: true }).first().click();
  await page.getByRole('textbox', { name: 'Note title', exact: true }).fill('Idea for the pilot');
  await page.getByRole('textbox', { name: 'Note text', exact: true }).fill('Keep the original English text.\nНе переводить мои заметки.');
  await page.getByRole('button', { name: 'Meetings', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Save changes to this note?' })).toBeVisible();
  await page.getByRole('button', { name: 'Keep editing', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Note text', exact: true })).toHaveValue(/Не переводить/);
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.getByText('Saved', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Meetings', exact: true }).click();
  await page.getByRole('button', { name: 'Notes', exact: true }).click();
  await page.getByRole('button', { name: /Idea for the pilot/ }).click();
  await expect(page.getByRole('textbox', { name: 'Note text', exact: true })).toHaveValue('Keep the original English text.\nНе переводить мои заметки.');
});

test('folder collapse preserves visible scope, stale meeting results cannot replace a newer selection', async ({ page }) => {
  await page.goto('/?demo=1');
  await page.getByRole('button', { name: 'Синк с командой', exact: false }).click();
  await page.getByRole('button', { name: 'Английский · первый урок', exact: false }).click();
  await expect(page.getByRole('main').getByRole('heading', { name: 'Английский · первый урок' })).toBeVisible();
  await page.waitForTimeout(350);
  await expect(page.getByRole('main').getByRole('heading', { name: 'Английский · первый урок' })).toBeVisible();
  await page.getByRole('tab', { name: 'Transcript', exact: true }).click();
  await expect(page.getByText('Could you tell me about the project you are working on?', { exact: true })).toBeVisible();
  await page.getByRole('navigation', { name: 'Folders', exact: true }).getByRole('button', { name: 'Английский', exact: true }).click();
  await page.getByRole('button', { name: 'Folders', exact: true }).click();
  await expect(page.getByRole('navigation', { name: 'Folders', exact: true })).not.toBeVisible();
  await expect(page.getByLabel('Active folder')).toHaveValue('english');
  await expect(page.locator('.scope-name')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Calendar', exact: true })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Record', exact: true })).toHaveCount(0);
});

test('language and theme change only interface, keyboard search opens library results', async ({ page }) => {
  await page.goto('/?demo=1');
  await page.getByRole('button', { name: 'Settings', exact: true }).first().click();
  await page.getByLabel('Interface language', { exact: true }).selectOption('ru');
  await expect(page.getByRole('dialog', { name: 'Настройки', exact: true })).toBeVisible();
  await page.getByLabel('Оформление', { exact: true }).selectOption('dark');
  await page.getByRole('button', { name: 'Готово', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Синк с командой', exact: false })).toBeVisible();
  await expect(page.locator('html')).toHaveAttribute('lang', 'ru');
  await expect(page.locator('html')).toHaveAttribute('data-appearance', 'dark');
  await page.keyboard.press('Control+k');
  await expect(page.getByRole('searchbox', { name: 'Поиск по библиотеке', exact: true })).toBeFocused();
  await page.getByRole('searchbox', { name: 'Поиск по библиотеке', exact: true }).fill('онбординга');
  await expect(page.getByRole('button', { name: /План пилота/ })).toBeVisible();
  await page.getByRole('button', { name: /План пилота/ }).click();
  await expect(page.getByRole('textbox', { name: 'Текст заметки', exact: true })).toHaveValue(/Подготовить сценарий онбординга/);
  await page.reload();
  await expect(page.getByRole('button', { name: 'Настройки', exact: true }).first()).toBeVisible();
});

test('browser without an explicit preview cannot show fake personal data', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Open the desktop application to use your library.' })).toBeVisible();
  await expect(page.getByText('Demo library', { exact: true })).toHaveCount(0);
  await expect(page.getByRole('button', { name: /Синк с командой/ })).toHaveCount(0);
});


test('folder rename refreshes attached note revisions, and folder drafts prevent unloading', async ({ page }) => {
  await page.goto('/?demo=1');
  await page.getByRole('button', { name: 'Notes', exact: true }).click();
  await page.getByRole('button', { name: /План пилота/ }).click();
  await page.getByRole('button', { name: 'Rename folder: Работа', exact: true }).click();
  await page.getByLabel('Folder name', { exact: true }).fill('Рабочие встречи');
  const prevented = await page.evaluate(() => {
    const event = new Event('beforeunload', { cancelable: true });
    window.dispatchEvent(event);
    return event.defaultPrevented;
  });
  expect(prevented).toBe(true);
  await page.getByRole('button', { name: 'Rename', exact: true }).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await page.getByRole('textbox', { name: 'Note text', exact: true }).fill('Changed after folder rename');
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.getByText('Saved', { exact: true })).toBeVisible();
  await expect(page.getByRole('alert')).toHaveCount(0);
});


test('global search shortcut stays inside a modal and language changes preserve focus', async ({ page }) => {
  await page.goto('/?demo=1');
  await page.getByRole('button', { name: 'Settings', exact: true }).first().click();
  const picker = page.getByLabel('Interface language', { exact: true });
  await picker.focus();
  await page.keyboard.press('Control+k');
  await expect(picker).toBeFocused();
  await expect(page.getByRole('searchbox')).toHaveCount(0);
  await picker.selectOption('ru');
  await expect(page.getByLabel('Язык интерфейса', { exact: true })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await page.getByRole('button', { name: 'Новая папка', exact: true }).first().click();
  const name = page.getByLabel('Название папки', { exact: true });
  await name.fill('Draft folder');
  await page.keyboard.press('Control+k');
  await expect(name).toBeFocused();
  await expect(name).toHaveValue('Draft folder');
  await expect(page.getByRole('searchbox')).toHaveCount(0);
});
