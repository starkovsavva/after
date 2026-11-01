# Очередь: прикладные сценарии и переносимое хранилище

Статус: реализованы storage и application-срезы этапа 4, 1 ноября 2026.

## Границы

`domain/jobs.rs` содержит сериализуемую модель задания, ограничения ресурсов,
исключение одновременной обработки одного объекта, определение ChatGPT-account/
quota failure и запрет сохранения секретов. Здесь нет SQLite, HTTP или вызовов ОС.
URL проверяются библиотекой `url`, без зависимости от HTTP-клиента.
Определения новых заданий отделены от сохранённых jobs: identity/time передаются
при создании извне. Переходы cancel/retry/update валидируют модель без I/O.

`application/jobs.rs` выполняет типизированные enqueue/list/get/claim/mutate/recover,
дедупликацию цепочек, admission и распространение dependency-blocked состояний.
Он зависит от портов `JobQueueRepository`, `JobQueueTransaction`, `JobClock`,
`JobIds` в `application/job_ports.rs`. Внутри нет SQL, путей, системного времени
или генерации случайных идентификаторов.

`infrastructure/job_queue.rs` реализует SQL-порты; `job_context.rs` предоставляет
системное время и UUID. `jobs.rs` переводит прежний JSON в команды/ответы и соединяет
адаптеры. Swift/CLI используют этот путь уже сейчас. Модуль очереди включён и в
Windows-сборку; Windows transport по-прежнему ограничен typed desktop protocol
и не открывает произвольные engine-команды.

## Гарантии

Проверка ресурсов выполняется внутри прежней `BEGIN IMMEDIATE` claim-транзакции,
вместе с проверками зависимостей и account pause. Нельзя вынести чтение snapshot
за транзакцию: два исполнителя могли бы одновременно пройти admission.
Сохраняются формат JSON/SQLite, dedup, expectedAttempt, explicit paid retry,
recover в interrupted и атомарное добавление следующих стадий.
Application получает заимствованную сессию только внутри callback. SQL adapter
делает commit после успешного callback; ошибка откатывает всю операцию, включая
обновление job и account pause. Это использует
[SQLite transaction semantics](https://www.sqlite.org/lang_transaction.html) и
[rollback-on-drop rusqlite](https://docs.rs/rusqlite/0.40.2/rusqlite/struct.Transaction.html).
Чтение списка теперь использует одну deferred read-транзакцию для согласованности
jobs/count/account pauses. Время не обновляется при повторном terminal completion;
его опоздавшие progress/message/result игнорируются, но stale expectedAttempt
по-прежнему отклоняется до проверки идемпотентности.

Открытие БД использует `platform_fs`: Unix permissions и Windows ACL/reparse guards
остаются в соответствующих адаптерах. До открытия проверяются основной файл и
все SQLite sidecars; ссылки и не-обычные файлы отклоняются. Добавлена проверка
hard links, чтобы очередь не изменяла файл с другим именем вне библиотеки.
SQLite также получает `SQLITE_OPEN_NOFOLLOW`; смысл флага описан в
[официальном SQLite API](https://www.sqlite.org/c3ref/open.html).
Проверенный приватный каталог канонизируется для системных aliases macOS `/tmp`.

## Проверки и следующий шаг

Существующие queue-тесты теперь входят и в Windows core test job. Они проверяют
конкурентные claims, миграции, зависимости, отмену, stale attempts, paid recovery,
account isolation и историю. Новые проверки отклоняют hard-linked и directory
database/sidecars до изменения внешнего файла. Unix отдельно проверяет symlink
и права `0600`.

Application-контракты проверяются независимым in-memory repository, clock и IDs:
invalid input до I/O, rollback цепочки, paid quota retry, recovery и late callbacks.
Отдельный тест настоящего SQLite проверяет откат job/account pause при ошибке
callback. Layer guard запрещает обратные вызовы в JSON-фасад очереди.

На Arch прошёл `python3 scripts/verify.py desktop`: 434 library + 4 CLI, 5 layer
guard tests, frontend build + 7 tests, 19 host + 2 real-engine + 1 real Tauri IPC.

Все 24 различных SQL-литерала очереди сохранены; повтор одинакового запроса state
сведён к одному методу порта. Windows/macOS локально не
запускались; CI-конфигурация не считается результатом их выполнения.
После staging нового engine пересобран автономный debug host с `custom-protocol`;
`check-desktop-linux.py` подтвердил реальный WebView и создание canonical library
на временных данных. Это startup smoke, не проверка всех операций очереди через UI.

Это ещё не общий исполнитель. Следующий срез переносит lifecycle живых attempts
за WorkerHost/ProcessSupervisor и общий coordinator. Swift JobCoordinator пока
управляет handles, progress, recording admission и shutdown.
Tauri queue API, ProcessSupervisor и Linux speech runtime ещё не реализованы.
