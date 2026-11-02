# Разработка на Arch Linux

Текущий Linux-срез Tauri: библиотека, заметки, папки, задачи/карточки и импорт медиа.
Микрофон Linux реализован через локальный PulseAudio/PipeWire-Pulse. Системное аудио, ASR, конспектирование, календарь и полный паритет со Swift-клиентом
ещё находятся в плане: [этапы](linux-implementation-plan.md), [аудит](linux-portability-audit.md).

## Подготовка

Нужны Rust stable, Node 24+, npm, Python 3, C/C++ toolchain и pkg-config.
Для существующего Tauri-host требуется именно GTK3/WebKitGTK 4.1:

```sh
sudo pacman -S --needed base-devel pkgconf rust nodejs npm python webkit2gtk-4.1 libpulse
pkg-config --modversion gtk+-3.0 webkit2gtk-4.1 openssl libpulse
cd desktop
npm ci --ignore-scripts
cd ..
```

`webkitgtk-6.0` не предоставляет `webkit2gtk-4.1.pc` для этой сборки.
Для выбора файлов нужна рабочая desktop-сессия с реализацией системного диалога;
Linux rfd использует portal backend. Наличие пакета portal не подтверждает работу
конкретного графического окружения. Поддержку медиа/кодеков проверяйте отдельно.

## Проверки и запуск

```sh
python3 scripts/verify.py desktop
cargo build --manifest-path rust-core/Cargo.toml --locked --target-dir .build/rust
python3 scripts/stage-desktop-engine.py
cd desktop
AFTER_DATA_DIR=/absolute/path/to/disposable-library npm run tauri dev
```

Профиль `desktop` не запускает Swift: реальные process-tree тесты, Rust-регрессия, build движка, frontend build/tests,
host tests и ignored интеграции настоящего engine через transport и Tauri IPC.
Он не заменяет графический smoke и не захватывает устройства. В CI Ubuntu также
проходят browser-интеграции; это отдельный уровень проверки от Linux WebView.

Стадируйте движок заново после изменений ядра и пересобирайте host: digest встроен
при сборке. Не подключайте живую библиотеку Mac-клиента. Preview сохраняет свою
библиотеку `app.posle.desktop`. Для сборки release engine обязателен в resources.

## Архитектурные границы

Общие настройки, модели workspace/задач и их валидация находятся в `rust-core/src/domain/`
без I/O и runtime. `scripts/check_layers.py` запрещает зависимости domain от внешних
модулей и системных библиотек; это source-level guard, не полный Rust dependency parser.
`ai_config` отвечает за чтение/разрешение профилей и пока относится к application/
infrastructure, а не к чистому domain. File picker изолирован в host `platform.rs`.
Engine объявляет общие tasks/cards; host дополняет capabilities своими адаптерами.
Запись доступна только там, где реализован capture backend.

## Автономная debug-сборка и native smoke

```sh
cd desktop
CARGO_TARGET_DIR="$PWD/../.build/tauri" npm run tauri -- build --debug --no-bundle --features custom-protocol
cd ..
python3 scripts/check-desktop-linux.py --app .build/tauri/debug/After --receipt .build/linux-native-smoke.json
```

Для автономной debug-сборки нужен `custom-protocol`; без него приложение ожидает
Vite dev server. Smoke запускает настоящее окно в графической сессии, проверяет
инициализацию canonical SQLite через UI/IPC/встроенный engine и завершает процесс.
Данные временные, личная библиотека не используется. Это проверка старта, не полный
UI-сценарий и не проверка нормального закрытия окна пользователем.
`AFTER_WEBVIEW_DIAGNOSTICS=1` включает консоль WebView и коды ошибок host только
в debug; не включайте её при работе с личными материалами.

## Подтверждённый срез

Локально на Arch прошли portable-профиль: 7 process-runtime entries (6 сценариев
и helper), 661 core (1 performance probe ignored) + 2 CLI, frontend build + 7 tests, 60 host + 10 real-engine
интеграции + 1 настоящий Tauri IPC-сценарий. Отдельно прошли 18 Playwright-сценариев. Проверен native WebView startup с
bundled engine. IPC-сценарий импортирует синтетический файл и читает диапазон медиа;
host-регрессия проверяет cleanup потомка с открытыми pipes. Диалог выбора файла,
кодеки и физические устройства этим не проверены. Удалённые workflows настроены,
но их прогон в этой сессии не выполнялся.

Workspace use cases теперь координируются в `application/workspace.rs` через
`WorkspaceRepository`, `WorkspaceLocks`, `WorkspaceRecovery`. SQLite, файловые lock
и journal recovery находятся в `infrastructure/`; корневые modules сохраняют API
и соединяют реализации. Порядок блокировок и общая транзакция сохранены.
Решение и ограничения: [ADR](decisions/workspace-boundaries.md).

Модель и чистые политики очереди находятся в `domain/jobs.rs`; SQLite queue adapter
в `infrastructure/job_queue.rs` использует общий `platform_fs` вместо Unix API.
Этот storage-срез включён в Windows core tests, но Windows-прогон локально не выполнен.
Типизированные enqueue/claim/update/cancel/retry/recover выполняет `application/jobs.rs`
через transaction/clock/ID порты; `jobs.rs` сохраняет Swift/CLI JSON API. Snapshot
читает jobs/count/account pauses в одной read-транзакции. Swift пока управляет
живыми заданиями. Native Tauri queue port использует scoped `desktop-import` очередь;
native `Run` выполняет import внутри lifetime lease; native connection startup сверяет receipts без запуска работы; выбор файла в UI использует durable controller
([ADR](decisions/scoped-executors.md)). Подробности: [границы очереди](decisions/job-queue-boundaries.md).

Engine worker и Tauri transport используют общий `process-runtime/` для владения
дочерними процессами. Linux timeout/error/Drop и normal parent exit останавливают
остаток приватной process group; потомки больше не удерживают transport pipes.
Это не полный queue executor и не sandbox; ограничения описаны в
[process supervision ADR](decisions/process-supervision.md).

Общие правила live coordinator находятся в `domain/job_runtime.rs`: transient state
и events возвращают decisions без I/O. Swift actor подключён через `NativeJobRuntime`;
проверены Rust state machine, SQL effects и настоящий JSON C ABI. Это ещё не Tauri
executor: native Swift suite запускается только на Mac (`verify.py queue`), локально
он не выполнен. Контракт и оставшиеся этапы: [ADR](decisions/live-job-coordinator.md).

Выбор файла использует [durable controller](decisions/queued-import-controller.md):
progress, отмена до публикации и восстановление панели после reload WebView.
Панель истории загружает импорты страницами по 50 и позволяет явный retry/cancel после
перезапуска host; startup probe сверяет receipts без запуска работы
([ADR](decisions/import-history-and-resume.md)). [Пагинация](decisions/import-history-pagination.md) использует неизменяемый creation key; Refresh получает новые записи. Сохранение и восстановление recordings используют [durable queue](decisions/durable-recording-import.md),
со стабильной capture identity и receipt check до WAV repair. `recordingRecovery`
доступен на Linux независимо от физического capture backend; Recorder использует [CaptureBackend port](decisions/capture-backend-port.md); PipeWire/portal запись ещё не реализована.

Native queue соединение удерживает [kernel lease](decisions/import-executor-lease.md).
Проверены конкурирующие owner-процессы и освобождение lock после аварийного exit.

Интеграция main 0.18.2 сохраняет новые knowledge/agent-сценарии и переносимые
слои ([решение и ограничения](decisions/main-0182-integration.md)). Snapshot MCP
и knowledge rebuild проверены через реальные CLI/C ABI на синтетических данных.
Swift-компилятор и Windows target здесь отсутствуют: source checks не заменяют
native сборку этих платформ.

[Owned import execution](decisions/owned-import-execution.md) связывает queue claim,
worker thread, cancellation/join и точный receipt. Проверен повтор после publication
без исходного файла: копия не создаётся заново, чужой receipt token отклоняется.

## Микрофон Linux

Адаптер `capture/linux.rs` использует асинхронный libpulse на worker thread.
Нужен работающий локальный PulseAudio или PipeWire-Pulse: по умолчанию
`$XDG_RUNTIME_DIR/pulse/native`; `PULSE_SERVER` поддерживается только как
`unix:/absolute/path`. Capability проверяет socket, доступность входа проверяется
при явном старте записи. Default source должен быть микрофоном, не monitor.
Смена источника, overflow или разрыв сервера прерывают запись и сохраняют WAV;
автоматического переключения устройства нет. Системное аудио пока недоступно.

Проверка настоящего SDK без физических устройств:

```sh
sudo pacman -S --needed pipewire libpulse
python3 scripts/check-linux-microphone.py --scenario capture
python3 scripts/check-linux-microphone.py --scenario disconnect
python3 scripts/check-linux-microphone.py --scenario monitor
```

Fixture создаёт отдельный сервер и виртуальный источник без hardware modules,
проверяет PCM и canonical queued import, сохранение после отключения и отказ
monitor. Физический микрофон, задержка и конкретные desktop-сессии требуют
отдельной проверки с разрешением пользователя. [Решение](decisions/linux-microphone.md).

## Подготовка переносимого Python runtime

`infrastructure/runtime_tree.rs` проверяет полный trusted inventory на Unix:
SHA-256, ownership/mode, отсутствие лишнего кода, symlink substitution и metadata
recheck. Layout и manifest выбирает вызывающий адаптер. macOS сохраняет свой pinned
CPython и загрузчик; тесты Linux не исполняют скачанный или системный Python.

```sh
cargo test --manifest-path rust-core/Cargo.toml --locked --target-dir .build/rust --lib runtime_tree
```

21 synthetic contract покрывает ELF-style inventory и существующий macOS
venv/descriptor binding. Linux x86_64 GNU CPython 3.12.16 теперь закреплён отдельным manifest и проверяется
через native verifier. Native generation installer теперь создаёт и атомарно активирует CPython/venv;
speech dependencies и сквозная очередь ASR ещё нужны.
[Граница verifier/loader](decisions/runtime-inventory-boundary.md).

## Настоящий закреплённый CPython

`backend/python-runtime-linux-x86_64.json` содержит полный inventory официального
Python build standalone 3.12.16 (`20261026`, x86_64 GNU). Архив закреплён по размеру
и SHA-256; native verifier использует только скомпилированный manifest.

```sh
python3 scripts/check-linux-python-runtime.py --download
# Либо без сети, с ранее скачанным архивом:
python3 scripts/check-linux-python-runtime.py --archive /absolute/path/python.tar.gz
python3 scripts/pin_python_runtime.py --archive /absolute/path/python.tar.gz --policy backend/python-runtime-linux-x86_64.json --check
```

Fixture сначала проверяет архив и дерево, затем запускает CPython/SSL и создаёт
изолированный venv без pip. Проверяет exact version/prefix, отсутствие изменений
в base после venv и отказ после tampering. Все данные временные; речь и модели не
загружаются. Реальный `--download` путь проверен на Arch; CI настроен, удалённый
прогон пока не подтверждён. Остальные Linux targets пока не имеют pinned policy.
[Происхождение и ограничения](decisions/linux-pinned-cpython.md).

## Установка CPython и venv отдельным поколением

Нативный установщик работает с уже существующим owned absolute root. Для проверки
используйте disposable library; полноценная speech-ready установка ещё не подключена.

```sh
AFTER_RUNTIME_TEST_ROOT="$(mktemp -d /tmp/after-runtime-install.XXXXXX)"
.build/rust/debug/posle-engine --posle-install-python-runtime --root "$AFTER_RUNTIME_TEST_ROOT" --archive /absolute/path/python.tar.gz
# Явный сетевой вариант вместо --archive:
.build/rust/debug/posle-engine --posle-install-python-runtime --root "$AFTER_RUNTIME_TEST_ROOT" --download
```

`runtime/linux-python/<generation>/` содержит проверенный readonly base и отдельный
venv, созданный сразу по окончательному пути. После проверки exact version/prefix
и SSL установщик sync-ит поколение и атомарно заменяет `active.json`. До публикации
ошибки удаляют только собственный candidate; previous generation остаётся доступным.
При неопределённом подтверждении после rename сохраняются оба поколения. Фиксированный
`.install.lock` удерживается до завершения; никогда не удаляйте его для разблокировки.
Прежние и неизвестные interrupted generations автоматически не очищаются.

`check-linux-python-runtime.py --download` проверяет и Rust HTTPS installer, и local
archive install, отказ повреждённого архива, сохранение предыдущего executable и
повторную активацию. Установщик не пишет `ready-v2`, не ставит pip/packages/models
и не означает готовность ASR. [Протокол установки](decisions/linux-runtime-generations.md).

## Выбор активного поколения перед обработкой

```sh
.build/rust/debug/posle-engine --posle-check-python-runtime --root "$AFTER_RUNTIME_TEST_ROOT"
```

Команда читает ограниченный `active.json`, проверяет canonical UUID v4, target,
точную версию и фиксированный путь interpreter внутри поколения. Затем проверяет
полный base inventory и `pyvenv.cfg`/alias chain через общий Unix `runtime_venv.rs`.
Путь из receipt не становится разрешением запустить произвольный Python.

Native `validate_active()` возвращает guard с `recheck()`; его нужно держать до
завершения процесса. Новый active pointer влияет на последующие выборы и не
обесценивает уже выбранное поколение. Real fixture теперь проверяет pointer/config/
alias redirect и удержание настоящего поколения во время atomic pointer update.
Он запускает opt-in Rust contract с feature `linux-runtime-fixture`.

Проверка не подтверждает происхождение third-party packages и не запускает ASR.
Текущий `worker.rs` ещё использует старый Darwin launch path: подключение Linux
execution adapter и speech-зависимостей остаётся следующим этапом.
[Решение](decisions/active-runtime-selection.md).
