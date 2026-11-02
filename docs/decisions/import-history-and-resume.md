# Durable import history and explicit resume

Статус: desktop UI показывает историю страницами по 50 импортов, Continue/Cancel
для pending jobs и Open meeting для succeeded. [Creation-key pagination](import-history-pagination.md)
позволяет загрузить старые jobs. Recovery обходит свои страницы по 64 записи
независимо от UI.

## Границы

Новые Tauri команды: `import_history {after?}`, `resume_import {jobId, expectedAttempt}`,
`cancel_queued_import {jobId, expectedAttempt}`. Они разрешены только локальному
main window. Путь, config, receipt token, engine action и kind не принимаются.
`import_history.rs` создаёт отдельный renderer DTO с ID, state, progress, attempt
и cancel flag; private queue DTO не сериализуется в WebView. Источник/title не
используется как произвольный error message или подпись истории.

`Imports.reserve()` исключает конкуренцию maintenance с началом импорта до
приобретения kernel lease. Reservation не выглядит как активный import; Drop
освобождает допуск после ошибки. Продолжение превращает reservation в session
с прежней logical operation identity. Bridge работает вне UI-потока.

Startup probe и открытие истории получают leased connection, сверяют receipts,
читают snapshot и закрывают owner. Они не вызывают Retry/Run. Renderer объединяет
только одновременно выполняющиеся history reads, чтобы React StrictMode и
startup/dialog не создавали конкурирующих владельцев; завершённый snapshot не
кэшируется. Ошибка чтения показывается отдельно от пустой истории.

## Явные действия

Resume проверяет expectedAttempt до receipt lookup и mutations. Подтверждённая
публикация открывает результат; нечитаемый receipt прекращает действие без Retry.
Queued job запускается как есть. Failed/cancelled/interrupted проходят typed Retry,
затем Run того же job ID, с теми же receipt IDs и attempt ровно на единицу больше.
Новых jobs или автоматических retries нет. Применяется общий supervised controller
с deadline/grace и остановкой owner до receipt fallback.

Cancel pending job тоже проверяет attempt и receipt: неизвестный исход нельзя
скрыть terminal cancellation. Подтверждённая публикация сохраняет приоритет.
Активная UI-сессия дополнительно получает новый opaque `controlId` при каждом
старте. Live `cancel_import` требует operationId и controlId; старая команда
отмены не может воздействовать на новую попытку той же logical operation.
Этот controlId не является private receipt token.

## Проверки и продолжение

Unit tests проверяют reservation lifetime, старый cancel control, stale resume,
тот же job ID/attempt increment и закрытый read model. Real-engine test пересоздаёт
bridge, восстанавливает interrupted job, явно продолжает его и проверяет источник;
нечитаемая metadata блокирует Retry/Cancel без ремонта. Настоящий Tauri IPC проверяет
history, stale expectedAttempt, resume и отсутствие grants. Playwright проверяет
reload без autorun, явное продолжение, ошибки истории и отмену queued attempt 0.
На Arch прошли desktop profile, 56 host, 10 real-engine и 18 browser scenarios.
Windows/macOS и системный picker локально не проверены.

Сохранение recordings использует [durable queue](durable-recording-import.md); ASR/model workers
и Linux capture остаются отдельными незавершёнными срезами. Swift не удаляется.
