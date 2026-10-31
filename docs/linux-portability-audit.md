# Linux / Arch: аудит переносимости и архитектуры

Срез: 31 октября 2026, `feat/increase-multiplatform-support`, исходный код
`9e510e6`. Это исследование текущей реализации и предложение границ рефакторинга,
а не заявление о готовности Linux-клиента. Ниже зафиксировано состояние до реализации;
текущие изменения и команды описаны в [Linux-инструкции](linux.md).

## Цель и критерий архитектуры

Полный пользовательский сценарий должен работать в Tauri на Arch Linux,
при сохранении macOS/Windows. Общие бизнес-правила не должны зависеть от ОС,
Tauri, SwiftUI, конкретной БД, загрузчика CPython или системного хранилища ключей.

Связи между компонентами допустимы через явные контракты с одним направлением
зависимостей. Нужны независимые границы ответственности, отсутствие циклов между
слоями и подстановка адаптеров. Изоляция не означает отсутствие всех зависимостей
между доменными сущностями или отдельный trait для каждой функции.

## Что уже подтверждено

- Среда аудита: Arch Linux x86_64; Python 3.14.7, Node 26.10.0. GTK3 и OpenSSL
  доступны через `pkg-config`; `webkit2gtk-4.1` отсутствует. PipeWire,
  WirePlumber и xdg-desktop-portal установлены. Работа устройств и portal backend
  в графической сессии не проверялась.
- В предыдущем прогоне этой сессии после rebase прошли 418 тестов Rust-библиотеки,
  4 теста CLI, сборка frontend и 7 frontend-тестов. Это не native WebView E2E.
- Во время аудита повторно выполнены 3 существующих Rust-теста
  `desktop::features::tests`: задачи, карточки/повторения и ограничения команд
  проходят на Linux. Полные наборы повторно не запускались.
- Установка зависимостей, запись, распознавание, графический запуск и упаковка
  Linux-приложения в рамках аудита не выполнялись.

## Карта ограничений по компонентам

### L01. Сборка оболочки и локальная среда

**Подтверждённый локальный блокер:** отсутствует WebKitGTK 4.1. Наличие рабочего
React/Vite и успешных core-тестов не подтверждает сборку/запуск Tauri-host.

Зависимости host: [Cargo.toml](../desktop/src-tauri/Cargo.toml),
конфигурация сборки: [tauri.conf.json](../desktop/src-tauri/tauri.conf.json).
Нативное воспроизведение, custom protocol, диапазоны медиа, фокус, IME и
закрытие окна требуют отдельной проверки в Linux WebView.

**Граница:** системные зависимости описываются в Linux setup/CI; логика UI и
домена не должна знать имена пакетов дистрибутива.

### L02. Возможности ошибочно привязаны к названию ОС

В [bridge.rs](../desktop/src-tauri/src/bridge.rs#L77) `workspace()` выставляет
`import`, `recording`, `tasks`, `cards` через `cfg!(windows)`. На Linux все четыре
возможности выключены. [App.tsx](../desktop/src/App.tsx#L352) скрывает элементы UI
по этим флагам. Для задач и карточек реализация общего ядра уже работает на Linux.

Есть три источника сведений: capability-флаги в
[desktop.rs](../rust-core/src/desktop.rs#L236), их переопределение в host и
[desktop_platform.rs](../rust-core/src/desktop_platform.rs), где запись всё ещё
обозначена как `not_connected`. Сообщения расходятся с Windows-реализацией.

**Граница:** отделить реализованность функции, наличие системного адаптера,
доступность runtime, пользовательские feature flags и разрешения. Вычислять
возможности из этих данных, не из одного имени ОС. Доменную авторизацию сохранить.

### L03. Импорт файлов ограничен Windows в host

[lib.rs](../desktop/src-tauri/src/lib.rs#L65) вызывает `rfd::FileDialog` только под
`cfg(windows)`; остальным ОС возвращает `unsupported_platform`. Сам `rfd` включён
только в Windows dependencies. Общий
[desktop_import.rs](../rust-core/src/desktop_import.rs) уже выполняет копирование,
публикацию метаданных, блокировки и восстановление незавершённых импортов.

**Граница:** адаптер выбора файла передаёт разрешённый источник application-слою.
Renderer по-прежнему не получает право задавать произвольный путь. Ручной разбор
длительности WAV в importer не заменяет общий media probe для остальных форматов.

### L04. Запись и разрешения

[capture.rs](../desktop/src-tauri/src/capture.rs#L81) явно запрещает запись вне
Windows. Единственная Tauri-реализация захвата —
[capture/windows.rs](../desktop/src-tauri/src/capture/windows.rs), WASAPI.
Запись экрана в preview отсутствует. Mac-реализация находится отдельно в
[Recording.swift](../Sources/PosleApp/Recording.swift) и
[MicrophoneCapture.swift](../Sources/PosleApp/MicrophoneCapture.swift), зависит от
ScreenCaptureKit/AVFoundation и не подключена к Tauri.

**Граница:** общий жизненный цикл записи, временная шкала, остановка и восстановление;
отдельные реализации микрофона, системного звука и видео. Для Linux требуется
исследование/прототип соответствующих PipeWire/portal-адаптеров и матрица графических
окружений. Наличие установленных пакетов не подтверждает корректность захвата.

При переносе проверить эквивалентность защиты файлов:
[capture/guard.rs](../desktop/src-tauri/src/capture/guard.rs#L37) на Unix использует
`symlink_metadata` и последующий `File::open`, тогда как Windows держит handles
без разрешения удаления. Семантика защиты от подмены требует отдельной проверки;
это не установленная эксплуатационная уязвимость.

### L05. CPython: закреплён конкретный Mac-runtime

[python-runtime.json](../backend/python-runtime.json#L4) описывает только
`aarch64-apple-darwin`. [python_runtime.rs](../rust-core/src/python_runtime.rs#L271)
обязательно ожидает `lib/libpython3.12.dylib`; та же форма зашита в
[pin_python_runtime.py](../scripts/pin_python_runtime.py#L86).
Загрузка через `/dev/fd` и проверка загруженного образа требуют Linux-валидации.

[embedded_speech.rs](../rust-core/src/embedded_speech.rs#L30) вручную описывает
`PyConfig` CPython 3.12 для macOS. Успешный тест размера структуры на Linux не
доказывает корректность реальной инициализации Linux CPython. Дополнительный
[python_host.rs](../rust-core/src/python_host.rs) использует тот же verifier.

[setup.sh](../backend/setup.sh#L14) требует `uname -m == arm64` и использует
macOS-инструменты/ключи: `plutil`, `lockf`, BSD `stat`. Замены URL недостаточно.

**Граница:** каталог артефактов по OS/arch, проверка runtime, установка с откатом и
отдельный Python host. Системный Python Arch 3.14 не является заменой закреплённому
runtime 3.12. Сохранить проверку целостности до исполнения загруженных компонентов.

### L06. ASR-модели, FFmpeg и локальный LLM-runtime

- [requirements.txt](../backend/requirements.txt) безусловно включает
  `parakeet-mlx`; [models.py](../backend/models.py#L20) предлагает по умолчанию
  MLX-модели. ONNX-ветки уже есть в `engine.py`/`models.py`, но полный Linux-путь
  установки и инференса не подтверждён. Нужны platform/backend-specific manifests;
  здесь не делается утверждение о поддержке всех платформ самим MLX.
- [media.rs](../rust-core/src/media.rs#L15) загружает исключительно
  `ffmpeg-macos-aarch64-v7.1` из macOS ARM64 wheel. На Linux этот путь не даст
  исполняемый Linux FFmpeg, хотя модуль компилируется под `cfg(unix)`.
- [engine.py](../backend/engine.py#L213) устанавливает `ollama-darwin.tgz`.
  Запуск и сопровождение managed LLM частично реализованы в
  [Services.swift](../Sources/PosleApp/Services.swift#L279).
- `fcntl`, POSIX permissions и process groups в Python переносимы в рамках
  Unix-семейства, но мешают цели общего Windows/Linux/macOS runtime без адаптеров.

**Граница:** `SpeechBackend`, каталог моделей/артефактов, `MediaRuntime` и
`LocalModelHost`. HTTP-провайдеры из Rust можно переиспользовать, подключив
настройки/секреты/очередь. Выбор способа поставки Linux FFmpeg и ускорителей
остаётся отдельным решением; не отключать проверки ради первого запуска.

### L07. Очередь и управление процессами

[jobs.rs](../rust-core/src/jobs.rs) хранит состояния в SQLite, но исполнитель,
admission, ограничение ресурсов, наблюдение и часть отмены живут в Swift actor
[JobCoordinator](../Sources/PosleApp/BackgroundJobs.swift#L116). Там же находится
macOS sleep inhibitor через IOKit. Это общая orchestration-логика внутри Mac-клиента.

[worker.rs](../rust-core/src/worker.rs#L141) знает структуру `.app/Contents/Helpers`,
запускает `setup.sh` через `/bin/bash`, управляет Unix process groups/signals.
Tauri [bridge.rs](../desktop/src-tauri/src/bridge.rs#L408) рассчитан на ограниченный
request/response: новый процесс на запрос, лимиты, timeout, `child.kill()`.
Он не предоставляет готовый контракт потокового progress/cancel для полной очереди;
его environment allowlist рассчитан на текущие операции библиотеки.

**Граница:** общий application scheduler + `WorkerHost`/`ProcessSupervisor`,
отдельный `ResourceLocator` и `SleepInhibitor`. Контракты должны сохранять отмену
дерева процессов, ревизии входов и явное разрешение повтора платных запросов.

### L08. Секреты, OAuth, календарь и интеграции

- [Services.swift](../Sources/PosleApp/Services.swift#L207): Keychain через
  Security.framework; общего хранилища секретов в Tauri нет.
- [ChatGPTAccount.swift](../Sources/PosleApp/ChatGPTAccount.swift): OAuth,
  браузерный вход, callback, проверка токенов и refresh с Keychain частично в Swift.
  `rust-core/chatgpt.rs` не заменяет этот клиентский жизненный цикл.
- [CalendarStore.swift](../Sources/PosleApp/CalendarStore.swift#L133): EventKit
  и macOS Internet Accounts. Linux-календарный адаптер отсутствует.
- [TrackerSyncCoordinator.swift](../Sources/PosleApp/TrackerSyncCoordinator.swift):
  таймер, авторизация/refresh и Keychain в Swift; провайдерские операции есть в Rust.

**Граница:** независимые контракты `CredentialStore`, OAuth/session service,
`CalendarProvider`, application coordinator синхронизации. Выбор Linux-хранилища
секретов и календарных источников ещё требуется. Нельзя переносить токены в renderer
или заменять защищённое хранилище обычным JSON.

### L09. Неполный перенос функциональности интерфейса

[api.ts](../desktop/src/api.ts) и [desktop.rs](../rust-core/src/desktop.rs#L429)
предоставляют ограниченный desktop API. Семантический поиск, помощник, очередь,
голосовые действия, трекеры, управление MCP и полные настройки моделей не подключены
к новому UI/API. Это отдельная работа даже для функций, чей Rust-код уже компилируется.
MCP CLI на Unix следует оценивать отдельно от его настройки в Tauri.

Заметки в desktop API содержат plain text; Mac использует RTF/AppKit
([RichNoteEditor.swift](../Sources/PosleApp/RichNoteEditor.swift)). OCR выполняется
через Apple Vision в [NotesStore.swift](../Sources/PosleApp/NotesStore.swift#L192).
Полные вложения, редактирование источников, профили папок, расширенные задачи и
карточки, импорт/экспорт, корзина и темы требуют отдельных срезов паритета.

**Граница:** перечень пользовательских сценариев и общие use cases/DTO; OS-вызовы
за портами. Не выдавать включение кнопок за достижение паритета со Swift-клиентом.

### L10. Поставка и тестирование

[build.sh](../scripts/build.sh) и [package.sh](../scripts/package.sh) предназначены
для Mac: Swift, `.app`, codesign, Sparkle, pkgbuild. Tauri-конфигурация сейчас
упаковывает staged engine, но не весь speech/backend runtime. Linux поставка полного
приложения не описана; `targets: all` не решает состав ресурсов и системные зависимости.
Updater есть в [AppUpdateController.swift](../Sources/PosleApp/AppUpdateController.swift),
но отсутствует в зависимостях/инициализации Tauri.

[stage-desktop-engine.py](../scripts/stage-desktop-engine.py) уже понимает target
triple. Проверка формата/архитектуры staged executable реализована специально для
Windows; аналогичная Linux-проверка и smoke упакованного продукта не настроены.

[verify.py](../scripts/verify.py) начинает `quick` со Swift и использует
`/private/tmp`; часть Python-тестов тоже зависит от этого пути/macOS.
В предыдущем прогоне 14 ошибок scripts были связаны с отсутствующим `/private/tmp`,
12 backend-ошибок — с отсутствующим NumPy. Это результаты среды, не доказательство
регрессий приложения. Совместимость закреплённых ML-зависимостей с текущим Arch
Python не проверена.

[desktop.yml](../.github/workflows/desktop.yml) содержит Ubuntu host-tests,
но полный build/test/staging ядра и real-engine-интеграции там запускаются только
на macOS. Windows имеет отдельный installer workflow. Arch job и Linux installed
WebView/media smoke отсутствуют. Push-фильтры desktop/workflows ограничены старыми
`codex/...` ветками; PR-проверки по путям настроены отдельно.

## Архитектурные зависимости, которые стоит исправить

### A01. Циклы вокруг workspace, recovery и persistence

Подтверждённые production-ссылки, не только импорты тестов:

```text
notes -> workspace_repository -> notes
notes -> corrections -> notes
workspace_repository -> corrections -> workspace_repository
```

Примеры: [notes.rs:128](../rust-core/src/notes.rs#L128),
[workspace_repository.rs:162](../rust-core/src/workspace_repository.rs#L162),
[workspace_repository.rs:636](../rust-core/src/workspace_repository.rs#L636),
[corrections.rs:203](../rust-core/src/corrections.rs#L203).
`notes` одновременно содержит модели/валидацию, файловые helpers и операции;
repository вызывает их обратно и инициирует recovery.

**Направление:** выделить workspace-модель и чистую валидацию; application use case
владеет порядком recovery/lock/transaction; storage-реализация исполняет контракт
репозитория. Атомарность совместных изменений заметок, задач и источников сохранить:
механическое разнесение на независимые repositories может её разрушить.

### A02. Доменные типы зависят от runtime-модуля AI

[folders.rs:36](../rust-core/src/folders.rs#L36) использует `crate::ai::AppFeatures`,
а `ai_config` обращается к folders и filesystem. На Windows `lib.rs` подменяет модуль
`ai` реэкспортом конфигурации. Зависимость `folders -> ai -> ai_config -> folders`
смешивает расположение типов и выполняемых сервисов.

**Направление:** вынести общие типы настроек, возможности и чистое разрешение
профилей в независимый модуль; чтение настроек и проверка актуальности — use cases
через repository. AI-провайдеры не должны владеть типами, нужными задачам и папкам.

### A03. Общий core пока не является чистым доменным слоем

`ai.rs` объединяет бизнес-правила конспекта, HTTP, файлы, блокировки и импорт GGUF.
В `storage.rs` соседствуют файловый I/O и FSRS scheduling. POSIX-вызовы остаются в
`semantic`, `knowledge`, `code_index`, `tracker_sync`, `voice`, `trash` и других
модулях, хотя часть уже вынесена в `platform_fs`. `cfg(unix)` разрешает компиляцию
на Linux, но не гарантирует переносимость используемого runtime.

**Направление:** чистые правила/сущности, use cases, порты и инфраструктурные адаптеры.
Оставить `platform_fs` отправной точкой; не удалять `O_NOFOLLOW`, приватные права,
блокировки и проверки ревизий ради уменьшения платформенного кода.

### A04. Границы API и тестов пока не закрепляют слоистость

Между React, Tauri DTO и Rust desktop API есть ручные повторения моделей/имён команд.
Расширение каждой функции затрагивает frontend, allowlist, host, capabilities и core
dispatch. Бизнес-операции часто принимают `Path` и `serde_json::Value`, совмещая
транспортную валидацию, правила и persistence. Есть хорошие typed DTO и запреты
произвольных команд, которые следует сохранить.

**Направление:** типизированные use-case контракты и transport mapping по краям;
интерфейсы, достаточно узкие для конкретного потребителя (ISP). Адapters выбираются
в composition root. Границы можно сначала закрепить модулями/visibility, затем при
необходимости отдельными crates и CI-проверками зависимостей. Полная перепись и
сеть микросервисов для этого не нужны.

## Предлагаемое направление зависимостей

```text
React UI -> typed desktop API -> application use cases -> domain
                                      |
                              ports / contracts
                                      ^
              storage / HTTP / OS / speech adapters

Tauri composition root выбирает и соединяет конкретные реализации.
```

SRP: разделить policy, orchestration и механизмы. DIP: use cases зависят от
контрактов, адаптеры их реализуют. OCP: новый backend подключается без правки домена.
ISP: отдельные контракты capture, credentials, repository, worker вместо одного
«PlatformService». LSP: общие контрактные тесты на одинаковые гарантии реализации;
различия возможностей объявляются явно.

## Очерёдность следующей работы

1. Зафиксировать матрицу пользовательских сценариев macOS/Tauri/Windows/Linux и
   исходные тесты. Уточнить целевые Wayland/X11 окружения и оборудование Arch.
2. Запустить Linux host и real-engine smoke на временной библиотеке; закрыть
   зависимости сборки и подключить Linux CI к текущей ветке/PR.
3. Исправить модель capabilities; включить подтверждённые общие tasks/cards;
   подключить Linux file picker и проверить импорт/проигрывание в WebView.
4. Выделять application/domain/config и разрывать подтверждённые циклы небольшими
   шагами, сохраняя транзакции и тесты. Ввести порты инфраструктуры по потребности.
5. Перенести scheduler, worker lifecycle, manifests CPython/FFmpeg/model runtime;
   затем пройти запись -> распознавание -> конспект -> поиск с отменой/восстановлением.
6. Довести интерфейс и интеграции до согласованного паритета; проверить Linux-поставку,
   миграции и обновление. Контрактные и native E2E запускать на каждой целевой ОС.

Порядок — предложение по результатам аудита. Конкретные библиотеки Linux-адаптеров,
способ поставки и сроки ещё не выбраны.
