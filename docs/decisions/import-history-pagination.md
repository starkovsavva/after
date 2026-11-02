# Complete import history through creation-key pages

Статус: native/application/repository/UI поддерживают всю историю по 50 jobs на
страницу. Старые pending imports доступны для явного Resume/Cancel. Прежний List
scheduler/Swift/CLI сохраняет все active jobs и прежний history limit.

## Контракт и слои

`JobQueue.history` проверяет cursor, scope, размер и порядок страницы через
`JobQueueRepository.history`. SQL adapter выбирает все состояния, фильтрует kind
до LIMIT и сортирует `(created_at DESC, id DESC)`. Ключ продолжения содержит
конечный timestamp и ID; это данные запроса, не путь или capability. Все значения
передаются SQL parameters. Cursor не требует существования anchor row.

Adapter читает максимум 51 job: дополнительная строка определяет hasMore, наружу
возвращаются 50. Count и строки относятся к одной read transaction. Между страницами
нет долгоживущей транзакции: новые записи в начале истории появляются после Refresh.
Progress/completion/retry меняют updated_at, поэтому не перемещают creation key.
Схема SQLite и прежние native JSON actions не меняются; History — отдельный action
закрытого leased import service. Recovery по 64 записи остаётся независимым.

Host проверяет порядок, границу предыдущего cursor и точное совпадение continuation
с последней строкой полной страницы. Grant-free read model выдаёт только состояния,
ID, progress/attempt/cancel flag, count и cursor; private config не сериализуется.
Tauri `import_history {after?}` использует прежний reservation/ACL. Renderer объединяет
только одинаковые in-flight page reads, дополняет список без дубликатов и сохраняет
уже загруженные строки при ошибке следующей страницы. Refresh заменяет список с начала.

## Точность и совместимость

Обычный JSON float parser менял некоторые epoch timestamps на один ULP: это могло
сломать cursor на границе страниц. Core и host используют `serde_json/float_roundtrip`;
JSON/JavaScript сохраняют точное double значение ключа. Protocol tests включают
дробный timestamp с этой ошибкой старого parser.

Старый payload после mutation мог уже отличаться от SQL created_at на один ULP.
History использует immutable SQL key в read view и принимает только такую узкую
погрешность; payload/metadata не переписываются. Несогласованные ID, нечисловое время
и более крупное расхождение отклоняются. Проверка совместимости сравнивает DB bytes
до/после чтения, а не ремонтирует пользовательские данные.

## Проверки и продолжение

Application/SQLite tests покрывают все состояния, одинаковые timestamps, чужой kind,
completion и новую запись между страницами, удалённый anchor, точность cursor и
неизменность legacy payload. Host tests отвергают повторную страницу/чужой continuation.
Real-engine test проходит 121 job тремя страницами и явно продолжает старый interrupted
job с неизменным источником. Настоящий Tauri IPC проверяет typed cursor и terminal
empty page при ненулевом общем count. Playwright проверяет догрузку, ошибку/retry
страницы, Refresh и Resume старой строки.

Параллельные Unix protocol fixtures запускали только что записанные scripts как
executables и давали подтверждённый ETXTBSY ещё до handshake. Queue fixture теперь
исполняет стабильный `/bin/sh`, читающий отдельный script; десять повторных
прогонов suite с параллельными тестами прошли без изменения production timeouts или integrity checks.

На Arch прошли desktop profile, 626 core + 2 CLI, 51 host, 10 real-engine,
1 настоящий Tauri IPC и 17 Playwright scenarios. Windows/macOS локально не проверены.
Recording import использует [durable queue](durable-recording-import.md). Далее — CaptureBackend и Linux capture/ASR adapters.
