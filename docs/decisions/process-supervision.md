# Управление процессами engine и host

Статус: первый общий process supervisor подключён, 1 ноября 2026.

## Проблема и границы

Tauri bridge завершал только прямой engine-процесс при timeout или ошибке pipe.
ASR worker имел отдельный Unix ChildGroup с собственным cleanup. Потомок мог
пережить engine и оставить stdout/stderr открытыми, блокируя transport до timeout.

`process-runtime/` — отдельный небольшой infrastructure crate, общий для engine
и Tauri. `ProcessTree` владеет запуском, stdio, остановкой и ожиданием. Крейту
неизвестны jobs, SQLite, UI, модели и команды приложения. Command создаёт доверенный
host/worker; renderer по-прежнему не выбирает исполняемый файл, аргументы или root.
Domain/application не зависят от этого crate: границу проверяет layer guard.

Tauri `bridge.rs` использует RAII cleanup на timeout, ошибках, раннем возврате
и unwind. `worker.rs` использует тот же supervisor, сохраняя allowlist ASR,
очистку environment, redaction, signal guard и TERM → grace → KILL policy.
Успешный выход прямого процесса завершает оставшиеся процессы его scope;
работник не должен запускать отделённые фоновые службы за пределами этой операции.

## Адаптеры

Unix: отдельная process group создаётся до exec. `waitid(WNOWAIT)` наблюдает выход,
не освобождая PID лидера; затем группа получает KILL и лидер reap-ится через Child.
После этого group ID больше не используется. Это закрывает окно PID reuse между
получением статуса и cleanup. `request_stop` посылает TERM, `kill` — KILL.
Обоснование WNOWAIT: [Linux waitid](https://man7.org/linux/man-pages/man2/waitpid.2.html).

Windows: Job Object с `KILL_ON_JOB_CLOSE`, child создаётся suspended/no-window,
назначается job и только затем возобновляется. Первичный поток находится через
ToolHelp snapshot с проверкой owner PID; используются документированные Win32 API.
Ошибка назначения/возобновления завершает и прямой suspended child. `request_stop`
завершает job: аналога Unix TERM для произвольного GUI-процесса нет.
См. [Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects),
[TerminateJobObject](https://learn.microsoft.com/en-us/windows/win32/api/jobapi2/nf-jobapi2-terminatejobobject)
и [ResumeThread](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-resumethread).

## Проверки и пределы

`cargo test --manifest-path process-runtime/Cargo.toml --locked --target-dir .build/rust`
запускает реальные дочерние копии test binary: force stop, stop request, Drop,
изоляция scope, выход родителя с живым потомком, stdin/wait и failed spawn.
Одна из семи test entries — helper fixture, остальные шесть — проверки поведения.
Tauri-регрессия отдельно проверяет engine, оставляющий потомка с открытыми pipes.
Тесты добавлены в desktop/quick verification и Unix/Windows CI; удалённый CI
и Windows/macOS native checks локально не запускались.

На Arch прошёл полный `verify.py desktop`: 7 process-runtime entries, 434 core +
4 CLI, frontend build + 7 tests, 20 host + 2 real-engine + 1 real Tauri IPC.
Отдельно прошли 17 tooling/layer guard tests. Бинарные ресурсы не коммитятся.
После staging нового engine и сборки host с `custom-protocol` native Linux smoke
подтвердил реальный WebView и создание временной canonical library. Полный UI и
аппаратные сценарии этим не проверяются.

Это lifecycle boundary, не sandbox. Unix setsid/setpgid может отделить потомка;
отдельные вложенные process groups требуют собственного владельца. Unix Drop не
исполняется при SIGKILL/abort host. Windows имеет маленькое crash-окно между
suspended spawn и job assignment; атомарный job-list spawn через Win32 attributes
можно ввести отдельным срезом. Наличие supervisor не подтверждает полный crash
recovery или поддержку Linux speech/capture.
Встроенный Python bridge пока отдельно владеет своей FFmpeg session; его перенос
в общий runtime не выполнен.

Общие правила live coordinator уже подключены к Swift через [reducer](live-job-coordinator.md).
Следующий шаг — WorkerHost и Tauri queue. Python/model paths, установщик runtime,
credentials и аппаратные сценарии ещё требуют переноса; Swift пока остаётся.
