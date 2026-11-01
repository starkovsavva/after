# Lifetime lease and native queue connection

Статус: kernel lease и persistent queue service реализованы; explicit native Run
[владеет worker lifetime](owned-import-execution.md). [Startup reconciliation](import-startup-recovery.md) выполняется при открытии native connection; file-picker UI использует
[durable controller](queued-import-controller.md); recording import пока standalone.

## Владение

Engine `desktop-import-queue --root` получает эксклюзивный lock фиксированного
`.desktop-import-executor.lock` через infrastructure adapter. `File::try_lock`
использует [стандартные Unix/Windows механизмы](https://doc.rust-lang.org/std/fs/struct.File.html#method.try_lock).
При конкуренции возвращается `busy`, без recovery или изменения jobs. Lock file
никогда не удаляется: новый inode разрушил бы эксклюзивность. Файл закрывается при
Drop/завершении процесса, root остаётся pinned до освобождения lock.

Адаптер использует private filesystem API, отвергает symlink, hard link и
необычные объекты до изменения прав lock file. Неизвестные объекты не очищаются.
Lease хранит canonical root. Queue envelope требует ссылку на непрозрачный lease
и берёт root из него; обычный `desktop-bridge` не принимает `import_queue`.
Так native queue API не позволяет отдельно выбрать root или обойти lease.
Legacy Swift/CLI API остаётся глобальным; при общем root его claim/recovery всё
ещё нужно ограничить. Штатная desktop-библиотека — отдельная `app.posle.desktop`.

## Протокол и host

После получения lease service отправляет versioned `ready`; каждый запрос имеет
UUID и закрытую import queue action. Ответ сохраняет UUID. EOF освобождает lease.
Неверный action возвращает sanitized domain error и сохраняет соединение;
повреждённый outer frame прекращает service. Recovery запускает native connection после handshake; автоматических retries нет.

`LibraryBridge.open_import_queue()` проверяет engine и возвращает
`QueueConnection`, реализующий порт `ImportQueue`. Host сериализует RPC через
mutex; отдельные bounded writer/reader обслуживают pipes. Запрос ограничен 256 KiB,
response frame — 8 MiB плюс framing. Stderr направлен в null, окружение очищено.
Проверяются version, UUID и envelope. Timeout 12 секунд покрывает и заблокированный
stdin writer. При transport/protocol error весь `ProcessTree` останавливается и
reaps; соединение больше не используется. Обычная queue error его не отравляет.

## Следующая граница

Explicit Run уже размещает import worker внутри owner-процесса и joins его
до освобождения lease. File-picker UI использует durable controller; recording import пока отдельный
путь. Нужны persistent history/retry UI и app-startup recovery; явный retry
проверяет receipt до нового копирования. Сам lease не делает внешний эффект
идемпотентным: [политика выполнения](owned-import-execution.md) описывает эту границу.

## Проверки

На Arch проверены два owner-процесса одного root, независимые библиотеки,
освобождение lock при Drop и аварийном exit, persistence/retry/fencing через новое
соединение. Проверены linked lock objects, bounded framing, несовместимый startup,
чужой reply UUID, timeout при молчащем helper и заблокированном stdin. Metadata
transport не вызывает queue без lease. Windows/macOS workflows настроены, но
локальный прогон этих ОС не выполнен.
