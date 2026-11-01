//! Persistent, leased import queue adapter. A failed connection cannot be reused;
//! its entire process scope is killed/reaped before another request is admitted.
use crate::{
    import_queue::{ImportQueue, QueueCommand, QueueReply},
    models::HostError,
};
use after_process_runtime::ProcessTree;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Read, Write},
    path::Path,
    process::{Command, Stdio},
    sync::{mpsc, Mutex},
    thread,
    time::{Duration, Instant},
};

const TIMEOUT: Duration = Duration::from_secs(12);
const MAX_FRAME: usize = 8 * 1024 * 1024 + 1024;

pub struct QueueConnection(Mutex<Connection>);
struct Connection {
    child: ProcessTree,
    input: mpsc::SyncSender<Vec<u8>>,
    events: mpsc::Receiver<Event>,
    healthy: bool,
    timeout: Duration,
}
enum Event {
    Frame(Frame),
    InputDone,
    Failed(HostError),
}
#[derive(Deserialize)]
#[serde(tag = "event", rename_all = "snake_case", deny_unknown_fields)]
enum Frame {
    Ready {
        version: u8,
    },
    Unavailable {
        version: u8,
        code: Unavailable,
    },
    Reply {
        version: u8,
        id: String,
        envelope: Envelope,
    },
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Unavailable {
    Busy,
    LibraryError,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    ok: bool,
    result: Option<Value>,
    error: Option<HostError>,
}

fn unavailable() -> HostError {
    HostError::new(
        "engine_failure",
        "The import queue connection is unavailable.",
    )
}
fn protocol() -> HostError {
    HostError::new(
        "invalid_response",
        "The import queue returned an invalid response.",
    )
}
fn timed_out() -> HostError {
    HostError::new(
        "engine_timeout",
        "The import queue did not respond in time.",
    )
}

fn read_frame(input: &mut impl BufRead) -> Result<Frame, HostError> {
    let mut bytes = Vec::new();
    Read::by_ref(input)
        .take((MAX_FRAME + 1) as u64)
        .read_until(b'\n', &mut bytes)
        .map_err(|_| unavailable())?;
    if bytes.is_empty() {
        return Err(unavailable());
    }
    if bytes.len() > MAX_FRAME || !bytes.ends_with(b"\n") {
        return Err(protocol());
    }
    serde_json::from_slice(&bytes).map_err(|_| protocol())
}

impl QueueConnection {
    pub(crate) fn open(engine: &Path, root: &Path) -> Result<Self, HostError> {
        Self::connect(engine, root, TIMEOUT)
    }
    fn connect(engine: &Path, root: &Path, timeout: Duration) -> Result<Self, HostError> {
        let mut command = Command::new(engine);
        command
            .args(["desktop-import-queue", "--root"])
            .arg(root)
            .current_dir(root)
            .env_clear()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        for name in ["SystemRoot", "WINDIR", "TMP", "TEMP", "LANG", "LC_ALL"] {
            if let Some(value) = std::env::var_os(name) {
                command.env(name, value);
            }
        }
        let mut child = ProcessTree::spawn(&mut command).map_err(|_| unavailable())?;
        let mut stdin = child.take_stdin().ok_or_else(unavailable)?;
        let stdout = child.take_stdout().ok_or_else(unavailable)?;
        let (sender, events) = mpsc::sync_channel(2);
        let (input, writer) = mpsc::sync_channel::<Vec<u8>>(1);
        let tx = sender.clone();
        thread::spawn(move || {
            while let Ok(bytes) = writer.recv() {
                let event = match stdin.write_all(&bytes).and_then(|_| stdin.flush()) {
                    Ok(()) => Event::InputDone,
                    Err(_) => Event::Failed(unavailable()),
                };
                let failed = matches!(event, Event::Failed(_));
                if tx.send(event).is_err() || failed {
                    return;
                }
            }
        });
        thread::spawn(move || {
            let mut stdout = BufReader::new(stdout);
            loop {
                let event = match read_frame(&mut stdout) {
                    Ok(frame) => Event::Frame(frame),
                    Err(error) => Event::Failed(error),
                };
                let failed = matches!(event, Event::Failed(_));
                if sender.send(event).is_err() || failed {
                    return;
                }
            }
        });
        let mut connection = Connection {
            child,
            input,
            events,
            healthy: true,
            timeout,
        };
        let ready = match connection.receive(Instant::now() + timeout) {
            Ok(Event::Frame(Frame::Ready { version: 1 })) => Ok(()),
            Ok(Event::Frame(Frame::Unavailable {
                version: 1,
                code: Unavailable::Busy,
            })) => Err(HostError::new(
                "busy",
                "Another host owns this import queue.",
            )),
            Ok(Event::Frame(Frame::Unavailable {
                version: 1,
                code: Unavailable::LibraryError,
            })) => Err(unavailable()),
            Ok(Event::Failed(error)) | Err(error) => Err(error),
            _ => Err(protocol()),
        };
        if let Err(error) = ready {
            connection.stop();
            return Err(error);
        }
        Ok(Self(Mutex::new(connection)))
    }
}
impl Connection {
    fn stop(&mut self) {
        self.healthy = false;
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
    fn receive(&self, deadline: Instant) -> Result<Event, HostError> {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(timed_out)?;
        self.events
            .recv_timeout(remaining)
            .map_err(|error| match error {
                mpsc::RecvTimeoutError::Timeout => timed_out(),
                mpsc::RecvTimeoutError::Disconnected => unavailable(),
            })
    }
    fn exchange(&mut self, bytes: Vec<u8>, id: &str) -> Result<Envelope, HostError> {
        if !self.healthy || self.child.try_wait().map_err(|_| unavailable())?.is_some() {
            return Err(unavailable());
        }
        self.input.try_send(bytes).map_err(|_| unavailable())?;
        let deadline = Instant::now() + self.timeout;
        let mut sent = false;
        let mut reply = None;
        while !sent || reply.is_none() {
            match self.receive(deadline)? {
                Event::InputDone if !sent => sent = true,
                Event::Frame(Frame::Reply {
                    version: 1,
                    id: received,
                    envelope,
                }) if received == id && reply.is_none() => reply = Some(envelope),
                Event::Failed(error) => return Err(error),
                _ => return Err(protocol()),
            }
        }
        Ok(reply.unwrap())
    }
}
impl ImportQueue for QueueConnection {
    fn execute(&self, command: QueueCommand) -> Result<QueueReply, HostError> {
        let id = uuid::Uuid::new_v4().to_string();
        let mut bytes = serde_json::to_vec(&json!({"version":1,"id":id,"request":command}))
            .map_err(|_| HostError::invalid())?;
        if bytes.len() >= 256 * 1024 {
            return Err(HostError::invalid());
        }
        bytes.push(b'\n');
        let mut connection = self.0.lock().map_err(|_| unavailable())?;
        let reply = match connection.exchange(bytes, &id) {
            Ok(reply) => reply,
            Err(error) => {
                connection.stop();
                return Err(error);
            }
        };
        match (reply.ok, reply.result, reply.error) {
            (false, None, Some(error)) => Err(error),
            (true, Some(value), None) => serde_json::from_value(value).map_err(|_| {
                connection.stop();
                protocol()
            }),
            _ => {
                connection.stop();
                Err(protocol())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn frames_are_bounded_complete_and_closed() {
        for bytes in [
            b"{}".to_vec(),
            b"{\"event\":\"ready\",\"version\":1,\"command\":\"run\"}\n".to_vec(),
            vec![b'x'; MAX_FRAME + 1],
        ] {
            assert!(read_frame(&mut std::io::Cursor::new(bytes)).is_err());
        }
        assert!(matches!(
            read_frame(&mut std::io::Cursor::new(
                b"{\"event\":\"ready\",\"version\":1}\n"
            )),
            Ok(Frame::Ready { version: 1 })
        ));
    }
    #[cfg(unix)]
    fn fake(script: &str) -> (tempfile::TempDir, std::path::PathBuf) {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let engine = root.path().join("engine");
        std::fs::write(&engine, format!("#!/bin/sh\n{script}\n")).unwrap();
        std::fs::set_permissions(&engine, std::fs::Permissions::from_mode(0o700)).unwrap();
        (root, engine)
    }
    #[cfg(unix)]
    #[test]
    fn unresponsive_owner_times_out_and_connection_is_not_reused() {
        let (root, engine) =
            fake("printf '%s\\n' '{\"event\":\"ready\",\"version\":1}'\nexec /usr/bin/sleep 30");
        let connection =
            QueueConnection::connect(&engine, root.path(), Duration::from_millis(200)).unwrap();
        assert_eq!(
            connection.execute(QueueCommand::List).err().unwrap().code,
            "engine_timeout"
        );
        assert_eq!(
            connection.execute(QueueCommand::List).err().unwrap().code,
            "engine_failure"
        );
    }
    #[cfg(unix)]
    #[test]
    fn mismatched_reply_identity_closes_the_owner_connection() {
        let (root, engine) = fake("printf '%s\\n' '{\"event\":\"ready\",\"version\":1}'\nIFS= read -r request\nprintf '%s\\n' '{\"event\":\"reply\",\"version\":1,\"id\":\"wrong\",\"envelope\":{\"ok\":true,\"result\":{\"jobs\":[]}}}'\nexec /usr/bin/sleep 30");
        let connection =
            QueueConnection::connect(&engine, root.path(), Duration::from_secs(3)).unwrap();
        assert_eq!(
            connection.execute(QueueCommand::List).err().unwrap().code,
            "invalid_response"
        );
        assert_eq!(
            connection.execute(QueueCommand::List).err().unwrap().code,
            "engine_failure"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_blocked_stdin_writer_cannot_defeat_the_request_deadline() {
        let (root, engine) =
            fake("printf '%s\\n' '{\"event\":\"ready\",\"version\":1}'\nexec /usr/bin/sleep 30");
        let connection =
            QueueConnection::connect(&engine, root.path(), Duration::from_secs(1)).unwrap();
        let before = Instant::now();
        let oversized_grant = crate::import_queue::ImportInput {
            operation_id: uuid::Uuid::new_v4().to_string(),
            attempt_token: uuid::Uuid::new_v4().to_string(),
            source_path: std::path::PathBuf::from(format!("/{}", "x".repeat(180_000))),
            title: None,
        };
        assert_eq!(
            connection
                .execute(QueueCommand::Enqueue {
                    input: oversized_grant
                })
                .err()
                .unwrap()
                .code,
            "engine_timeout"
        );
        assert!(before.elapsed() < Duration::from_secs(5));
    }

    #[cfg(unix)]
    #[test]
    fn an_incompatible_startup_protocol_never_admits_requests() {
        let (root, engine) =
            fake("printf '%s\\n' '{\"event\":\"ready\",\"version\":2}'\nexec /usr/bin/sleep 30");
        assert_eq!(
            QueueConnection::connect(&engine, root.path(), Duration::from_secs(1))
                .err()
                .unwrap()
                .code,
            "invalid_response"
        );
    }
}
