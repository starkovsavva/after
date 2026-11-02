# Durable recording save and explicit recovery

Статус: Stop/Recover и file-picker используют один durable executor. Private PCM WAV
можно восстанавливать на всех desktop OS; физическая запись пока Windows-only.
[CaptureBackend port](capture-backend-port.md) отделяет общий lifecycle от драйвера; Linux portal/PipeWire и ASR/model workers остаются незавершёнными.

## Слои и identity

Native `recording_import.rs` задаёт use case через порты `CapturedRecording` и
`RecordingLibrary`. Capture adapter владеет файлами/repair/marker; bridge реализует
queue/receipt/execution. Policy не выбирает ОС, не запускает процессы и не читает
WAV. Tauri handlers собирают adapters, RecordingGate и Imports reservation.

Capture UUID становится logical operation ID. Private token и исходный title
создаются один раз в canonical queue **до Run** и сохраняются при recovery/retry.
Новый native-only Find использует `JobQueue.object_job` и repository port: scope
проверяется до LIMIT 2, несколько jobs означают неоднозначность и ошибку. Policy
сверяет object ID, private input и фиксированный captured source path. Renderer
не получает token/path и не выбирает kind, source, engine command или Find.

## Публикация и восстановление

Stop сначала останавливает/join capture и финализирует WAV, затем получает queue
admission: отказ сохраняет остановленный источник для recovery. Recover открывает
только session guard и ищет job/точный receipt **до WAV repair**. Подтверждённая
публикация возвращает прежнюю встречу даже без source.wav. Неизвестный receipt
блокирует repair/Retry/Run. При известном отсутствии explicit Recover финализирует
источник и продолжает тот же job/attempt через supervised controller.

`imported` — локальный пустой marker, canonical receipt остаётся authoritative.
Ошибку ack после публикации можно повторить без нового импорта. Listing сверяет
опубликованные queue identities и записывает поздний ack, включая успех через
общую панель истории; source/header не изменяются. Неопределённые outcomes остаются
видимыми. Legacy imported markers сохраняются; для старых unmarked captures без
queued identity исторический random operation ID не угадывается.

## Владение и portability

`capture/guard.rs` удерживает kernel `.capture-session.lock` от старта capture до
конца finalize/import. Session lock inode никогда не удаляется. Guard явно unlocks
при Drop: временно унаследованный fork/duplicate handle не задерживает release.
Sidecar позволяет engine читать source.wav на Windows. Другая recovery не ремонтирует
активную запись. Unix NOFOLLOW/NONBLOCK и handle metadata, Windows reparse/link
checks отвергают symlinks, hard links и необычные объекты без изменения внешних файлов.

`recordingRecovery` отделён от hardware `recording`. UI показывает recovery на Linux
без кнопки физической записи; history/recovery reads сериализуются и coalesce только
in-flight requests, чтобы startup probes не конкурировали за native reservation.
Live cancellation использует новый controlId и прежние deadline/grace правила.

## Проверки и продолжение

626 core + 2 CLI, 56 host, 10 real-engine и расширенный настоящий Tauri IPC прошли
на Arch. IPC восстанавливает synthetic capture, повторяет publication/ack gap без
source и подтверждает поздний ack после history Resume. Unit tests проверяют scope,
ambiguity, receipt-before-repair, private token, guard lifetime, duplicate handles,
реальный child-process lock и сохранность linked files. 18 Playwright scenarios
включают recovery без physical backend и последовательность maintenance reads.
Native WebView smoke использует временную библиотеку. Физические устройства,
macOS/Windows runtime и качество ASR локально не проверялись; Swift сохраняется.
