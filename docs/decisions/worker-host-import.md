# Import WorkerHost

Статус: standalone WorkerHost используется recording import и protocol checks.
Выбор файла в UI использует durable native [controller](queued-import-controller.md).

## Границы

Native host получает путь только через свой file picker. WebView видит статус и
непрозрачный operation ID; команды `import_status` и `cancel_import` ограничены ACL.
Путь, attempt token и управление процессами недоступны renderer.

`worker_host.rs` задаёт узкий порт, `process_worker.rs` реализует его через общий
`process-runtime`. Engine принимает только `desktop-import-worker --root` и закрытый
версионированный NDJSON-протокол импорта. Это не универсальный запуск команд.
`application/imports.rs` управляет bounded copy и checkpoints; файловые гарантии
остаются в `desktop_import.rs`. Read-only adapter `infrastructure/import_source.rs`
отклоняет специальные файлы, Unix symlink и Windows reparse point; права исходника
не меняются. Receipt lookup находится в import adapter, без цикла через DTO transport.

## Завершение и отмена

Host одновременно обслуживает stdin/stdout/stderr, ограничивает размер сообщений и
буферов и проверяет IDs, порядок фаз и монотонность progress. Bounded channel создаёт
[backpressure](https://doc.rust-lang.org/std/sync/mpsc/fn.sync_channel.html).
Процесс получает очищенное окружение. Timeout — 30 минут, cooperative cancellation
имеет 3 секунды на завершение, затем scoped supervisor останавливает потомков и
reaps child. Владение процессом учитывает требования
[Rust Child](https://doc.rust-lang.org/std/process/struct.Child.html).

Отмена проверяется между блоками и непосредственно до atomic metadata publication.
После публикации успех имеет приоритет: при потере terminal frame host проверяет
receipt с точными operation ID и attempt token. Чужая попытка не принимается за успех.
Источник не изменяется; незавершённый собственный staging очищается под lock.

Native `imports.rs` владеет transient session. UI показывает progress, отменяет по ID
и восстанавливает панель после reload. Закрытие окна при активном импорте блокируется.

## Проверки и ограничения

На Arch прошли desktop verification, 13 Playwright-сценариев, реальные engine/IPC
проверки progress, отмены, изоляции и receipts. Диалог выбора, физические устройства
и кодеки не покрыты этими проверками. Windows/macOS локально не запускались.

Native [scoped queue port](scoped-executors.md) реализован отдельно. Native Run и [startup reconciliation](import-startup-recovery.md) готовы; persistent history/retry UI, recording queue binding, ASR/model workers, ResourceLocator
и SleepInhibitor остаются следующими этапами. Swift сохраняется до проверки паритета.
