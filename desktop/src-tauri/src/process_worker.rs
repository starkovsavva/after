//! Process adapter for the closed streaming import protocol.
use crate::{
    models::{HostError, Meeting},
    worker_host::*,
};
use after_process_runtime::ProcessTree;
use serde::Deserialize;
use serde_json::json;
use std::{
    io::{BufRead, BufReader, Read, Write},
    path::Path,
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};
pub(crate) struct ProcessWorker<'a> {
    pub engine: &'a Path,
    pub root: &'a Path,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Frame {
    version: u8,
    operation_id: String,
    attempt_token: String,
    payload: Payload,
}
#[derive(Deserialize)]
#[serde(tag = "event", rename_all = "snake_case", deny_unknown_fields)]
enum Payload {
    Progress { progress: ImportProgress },
    Committed { meeting: Meeting },
    Cancelled,
    Failed,
}
enum Event {
    Frame(Frame),
    OutputDone,
    InputDone,
    Error(HostError),
    StderrDone,
}
fn error() -> HostError {
    HostError::new(
        "import_failed",
        "Could not import this file. The original was preserved.",
    )
}
fn protocol() -> HostError {
    HostError::new(
        "invalid_response",
        "The import worker returned an invalid response.",
    )
}
fn frames(input: impl Read, sender: &mpsc::SyncSender<Event>) -> Result<(), HostError> {
    let mut input = BufReader::new(input);
    let mut total = 0usize;
    loop {
        let mut bytes = Vec::new();
        Read::by_ref(&mut input)
            .take(65_537)
            .read_until(b'\n', &mut bytes)
            .map_err(|_| error())?;
        if bytes.is_empty() {
            return Ok(());
        }
        total = total.saturating_add(bytes.len());
        if bytes.len() > 65_536 || total > 64 * 1024 * 1024 || !bytes.ends_with(b"\n") {
            return Err(protocol());
        }
        let frame = serde_json::from_slice(&bytes).map_err(|_| protocol())?;
        sender.send(Event::Frame(frame)).map_err(|_| error())?;
    }
}
impl WorkerHost for ProcessWorker<'_> {
    fn import(
        &self,
        work: &ImportWork,
        cancelled: &AtomicBool,
        progress: &mut dyn FnMut(ImportProgress),
    ) -> Result<Meeting, HostError> {
        if cancelled.load(Ordering::Acquire) {
            return Err(HostError::new("cancelled", "Import cancelled."));
        }
        let source = work
            .source
            .to_str()
            .filter(|path| path.len() <= 32760 && !path.contains('\0'))
            .ok_or_else(HostError::invalid)?;
        if !work.source.is_absolute()
            || work.operation_id.len() != 36
            || uuid::Uuid::parse_str(&work.operation_id).is_err()
            || work.attempt_token.len() != 36
            || uuid::Uuid::parse_str(&work.attempt_token).is_err()
        {
            return Err(HostError::invalid());
        }
        let mut input = serde_json::to_vec(&json!({"version":1,"operationId":work.operation_id,"attemptToken":work.attempt_token,"sourcePath":source,"title":work.title})).map_err(|_| HostError::invalid())?;
        if input.len() > 256 * 1024 {
            return Err(HostError::invalid());
        }
        input.push(b'\n');
        let mut command = Command::new(self.engine);
        command
            .args(["desktop-import-worker", "--root"])
            .arg(self.root)
            .current_dir(self.root)
            .env_clear()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for name in ["SystemRoot", "WINDIR", "TMP", "TEMP", "LANG", "LC_ALL"] {
            if let Some(value) = std::env::var_os(name) {
                command.env(name, value);
            }
        }
        let mut child = ProcessTree::spawn(&mut command).map_err(|_| error())?;
        let mut stdin = child.take_stdin().ok_or_else(error)?;
        let stdout = child.take_stdout().ok_or_else(error)?;
        let stderr = child.take_stderr().ok_or_else(error)?;
        let (sender, receiver) = mpsc::sync_channel(16);
        let (cancel_sender, cancel_receiver) = mpsc::channel();
        let tx = sender.clone();
        thread::spawn(move || {
            match stdin.write_all(&input) {
                Ok(()) => {
                    let _ = tx.send(Event::InputDone);
                }
                Err(_) => {
                    let _ = tx.send(Event::Error(error()));
                    return;
                }
            }
            if cancel_receiver.recv().is_ok() {
                let _ = stdin.write_all(b"cancel\n");
            }
        });
        let tx = sender.clone();
        thread::spawn(move || {
            let event = match frames(stdout, &tx) {
                Ok(()) => Event::OutputDone,
                Err(error) => Event::Error(error),
            };
            let _ = tx.send(event);
        });
        thread::spawn(move || {
            let mut bytes = Vec::new();
            let event = match stderr.take(65_537).read_to_end(&mut bytes) {
                Ok(_) if bytes.len() <= 65_536 => Event::StderrDone,
                _ => Event::Error(error()),
            };
            let _ = sender.send(event);
        });
        let deadline = Instant::now() + Duration::from_secs(30 * 60);
        let mut cancelling = None;
        let mut terminal = None;
        let (mut input_done, mut output_done, mut stderr_done, mut exited) =
            (false, false, false, false);
        let mut previous: Option<ImportProgress> = None;
        loop {
            while let Ok(event) = receiver.try_recv() {
                match event {
                    Event::InputDone => input_done = true,
                    Event::OutputDone => output_done = true,
                    Event::StderrDone => stderr_done = true,
                    Event::Error(error) => return Err(error),
                    Event::Frame(frame) => {
                        if frame.version != 1
                            || frame.operation_id != work.operation_id
                            || frame.attempt_token != work.attempt_token
                            || terminal.is_some()
                        {
                            return Err(protocol());
                        }
                        match frame.payload {
                            Payload::Progress { progress: value } => {
                                if value.total_bytes == 0
                                    || value.copied_bytes > value.total_bytes
                                    || previous.is_some_and(|old| {
                                        value.total_bytes != old.total_bytes
                                            || value.copied_bytes < old.copied_bytes
                                            || (old.phase == ImportPhase::Committing
                                                && value.phase != ImportPhase::Committing)
                                    })
                                    || (value.phase == ImportPhase::Committing
                                        && value.copied_bytes != value.total_bytes)
                                {
                                    return Err(protocol());
                                }
                                previous = Some(value);
                                progress(value);
                            }
                            Payload::Committed { meeting } => {
                                if meeting.id != work.operation_id {
                                    return Err(protocol());
                                }
                                terminal = Some(Ok(meeting));
                            }
                            Payload::Cancelled => {
                                terminal =
                                    Some(Err(HostError::new("cancelled", "Import cancelled.")))
                            }
                            Payload::Failed => terminal = Some(Err(error())),
                        }
                    }
                }
            }
            if !exited {
                match child.try_wait().map_err(|_| error())? {
                    Some(status) if status.success() => exited = true,
                    Some(_) => return Err(error()),
                    None => {}
                }
            }
            if exited && input_done && output_done && stderr_done {
                return terminal.unwrap_or_else(|| Err(protocol()));
            }
            if cancelling.is_none()
                && (cancelled.load(Ordering::Acquire) || Instant::now() >= deadline)
            {
                let _ = cancel_sender.send(());
                cancelling = Some(Instant::now());
            }
            if cancelling.is_some_and(|at: Instant| at.elapsed() >= Duration::from_secs(3)) {
                return Err(HostError::new(
                    if cancelled.load(Ordering::Acquire) {
                        "cancelled"
                    } else {
                        "engine_timeout"
                    },
                    "Import stopped. The original was preserved.",
                ));
            }
            thread::sleep(Duration::from_millis(5));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn malformed_oversized_and_partial_frames_are_not_forwarded() {
        for bytes in [
            b"secret-path-not-json\n".to_vec(),
            vec![b'x'; 65_537],
            b"{\"version\":1}".to_vec(),
        ] {
            let (sender, _receiver) = mpsc::sync_channel(16);
            let error = frames(std::io::Cursor::new(bytes), &sender).unwrap_err();
            assert_eq!(error.code, "invalid_response");
            assert!(!error.message.contains("secret-path"));
        }
    }
    #[cfg(unix)]
    #[test]
    fn stale_operation_frames_are_rejected_without_waiting_for_the_worker() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let engine = temp.path().join("fixture-engine");
        let bytes = b"#!/bin/sh\nprintf '%s\\n' '{\"version\":1,\"operationId\":\"wrong\",\"attemptToken\":\"wrong\",\"payload\":{\"event\":\"failed\"}}'\n/bin/sleep 30\n";
        std::fs::write(&engine, bytes).unwrap();
        std::fs::set_permissions(&engine, std::fs::Permissions::from_mode(0o700)).unwrap();
        let work = ImportWork {
            operation_id: uuid::Uuid::new_v4().to_string(),
            attempt_token: uuid::Uuid::new_v4().to_string(),
            source: temp.path().join("private.wav"),
            title: None,
        };
        let result = ProcessWorker {
            engine: &engine,
            root: temp.path(),
        }
        .import(&work, &AtomicBool::new(false), &mut |_| {});
        assert_eq!(result.unwrap_err().code, "invalid_response");
    }
    #[cfg(unix)]
    #[test]
    fn cancellation_is_sent_over_stdin_while_progress_is_being_drained() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let engine = temp.path().join("fixture-engine");
        let work = ImportWork {
            operation_id: uuid::Uuid::new_v4().to_string(),
            attempt_token: uuid::Uuid::new_v4().to_string(),
            source: temp.path().join("source.wav"),
            title: None,
        };
        let frame = |payload| {
            json!({"version":1,"operationId":work.operation_id,"attemptToken":work.attempt_token,"payload":payload}).to_string()
        };
        let progress = frame(
            json!({"event":"progress","progress":{"phase":"copying","copiedBytes":0,"totalBytes":100}}),
        );
        let stopped = frame(json!({"event":"cancelled"}));
        let script = format!("#!/bin/sh\nIFS= read -r request\nprintf '%s\\n' '{progress}'\nIFS= read -r action\n[ \"$action\" = cancel ] || exit 4\nprintf '%s\\n' '{stopped}'\n");
        std::fs::write(&engine, script).unwrap();
        std::fs::set_permissions(&engine, std::fs::Permissions::from_mode(0o700)).unwrap();
        let cancelled = AtomicBool::new(false);
        let result = ProcessWorker {
            engine: &engine,
            root: temp.path(),
        }
        .import(&work, &cancelled, &mut |_| {
            cancelled.store(true, Ordering::Release)
        });
        assert_eq!(result.unwrap_err().code, "cancelled");
    }
}
