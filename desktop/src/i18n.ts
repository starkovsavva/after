export type Language = 'en' | 'ru';
export type LanguagePreference = 'system' | Language;

const en = {
  appName: 'After', meetings: 'Meetings', notes: 'Notes', folders: 'Folders', allFolders: 'All folders',
  newFolder: 'New folder', newNote: 'New note', settings: 'Settings', search: 'Search library',
  searchPlaceholder: 'Find a meeting or note', searchResults: 'Search results', noResults: 'No results',
  noResultsHint: 'Try another phrase or search in all folders.', searchAll: 'Search all folders',
  hideFolders: 'Hide folders', showFolders: 'Show folders', renameFolder: 'Rename folder',
  folderName: 'Folder name', folder: 'Folder', noFolder: 'No folder', createFolder: 'Create folder',
  create: 'Create', rename: 'Rename', cancel: 'Cancel', close: 'Close', done: 'Done', save: 'Save',
  saving: 'Saving…', saved: 'Saved', unsaved: 'Unsaved changes', discard: 'Discard changes',
  unsavedTitle: 'Save changes to this note?', unsavedHint: 'Your changes have not been saved yet.',
  keepEditing: 'Keep editing', saveAndContinue: 'Save changes', retry: 'Try again', loading: 'Loading…',
  loadFailed: 'Could not open the library.', connectionRequired: 'Open the desktop application to use your library.',
  connectionHint: 'This browser page is not connected to your data.',
  noteTitle: 'Note title', noteText: 'Note text', untitled: 'Untitled note', writeSomething: 'Write your thoughts…',
  noNotes: 'No notes yet', noNotesHint: 'Keep your thoughts, decisions, and meeting notes in one place.',
  noMeetings: 'No meetings here yet', noMeetingsHint: 'Saved meetings will appear here when you open an existing library.',
  chooseMeeting: 'Choose a meeting', chooseMeetingHint: 'Open a meeting to read its notes, summary, and transcript.',
  chooseNote: 'Choose a note', chooseNoteHint: 'Open a note or create a new one.',
  summary: 'Summary', transcript: 'Transcript', meetingNotes: 'Meeting notes',
  noSummary: 'No summary yet', noSummaryHint: 'This meeting does not have a saved summary.',
  noTranscript: 'No transcript yet', noTranscriptHint: 'This meeting does not have a saved transcript.',
  noMeetingNotes: 'No notes for this meeting', noMeetingNotesHint: 'Add your thoughts or a decision you want to remember.',
  language: 'Interface language', systemLanguage: 'Use system language', russian: 'Русский', english: 'English',
  appearance: 'Appearance', systemAppearance: 'Use system appearance', light: 'Light', dark: 'Dark',
  preferencesHint: 'These settings change the interface. Your notes and transcripts keep their original language.',
  aboutPort: 'Cross-platform preview', aboutPortHint: 'Your library, folders, notes, summaries, and transcripts are available. Recording and other system features are still being transferred.',
  demo: 'Demo library', demoHint: 'Sample data. Your personal library is not connected.',
  itemCount: 'items', today: 'Today', unknownSpeaker: 'Unknown speaker', back: 'Back',
  errorConflict: 'This item changed elsewhere. Your draft is still here. Reopen the item before saving another version.',
  errorInput: 'Check the title and text, then try again.',
  errorNotFound: 'This item is no longer available. Your draft is still here.',
  errorUnavailable: 'The library is unavailable. Check the desktop connection and try again.',
  errorGeneric: 'The operation could not be completed. Your changes are still here.',
  requiredFolder: 'Enter a folder name.', requiredTitle: 'Enter a title.',
  keyboardSearch: 'Search', relatedMeeting: 'From meeting', noDate: 'No date',
  activeFolder: 'Active folder', library: 'Library', refreshLibrary: 'Reload library', sameAsMeeting: 'Same as meeting',
  unsavedFolderTitle: 'Save changes to this folder?', refreshFailed: 'Changes were saved, but the library could not refresh. Try again.',
};
export type Copy = typeof en;
const ru: Copy = {
  appName: 'После', meetings: 'Встречи', notes: 'Заметки', folders: 'Папки', allFolders: 'Все папки',
  newFolder: 'Новая папка', newNote: 'Новая заметка', settings: 'Настройки', search: 'Поиск по библиотеке',
  searchPlaceholder: 'Найти встречу или заметку', searchResults: 'Результаты поиска', noResults: 'Ничего не найдено',
  noResultsHint: 'Попробуйте другую фразу или поиск во всех папках.', searchAll: 'Искать во всех папках',
  hideFolders: 'Скрыть папки', showFolders: 'Показать папки', renameFolder: 'Переименовать папку',
  folderName: 'Название папки', folder: 'Папка', noFolder: 'Без папки', createFolder: 'Создать папку',
  create: 'Создать', rename: 'Переименовать', cancel: 'Отмена', close: 'Закрыть', done: 'Готово', save: 'Сохранить',
  saving: 'Сохраняю…', saved: 'Сохранено', unsaved: 'Есть изменения', discard: 'Не сохранять',
  unsavedTitle: 'Сохранить изменения заметки?', unsavedHint: 'Изменения пока не сохранены.',
  keepEditing: 'Продолжить редактирование', saveAndContinue: 'Сохранить', retry: 'Повторить', loading: 'Загрузка…',
  loadFailed: 'Не удалось открыть библиотеку.', connectionRequired: 'Откройте приложение, чтобы работать с библиотекой.',
  connectionHint: 'Эта страница в браузере не подключена к вашим данным.',
  noteTitle: 'Название заметки', noteText: 'Текст заметки', untitled: 'Новая заметка', writeSomething: 'Запишите свои мысли…',
  noNotes: 'Заметок пока нет', noNotesHint: 'Сохраняйте мысли, решения и заметки со встреч в одном месте.',
  noMeetings: 'Встреч пока нет', noMeetingsHint: 'Сохранённые встречи появятся здесь при открытии существующей библиотеки.',
  chooseMeeting: 'Выберите встречу', chooseMeetingHint: 'Откройте встречу, чтобы прочитать заметки, конспект и транскрипт.',
  chooseNote: 'Выберите заметку', chooseNoteHint: 'Откройте заметку или создайте новую.',
  summary: 'Конспект', transcript: 'Транскрипт', meetingNotes: 'Заметки встречи',
  noSummary: 'Конспекта пока нет', noSummaryHint: 'У этой встречи нет сохранённого конспекта.',
  noTranscript: 'Транскрипта пока нет', noTranscriptHint: 'У этой встречи нет сохранённого транскрипта.',
  noMeetingNotes: 'Заметок по встрече пока нет', noMeetingNotesHint: 'Добавьте мысли или решение, которое хотите запомнить.',
  language: 'Язык интерфейса', systemLanguage: 'Как в системе', russian: 'Русский', english: 'English',
  appearance: 'Оформление', systemAppearance: 'Как в системе', light: 'Светлое', dark: 'Тёмное',
  preferencesHint: 'Эти настройки меняют интерфейс. Язык заметок и транскриптов остаётся исходным.',
  aboutPort: 'Кроссплатформенная версия', aboutPortHint: 'Доступны библиотека, папки, заметки, конспекты и транскрипты. Запись и другие системные возможности ещё переносятся.',
  demo: 'Демонстрационная библиотека', demoHint: 'Пример данных. Личная библиотека не подключена.',
  itemCount: 'материалов', today: 'Сегодня', unknownSpeaker: 'Голос не определён', back: 'Назад',
  errorConflict: 'Этот материал уже изменён в другом окне. Черновик сохранён в редакторе. Откройте материал заново перед сохранением новой версии.',
  errorInput: 'Проверьте название и текст, затем повторите.',
  errorNotFound: 'Этот материал больше недоступен. Черновик остался в редакторе.',
  errorUnavailable: 'Библиотека недоступна. Проверьте подключение приложения и повторите.',
  errorGeneric: 'Не удалось выполнить действие. Изменения остались в редакторе.',
  requiredFolder: 'Введите название папки.', requiredTitle: 'Введите название.',
  keyboardSearch: 'Поиск', relatedMeeting: 'Из встречи', noDate: 'Без даты',
  activeFolder: 'Текущая папка', library: 'Библиотека', refreshLibrary: 'Обновить библиотеку', sameAsMeeting: 'Как у встречи',
  unsavedFolderTitle: 'Сохранить изменения папки?', refreshFailed: 'Изменения сохранены, но библиотека не обновилась. Повторите загрузку.',
};
export function resolveLanguage(preference: LanguagePreference, languages: readonly string[] = navigator.languages): Language {
  if (preference !== 'system') return preference;
  for (const language of languages) {
    if (language.toLowerCase().startsWith('ru')) return 'ru';
    if (language.toLowerCase().startsWith('en')) return 'en';
  }
  return 'en';
}
export function copy(language: Language): Copy { return language === 'ru' ? ru : en; }
