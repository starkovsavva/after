//! Adapter for the isolated ASR worker. All meeting AI runs in Rust instead.
//!
//! A worker gets its own process group. SIGTERM/SIGINT, a closed UI pipe, and
//! error paths terminate the entire group, including ffmpeg/uv descendants.

use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};
use std::ffi::OsString;
use std::io::{self, Read, Write};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const MAX_LINE_BYTES: usize = 16 * 1024;
const TERMINATE_GRACE: Duration = Duration::from_secs(2);
static CANCEL_SIGNAL: AtomicI32 = AtomicI32::new(0);
// Signal dispositions belong to the process, rather than an individual thread.
static WORKER_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug)]
struct ReportedWorkerError;

impl std::fmt::Display for ReportedWorkerError {
    fn fmt(&self, output: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        output.write_str("Обработка не завершена.")
    }
}

impl std::error::Error for ReportedWorkerError {}

/// Avoid replacing a detailed worker error event with a second generic event.
pub fn error_was_reported(error: &anyhow::Error) -> bool {
    error.is::<ReportedWorkerError>()
}

#[derive(Debug)]
struct WorkerSpec {
    executable: PathBuf,
    arguments: Vec<OsString>,
    forwards_plain_progress: bool,
}

/// Run only an audio/model command. Cloud/local LLM commands are deliberately
/// absent from the allowlist, and provider secrets are removed from the child.
pub fn run_worker(
    root: &Path,
    backend: &Path,
    command: &str,
    meeting: Option<&Path>,
    speakers: u32,
    diarization: bool,
) -> Result<()> {
    let spec = worker_spec(root, backend, command, meeting, speakers, diarization)?;
    if !spec.executable.is_file() {
        bail!("Сначала установите модели в настройках.");
    }
    if !backend.join("engine.py").is_file() {
        bail!("В приложении отсутствует модуль распознавания. Повторите установку приложения.");
    }
    run(root, spec)
}

/// Install the private Python runtime and ASR dependencies, without a shell
/// command string, shell profile changes, or passing any API key to the script.
pub fn install_runtime(root: &Path, backend: &Path) -> Result<()> {
    let spec = setup_spec(root, backend)?;
    if !backend.join("setup.sh").is_file() {
        bail!("В приложении отсутствует установщик моделей. Повторите установку приложения.");
    }
    run(root, spec)
}

fn validate_paths(root: &Path, backend: &Path) -> Result<()> {
    if !root.is_absolute() || !backend.is_absolute() {
        bail!("Папки данных и модуля распознавания должны иметь абсолютные пути.");
    }
    Ok(())
}

fn worker_spec(
    root: &Path,
    backend: &Path,
    command: &str,
    meeting: Option<&Path>,
    speakers: u32,
    diarization: bool,
) -> Result<WorkerSpec> {
    validate_paths(root, backend)?;
    if !matches!(command, "prepare" | "transcribe" | "finalize" | "install-local") {
        bail!("Неизвестная команда модуля распознавания.");
    }
    let needs_meeting = matches!(command, "transcribe" | "finalize");
    if needs_meeting && meeting.is_none() {
        bail!("Не выбрана встреча для обработки.");
    }
    if meeting.is_some_and(|path| !path.is_absolute()) {
        bail!("Папка встречи должна иметь абсолютный путь.");
    }
    let mut arguments = vec![
        backend.join("engine.py").into_os_string(),
        OsString::from(command),
        OsString::from("--root"),
        root.as_os_str().to_owned(),
    ];
    if needs_meeting {
        arguments.push(OsString::from("--meeting"));
        arguments.push(meeting.unwrap().as_os_str().to_owned());
    }
    if command == "transcribe" {
        arguments.push(OsString::from("--speakers"));
        arguments.push(OsString::from(speakers.to_string()));
        if !diarization {
            arguments.push(OsString::from("--no-diarization"));
        }
    }
    Ok(WorkerSpec {
        executable: root.join("runtime/venv/bin/python"),
        arguments,
        forwards_plain_progress: false,
    })
}

fn setup_spec(root: &Path, backend: &Path) -> Result<WorkerSpec> {
    validate_paths(root, backend)?;
    Ok(WorkerSpec {
        executable: PathBuf::from("/bin/bash"),
        arguments: vec![backend.join("setup.sh").into_os_string(), root.as_os_str().to_owned()],
        forwards_plain_progress: true,
    })
}

extern "C" fn cancel_signal(signal: libc::c_int) {
    // Atomic operations are lock-free on the supported Apple Silicon target.
    CANCEL_SIGNAL.store(signal, Ordering::Relaxed);
}

struct SignalGuard {
    previous: Vec<(libc::c_int, libc::sigaction)>,
}

impl SignalGuard {
    fn install() -> Result<Self> {
        let mut guard = Self { previous: Vec::new() };
        CANCEL_SIGNAL.store(0, Ordering::Relaxed);
        for signal in [libc::SIGTERM, libc::SIGINT] {
            // sigaction/sigemptyset initialize the platform-defined C structs.
            let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
            let mut previous: libc::sigaction = unsafe { std::mem::zeroed() };
            action.sa_sigaction = cancel_signal as *const () as libc::sighandler_t;
            action.sa_flags = 0;
            unsafe { libc::sigemptyset(&mut action.sa_mask) };
            if unsafe { libc::sigaction(signal, &action, &mut previous) } != 0 {
                bail!("Не удалось подготовить безопасную отмену обработки.");
            }
            guard.previous.push((signal, previous));
        }
        Ok(guard)
    }
}

impl Drop for SignalGuard {
    fn drop(&mut self) {
        for (signal, action) in self.previous.iter().rev() {
            unsafe { libc::sigaction(*signal, action, std::ptr::null_mut()) };
        }
    }
}

struct ChildGroup {
    child: Child,
    group: libc::pid_t,
}

impl ChildGroup {
    fn signal(&self, signal: libc::c_int) {
        // A negative PID addresses the private group, never the UI's group.
        unsafe { libc::kill(-self.group, signal) };
    }
}

impl Drop for ChildGroup {
    fn drop(&mut self) {
        // Also handles early Rust errors/panics after spawn. wait() reaps the
        // direct child; killing the group prevents orphan ASR/GPU processes.
        self.signal(libc::SIGKILL);
        let _ = self.child.wait();
    }
}

fn sensitive_key(name: &str) -> bool {
    let name = name.to_ascii_uppercase();
    ["API_KEY", "ACCESS_KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "COOKIE"]
        .iter()
        .any(|part| name.contains(part))
}

#[derive(Clone, Default)]
struct Redactor {
    values: Vec<String>,
}

impl Redactor {
    fn from_environment() -> Self {
        let mut values = Vec::new();
        for (name, value) in std::env::vars_os() {
            let name = name.to_string_lossy();
            // pip/proxy URLs may contain basic-auth credentials. They remain
            // usable for installation, but never become progress messages.
            let url_setting = ["PIP_INDEX_URL", "PIP_EXTRA_INDEX_URL", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"]
                .iter().any(|key| name.eq_ignore_ascii_case(key));
            if sensitive_key(&name) || url_setting {
                if let Some(value) = value.to_str().filter(|value| value.len() >= 4) {
                    values.push(value.to_owned());
                }
            }
        }
        values.sort_by_key(|value| std::cmp::Reverse(value.len()));
        values.dedup();
        Self { values }
    }

    fn clean(&self, text: &str, maximum: usize) -> String {
        let mut cleaned = text.to_owned();
        for secret in &self.values {
            cleaned = cleaned.replace(secret, "[hidden]");
        }
        cleaned.chars().take(maximum).collect()
    }
}

fn run(root: &Path, spec: WorkerSpec) -> Result<()> {
    let _single_worker = WORKER_LOCK.lock().map_err(|_| anyhow!("Предыдущая обработка прервалась. Повторите попытку."))?;
    let _signals = SignalGuard::install()?;
    let initial_parent = unsafe { libc::getppid() };
    let redactor = Redactor::from_environment();
    let mut command = Command::new(&spec.executable);
    command.args(&spec.arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        // Never print stderr, command arguments, or process environments.
        .stderr(Stdio::null())
        .env("HF_HOME", root.join("cache/huggingface"))
        .env("HF_HUB_DISABLE_TELEMETRY", "1")
        .env("PYTHONUNBUFFERED", "1")
        .env("PYTHONDONTWRITEBYTECODE", "1")
        .process_group(0);
    for (name, _) in std::env::vars_os() {
        if sensitive_key(&name.to_string_lossy()) {
            command.env_remove(name);
        }
    }
    // Explicit even when the parent environment did not contain it at scan time.
    command.env_remove("POSLE_API_KEY");
    let child = command.spawn().map_err(|_| anyhow!("Не удалось запустить модуль распознавания. Проверьте установку моделей."))?;
    let group = libc::pid_t::try_from(child.id()).map_err(|_| anyhow!("Не удалось подготовить процесс распознавания."))?;
    let mut child = ChildGroup { child, group };
    let stdout = child.child.stdout.take().ok_or_else(|| anyhow!("Не удалось прочитать прогресс обработки."))?;
    let pipe_failed = Arc::new(AtomicBool::new(false));
    let reported_error = Arc::new(AtomicBool::new(false));
    let failed_for_reader = Arc::clone(&pipe_failed);
    let error_for_reader = Arc::clone(&reported_error);
    let plain_progress = spec.forwards_plain_progress;
    let (sender, receiver) = mpsc::channel();
    let reader = thread::Builder::new().name("posle-worker-progress".into()).spawn(move || {
        let result = forward_stdout(stdout, plain_progress, &redactor, &error_for_reader);
        if result.is_err() { failed_for_reader.store(true, Ordering::Release); }
        let _ = sender.send(result);
    }).map_err(|_| anyhow!("Не удалось прочитать прогресс обработки."))?;

    let mut termination_started: Option<Instant> = None;
    let mut killed = false;
    let mut cancelled = false;
    let status: ExitStatus = loop {
        // Also stop if the UI crashes before it can send SIGTERM or consume
        // another progress event. Reparenting is observable without polling UI.
        let parent_gone = initial_parent > 1 && unsafe { libc::getppid() } != initial_parent;
        if CANCEL_SIGNAL.load(Ordering::Relaxed) != 0 || pipe_failed.load(Ordering::Acquire) || parent_gone {
            cancelled |= CANCEL_SIGNAL.load(Ordering::Relaxed) != 0;
            if termination_started.is_none() {
                child.signal(libc::SIGTERM);
                termination_started = Some(Instant::now());
            }
        }
        if !killed && termination_started.is_some_and(|start| start.elapsed() >= TERMINATE_GRACE) {
            child.signal(libc::SIGKILL);
            killed = true;
        }
        if let Some(status) = child.child.try_wait().map_err(|_| anyhow!("Не удалось дождаться завершения обработки."))? {
            break status;
        }
        thread::sleep(Duration::from_millis(25));
    };
    // A failed shell/Python may have left descendants keeping stdout open.
    child.signal(libc::SIGTERM);
    let output = match receiver.recv_timeout(TERMINATE_GRACE) {
        Ok(result) => result,
        Err(mpsc::RecvTimeoutError::Timeout) => {
            child.signal(libc::SIGKILL);
            receiver.recv_timeout(TERMINATE_GRACE)
                .map_err(|_| anyhow!("Не удалось завершить модуль распознавания."))?
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => bail!("Не удалось прочитать прогресс обработки."),
    };
    let _ = reader.join();
    if cancelled || CANCEL_SIGNAL.load(Ordering::Relaxed) != 0 {
        bail!("Обработка остановлена. Исходная запись сохранена.");
    }
    output.map_err(|_| anyhow!("Соединение с приложением прервалось. Обработка остановлена."))?;
    if !status.success() {
        if reported_error.load(Ordering::Acquire) {
            return Err(ReportedWorkerError.into());
        }
        if let Some(code) = status.code() {
            bail!("Обработка не завершена (код {}). Проверьте установку моделей.", code);
        }
        if let Some(signal) = status.signal() {
            bail!("Обработка прервана системой (сигнал {}). Исходная запись сохранена.", signal);
        }
        bail!("Обработка не завершена. Исходная запись сохранена.");
    }
    if reported_error.load(Ordering::Acquire) {
        return Err(ReportedWorkerError.into());
    }
    Ok(())
}

fn write_event(event: &Value) -> io::Result<()> {
    let mut output = io::stdout().lock();
    serde_json::to_writer(&mut output, event)?;
    output.write_all(b"\n")?;
    output.flush()
}

fn forward_line(line: &[u8], plain_progress: bool, redactor: &Redactor, reported_error: &AtomicBool) -> io::Result<()> {
    if let Ok(value) = serde_json::from_slice::<Value>(line) {
        match value.get("event").and_then(Value::as_str) {
            Some("progress") => {
                let message = redactor.clean(value.get("message").and_then(Value::as_str).unwrap_or("Обрабатываю встречу…"), 2000);
                let fraction = value.get("fraction").and_then(Value::as_f64).filter(|value| value.is_finite()).unwrap_or(-1.0);
                write_event(&json!({"event": "progress", "message": message, "fraction": fraction}))?;
            }
            Some("error") => {
                reported_error.store(true, Ordering::Release);
                let message = redactor.clean(value.get("message").and_then(Value::as_str).unwrap_or("Обработка не завершена."), 2000);
                write_event(&json!({"event": "error", "message": message}))?;
            }
            // The Rust entry point emits one final done after this function.
            _ => {}
        }
    } else if plain_progress {
        let message = redactor.clean(String::from_utf8_lossy(line).trim(), 240);
        if !message.is_empty() {
            write_event(&json!({"event": "progress", "message": message, "fraction": -1.0}))?;
        }
    }
    Ok(())
}

fn forward_stdout(mut input: impl Read, plain_progress: bool, redactor: &Redactor, reported_error: &AtomicBool) -> io::Result<()> {
    let mut buffer = [0_u8; 4096];
    let mut line = Vec::with_capacity(4096);
    let mut oversized = false;
    loop {
        let count = match input.read(&mut buffer) {
            Ok(count) => count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        if count == 0 { break; }
        for byte in &buffer[..count] {
            if *byte == b'\n' {
                if !oversized { forward_line(&line, plain_progress, redactor, reported_error)?; }
                line.clear(); oversized = false;
            } else if !oversized {
                if line.len() < MAX_LINE_BYTES { line.push(*byte); }
                else { line.clear(); oversized = true; }
            }
        }
    }
    if !line.is_empty() && !oversized {
        forward_line(&line, plain_progress, redactor, reported_error)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(spec: &WorkerSpec) -> Vec<String> {
        spec.arguments.iter().map(|argument| argument.to_string_lossy().into_owned()).collect()
    }

    #[test]
    fn transcription_arguments_keep_unicode_spaces_and_shell_text_literal() {
        let root = Path::new("/tmp/После данные");
        let backend = Path::new("/Applications/После.app/Contents/Resources/backend");
        let meeting = Path::new("/tmp/После данные/meetings/$(touch impossible); моя встреча");
        let spec = worker_spec(root, backend, "transcribe", Some(meeting), 3, false).unwrap();
        assert_eq!(spec.executable, root.join("runtime/venv/bin/python"));
        assert_eq!(strings(&spec), vec![
            "/Applications/После.app/Contents/Resources/backend/engine.py", "transcribe", "--root",
            "/tmp/После данные", "--meeting", "/tmp/После данные/meetings/$(touch impossible); моя встреча",
            "--speakers", "3", "--no-diarization",
        ]);
    }

    #[test]
    fn rejects_ai_commands_and_missing_or_relative_paths() {
        let root = Path::new("/tmp/data");
        let backend = Path::new("/tmp/backend");
        for command in ["summarize", "example", "review", "pull", "check", "transcribe; echo secret"] {
            assert!(worker_spec(root, backend, command, None, 0, true).is_err());
        }
        assert!(worker_spec(root, backend, "transcribe", None, 0, true).is_err());
        assert!(worker_spec(root, backend, "finalize", Some(Path::new("relative")), 0, true).is_err());
        assert!(worker_spec(Path::new("relative"), backend, "prepare", None, 0, true).is_err());
        assert!(setup_spec(root, Path::new("relative")).is_err());
    }

    #[test]
    fn non_transcription_commands_do_not_receive_speaker_options() {
        for command in ["prepare", "install-local", "finalize"] {
            let spec = worker_spec(Path::new("/tmp/data"), Path::new("/tmp/backend"), command, Some(Path::new("/tmp/meeting")), 4, false).unwrap();
            assert!(!strings(&spec).iter().any(|argument| argument == "--speakers" || argument == "--no-diarization"));
        }
    }

    #[test]
    fn setup_uses_bash_file_arguments_and_no_command_string() {
        let spec = setup_spec(Path::new("/tmp/a b; literal"), Path::new("/tmp/моё приложение")).unwrap();
        assert_eq!(spec.executable, Path::new("/bin/bash"));
        assert_eq!(strings(&spec), vec!["/tmp/моё приложение/setup.sh", "/tmp/a b; literal"]);
        assert!(spec.forwards_plain_progress);
    }

    #[test]
    fn redacts_secrets_before_truncating_and_removes_provider_variables() {
        let redactor = Redactor { values: vec!["private-provider-key".into()] };
        assert_eq!(redactor.clean("private-provider-key failed", 100), "[hidden] failed");
        for key in ["POSLE_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "HF_TOKEN", "AWS_SECRET_ACCESS_KEY"] {
            assert!(sensitive_key(key));
        }
        assert!(!sensitive_key("PATH"));
        assert!(!sensitive_key("HOME"));
    }

    // This helper runs only in a separate copy of the test binary: sending
    // SIGTERM to the ordinary cargo test runner would disturb unrelated tests.
    #[test]
    fn cancellation_helper() {
        let Some(directory) = std::env::var_os("POSLE_WORKER_TEST_DIRECTORY") else { return; };
        let directory = PathBuf::from(directory);
        let result = run(&directory, WorkerSpec {
            executable: PathBuf::from("/bin/bash"),
            arguments: vec![directory.join("fixture.sh").into_os_string(), directory.join("pids").into_os_string()],
            forwards_plain_progress: false,
        });
        assert!(result.unwrap_err().to_string().contains("остановлена"));
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn sigterm_to_adapter_terminates_worker_and_its_descendant() {
        use std::fs;
        use std::time::{SystemTime, UNIX_EPOCH};

        struct Fixture {
            directory: PathBuf,
            helper: Option<Child>,
            pids: Vec<libc::pid_t>,
        }
        impl Drop for Fixture {
            fn drop(&mut self) {
                // Cleanup also runs if an assertion fails.
                for pid in &self.pids { unsafe { libc::kill(*pid, libc::SIGKILL); } }
                if let Some(helper) = &mut self.helper {
                    let _ = helper.kill();
                    let _ = helper.wait();
                }
                let _ = fs::remove_dir_all(&self.directory);
            }
        }
        let unique = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let directory = std::env::temp_dir().join(format!("posle-worker-cancel-{}-{unique}", std::process::id()));
        fs::create_dir(&directory).unwrap();
        let mut fixture = Fixture { directory, helper: None, pids: Vec::new() };
        fs::write(fixture.directory.join("fixture.sh"), "#!/bin/bash\nsleep 120 &\nprintf '%s\\n%s\\n' \"$$\" \"$!\" > \"$1\"\nwait\n").unwrap();
        fixture.helper = Some(Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "worker::tests::cancellation_helper", "--nocapture", "--test-threads=1"])
            .env("POSLE_WORKER_TEST_DIRECTORY", &fixture.directory)
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
            .spawn().unwrap());
        let started = Instant::now();
        while fixture.pids.len() != 2 && started.elapsed() < Duration::from_secs(5) {
            if let Ok(text) = fs::read_to_string(fixture.directory.join("pids")) {
                if text.ends_with('\n') {
                    fixture.pids = text.lines().filter_map(|line| line.parse().ok()).collect();
                }
            }
            if fixture.pids.len() == 2 { break; }
            thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(fixture.pids.len(), 2, "worker did not start");
        let helper_pid = fixture.helper.as_ref().unwrap().id() as libc::pid_t;
        assert_eq!(unsafe { libc::kill(helper_pid, libc::SIGTERM) }, 0);
        let stopped = Instant::now();
        let status = loop {
            if let Some(status) = fixture.helper.as_mut().unwrap().try_wait().unwrap() { break status; }
            assert!(stopped.elapsed() < Duration::from_secs(6), "adapter failed to stop");
            thread::sleep(Duration::from_millis(20));
        };
        assert!(status.success(), "isolated cancellation test failed");
        // launchd may need a brief moment to reap an orphaned sleep process.
        let reaping = Instant::now();
        while fixture.pids.iter().any(|pid| unsafe { libc::kill(*pid, 0) } == 0)
            && reaping.elapsed() < Duration::from_secs(2) {
            thread::sleep(Duration::from_millis(20));
        }
        for pid in &fixture.pids {
            assert_eq!(unsafe { libc::kill(*pid, 0) }, -1, "worker descendant survived cancellation");
        }
    }
}
