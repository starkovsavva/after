# Очередь: общая модель и переносимое хранилище

Статус: реализован первый срез этапа 4, 1 ноября 2026.

## Границы

`domain/jobs.rs` содержит сериализуемую модель задания, ограничения ресурсов,
исключение одновременной обработки одного объекта, определение ChatGPT-account/
quota failure и запрет сохранения секретов. Здесь нет SQLite, HTTP или вызовов ОС.
URL проверяются библиотекой `url`, без зависимости от HTTP-клиента.

`infrastructure/job_queue.rs` сохраняет существующие SQL-операции и транзакции.
`jobs.rs` остаётся совместимым API для Swift/CLI и реэкспортирует модель. Модуль
очереди больше не исключён из Windows-сборки через `cfg(unix)`; Windows transport по-прежнему
ограничен typed desktop protocol и не открывает произвольные engine-команды.

## Гарантии

Проверка ресурсов выполняется внутри прежней `BEGIN IMMEDIATE` claim-транзакции,
вместе с проверками зависимостей и account pause. Нельзя вынести чтение snapshot
за транзакцию: два исполнителя могли бы одновременно пройти admission.
Сохраняются формат JSON/SQLite, dedup, expectedAttempt, explicit paid retry,
recover в interrupted и атомарное добавление следующих стадий.

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

На Arch прошёл `python3 scripts/verify.py desktop`: 429 library + 4 CLI, 4 layer
guard tests, frontend build + 7 tests, 19 host + 2 real-engine + 1 real Tauri IPC.
Все 26 SQL-литералов очереди сохранены при переносе. Windows/macOS локально не
запускались; CI-конфигурация не считается результатом их выполнения.
После staging нового engine пересобран автономный debug host с `custom-protocol`;
`check-desktop-linux.py` подтвердил реальный WebView и создание canonical library
на временных данных. Это startup smoke, не проверка всех операций очереди через UI.

Это ещё не общий исполнитель. SQL adapter пока содержит прикладные переходы
состояний и JSON dispatch; следующий срез должен выделить типизированные команды
и application-контракты, сохранив транзакционные границы. Swift JobCoordinator
пока управляет живыми handles, progress, recording admission и shutdown.
Tauri queue API, ProcessSupervisor и Linux speech runtime ещё не реализованы.
