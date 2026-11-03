//! Shared native queue framing and owned process transport. A failed connection cannot be reused;
//! its entire process scope is killed/reaped before another request is admitted.
use crate::{models::HostError, queue_budget::RequestBudget};
use after_process_runtime::ProcessTree;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Read, Write},
    process::{Command, Stdio},
    sync::{mpsc, Mutex},
    thread,
    time::{Duration, Instant},
};

pub(crate) const TIMEOUT: Duration = Duration::from_secs(12);
const MAX_FRAME: usize = 8 * 1024 * 1024 + 1024;

pub(crate) struct NativeQueueConnection(Mutex<Connection>);
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
        "The native queue connection is unavailable.",
    )
}
fn protocol() -> HostError {
    HostError::new(
        "invalid_response",
        "The native queue returned an invalid response.",
    )
}
fn timed_out() -> HostError {
    HostError::new(
        "engine_timeout",
        "The native queue did not respond in time.",
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

impl NativeQueueConnection {
    pub(crate) fn connect(mut command: Command, timeout: Duration) -> Result<Self, HostError> {
        command
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
                "Another host owns this native queue.",
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
    fn receive_with_budget(
        &self,
        budget: &dyn RequestBudget,
        rpc_deadline: Instant,
    ) -> Result<Event, HostError> {
        loop {
            let deadline = budget.deadline().min(rpc_deadline);
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .ok_or_else(timed_out)?;
            match self
                .events
                .recv_timeout(remaining.min(Duration::from_millis(20)))
            {
                Ok(event) => return Ok(event),
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => return Err(unavailable()),
            }
        }
    }
    fn exchange(
        &mut self,
        bytes: Vec<u8>,
        id: &str,
        budget: &dyn RequestBudget,
    ) -> Result<Envelope, HostError> {
        if !self.healthy || self.child.try_wait().map_err(|_| unavailable())?.is_some() {
            return Err(unavailable());
        }
        let rpc_deadline = Instant::now() + self.timeout;
        if budget.deadline().min(rpc_deadline) <= Instant::now() {
            return Err(timed_out());
        }
        self.input.try_send(bytes).map_err(|_| unavailable())?;
        let mut sent = false;
        let mut reply = None;
        while !sent || reply.is_none() {
            match self.receive_with_budget(budget, rpc_deadline)? {
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
impl NativeQueueConnection {
    pub(crate) fn shutdown(&self) {
        self.0
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .stop();
    }
    pub(crate) fn execute<C: Serialize, T: DeserializeOwned>(
        &self,
        command: C,
        budget: &dyn RequestBudget,
    ) -> Result<T, HostError> {
        let id = uuid::Uuid::new_v4().to_string();
        let mut bytes = serde_json::to_vec(&json!({"version":1,"id":id,"request":command}))
            .map_err(|_| HostError::invalid())?;
        if bytes.len() >= 256 * 1024 {
            return Err(HostError::invalid());
        }
        bytes.push(b'\n');
        let mut connection = loop {
            if Instant::now() >= budget.deadline() {
                return Err(timed_out());
            }
            match self.0.try_lock() {
                Ok(connection) => break connection,
                Err(std::sync::TryLockError::Poisoned(_)) => return Err(unavailable()),
                Err(std::sync::TryLockError::WouldBlock) => thread::sleep(Duration::from_millis(1)),
            }
        };
        let reply = match connection.exchange(bytes, &id, budget) {
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
}
