# Workspace: domain, application и storage adapters

Статус: реализовано, 1 ноября 2026. Относится к хранению заметок/задач,
папкам, recovery журнала правок, receipts и outbox. Полный перенос приложения
и удаление Swift этим решением не объявляются завершёнными.

## Проблема

Раньше `notes`, `workspace_repository` и `corrections` вызывали друг друга.
Модели и их валидация принадлежали модулю, выполняющему файловые операции.
Репозиторий сам получал lock через notes и запускал recovery через corrections.
Это мешало тестировать порядок операций отдельно от ОС и SQLite и затрудняло
перенос инфраструктуры без изменения прикладных сценариев.

## Решение

- `domain/`: модели, настройки, валидация, нормализация старых значений и envelope
  workspace/outbox. Модели не зависят от валидаторов; валидаторы используют модели.
- `application/ports.rs`: контракты `WorkspaceRepository`, `WorkspaceLocks`,
  `WorkspaceRecovery`. Контракты принадлежат потребляющему application-слою.
- `application/workspace.rs`: координатор задаёт порядок операций через эти порты.
  В нём нет вызовов SQL, filesystem, процессов или конкретных адаптеров.
- `infrastructure/workspace_repository.rs`: прежние SQL-транзакции, миграции,
  сохранение неизвестных полей, receipts и outbox. Locked-методы не инициируют recovery.
- `infrastructure/workspace_files.rs`: приватные каталоги и межпроцессный lock.
- `infrastructure/corrections.rs`: существующий effectful journal/media adapter,
  использующий domain и низкоуровневый repository без вызова notes operations.
- `infrastructure/workspace_adapters.rs`: реализации трёх application-контрактов.
- Корневой `workspace_repository.rs` — compatibility API и composition root;
  корневой `corrections.rs` — compatibility transport facade. Старые публичные
  функции остаются доступны вызывающему коду. FFI/CLI/IPC не меняют JSON-контракт.

Это применение Dependency Inversion: прикладной сценарий зависит от интерфейсов,
реализация инфраструктуры реализует их, а composition root соединяет стороны.
Такое направление описано в [официальном руководстве Microsoft по Clean Architecture](https://learn.microsoft.com/en-us/dotnet/architecture/modern-web-apps-azure/common-web-application-architectures).

## Гарантии и порядок

Снимок, compare-and-save и чтение outbox получают workspace lock, восстанавливают
незавершённую правку и только затем обращаются к repository. Guard удерживается
до завершения операции, в том числе освобождается при возврате ошибки.
Порядок destructor scopes основан на [Rust Reference](https://doc.rust-lang.org/reference/destructors.html)
и дополнительно проверяется тестом с записывающим fake guard.

Receipts и подтверждение outbox намеренно сохраняют прежний путь без recovery.
Invalid consumer/limit/event отклоняется до открытия библиотеки. Методы с суффиксом
`_locked` рассчитаны на уже полученный lock и не захватывают его повторно.
Journal adapter использует raw locked repository, чтобы recovery не запускал себя
через notes::load. Порядок workspace lock → meeting lock сохраняется.

Workspace, entity catalogue, operation receipts и outbox продолжают фиксироваться
одной SQLite-транзакцией. Выделение портов не разбивает её на отдельные commits.
Формат данных, неизвестные поля, ревизии, миграции и compatibility export сохраняются.

## Проверки и границы решения

`scripts/check_layers.py` проверяет запрещённые зависимости domain/application,
обратные вызовы infrastructure в legacy facades и циклы плоских domain-модулей.
Это source-level guard, не полноценный Rust parser или доказательство отсутствия
любого возможного цикла. Контрактные тесты проверяют последовательность и отказы
координатора без I/O. Существующие integration-тесты проверяют реальные миграции,
конфликты, rollback, конкурентные записи и recovery.

Legacy-модули операций ещё содержат orchestration и filesystem; journal adapter
ещё содержит правила правки конспекта. Следующие изменения должны выделять эти
use cases постепенно. Не следует ради красивой схемы ослаблять атомарность,
проверки источников, отмену и защиту файлов. Разделение на дополнительные crates
и замену Path в storage-контрактах на типизированные library scopes можно выполнить
после стабилизации этих границ. Swift остаётся до проверенного паритета.
