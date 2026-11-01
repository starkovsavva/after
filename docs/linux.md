# Разработка на Arch Linux

Текущий Linux-срез Tauri: библиотека, заметки, папки, задачи/карточки и импорт медиа.
Запись Linux, ASR, конспектирование, календарь и полный паритет со Swift-клиентом
ещё находятся в плане: [этапы](linux-implementation-plan.md), [аудит](linux-portability-audit.md).

## Подготовка

Нужны Rust stable, Node 24+, npm, Python 3, C/C++ toolchain и pkg-config.
Для существующего Tauri-host требуется именно GTK3/WebKitGTK 4.1:

```sh
sudo pacman -S --needed base-devel pkgconf rust nodejs npm python webkit2gtk-4.1
pkg-config --modversion gtk+-3.0 webkit2gtk-4.1 openssl
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
и helper), 620 core (1 performance probe ignored) + 2 CLI, frontend build + 7 tests, 29 host + 7 real-engine
интеграции + 1 настоящий Tauri IPC-сценарий. Отдельно прошли 13 Playwright-сценариев. Проверен native WebView startup с
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
native `Run` выполняет import внутри lifetime lease; native connection startup сверяет receipts без запуска работы; UI binding ещё не подключён
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

Импорт использует [WorkerHost](decisions/worker-host-import.md): progress, отмена до
публикации и восстановление панели после reload WebView. Это ещё не durable queue.

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
