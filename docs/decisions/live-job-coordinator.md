# Общие правила живых фоновых задач

Статус: reducer подключён к Swift actor, 1 ноября 2026. Полный WorkerHost/Tauri
executor и удаление Swift этим решением не объявляются завершёнными.

## Разделение

`domain/job_runtime.rs` — детерминированная state machine: transient runtime state
и событие дают новое состояние и типизированное решение. Здесь нет SQL, потоков,
файлов, системного времени, процессов или UI. Подход соответствует отделению
model/update от исполняемых effects в [Elm Architecture](https://guide.elm-lang.org/architecture/)
и [commands/subscriptions](https://guide.elm-lang.org/effects/).

В Rust перенесены recording admission, sign-out gate, владение `(jobID, attempt)`,
throttle progress, normalizing fractions, shutdown, ephemeral-draft cleanup policy
и итоговое состояние worker. Committed результат остаётся succeeded даже после
cancel. Ошибка при shutdown/cancel становится interrupted; обычная отмена —
cancelled. Текст failure ограничивается по UTF-8 до 2000 bytes, чтобы Unicode
не мешал записать состояние. Устаревшие callbacks не меняют живую попытку.

`jobs.rs` предоставляет внутренний `job-runtime-event` через прежний JSON C ABI.
`NativeJobRuntime.swift` инкапсулирует transient state и DTO. `JobCoordinator`
последовательно исполняет решения: durable queue commands, запуск executor,
отмена физических handles, доставка subscriber continuations и публикация UI.
Остаются существующие model/native executors; inference не исполняется в reducer.

## Источник истины и порядок

Один actor владеет bridge и физическими handles. State создаётся заново при старте,
никогда не сохраняется и не переиспользуется для другой библиотеки. В нём только
flags, account IDs и attempt metadata — нет config, credentials, путей или результатов.
Schema version и unknown fields проверяются; state/event ограничены 64 KiB каждый.
Текст worker failure нормализуется до применения event budget, чтобы большой
NSError/provider description не мешал опубликовать ограниченный failed status.

Start запрашивает recovery до Ready. Host подтверждает Ready только после успешного
recovery и отмены ephemeral drafts; повтор Start после Ready не восстанавливает
живые attempts. Claim decision содержит resource/account admission context;
`application/jobs.rs` применяет account exclusions внутри прежней claim-транзакции.
Затем host регистрирует выданный attempt и запускает executor. Квоты, зависимости,
resource capacity и expectedAttempt по-прежнему проверяет durable очередь.
Admission проверяет фактический saved execution route: несовпадающий legacy `kind`
не обходит sign-out или существующую quota-паузу. Создание новой quota-паузы всё
ещё требует совпадения kind/config command; speech не получает паузу текстового provider.

Runtime state не заменяет SQL и не является authorization token. Ошибка effect
останавливает дальнейший admission; уже опубликованный model result не откатывается.
При недоступном bridge host локально фиксирует halted/stopping и отменяет только
свои handles. Это fallback транспорта, а не вторая реализация scheduler.
Progress использует monotonic milliseconds host; reducer сам не читает clock.

## Проверки и остаток

Rust-тесты покрывают старт/retry, gates, stale callbacks, throttle, committed cancel,
shutdown, Unicode и roundtrip state. Сквозные проверки исполняют decisions через
настоящий SQLite и `posle_request`, включая отсутствие filesystem effects у reducer.
Swift queue diagnostics добавляют прямой adapter roundtrip к существующим actor/
subscription/recovery checks. `python3 scripts/verify.py queue` запускает только
этот native suite на графическом Mac; шаг добавлен в macOS CI. Локально Swift/Mac
недоступны, и конфигурация CI не считается выполненной native проверкой.

На Arch прошёл `verify.py desktop`: 448 core + 4 CLI, 7 process-runtime entries,
frontend build + 7 tests, 20 host + 2 real-engine + 1 real Tauri IPC. Отдельно
прошли 18 tooling/layer tests. Эти проверки не заменяют Swift compiler/runtime.
Финальный engine заново staged, host пересобран с `custom-protocol`; Linux native
smoke подтвердил WebView и временную canonical library с актуальным digest.

Import [WorkerHost](worker-host-import.md) реализован отдельно; durable очередь пока не подключена.
Native [queue port](scoped-executors.md) реализован. Следующие срезы: lifetime lease,
Tauri queue executor/UI, общая политика подписчиков
и retry presentation, platform resource locator/sleep inhibitor, Linux speech runtime.
Перенос reducer не подтверждает весь функциональный паритет приложения.
