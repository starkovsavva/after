# Device capture behind an injected backend

Статус: общий Recorder не выбирает ОС; Windows WASAPI реализует отдельный port.
Production Linux/macOS backend пока unavailable. Portable private WAV recovery,
durable import и media playback сохраняются независимо от hardware capture.

## Зависимости

`capture_backend.rs` содержит typed CaptureMode/Capabilities, private CaptureRequest
и CaptureControl/CaptureBackend. В нём нет SDK, файловых операций или Recorder state.
`Recorder::new(root, Arc<dyn CaptureBackend>)` требует явную dependency injection.
`capture_platform.rs` выбирает production adapter в composition boundary.
`capture/windows.rs` зависит от port и shared PCM/WAV leaf `capture_audio.rs`;
WASAPI packet/QPC/mixer loop сохранён. Форматный leaf содержит файловый writer и
нужные file-sharing options; он не владеет lifecycle Recorder.

Backend получает только leased destination и выбранный mode, сообщает started один
раз и ждёт stop через control. Он не получает Shared/RecordingStatus/Mutex Recorder.
Общий SessionControl устанавливает monotonic elapsed clock, ready notification,
terminal phase и warning. Повторная readiness даёт interrupted; успешный return без
readiness — startup error. До начала сессии mode проверяется по capabilities без
создания capture directory; mixed audio не превращается неявно в microphone-only.

## Lifecycle и capabilities

Существующие startup deadline 10 секунд, stop/join, capture lease, partial WAV recovery
и durable import сохранены. Timeout просит stop и удерживает session до cleanup;
поздняя readiness с уже закрытым receiver позволяет adapter завершить stream cleanup.
Исчезновение stop sender также означает stop. Device initialization остаётся
кооперативным: зависший OS вызов не получает гарантированного принудительного thread
kill; для такой гарантии нужен отдельный worker process.

`get_workspace` добавляет capabilities управляемого Recorder. Metadata-only
LibraryBridge не объявляет device capture. `recordingModes` задаёт допустимые modes;
UI показывает их и блокирует неподдерживаемый выбор. Старые fixture без списка
сохраняют прежние два режима. `recordingRecovery` остаётся независимым флагом.
Ни renderer, ни library config не выбирают executable/backend implementation.

## Проверки и продолжение

Source guard запрещает driver/OS selection в lifecycle, SDK/I/O в port и связь
Windows adapter с Recorder state. Его контракты включены в `verify.py desktop`.
Synthetic lifecycle tests проверяют start/stop, неподдерживаемый mode до filesystem,
no-ready/panic, duplicate readiness, timeout/late cleanup и сохранность WAV/lease.
Настоящий Tauri IPC с injected synthetic microphone проходит start → stop →
canonical queued import/ack; это не физический microphone test.

На Arch прошли desktop profile: 626 core + 2 CLI, 56 host, 10 real-engine,
1 настоящий IPC и 18 Playwright scenarios. Browser проверяет microphone-only mode
без system-audio fallback. Windows SDK/runtime и физические устройства локально
не проверены; изменения WASAPI требуют platform CI/ручного прогона.

Следующий этап — Linux microphone adapter, затем system audio через подтверждённый
portal/PipeWire путь, разрешения/device changes и физический сквозной тест.
