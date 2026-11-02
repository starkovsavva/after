# Supervised durable imports from the file picker

Статус: выбор файла в Tauri UI использует durable queue. [Recording import](durable-recording-import.md) использует те же queue/controller ports; [история и явный retry](import-history-and-resume.md) после перезапуска host подключены.

## Разделение ответственности

`choose_and_import` выбирает файл через native adapter вне UI-потока и вызывает
`LibraryBridge.import_queued_work`. `queued_import.rs` управляет enqueue/Run/Get/
Cancel через `ImportQueueSession`; он не читает источник и не запускает процессы.
`QueueConnection` реализует transport и остановку owner. Canonical claim,
publication и завершение ledger остаются в engine application/infrastructure.
Новых renderer-команд с путями, config, tokens или произвольным job action нет.

Перед enqueue bridge проверяет точный receipt: завершённая операция не создаёт
новую строку только потому, что общий queue dedup исключает terminal history.
Перед Run контроллер проверяет private input; затем фиксирует job ID и attempt.
Чужой input, смена attempt, неправильное состояние и регресс progress прекращают
операцию. Failed/interrupted jobs автоматически не повторяются.

## Отмена и завершение

Один request budget охватывает импорт: deadline 30 минут, grace 3 секунды после
отмены или deadline. Budget фиксирует начало остановки один раз; следующие RPC
не продлевают grace. Transport проверяет его и во время ожидания ответа каждые
20 мс, сохраняя собственный максимум 12 секунд для RPC и прежние frame limits.
Если ответ приходит вовремя, контроллер отправляет attempt-fenced Cancel. Если
owner не отвечает, transport останавливает/reaps весь process scope.

Контроллер всегда останавливает owner до возврата. После ошибки bridge пытается
переподключиться для receipt reconciliation без запуска работы, затем читает
точный receipt. Publication выигрывает позднюю отмену и потерю ответа. Receipt
не подтверждает чужой token. Неопределённость не разрешает повторное копирование.

UI получает fraction 0..1 из canonical progress, сохраняя opaque operation ID и
transient session для reload WebView и отмены. Старый byte-progress поддерживается
для существующих fixture/standalone сценариев; дробь не выдаётся за реальные bytes.

## Проверки и следующие шаги

На Arch прошли 51 host tests, 10 real-engine integrations, настоящий Tauri IPC,
frontend build/model checks и 17 Playwright scenarios. Проверены изменение budget
внутри зависшего RPC, grace, stale attempts, отмена до enqueue, published success,
неизменность source и повторный receipt lookup без исходного файла.
Системный file picker и Windows/macOS локально не проверены.

Grant-free history и явный retry/cancel pending jobs подключены; startup probe
открывает queue для reconciliation без выполнения работы. Connection используется
на одну native операцию; reservation сериализует чтение и запуск. UI загружает
всю историю страницами по 50 jobs ([ADR](import-history-pagination.md)). Следующие этапы —
CaptureBackend и Linux capture/ASR adapters. Платные и model workers не запускаются автоматически.
