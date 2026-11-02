# Scoped durable queue executors

Статус: scoped application queue и native import queue port реализованы.
Native connection startup сверяет receipts; file-picker UI использует durable controller с transient status.

## Проблема

Legacy `job-recover` переводит все running-задания библиотеки в interrupted.
При добавлении второго клиента это затронуло бы живые задания Swift. Фильтрация
готового snapshot тоже недостаточна: 50 последних чужих записей вытесняют свою
историю, а одновременные claim/mutation требуют транзакционной проверки владельца.

## Решение

Composition root задаёт `JobQueue.kind`. `None` сохраняет существующий Swift/CLI
контракт; desktop import использует фиксированный `desktop-import`. Renderer
не выбирает scope. Legacy API остаётся глобальным: scope не является
авторизацией и не защищает от recovery через старый native клиент. При совместном
root перед включением нового executor требуется исключить его kind из legacy
claim/recovery; штатно desktop использует отдельную библиотеку `app.posle.desktop`.
Application проверяет принадлежность при enqueue, get,
mutation, claim, recovery и propagation зависимостей. В scoped цепочках нельзя
добавить чужой follow-up или dependency; ошибка откатывает всю транзакцию.

Claim рассматривает только свои queued-задания, но admission считает **все**
running-задания: разные клиенты не обходят общий лимит CPU/cloud или same-object
exclusion. Проверка attempt остаётся внутри write-транзакции; старый worker не
может завершить новую попытку. Recovery меняет только свой kind и оставляет
interrupted для явного продолжения; платные запросы автоматически не повторяются.

`JobQueueRepository.snapshot(kind)` фильтрует SQL-выборку до history LIMIT. Jobs,
total и admission pauses читаются в одной read-транзакции; схема SQLite не меняется.

## Native boundary

`desktop_queue.rs` собирает application service и SQLite/clock/ID adapters.
Закрытый `desktop-import-queue` service принимает typed enqueue/list/get/claim/
cancel/retry/update/recover. Путь, title и receipt сохраняются в private queue;
API не принимает kind, environment, executable или произвольную команду.
List/recovery возвращают компактные summaries без config, путей и receipt tokens;
полный private input получают отдельно через native get/claim.
Host зависит от порта `import_queue::ImportQueue`; `LibraryBridge.open_import_queue()`
возвращает leased `QueueConnection` через bounded persistent transport.
Обычный metadata transport больше не принимает `import_queue`. Порт не зарегистрирован в Tauri
ACL, private DTO нельзя выдавать WebView. File-picker UI использует durable executor; transient status не является сохранённой историей.

## Следующий обязательный шаг

Scope — граница ответственности, **не lease процесса**. Перед production recovery
реализован [lifetime lock](import-executor-lease.md), исключающий второй queue owner.
Для explicit import Run [worker lifetime покрыт lease](owned-import-execution.md); file-picker UI подключён, [history/retry UI](import-history-and-resume.md) с пагинацией по 50 jobs подключён. После получения lease native connection [сверяет atomic publication receipts](import-startup-recovery.md) до возврата caller; повторный запуск остаётся явным. Публикация и запись queue completion разделены;
повторное выполнение нельзя считать безопасным только потому, что job interrupted.
Это соответствует требованиям к идемпотентным Activities в
[Temporal](https://github.com/temporalio/documentation/blob/main/docs/encyclopedia/activities/activity-definition.mdx).

## Проверки

Pure application tests проверяют изоляцию, транзакционный rollback цепочек и общий
resource admission. SQLite/engine protocol tests проверяют чужие paid jobs, history
pagination, закрытую схему, persistence и fencing attempts. Real-engine host test
пересоздаёт bridge и продолжает ту же очередь через типизированный порт. ACL test
подтверждает, что renderer не вызывает `import_queue`. Windows/macOS локально не
проверены; Swift сохраняется до подтверждённого паритета.
