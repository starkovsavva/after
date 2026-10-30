import { test, expect } from '@playwright/test';

test('empty library creates a folder and a real editable note, navigation protects drafts', async ({ page }) => {
  await page.goto('/?demo=1&fixture=empty');
  await expect(page.getByText('Demo library', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'New folder', exact: true }).first().click();
  await page.getByLabel('Folder name', { exact: true }).fill('Research');
  await page.getByRole('button', { name: 'Create', exact: true }).click();
  await expect(page.getByLabel('Active folder')).toHaveValue(/.+/);
  await page.getByRole('main').getByRole('button', { name: 'New note', exact: true }).click();
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
  await page.keyboard.press(process.platform === 'darwin' ? 'Meta+k' : 'Control+k');
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
  await expect(page.getByRole('alert')).toHaveCount(0);
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
  await page.keyboard.press(process.platform === 'darwin' ? 'Meta+k' : 'Control+k');
  await expect(picker).toBeFocused();
  await expect(page.getByRole('searchbox')).toHaveCount(0);
  await picker.selectOption('ru');
  await expect(page.getByLabel('Язык интерфейса', { exact: true })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await page.getByRole('button', { name: 'Новая папка', exact: true }).first().click();
  const name = page.getByLabel('Название папки', { exact: true });
  await name.fill('Draft folder');
  await page.keyboard.press(process.platform === 'darwin' ? 'Meta+k' : 'Control+k');
  await expect(name).toBeFocused();
  await expect(name).toHaveValue('Draft folder');
  await expect(page.getByRole('searchbox')).toHaveCount(0);
});


test('Windows shortcuts ignore alternate modifiers and Ctrl-S saves the first note', async ({ page }) => {
  await page.addInitScript(() => Object.defineProperty(navigator, 'platform', { value: 'Win32', configurable: true }));
  await page.goto('/?demo=1&fixture=empty');
  await page.getByRole('main').getByRole('button', { name: 'New note', exact: true }).click();
  await page.getByRole('textbox', { name: 'Note title', exact: true }).fill('Windows draft');
  const text = page.getByRole('textbox', { name: 'Note text', exact: true });
  await text.fill('Сохранить исходный текст.');
  await text.focus();
  await page.keyboard.press('Control+Alt+k');
  await expect(page.getByRole('searchbox')).toHaveCount(0);
  await expect(text).toBeFocused();
  await page.keyboard.press('Control+Shift+k');
  await expect(page.getByRole('searchbox')).toHaveCount(0);
  await expect(text).toBeFocused();
  await text.dispatchEvent('keydown', { key: 'ы', code: 'KeyS', ctrlKey: true });
  await expect(page.getByText('Saved', { exact: true })).toBeVisible();
  await text.fill('Сохранить через Ctrl+S.');
  await page.keyboard.press('Control+s');
  await expect(page.getByText('Saved', { exact: true })).toBeVisible();
  await text.dispatchEvent('keydown', { key: 'л', code: 'KeyK', ctrlKey: true });
  const search = page.getByRole('searchbox', { name: 'Search library', exact: true });
  await expect(search).toBeFocused();
  await search.fill('Windows draft');
  await expect(page.getByRole('button', { name: /Windows draft/ })).toBeVisible();
  await expect(page.getByRole('textbox', { name: 'Note text', exact: true })).toHaveValue('Сохранить через Ctrl+S.');
});


test('a failed native library load stays distinct from an empty library and can recover', async ({ page }) => {
  await page.addInitScript(() => {
    let readable = false;
    Object.defineProperty(window, '__AFTER_TEST_LIBRARY_READY__', {value: () => { readable = true; }, configurable: true});
    const bridge = {invoke: async (command: string) => {
      if (command !== 'get_workspace') throw {code:'ENGINE_FAILURE',message:'Synthetic unsupported operation'};
      if (!readable) throw {code:'ENGINE_FAILURE',message:'Synthetic startup failure'};
      return {folders:[],meetings:[],notes:[],capabilities:{library:true,recording:false,calendar:false,assistant:false,cards:false,tasks:false}};
    }};
    Object.defineProperty(window, '__TAURI_INTERNALS__', {value:bridge,configurable:true});
  });
  await page.goto('/');
  await expect(page.getByRole('heading', {name:'Could not open the library.',exact:true})).toBeVisible();
  await expect(page.getByRole('heading', {name:'No meetings here yet',exact:true})).toHaveCount(0);
  await expect(page.getByRole('main').getByRole('button', {name:'New note',exact:true})).toHaveCount(0);
  await page.evaluate(() => (window as unknown as {__AFTER_TEST_LIBRARY_READY__: () => void}).__AFTER_TEST_LIBRARY_READY__());
  await page.getByRole('main').getByRole('button', {name:'Try again',exact:true}).click();
  await expect(page.getByRole('main').getByRole('heading', {name:'No meetings here yet',exact:true})).toBeVisible();
  await expect(page.getByRole('main').getByRole('button', {name:'New note',exact:true})).toBeVisible();
  await expect(page.getByRole('heading', {name:'Could not open the library.',exact:true})).toHaveCount(0);
});

test('import protects an active operation and opens the resulting meeting in all folders', async ({ page }) => {
  await page.goto('/?demo=1&fixture=empty&import=slow');
  await page.getByRole('button', { name: 'New folder', exact: true }).first().click();
  await page.getByLabel('Folder name', { exact: true }).fill('Selected folder');
  await page.getByRole('button', { name: 'Create', exact: true }).click();
  await expect(page.getByLabel('Active folder')).toHaveValue(/.+/);
  await page.getByRole('button', { name: 'Import recording', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Choose or import a recording…' })).toBeVisible();
  expect(await page.evaluate(() => {
    const event = new Event('beforeunload', { cancelable: true });
    window.dispatchEvent(event);
    return event.defaultPrevented;
  })).toBe(true);
  await expect(page.getByRole('main').getByRole('heading', { name: 'Imported fixture' })).toBeVisible();
  await expect(page.getByLabel('Active folder')).toHaveValue('');
  await expect(page.getByRole('dialog')).toHaveCount(0);
});

test('cancelled import leaves the library unchanged and failed import reports recovery', async ({ page }) => {
  await page.goto('/?demo=1&fixture=empty');
  await page.getByRole('button', { name: 'Import recording', exact: true }).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect(page.getByRole('button', { name: /Imported fixture/ })).toHaveCount(0);
  await page.goto('/?demo=1&fixture=empty&import=fail');
  await page.getByRole('button', { name: 'Import recording', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('The original was not changed');
  await expect(page.getByRole('dialog')).toHaveCount(0);
});

test('recording stays visible after interface reload and stops without discarding the library', async ({ page }) => {
  await page.goto('/?demo=1&fixture=empty&recording=1');
  await page.getByRole('button', { name: 'Record meeting', exact: true }).click();
  await page.getByLabel('Meeting title').fill('Windows meeting');
  await page.getByRole('button', { name: 'Start recording', exact: true }).click();
  await expect(page.getByRole('button', { name: /Stop and save/ })).toBeVisible();
  expect(await page.evaluate(() => { const e = new Event('beforeunload', { cancelable: true }); window.dispatchEvent(e); return e.defaultPrevented; })).toBe(true);
  await page.reload();
  await expect(page.getByRole('button', { name: /Stop and save/ })).toBeVisible();
  await page.getByRole('button', { name: /Stop and save/ }).click();
  await expect(page.getByText('Recording saved.', { exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: /Windows meeting/ })).toBeVisible();
});
