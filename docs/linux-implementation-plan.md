# План: полный Linux-клиент и разделение архитектуры

Статус: план реализации от 31 октября 2026. Основание — [аудит](linux-portability-audit.md).
Цель: функциональный паритет с macOS в Tauri на Arch, сохранение Windows/macOS,
общие правила без зависимости от системных реализаций. Наличие окна приложения
не считается завершением переноса.

## Текущее состояние реализации

- Linux baseline: host собирается; новый `verify.py desktop` прошёл на Arch;
  native WebView smoke с bundled engine создал временную canonical библиотеку.
- Tasks/cards объявляются ядром независимо от ОС. File picker вынесен в host-адаптер
  и подключён на Linux; импорт/чтение media ranges проверены через настоящий IPC.
  Системный диалог и аппаратные/кодековые сценарии ещё требуют ручной проверки.
- Добавлены Ubuntu real-engine проверки и Arch CI job; удалённый CI пока не запускался.
- Общие Settings/AppFeatures и модели/валидация заметок, папок и задач выделены
  в чистый `domain`; старые API-пути сохранены реэкспортами. Границы domain проверяет
  `scripts/check_layers.py`. Циклы между notes/repository/corrections устранены: application-координатор
  использует контракты repository/locks/recovery, реализации находятся в infrastructure.
  Старые публичные API сохранены. См. [ADR](decisions/workspace-boundaries.md).
  Очередь: модель, resource/secret/quota policies выделены в `domain/jobs.rs`,
  SQLite adapter использует `platform_fs` и включён также в Windows-сборку.
  Типизированные queue use cases перенесены в `application/jobs.rs`, порты transaction/
  clock/identity — в `application/job_ports.rs`. SQLite больше не содержит scheduler
  или JSON dispatch. Claim-транзакции и прежний API сохранены;
  [границы](decisions/job-queue-boundaries.md). Общий executor и Tauri queue API ещё не завершены.
- `process-runtime/` подключён к metadata Tauri bridge и ASR worker: общий scoped
  supervisor, Unix groups и Windows Job Object adapters. На Linux проверяются
  отмена/Drop/normal-parent-exit с настоящими потомками. Windows/macOS пока не
  проверены локально; crash/escape ограничения описаны в [ADR](decisions/process-supervision.md).
  Правила live coordinator выделены в чистый `domain/job_runtime.rs` и подключены
  к Swift через `NativeJobRuntime`: admission/progress/finish/shutdown decisions.
  SQL остаётся authoritative; state transient и не сохраняется. Import WorkerHost реализован с progress/cancel и commit receipts
  ([ADR](decisions/worker-host-import.md)); typed native queue port и scoped
  canonical queue реализованы ([ADR](decisions/scoped-executors.md)). Lifetime queue lease реализован
  ([ADR](decisions/import-executor-lease.md)); explicit native Run теперь
  [владеет worker lifetime и проверяет receipts](decisions/owned-import-execution.md).
  Native connection startup сверяет receipts по всем страницам без повторного импорта; выбор файла в UI подключён к [durable controller](decisions/queued-import-controller.md). [История/retry](decisions/import-history-and-resume.md) с keyset pagination по 50 импортов и startup reconciliation подключены; [recording import](decisions/durable-recording-import.md) перенесён на ту же queue; portable recovery capability отделена от hardware capture; [CaptureBackend](decisions/capture-backend-port.md) внедряется в общий Recorder, Windows не меняет его state напрямую; [ADR](decisions/live-job-coordinator.md).
- Main 0.18.2 интегрирован: Swift разбит на AfterCore/Platform/Localization/macOS/App;
  новые knowledge SQL/rebuild modules сохраняют canonical transaction в infrastructure.
  Optional semantic/agent cleanup выбираются через native boundaries; Tauri UI
  новых Swift-сценариев и Linux model/capture runtime ещё требуют переноса.
  [Интеграция и проверки](decisions/main-0182-integration.md).
- Команды и ограничения актуальны в [Linux-инструкции](linux.md).

## Правила выполнения

- Небольшие проверяемые изменения: сначала поведение и контракты, затем перенос реализации.
- Сохранять формат библиотеки, неизвестные поля, CAS/revision, operation receipts,
  атомарность, блокировки, восстановление и ограничения доступа.
- Использовать временные библиотеки. Миграции проверять на копиях; личные данные,
  аккаунты и платные вызовы требуют отдельного пользовательского сценария.
- Каждый этап обновляет AGENTS.md и матрицу возможностей. Результаты тестов
  различать: unit, настоящий движок, browser, native WebView, физические устройства.
- Рефакторинг не должен одновременно менять бизнес-политику. Новые форматы данных
  вводить отдельным изменением с совместимой миграцией.

## Целевая структура зависимостей

- `domain`: сущности, настройки, профили, валидация и политики; без Tauri, SQL,
  файловых путей, HTTP, subprocess и вызовов ОС.
- `application`: сценарии, транзакционные границы, очередь, orchestration;
  зависит от domain и узких портов repository/runtime/credentials/capture.
- `infrastructure`: SQLite, файлы, HTTP, процессы, Python, системные адаптеры;
  реализует порты. Порты принадлежат потребляющему внутреннему слою.
- `transport`: CLI, C ABI, MCP, desktop IPC; переводит DTO в типизированные команды.
- Tauri-host и существующий Swift-клиент соединяют реализации в composition root.

Начать с модулей и visibility внутри существующего crate. После стабилизации границ
выделить domain/application в crates, если это позволяет механически запрещать
обратные зависимости. Не создавать один универсальный PlatformService.

## Этап 1. Воспроизводимый Linux baseline

**Компоненты:** desktop host, scripts, CI, документация.

1. Зафиксировать матрицу сценариев: реализация, UI, адаптер, тест, целевая ОС.
2. Подготовить Arch-инструкцию и проверку нативных зависимостей; собрать host,
   ядро и staged engine, запустить на временной библиотеке.
3. Отделить portable test profile от Swift/macOS checks и жёстких `/private/tmp`.
4. Исправить workflow triggers; добавить Linux core и real-engine IPC checks.
   Arch-проверку выполнять отдельно от Ubuntu; графические тесты требуют отдельного стенда.

**Готово:** чистый checkout собирается по инструкции; установленный/собранный host
создаёт заметку, сохраняет и открывает её после перезапуска через настоящий движок.
Mac/Windows проверки остаются доступными. Нативное видео/аудио пока не заявляется.

## Этап 2. Общие возможности, импорт и воспроизведение

**Компоненты:** bridge.rs, desktop_platform.rs, desktop.rs, lib.rs, Cargo.toml, React.

1. Убрать привязку tasks/cards к Windows. Единый capability resolver учитывает
   наличие backend, runtime и разрешений; пользовательские feature flags проверяются отдельно.
2. Подключить file picker на Linux через узкий host-адаптер; сохранить запрет
   передачи произвольных путей из renderer.
3. Проверить импорт WAV/MP3/MP4, сохранность оригинала, большие файлы, range requests,
   перемотку, ошибки кодеков и восстановление импорта в Linux WebView.
4. Проверить файловые гарантии Unix-веток capture/import; устранить расхождения
   между проверкой пути и использованием файла без ослабления Windows-защит.

**Готово:** задачи/карточки и импорт доступны на Linux; перезапуск, конфликты и
повторение карточек проходят через реальный IPC. Capability metadata непротиворечива.

## Этап 3. Domain/config и разрыв циклов persistence

**Компоненты:** ai_config, ai, folders, notes, corrections, workspace_repository, storage.

1. Выделить общие модели/config и чистые правила профилей; убрать зависимость
   папок/задач от runtime-модуля ai и платформенные подмены его API.
2. Выделить workspace-модель и валидацию из notes; repository использует эти типы.
3. Вынести координацию recovery, locks и транзакции в application-сценарий.
   Разорвать notes ↔ repository ↔ corrections без разбиения единой операции
   на несколько неатомарных сохранений.
4. Перенести прямые системные операции из доменных функций в инфраструктуру,
   используя platform_fs как отправную точку.
5. Закрепить направление зависимостей visibility/crate boundaries и CI-проверками.

**Готово:** подтверждённые циклы устранены; domain тестируется без файлов/сети/ОС;
контрактные тесты repository сохраняют CAS, receipts, неизвестные поля, rollback
и восстановление после падения. Unix/Windows адаптеры удовлетворяют одинаковым гарантиям.

## Этап 4. Общие очередь и управление процессами

**Компоненты:** BackgroundJobs.swift, Services.swift, jobs.rs, worker.rs, desktop transport.

1. Перенести admission, resource limits, retries и lifecycle из Swift JobCoordinator
   в общий application scheduler; сначала адаптировать Swift к нему.
2. Ввести WorkerHost, ProcessSupervisor, ResourceLocator и SleepInhibitor;
   macOS bundle paths, Unix signals и Windows process lifecycle оставить в адаптерах.
3. Добавить типизированные start/status/progress/cancel операции длительных задач.
   Сохранить ограниченный IPC и явную передачу разрешённых секретов.

**Готово:** очередь доступна из Tauri; отмена завершает дерево процессов;
перезапуск восстанавливает задания; старый результат не заменяет новую ревизию;
платный прерванный запрос не повторяется автоматически.

## Этап 5. Linux media, Python и модели

Общая descriptor-based проверка полного CPython inventory выделена в
`infrastructure/runtime_tree.rs`; macOS сохраняет выбор pinned policy/layout и loader.
На Linux выполняются ELF-style inventory и synthetic macOS venv contracts.
Linux x86_64 GNU CPython закреплён и проверен на настоящем архиве/изолированном venv;
generation installer CPython/venv реализован с atomic activation и сохранением previous generation;
проверяемый active-generation selector и общий Unix venv binding подключены;
Linux worker launch теперь использует verified standalone CPython через общий supervisor;
speech dependencies, очередь ASR и настоящее распознавание ещё не подключены; [ADR](decisions/runtime-inventory-boundary.md).

**Компоненты:** python_runtime, python_host, embedded_speech, media, backend/setup,
requirements, manifests, managed model host.

1. Ввести каталог проверяемых артефактов по OS/arch; определить Linux-поставку
   CPython и FFmpeg. Проверить Python ABI через безопасную платформенную границу,
   не переиспользовать непроверенный macOS PyConfig layout.
2. Установщик с проверкой до исполнения, staging и rollback сделать переносимым.
   Убрать зависимость общего пути от plutil/BSD stat/lockf.
3. Разделить speech-зависимости и каталог моделей по backend. Сначала подтвердить
   Linux CPU ONNX на синтетическом/разрешённом аудио; ускорители — отдельными срезами.
4. Разделить внешний HTTP LLM provider и managed runtime. Для managed определить
   Linux-артефакт, запуск, остановку, каталог моделей и восстановление установки.
5. Подключить через очередь распознавание, диаризацию и конспектирование к Tauri.

**Готово:** импорт → распознавание → конспект → поиск проходит на Arch;
проверены отмена, повреждённый runtime, нехватка места и сохранность предыдущего
результата. Системный Python Arch не используется как неявная замена pinned runtime.

## Этап 6. Linux-запись

Микрофон реализован через локальный libpulse adapter; private PipeWire SDK fixture
проверяет запись, отключение и monitor rejection. Физический микрофон и system audio
ещё требуют проверки/реализации; [ADR](decisions/linux-microphone.md).

**Компоненты:** общий recording lifecycle и отдельные capture backends.

1. Выделить общий контракт дорожек, монотонного времени, состояния и восстановления.
2. Реализовать Linux микрофон, затем системное аудио, затем видео экрана;
   подтвердить PipeWire/portal путь на выбранных графических окружениях.
3. Интегрировать разрешения, смену устройств, запрет сна и завершение приложения.
4. Проверить длинные записи, паузы, sleep/resume, отключение устройств, потерю
   разрешений, аварийный выход и восстановление. Повторно проверить Windows backend.

**Готово:** запись → восстановление/остановка → обработка проходит на физических
устройствах целевого Arch-стенда; ограничения окружений явно документированы.
Этап зависит от 4; полный сквозной сценарий также зависит от 5.

## Этап 7. Секреты, авторизация и интеграции

Ввести CredentialStore и общий lifecycle сессий; реализовать Linux-хранилище,
не выдающее заблокированный vault за отсутствие учётной записи. Затем перенести
OAuth/refresh ChatGPT, трекеры и календарь за отдельные контракты. Сохранить
области разрешений и запрет неявного включения интеграций. Добавить Tauri UI и
настройки MCP, semantic search, assistant и voice use cases.

**Готово:** сценарии входа, отказа, refresh, выхода, конфликтов синхронизации и
изменения профиля проверены; renderer не получает секреты. Контракты тестируются
локальными fixtures; реальные аккаунты проверяются отдельно по разрешению.

## Этап 8. Полный UI-паритет и Linux-поставка

По матрице этапа 1 закрыть rich text/совместимость RTF, вложения/OCR, редактирование
источников, профили папок, расширенные задачи и карточки, корзину, импорт/экспорт,
темы и остальные пользовательские сценарии. Это отдельные небольшие изменения,
а не одна финальная перепись интерфейса.

Определить формат Linux-поставки, состав ресурсов, политику обновлений и миграций.
Добавить ELF/architecture validation staged engine и smoke готового пакета на чистом
стенде. Проверить совместимость с библиотекой Mac на копии и сохранность данных
после обновления. Подпись/публикация — отдельная завершающая операция.

**Готово:** у каждого согласованного сценария есть реализация, UI и подтверждение
на целевой ОС; отсутствующие/ограниченные функции видны в матрице. Проверен готовый
Linux-артефакт, а не только dev-сервер. Mac/Windows регрессии пройдены.

## Первый пакет реализации

Начать с этапа 1 и небольшого среза этапа 2: Linux baseline, capability resolver,
tasks/cards, file picker, real-engine tests. До переноса speech/capture выполнить
этапы 3–4, чтобы не размножать платформенные ветвления в общем коде.

Перед capture уточнить графическое окружение пользователя (Wayland/X11, compositor),
источники звука и оборудование. Перед поставкой выбрать формат пакета/обновлений.
Эти решения не блокируют baseline и исправление архитектурных зависимостей.
