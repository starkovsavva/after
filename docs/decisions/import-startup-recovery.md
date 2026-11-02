# Native import queue startup reconciliation

Статус: реализовано при открытии native queue connection. Выбор файла в Tauri UI использует
[durable controller](queued-import-controller.md); [история/retry](import-history-and-resume.md) после перезапуска host подключены.

## Границы и порядок

После проверки engine, получения kernel lease и handshake `QueueConnection.open`
проходит все recovery pages до возврата соединения. Application policy в
`application/import_recovery.rs` зависит от `ImportReceipts` и
`ImportRecoveryStore`: у неё нет возможности вызвать worker или копировать источник.
Filesystem probe и SQLite остаются адаптерами. Native `Recover` использует ту же
политику; legacy Swift/CLI `job-recover` сохраняет прежний глобальный контракт.
При общем root legacy writer всё ещё может вмешаться; штатные библиотеки разделены.

Кандидаты — только `desktop-import` в running/interrupted. SQL использует ID cursor
и страницы по 64 записи независимо от UI-страниц истории по 50 записей.
Cursor продвигается и через неопределённые исходы; полная последняя страница
допускает дополнительный пустой запрос. Каждый RPC ограничен прежними frame limits
и deadline 12 секунд. File-picker controller открывает соединение вне UI-потока.

## Выбор исхода

- Точный опубликованный receipt выигрывает позднюю отмену и потерянный completion:
  job становится succeeded без чтения исходного файла.
- Подтверждённое отсутствие receipt даёт cancelled при durable cancel, иначе running
  становится interrupted. Уже interrupted история без изменения остаётся прежней.
- Ошибка чтения, повреждение receipt или некорректный input оставляют interrupted,
  сохраняют pending cancel и не инициируют retry. Metadata не ремонтируется.

Перед записью adapter повторно сравнивает все типизированные поля наблюдавшегося job
в транзакции. При конкурентном изменении запись не перезаписывается; startup
возвращает busy. Совместимые неизвестные поля payload сохраняются при mutation;
неподдерживаемая будущая версия схемы отклоняется до migration/write.
Логические receipt IDs не меняются при явном retry, attempt продолжает защищать CAS.

## Проверки и ограничения

Application tests проверяют приоритет publication, неопределённость, paging и stale
наблюдения. SQLite tests проверяют сохранение extension fields и отказ будущей
схемы. Real-engine checks проходят publication/completion gap без исходного файла,
повторное открытие, receipt за первой страницей, durable cancel и повреждённый
receipt без повторного импорта. Windows/macOS локально не проверены.

Recovery не включает автоматический запуск/retry. File-picker controller сохраняет deadline/grace и восстанавливает соединение после ошибки без запуска работы. Startup probe вызывает grant-free history и выполняет reconciliation без Run; явный retry доступен в панели истории.
