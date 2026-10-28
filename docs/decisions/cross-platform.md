# Один клиент После / After для macOS, Windows и Linux

Статус: **Tauri 2 принят пользователем**, 28 октября 2026 года.
Перенос начат в ветке `codex/cross-platform`. Первый срез — библиотека и заметки; перенос всех возможностей на Windows/Linux ещё не завершён. [Запуск и границы прототипа](../desktop.md).

## Выбор

Используем **Tauri 2 + React/TypeScript + существующее Rust-ядро** как одну целевую реализацию интерфейса для всех трёх ОС. Это инженерный выбор с учётом нынешнего стека, не утверждение о превосходстве скорости или памяти.

**Qt 6 / Qt Quick** — основная альтернатива, если принципиален интерфейс без webview. Qt поддерживает macOS, Windows и Linux; Linux сам по себе не требует Qt. **Flutter** и **Avalonia** тоже поддерживают эти три desktop-платформы, но добавляют соответственно Dart или .NET/C#/XAML и мост к Rust.

У Tauri системный webview: WebView2 в Windows, WebKit в macOS, WebKitGTK в Linux. Общий UI не означает идентичный движок рендеринга. Проверять редактор заметок, CSS, воспроизведение, клавиатуру и доступность на каждой ОС.

Источники: [Tauri architecture](https://v2.tauri.app/concept/architecture/), [Webview versions](https://v2.tauri.app/reference/webview-versions/), [Qt platforms](https://doc.qt.io/qt-6/supported-platforms.html), [Flutter desktop](https://docs.flutter.dev/platform-integration/desktop), [Avalonia platforms](https://docs.avaloniaui.net/docs/supported-platforms).

## Что сохраняем, что переносим

Общая реализация экранов: встречи, папки, заметки, транскрипты, конспекты, задачи, карточки, поиск, помощник и настройки. Существующий SwiftUI/AppKit UI нельзя просто перекомпилировать для Windows/Linux — его придётся реализовать заново для любого общего UI-фреймворка.

Сохраняем доменные правила Rust: SQLite, поиск, интервалы карточек, операции с контекстом, очереди, проверки актуальности, MCP и внешние трекеры. Но инфраструктура ядра пока не переносима целиком. В worker, файловом хранилище и индексаторе используются незащищённые `std::os::unix`, `openat`, `O_NOFOLLOW`, `flock`, Unix-сигналы и process groups. Удалять защиты ради компиляции нельзя: нужны эквивалентные платформенные реализации.

Факты из репозитория: [Package.swift](../../Package.swift), [worker.rs](../../rust-core/src/worker.rs), [notes.rs](../../rust-core/src/notes.rs), [code_index.rs](../../rust-core/src/code_index.rs), [media.rs](../../rust-core/src/media.rs), [Python runtime](../../rust-core/src/python_host.rs), [ASR catalog](../../backend/models.py), [requirements](../../backend/requirements.txt).

Предлагаемые границы:

- Общий UI на React/TypeScript, локальные assets и одна дизайн-система.
- Узкий типизированный API команд/событий к Rust. Авторизация операций и область доступа проверяются в ядре; произвольный `dispatch(command)` или прямой доступ UI к токенам/SQLite не добавляется.
- `CaptureBackend`: отдельные mic/system/video tracks, общий монотонный таймлайн, обработка потери устройства и корректное завершение файлов.
- `PlatformFs`: атомарные записи, блокировки, приватные права и защита от symlink/junction/reparse-point переходов.
- `WorkerHost`: запуск, отмена и очистка всего дерева процессов; Unix process groups либо Windows Job Objects.
- `CredentialStore`, `CalendarProvider`, `UpdateChannel`, desktop dialogs/shortcuts — платформенные адаптеры.
- ASR worker с общим протоколом и отдельным manifest артефактов для ОС/архитектуры.

[Права Tauri](https://v2.tauri.app/security/capabilities/) помогают ограничить IPC, но не заменяют существующие доменные проверки Posle. Пользовательские материалы и ответы LLM остаются данными, а не разрешением выполнять команды ОС.

## Запись и интеграции ОС

### macOS

Текущая запись использует ScreenCaptureKit/AVFoundation, календарь — EventKit, секреты — Keychain. Эти адаптеры сохраняем или переносим под общий контракт. При переходе проверяем разрешения, идентичность приложения, открытые черновики, обновление с текущего Sparkle и сохранность библиотеки. Не запускаем старый и новый клиенты одновременно на одной живой базе.

### Windows

Микрофон отдельно, системный звук — WASAPI loopback; видео — Windows.Graphics.Capture. Нужны системный выбор источника, обработка изменения размеров/потери устройства, корректное завершение и восстановление записи. Job Objects позволяют контролировать дочерние ASR/ffmpeg процессы. Ключи — Credential Manager либо DPAPI текущего пользователя; зашифрованные таким образом секреты не считаем переносимым экспортом на другой компьютер.

Первый целевой стенд предложен как Windows 11 x64. ARM64 и расширенная аппаратная матрица — после проверки нативных зависимостей. Календарь требует адаптера прямых API провайдеров: универсальную замену EventKit не предполагаем.

Источники: [WASAPI](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording), [Windows screen capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture), [Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects), [Credential Manager](https://learn.microsoft.com/en-us/windows/win32/api/wincred/nf-wincred-credwritew), [DPAPI](https://learn.microsoft.com/en-us/windows/win32/SecCrypto/example-c-program-using-cryptprotectdata).

### Linux

Для Wayland: XDG Desktop Portal ScreenCast → системный выбор источника → PipeWire. Захват микрофона и monitor/system audio проектируем отдельно; разрешение screen portal не считаем разрешением на любой системный звук. Обрабатываем отмену, отзыв доступа, завершение сессии и отключение монитора. XWayland не предоставляет доступ ко всему Wayland desktop.

Qt также зависит от portal/PipeWire; официальные ограничения QScreenCapture называют Wayland-путь экспериментальным. Поэтому выбор Qt не снимает риск записи. Secret Service — адаптер секретов с явной обработкой заблокированного или отсутствующего keyring. Горячие клавиши на Wayland зависят от возможностей GlobalShortcuts portal и окружения.

Первый предложенный стенд: Ubuntu LTS x86_64, GNOME/Wayland. KDE/Wayland — отдельная обязательная проверка перед объявлением поддержки. Не обещаем поддержку «любого Linux» на основании успешной сборки одного AppImage.

Источники: [ScreenCast portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html), [Qt screen capture](https://doc.qt.io/qt-6/qscreencapture.html), [Secret Service](https://specifications.freedesktop.org/secret-service/latest-single/), [GlobalShortcuts](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html).

## Локальные модели

Нынешние defaults, Python host, FFmpeg и загрузка Ollama привязаны к macOS-артефактам. В проекте уже есть ONNX-ветки. Для первого переносимого прототипа проверяем ONNX CPU; затем добавляем и измеряем отдельные ускорители. CPU-baseline не является обещанием скорости распознавания в реальном времени.

MLX уже документирует Linux CPU и CUDA. Нельзя писать, что MLX исключительно Mac-only; это не доказывает совместимость нашего закреплённого parakeet-mlx и embedded-runtime. Для Windows MLX-поддержку не предполагаем без отдельного подтверждения.

Источники: [MLX installation](https://github.com/ml-explore/mlx#installation), [ONNX providers](https://onnxruntime.ai/docs/execution-providers/).

## Поставка и обновления

Каждая ОС получает собственный артефакт и канал обновления. Для Windows возможен подписанный installer; подпись обновления Tauri и Authenticode решают разные задачи. На Linux сначала проверяем .deb/AppImage, Flatpak — отдельно после проверки MCP stdio, локальных папок и моделей внутри sandbox. Package-managed установку обновляет её пакетный менеджер, а не второй конкурирующий updater. Подпись Tauri updater обязательна.

Источники: [Tauri Windows installer](https://v2.tauri.app/distribute/windows-installer/), [Windows signing](https://v2.tauri.app/distribute/sign/windows/), [Updater](https://v2.tauri.app/plugin/updater/), [AppImage](https://v2.tauri.app/distribute/appimage/), [Flatpak permissions](https://docs.flatpak.org/en/latest/sandbox-permissions.html), [Qt licensing](https://doc.qt.io/qt-6/licensing.html).

## Прототип и критерий решения

1. Выделить platform-fs/process interfaces и собрать Rust на трёх ОС в CI, сохранив тесты приватности, CAS, восстановления и MCP.
2. Общий UI открывает изолированную тестовую библиотеку: папки, заметка, транскрипт и задача. Проверяем редактор, IME, меню, фокус, keyboard navigation, доступность и большие списки.
3. На каждой ОС выполнить полный путь: экран + микрофон + system audio → распознавание → конспект → поиск → действие через MCP.
4. Проверить 30–60 минут записи, статичный экран, смену устройств, sleep/resume, отмену разрешения, прерывание worker и восстановление файлов. Звук собеседника через динамики может попадать в микрофон: источник дорожки сам по себе не доказывает личность говорящего.
5. Проверить обновление с активной записью/черновиком и миграцию копии библиотеки. Измерить отзывчивость UI, память и скорость распознавания на реальных стендах.
6. По результатам закрыть найденные ограничения Tauri и платформенных адаптеров до объявления готовности каждой ОС. Qt остаётся запасным вариантом при подтверждённом блокере webview.

До прохождения прототипа сохраняем рабочий Mac-клиент. Это временная стратегия перехода к одной UI-кодовой базе, а не предложение постоянно содержать три разных интерфейса. Синхронизация устройств и логический импорт/экспорт библиотеки остаются отдельными задачами.
