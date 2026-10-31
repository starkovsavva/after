//! Adapter for the isolated ASR worker. All meeting AI runs in Rust instead.
//!
//! A worker gets its own process group. SIGTERM/SIGINT, a closed UI pipe, and
//! error paths terminate the entire group, including ffmpeg/uv descendants.

use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};
use std::ffi::OsString;
use std::fs::OpenOptions;
use std::os::unix::fs::OpenOptionsExt;
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
    accepts_speech_key: bool,
}

/// Run only an audio/model command. Cloud/local LLM commands are deliberately
/// absent from the allowlist. Only explicitly selected cloud ASR may receive
/// its dedicated speech credential; all text-provider secrets are removed.
pub fn run_worker(
    root: &Path,
    backend: &Path,
    command: &str,
    meeting: Option<&Path>,
    speakers: u32,
    diarization: bool,
) -> Result<()> {
    let spec = worker_spec(root, backend, command, meeting, speakers, diarization)?;
    if !root.join("runtime/venv/bin/python").is_file() {
        bail!("Сначала установите модели в настройках.");
    }
    if !spec.executable.is_file() {
        bail!("В приложении отсутствует движок распознавания. Повторите установку приложения.");
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
    if !matches!(command, "prepare" | "transcribe" | "diarize" | "finalize" | "install-local") {
        bail!("Неизвестная команда модуля распознавания.");
    }
    let needs_meeting = matches!(command, "transcribe" | "diarize" | "finalize");
    if needs_meeting && meeting.is_none() {
        bail!("Не выбрана встреча для обработки.");
    }
    if meeting.is_some_and(|path| !path.is_absolute()) {
        bail!("Папка встречи должна иметь абсолютный путь.");
    }
    let mut arguments = vec![
        OsString::from("--posle-python-host"),
        root.join("runtime/venv/bin/python").into_os_string(),
        backend.join("engine.py").into_os_string(),
        OsString::from(command),
        OsString::from("--root"),
        root.as_os_str().to_owned(),
    ];
    if needs_meeting {
        arguments.push(OsString::from("--meeting"));
        arguments.push(meeting.unwrap().as_os_str().to_owned());
    }
    if matches!(command, "transcribe" | "diarize") {
        arguments.push(OsString::from("--speakers"));
        arguments.push(OsString::from(speakers.to_string()));
        if !diarization {
            arguments.push(OsString::from("--no-diarization"));
        }
    }
    Ok(WorkerSpec {
        executable: native_host_path(&std::env::current_exe()
            .map_err(|_| anyhow!("Не удалось найти движок приложения."))?),
        arguments,
        forwards_plain_progress: false,
        accepts_speech_key: command == "transcribe" && cloud_speech_selected(root),
    })
}

/// Resolve the outer application from either its compatibility CLI executable
/// or one of its nested helper applications. Helper resources belong to the
/// enclosing product, rather than the helper's own Contents directory.
pub fn application_contents(executable: &Path) -> Option<&Path> {
    let contents = executable.parent()
        .filter(|path| path.file_name().is_some_and(|name| name == "MacOS"))?
        .parent().filter(|path| path.file_name().is_some_and(|name| name == "Contents"))?;
    let package = contents.parent().filter(|path| path.extension().is_some_and(|name| name == "app"))?;
    if let Some(outer) = package.parent()
        .filter(|path| path.file_name().is_some_and(|name| name == "Helpers"))
        .and_then(Path::parent)
        .filter(|path| path.file_name().is_some_and(|name| name == "Contents"))
        .filter(|path| path.parent().is_some_and(|parent| parent.extension().is_some_and(|name| name == "app"))) {
        return Some(outer);
    }
    Some(contents)
}

/// Production uses a separately branded native helper inside the app. The
/// ordinary engine binary supports the same private entry point for developers.
fn native_host_path(engine: &Path) -> PathBuf {
    application_contents(engine)
        .map(|contents| {
            let directory = contents.join("Helpers/После Распознавание.app/Contents/MacOS");
            let current = directory.join("After Speech");
            let legacy = directory.join("После Речь");
            // A process from an earlier version may still see the old bundle
            // while an update is being applied. Never prefer the legacy file
            // when the current helper is present.
            if !current.is_file() && legacy.is_file() { legacy } else { current }
        })
        .unwrap_or_else(|| engine.to_owned())
}

fn setup_spec(root: &Path, backend: &Path) -> Result<WorkerSpec> {
    validate_paths(root, backend)?;
    Ok(WorkerSpec {
        executable: PathBuf::from("/bin/bash"),
        arguments: vec![OsString::from("-p"), backend.join("setup.sh").into_os_string(), root.as_os_str().to_owned(), native_host_path(&std::env::current_exe()?).into_os_string()],
        forwards_plain_progress: true,
        accepts_speech_key: false,
    })
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct SpeechSelection {
    speech_mode: Option<String>,
}

/// Match the worker's explicit job snapshot before consulting global settings.
/// A supplied invalid snapshot must not gain authority from a different disk
/// selection. Legacy calls without a snapshot use only a bounded regular file,
/// without following a replacement symlink.
fn cloud_speech_selected(root: &Path) -> bool {
    if let Some(snapshot) = std::env::var_os("POSLE_JOB_SETTINGS") {
        return snapshot.to_str()
            .and_then(|raw| crate::ai::snapshot_settings::<SpeechSelection>(raw).ok())
            .is_some_and(|settings| settings.speech_mode.as_deref() == Some("cloud"));
    }
    let Ok(file) = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(root.join("settings.json")) else { return false; };
    let Ok(metadata) = file.metadata() else { return false; };
    const MAX_SETTINGS: u64 = 1024 * 1024;
    if !metadata.is_file() || metadata.len() > MAX_SETTINGS { return false; }
    let mut bytes = Vec::new();
    if file.take(MAX_SETTINGS + 1).read_to_end(&mut bytes).is_err() || bytes.len() as u64 > MAX_SETTINGS {
        return false;
    }
    serde_json::from_slice::<Value>(&bytes).ok()
        .and_then(|settings| settings.get("speechMode").and_then(Value::as_str).map(|mode| mode == "cloud"))
        .unwrap_or(false)
}

/// Text-model credentials never cross into an audio worker. The single speech
/// credential is preserved only for a cloud transcription spec; setup and local
/// ASR receive the same stripped environment as before.
fn sanitize_environment(command: &mut Command, accepts_speech_key: bool,
                        variables: impl IntoIterator<Item = (OsString, OsString)>) {
    for (name, _) in variables {
        if unsafe_startup_key(&name) || (sensitive_key(&name.to_string_lossy()) && !(accepts_speech_key && name == "POSLE_SPEECH_API_KEY")) {
            command.env_remove(name);
        }
    }
    command.env_remove("POSLE_API_KEY");
    if !accepts_speech_key { command.env_remove("POSLE_SPEECH_API_KEY"); }
    for name in ["__PYVENV_LAUNCHER__", "PYTHONEXECUTABLE", "PYTHONHOME", "PYTHONPATH"] {
        command.env_remove(name);
    }
}

/// These controls can run code before setup's first statement or before a
/// spawned native helper reaches its own library-integrity validation.
fn unsafe_startup_key(name: &std::ffi::OsStr) -> bool {
    let name = name.to_string_lossy().to_ascii_uppercase();
    name.starts_with("DYLD_") || name.starts_with("LD_") || name.starts_with("BASH_FUNC_")
        || matches!(name.as_str(), "BASH_ENV" | "ENV" | "SHELLOPTS" | "BASHOPTS" | "CDPATH" | "GLOBIGNORE" | "IFS" | "PS4")
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
    fn from_environment() -> Self { Self::from_variables(std::env::vars_os()) }

    fn from_variables(variables: impl IntoIterator<Item = (OsString, OsString)>) -> Self {
        let mut values = Vec::new();
        for (name, value) in variables {
            let name = name.to_string_lossy();
            // pip/proxy URLs may contain basic-auth credentials. They remain
            // usable for installation, but never become progress messages.
            let url_setting = ["PIP_INDEX_URL", "PIP_EXTRA_INDEX_URL", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"]
                .iter().any(|key| name.eq_ignore_ascii_case(key));
            if sensitive_key(&name) || url_setting {
                if let Some(value) = value.to_str().filter(|value| value.len() >= 4 || (name == "POSLE_SPEECH_API_KEY" && !value.is_empty())) {
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
    sanitize_environment(&mut command, spec.accepts_speech_key, std::env::vars_os());
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
        assert_eq!(spec.executable, std::env::current_exe().unwrap());
        assert_eq!(strings(&spec), vec![
            "--posle-python-host", "/tmp/После данные/runtime/venv/bin/python",
            "/Applications/После.app/Contents/Resources/backend/engine.py", "transcribe", "--root",
            "/tmp/После данные", "--meeting", "/tmp/После данные/meetings/$(touch impossible); моя встреча",
            "--speakers", "3", "--no-diarization",
        ]);
    }

    #[test]
    fn production_selects_branded_helper_and_development_keeps_native_engine() {
        let fixture = tempfile::tempdir().unwrap();
        let contents = fixture.path().join("After.app/Contents");
        let bundled = contents.join("MacOS/posle-engine");
        let directory = contents.join("Helpers/После Распознавание.app/Contents/MacOS");
        let current = directory.join("After Speech");
        let legacy = directory.join("После Речь");
        std::fs::create_dir_all(&directory).unwrap();
        assert_eq!(native_host_path(&bundled), current);
        std::fs::write(&legacy, b"legacy").unwrap();
        assert_eq!(native_host_path(&bundled), legacy);
        std::fs::write(&current, b"current").unwrap();
        assert_eq!(native_host_path(&bundled), current);
        let processing = contents.join("Helpers/После Обработка.app/Contents/MacOS/After Processing");
        assert_eq!(native_host_path(&processing), current);
        assert_eq!(application_contents(&processing), Some(contents.as_path()));
        let development = Path::new("/tmp/build/debug/posle-engine");
        assert_eq!(native_host_path(development), development);
        assert!(application_contents(development).is_none());
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
        let expected_host = native_host_path(&std::env::current_exe().unwrap());
        assert_eq!(strings(&spec), vec!["-p", "/tmp/моё приложение/setup.sh", "/tmp/a b; literal", expected_host.to_str().unwrap()]);
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

    #[test]
    fn only_cloud_transcription_specs_may_receive_the_speech_key() {
        let root = tempfile::tempdir().unwrap();
        let backend = Path::new("/tmp/backend");
        let meeting = Path::new("/tmp/meeting");
        std::fs::write(root.path().join("settings.json"), r#"{"speechMode":"cloud"}"#).unwrap();
        for command in ["prepare", "transcribe", "diarize", "finalize", "install-local"] {
            let spec = worker_spec(root.path(), backend, command, Some(meeting), 0, true).unwrap();
            assert_eq!(spec.accepts_speech_key, command == "transcribe");
        }
        assert!(!setup_spec(root.path(), backend).unwrap().accepts_speech_key);
        for content in [r#"{"speechMode":"local"}"#, r#"{"mode":"cloud"}"#, "broken JSON"] {
            std::fs::write(root.path().join("settings.json"), content).unwrap();
            assert!(!worker_spec(root.path(), backend, "transcribe", Some(meeting), 0, true).unwrap().accepts_speech_key);
        }
        std::fs::remove_file(root.path().join("settings.json")).unwrap();
        assert!(!cloud_speech_selected(root.path()));
        let target = root.path().join("linked-settings.json");
        std::fs::write(&target, r#"{"speechMode":"cloud"}"#).unwrap();
        std::os::unix::fs::symlink(&target, root.path().join("settings.json")).unwrap();
        assert!(!cloud_speech_selected(root.path()));
    }

    #[test]
    fn queued_speech_credentials_follow_the_validated_snapshot_in_isolated_children() {
        use std::os::unix::ffi::OsStringExt;
        const CHILD_ROOT: &str = "POSLE_TEST_WORKER_SNAPSHOT_ROOT";
        const EXPECT_KEY: &str = "POSLE_TEST_WORKER_EXPECT_SPEECH_KEY";
        if let Some(root) = std::env::var_os(CHILD_ROOT) {
            let root = Path::new(&root);
            let expected = std::env::var(EXPECT_KEY).unwrap() == "true";
            for name in ["prepare", "transcribe", "diarize", "finalize", "install-local"] {
                let spec = worker_spec(root, Path::new("/tmp/backend"), name, Some(Path::new("/tmp/meeting")), 0, true).unwrap();
                let authorized = name == "transcribe" && expected;
                assert_eq!(spec.accepts_speech_key, authorized, "{name}");
                let variables: Vec<(OsString, OsString)> = [
                    ("POSLE_SPEECH_API_KEY", "synthetic-speech-key"),
                    ("POSLE_API_KEY", "synthetic-text-key"),
                    ("OPENAI_API_KEY", "synthetic-other-key"),
                ].into_iter().map(|(key,value)| (key.into(),value.into())).collect();
                let mut child = Command::new("/usr/bin/env");
                child.env_clear().envs(variables.clone());
                sanitize_environment(&mut child, spec.accepts_speech_key, variables);
                let output = child.output().unwrap();
                assert!(output.status.success());
                let text = String::from_utf8(output.stdout).unwrap();
                assert_eq!(text.contains("POSLE_SPEECH_API_KEY=synthetic-speech-key"), authorized);
                assert!(!text.contains("POSLE_API_KEY="));
                assert!(!text.contains("OPENAI_API_KEY="));
                assert!(!strings(&spec).iter().any(|arg| arg.contains("synthetic-speech-key") || arg.contains("speechMode")));
            }
            assert!(!setup_spec(root, Path::new("/tmp/backend")).unwrap().accepts_speech_key);
            return;
        }
        let root = tempfile::tempdir().unwrap();
        let mut cases = vec![
            (Some(OsString::from(r#"{"speechMode":"cloud"}"#)), "local", true),
            (Some(OsString::from(r#"{"speechMode":"local"}"#)), "cloud", false),
            (None, "cloud", true),
            (None, "local", false),
        ];
        for raw in ["", "broken", "null", "[]", r#"["cloud"]"#, "{}", r#"{"mode":"cloud"}"#,
                    r#"{"speechMode":true}"#, r#"{"speechMode":null}"#] {
            cases.push((Some(raw.into()), "cloud", false));
        }
        cases.push((Some(format!(r#"{{"speechMode":"cloud","focus":"{}"}}"#, "x".repeat(256 * 1024)).into()), "cloud", false));
        cases.push((Some(OsString::from_vec(vec![0xff])), "cloud", false));
        for (index, (snapshot, disk_mode, expected)) in cases.into_iter().enumerate() {
            std::fs::write(root.path().join("settings.json"), json!({"speechMode":disk_mode}).to_string()).unwrap();
            let mut child = Command::new(std::env::current_exe().unwrap());
            child.args(["--exact", "worker::tests::queued_speech_credentials_follow_the_validated_snapshot_in_isolated_children", "--nocapture"])
                .env(CHILD_ROOT, root.path()).env(EXPECT_KEY, expected.to_string()).env_remove("POSLE_JOB_SETTINGS");
            if let Some(snapshot) = snapshot { child.env("POSLE_JOB_SETTINGS", snapshot); }
            let output = child.output().unwrap();
            assert!(output.status.success(), "isolated case {index}: {}\n{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
        }
    }

    #[test]
    fn actual_child_receives_only_authorized_speech_credential() {
        let variables: Vec<(OsString, OsString)> = [
            ("POSLE_SPEECH_API_KEY", "test-only-speech-key"),
            ("POSLE_API_KEY", "test-text-key"), ("OPENAI_API_KEY", "other-text-key"),
            ("HF_TOKEN", "test-hf-token"), ("AWS_SECRET_ACCESS_KEY", "test-aws-secret"),
            ("PYTHONPATH", "/untrusted/python"), ("SAFE_SETTING", "retained"),
            ("BASH_ENV", "/untrusted/startup"), ("ENV", "/untrusted/startup"), ("SHELLOPTS", "xtrace"),
            ("BASHOPTS", "expand_aliases"), ("BASH_FUNC_echo%%", "() { false; }"),
            ("DYLD_INSERT_LIBRARIES", "/untrusted/library"), ("LD_PRELOAD", "/untrusted/library"),
        ].into_iter().map(|(key, value)| (key.into(), value.into())).collect();
        for accepts_speech_key in [false, true] {
            let mut child = Command::new("/usr/bin/env");
            child.env_clear().envs(variables.clone());
            sanitize_environment(&mut child, accepts_speech_key, variables.clone());
            let output = child.output().unwrap();
            assert!(output.status.success());
            let text = String::from_utf8(output.stdout).unwrap();
            assert_eq!(text.contains("POSLE_SPEECH_API_KEY=test-only-speech-key"), accepts_speech_key);
            assert!(text.contains("SAFE_SETTING=retained"));
            for forbidden in ["POSLE_API_KEY=", "OPENAI_API_KEY=", "HF_TOKEN=", "AWS_SECRET_ACCESS_KEY=", "PYTHONPATH=", "BASH_ENV=", "ENV=", "SHELLOPTS=", "BASHOPTS=", "BASH_FUNC_", "DYLD_", "LD_PRELOAD="] {
                assert!(!text.contains(forbidden));
            }
            let redactor = Redactor::from_variables(variables.clone());
            assert_eq!(redactor.clean("speech test-only-speech-key; text test-text-key", 200), "speech [hidden]; text [hidden]");
            assert!(!redactor.clean(&text, 2000).contains("test-only-speech-key"));
        }
        let short = Redactor::from_variables([(OsString::from("POSLE_SPEECH_API_KEY"), OsString::from("abc"))]);
        assert_eq!(short.clean("key: abc", 100), "key: [hidden]");
    }

    #[test]
    fn installer_never_executes_shell_environment_before_its_verifier_guard() {
        let temp = tempfile::tempdir().unwrap();
        let backend = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().join("backend");
        let startup = temp.path().join("startup.sh");
        let marker = temp.path().join("startup-executed");
        std::fs::write(&startup, ": > \"$POSLE_TEST_STARTUP_MARKER\"\nexit 73\n").unwrap();
        for privileged in [true, false] {
            let mut spec = setup_spec(temp.path(), &backend).unwrap();
            *spec.arguments.last_mut().unwrap() = OsString::from("/nonexistent-posle-test-host");
            if !privileged { assert_eq!(spec.arguments.remove(0), "-p"); }
            let variables: Vec<(OsString, OsString)> = vec![
                ("PATH".into(), "/usr/bin:/bin".into()), ("BASH_ENV".into(), startup.as_os_str().to_owned()),
                ("ENV".into(), startup.as_os_str().to_owned()), ("POSLE_TEST_STARTUP_MARKER".into(), marker.as_os_str().to_owned()),
                ("BASH_FUNC_echo%%".into(), r#"() { /usr/bin/touch "$POSLE_TEST_STARTUP_MARKER"; }"#.into()),
            ];
            let mut command = Command::new(spec.executable);
            command.args(spec.arguments).env_clear().envs(variables.clone());
            // Check each protection independently: privileged bash ignores even
            // an explicitly supplied startup; sanitization also protects bash
            // without -p if a future caller accidentally drops that argument.
            if !privileged { sanitize_environment(&mut command, false, variables); }
            let output = command.output().unwrap();
            assert!(!output.status.success());
            assert_ne!(output.status.code(), Some(73));
            assert!(!marker.exists(), "Shell startup ran before the verifier guard");
            assert!(!temp.path().join("runtime").exists(), "Setup advanced past its missing-verifier guard");
        }
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
            accepts_speech_key: false,
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
