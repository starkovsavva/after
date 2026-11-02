# Imports owned by the queue lease

Статус: явный native `Run` выполняет durable import внутри leased service.
Native connection startup выполняет [receipt reconciliation](import-startup-recovery.md); выбор файла в Tauri UI подключён через [controller](queued-import-controller.md).

## Границы

`application/import_ports.rs` задаёт private input, store/worker contracts и
attempt-scoped `ImportStop`. `application/import_execution.rs` проверяет вход,
выбирает исход по receipt и управляет progress/cancellation без файлов, потоков
или выбора ОС. Standalone worker использует ту же проверку input.

`desktop_queue_executor.rs` собирает эти порты: store вызывает существующие queue
use cases с SQLite adapter, worker использует существующий verified-copy import.
Копирование и metadata publication идут в потоке **того же процесса**, который
держит kernel lease. Новая команда не запускает произвольный executable/provider.

## Жизненный цикл

`Run {jobId}` сначала выполняет transactional claim с общими resource limits,
затем запускает один worker и немедленно возвращает running attempt. RPC остаётся
доступным для Get/List/Enqueue/Cancel. Пока worker жив, Claim/Run/Update/Retry/Recover
возвращают `busy`: caller не может преждевременно завершить или восстановить его.
Cancel сохраняется с `expectedAttempt`, затем сигнал получает только этот worker.
Отклонённый stale cancel не меняет control новой попытки.

EOF/error/shutdown останавливает и joins worker до освобождения lease. Просто
удалить `JoinHandle` недостаточно: это
[отсоединяет поток](https://doc.rust-lang.org/stable/std/thread/struct.JoinHandle.html).
Worker adapters дополнительно удерживают Arc lease. При принудительной остановке
helper процесс и его потоки завершаются вместе; successor получает lock после
освобождения kernel handles. Standalone WorkerHost сохраняется для recording import и protocol checks; file-picker UI использует durable execution path.

## Публикация и исход

Перед работой проверяется точный receipt `(operationId, attemptToken)`. Его
наличие завершает попытку успешно без повторного чтения/копирования источника.
Логическая receipt identity сохраняется на retry; queue `attempt` отдельно
защищает progress/completion через CAS.

После worker error receipt проверяется снова. Подтверждённая публикация выигрывает
у потерянного ответа и поздней отмены. Неизвестный receipt даёт `interrupted`,
без автоматического повтора. Только известное отсутствие позволяет выбрать
`failed` или `cancelled`. Metadata probe различает NotFound и I/O/corruption;
dangling receipt не считается доказательством отсутствия публикации.
Так side effect остаётся идемпотентным при повторе, как требуется для
[durable activities](https://github.com/temporalio/documentation/blob/main/docs/encyclopedia/activities/activity-definition.mdx).

Остановка owner без user cancel — `interrupted`; явная отмена — `cancelled`.
Успешная публикация сохраняет приоритет в обоих случаях. В ledger не попадают
raw worker errors. Progress пишется при изменении процента/фазы, cancellation
проверяется на каждом copy checkpoint; перед publication проверяется и durable
cancel flag. Недоступный progress store останавливает публикацию.

## Проверки и оставшаяся работа

Application tests проверяют lost reply, unknown receipt, cancellation, shutdown,
bounded/monotonic progress, invalid input и stale completion. Детерминированный
native test удерживает worker перед publication: Drop ждёт join, второй lease
недоступен, после остановки metadata не публикуется. Проверены busy recovery,
stale cancel и unreadable metadata.

Real-engine test выполняет Run, проверяет неизменность источника, затем восстанавливает
publication/completion gap без исходного файла; чужой token не принимает receipt.
Это не проверка кодеков, физического захвата или model quality. Windows/macOS
локально не запускались. Native Run отменяется кооперативно на checkpoints; принудительная граница
супервизора — весь owner process. File-picker controller сохраняет deadline/grace политику прежнего WorkerHost и восстанавливает соединение без повторного запуска.
Следующие шаги — полная пагинация истории, перенос recording import и расширение worker ports; автоматические retries и Swift removal
не включены. При совместном root с legacy writer всё ещё нужна защита от его
глобального claim/recover; штатные библиотеки клиентов разделены.
