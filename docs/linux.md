# Разработка на Arch Linux

Текущий Linux-срез Tauri: библиотека, заметки, папки, задачи/карточки и импорт медиа.
Микрофон Linux реализован через локальный PulseAudio/PipeWire-Pulse. CLI ASR на CPU с явно выбранной managed-моделью проверен на синтетической английской речи. Системное аудио, ASR через Tauri, конспектирование, календарь и полный паритет со Swift-клиентом
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
и helper), 664 core (1 performance probe ignored) + 2 CLI, frontend build + 7 tests, 60 host + 10 real-engine
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

Synthetic contracts покрывают ELF-style inventory и существующий macOS
venv/descriptor binding. Linux x86_64 GNU CPython 3.12.16 теперь закреплён отдельным manifest и проверяется
через native verifier. Native generation installer теперь создаёт и атомарно активирует CPython/venv;
CPU speech dependencies, managed Parakeet и native durable ASR queue реализованы ниже;
Tauri host binding, упаковка backend и UI ещё нужны.
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
Worker теперь выбирает launch через platform composition и исполняет проверенный
Linux CPython. Optional Linux CPU dependency profile теперь доступен; managed Parakeet и настоящая CLI ASR-обработка реализованы ниже. Интеграция очереди Tauri остаётся следующим этапом.
[Решение](decisions/active-runtime-selection.md).

## Speech launch и общий supervisor

`application/speech_launch.rs` задаёт executable/arguments и удерживаемый runtime
guard. Linux-адаптер выбирает active generation, общий `worker.rs` повторно проверяет
guard перед spawn и удерживает его до завершения процесса. Аргументы job и фильтрация
credentials/progress остаются общими. Darwin helper/setup и bundle layout вынесены
в platform adapters. `install-runtime` на Linux пока явно отказывает до подключения подготовки моделей.
Native installer поддерживает отдельный CPU dependency profile.

Real runtime fixture теперь запускает synthetic `engine.py` через настоящую CLI
`prepare`, проверяет venv/prefix, resource import, Python flags и удаление synthetic
секретов. Затем отменяет долгий worker с потомком, игнорирующим SIGTERM, и проверяет
их остановку. Это тест launch/supervision; аудио/ASR-модели не используются.
[Архитектурная граница](decisions/speech-launch-port.md).

## Linux CPU speech-зависимости

```sh
.build/rust/debug/posle-engine --posle-install-python-runtime --root "$AFTER_RUNTIME_TEST_ROOT" --download --profile linux-cpu
# Offline input: дополните --archive ранее проверенным --wheelhouse:
.build/rust/debug/posle-engine --posle-install-python-runtime --root "$AFTER_RUNTIME_TEST_ROOT" --archive /absolute/path/python.tar.gz --profile linux-cpu --wheelhouse /absolute/path/wheels
python3 scripts/check-linux-speech-profile.py --download
```

Профиль содержит 9 закреплённых wheels: imageio-ffmpeg, sherpa-onnx/core, onnx-asr,
onnxruntime, numpy, protobuf, packaging и flatbuffers. MLX/Torch/GPU не входят.
Все direct/transitive версии, PyPI URL, размер и SHA-256 находятся в
`backend/python-wheels-linux-x86_64.json`. Input requirements служит для явного
обновления lock; native installer использует скомпилированный lock.

Сначала native downloader проверяет каждый wheel, затем bundled ensurepip ставит
пакеты только из private wheelhouse с hash checking, без index/source builds и
неявных зависимостей. `pip check`, imports, настоящее CPU ONNX Identity inference
и synthetic FFmpeg conversion проходят до atomic activation; base CPython
перепроверяется. Повреждённый wheel сохраняет прежнюю активную среду.

Это не ASR-модель, не проверка качества речи и не attestation всех installed files.
`RECORD` не используется как trust root; models и `ready-v2` не публикуются.
[Политика и ограничения](decisions/linux-cpu-speech-profile.md).


## Managed Parakeet и настоящая CLI ASR

После установки CPU profile в ту же disposable-библиотеку:

```sh
.build/rust/debug/posle-engine --posle-install-asr-model --root "$AFTER_RUNTIME_TEST_ROOT" --download
# Offline: вместо --download используйте --archive /absolute/path/parakeet.tar.bz2
```

Receipt содержит `directory`: явно укажите его в `settings.json` как `asrModelPath`,
с `speechMode: "local"`, `asrModelFormat: "onnx"`, `diarization: false`.
Установка не меняет настройки и не публикует `ready-v2`. Native guard проверяет
полный managed inventory до запуска backend и удерживается до завершения worker;
замороженный job snapshot имеет приоритет над текущими настройками. Native host
фиксирует один снимок (до 256 KiB UTF-8 JSON) для model guard, credential admission
и backend. Изменение settings после выбора не меняет выполняемую операцию.
Указывайте абсолютный путь: `~` нужно раскрыть до выбора модели.

Opt-in проверка требует espeak/espeak-ng и около 3 ГБ свободного места:

```sh
python3 scripts/check-linux-asr.py --python-archive /absolute/path/python.tar.gz --model-archive /absolute/path/parakeet.tar.bz2 --wheelhouse /absolute/path/wheels
```

Она устанавливает настоящий runtime/model в временную Unicode-библиотеку,
импортирует синтетическую английскую речь и сохраняет canonical transcript.
Проверяет отказ при повреждении архива/модели, frozen selection и сохранность
предыдущего результата/источника. Микрофон и личные записи не используются.
Качество других языков, диаризация и Tauri speech queue этим не подтверждены.
[Артефакты и архитектура](decisions/managed-parakeet-model.md).


Native speech jobs теперь имеют отдельный staged execution/publication протокол:
вычисление использует копии медиа, Rust проверяет исходную ревизию и публикует
транскрипт с приватным receipt. Повтор уже committed операции не запускает модель.
Это фундамент для durable Tauri speech queue; UI capability пока не включена.
[Протокол, восстановление и ограничения](decisions/native-speech-publication.md).


Native service `--posle-speech-queue --root /owned/root --backend /trusted/backend`
теперь сохраняет speech jobs в общей SQLite-очереди, использует отдельный lease,
проверяет receipt при recovery и выполняет только явный Run. Read models не
возвращают настройки/receipt/attempt token. Python и его дочерние процессы входят
во внешний owned scope; проверка `check-linux-asr.py` покрывает реальную очередь
и отмену native/SDK/descendant. Tauri UI пока не подключён.
[Владение, протокол и intentional group termination](decisions/durable-speech-queue.md).


Tauri теперь упаковывает Python-модули из `backend/desktop-speech-files.json`
в `engine/speech-backend`. `stage-desktop-engine.py` обновляет engine и эти ресурсы;
после изменения backend запускайте staging снова. Host build отказывает при stale/partial
stage и закрепляет source hashes из checkout; release требует полный stage.
Native `LibraryBridge.speech_backend()` проверяет состав, хеши и aliases и выдаёт
удерживаемый source grant с recheck. Это не подтверждение runtime/model readiness.
Linux WebView smoke также проверяет упакованные speech resources.

### Явная offline-проверка локального распознавания

После явного выбора local mode, `diarization: false` и абсолютного `asrModelPath`
можно выполнить:

```sh
.build/rust/debug/posle-engine check-speech --root /absolute/test-library --backend "$PWD/backend"
```

Команда использует тот же verified runtime/model launch, что и ASR, исключает
credentials и посторонние настройки. FFmpeg создаёт секунду синтетической тишины,
выбранная модель действительно загружается/декодирует её. Модели не скачиваются;
встречи не читаются и транскрипты не публикуются. Возможны private media/cache
артефакты и временный WAV; обычный выход удаляет WAV и закрывает модель.
Успех требует корректного bounded completion, а не только exit code 0.
Это проверка текущей local inference/media конфигурации, не качества распознавания,
диаризации или постоянной готовности после обновления файлов. Native Tauri readiness
и UI ещё требуют подключения; результат не включает пути, настройки или текст.

Native speech-port также поддерживает отдельные preflight jobs: EnqueueCheck только
фиксирует минимальные local-настройки; RunCheck запускает их после общего
local-heavy admission. GetCheck и CancelCheck используют opaque ID и attempt.
На cancel/EOF owner завершает native/SDK/descendant scope и ждёт его до освобождения
lease. История транскрипций не включает preflight, а исторический успех не отменяет
повторную проверку runtime/model при распознавании. Renderer-кнопки ещё не подключены.
