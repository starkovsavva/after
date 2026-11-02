//! Dedicated native CLI process adapter; SDKs never execute in the queue owner.
use crate::application::{
    attempt_execution::AttemptStop,
    speech_execution::{SpeechPublication, SpeechReceipt, SpeechWork},
    speech_jobs::{SpeechJobWorker, SpeechObserver},
};
use after_process_runtime::ProcessTree;
use anyhow::{anyhow, ensure, Result};
use serde::Deserialize;
use std::{
    io::{BufRead, BufReader, Read, Write},
    path::PathBuf,
    process::{Command, Stdio},
    sync::mpsc,
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
pub(crate) struct NativeSpeechProcess {
    pub lease: std::sync::Arc<crate::infrastructure::executor_lease::SpeechExecutorLease>,
    pub engine: PathBuf,
    pub backend: PathBuf,
}
#[derive(Deserialize)]
#[serde(tag = "event", rename_all = "snake_case", deny_unknown_fields)]
enum Frame {
    Progress {
        message: String,
        fraction: f64,
    },
    Done {
        #[serde(rename = "speechJob")]
        speech_job: Completion,
    },
    Error {
        message: String,
    },
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Completion {
    receipt: SpeechReceipt,
}
enum Event {
    Frame(Frame),
    InputDone,
    OutputDone,
    StderrDone,
    Invalid,
}
fn frames(reader: impl Read, sender: &mpsc::SyncSender<Event>) -> Result<()> {
    let mut reader = BufReader::new(reader);
    let mut total = 0usize;
    loop {
        let mut line = Vec::new();
        Read::by_ref(&mut reader)
            .take(65_537)
            .read_until(b'\n', &mut line)?;
        if line.is_empty() {
            return Ok(());
        }
        total = total.saturating_add(line.len());
        ensure!(
            line.len() <= 65_536 && total <= 64 * 1024 * 1024 && line.ends_with(b"\n"),
            "Invalid speech frame"
        );
        sender.send(Event::Frame(serde_json::from_slice(&line)?))?;
    }
}
struct Running {
    child: Option<ProcessTree>,
    receiver: Option<mpsc::Receiver<Event>>,
    threads: Vec<JoinHandle<()>>,
}
impl Drop for Running {
    fn drop(&mut self) {
        // Stop/reap first, close the bounded channel, then join readers/writer.
        // This also unblocks a writer whose child never consumed its request.
        drop(self.child.take());
        drop(self.receiver.take());
        for task in self.threads.drain(..) {
            let _ = task.join();
        }
    }
}
impl SpeechJobWorker for NativeSpeechProcess {
    fn committed(&self, work: &SpeechWork) -> Result<bool> {
        crate::infrastructure::speech_publication::Publication {
            root: self.lease.root(),
        }
        .committed(work)
    }
    fn run(
        &self,
        work: &SpeechWork,
        stop: &AttemptStop,
        observer: &mut dyn SpeechObserver,
    ) -> Result<()> {
        work.validate()?;
        ensure!(!stop.is_requested(), "Speech stopped");
        let input = serde_json::to_vec(work)?;
        ensure!(
            input.len() <= 256 * 1024,
            "Speech request exceeds its bound"
        );
        ensure!(
            self.engine.is_absolute() && self.backend.is_absolute(),
            "Native speech resources must be absolute"
        );
        let mut command = Command::new(&self.engine);
        command
            .args(["--posle-speech-job", "--root"])
            .arg(self.lease.root())
            .arg("--backend")
            .arg(&self.backend)
            .current_dir(self.lease.root())
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("LANG", "C.UTF-8")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        self.lease.inherit(&mut command)?;
        let mut child = ProcessTree::spawn(&mut command)?;
        let mut stdin = child
            .take_stdin()
            .ok_or_else(|| anyhow!("Missing speech input"))?;
        let stdout = child
            .take_stdout()
            .ok_or_else(|| anyhow!("Missing speech output"))?;
        let stderr = child
            .take_stderr()
            .ok_or_else(|| anyhow!("Missing speech diagnostics"))?;
        let (sender, receiver) = mpsc::sync_channel(16);
        let mut running = Running {
            child: Some(child),
            receiver: Some(receiver),
            threads: Vec::new(),
        };
        let tx = sender.clone();
        running
            .threads
            .push(
                thread::Builder::new()
                    .name("speech-input".into())
                    .spawn(move || {
                        let event = if stdin.write_all(&input).is_ok() {
                            Event::InputDone
                        } else {
                            Event::Invalid
                        };
                        drop(stdin);
                        let _ = tx.send(event);
                    })?,
            );
        let tx = sender.clone();
        running
            .threads
            .push(
                thread::Builder::new()
                    .name("speech-output".into())
                    .spawn(move || {
                        let event = if frames(stdout, &tx).is_ok() {
                            Event::OutputDone
                        } else {
                            Event::Invalid
                        };
                        let _ = tx.send(event);
                    })?,
            );
        running.threads.push(
            thread::Builder::new()
                .name("speech-diagnostics".into())
                .spawn(move || {
                    let result = std::io::copy(&mut stderr.take(65_537), &mut std::io::sink());
                    let event = if result.is_ok_and(|n| n <= 65_536) {
                        Event::StderrDone
                    } else {
                        Event::Invalid
                    };
                    let _ = sender.send(event);
                })?,
        );
        let deadline = Instant::now() + Duration::from_secs(24 * 60 * 60);
        let (mut input_done, mut output_done, mut stderr_done, mut exited, mut terminal) =
            (false, false, false, false, false);
        let mut stopping = None;
        loop {
            while let Ok(event) = running.receiver.as_ref().unwrap().try_recv() {
                match event {
                    Event::InputDone => input_done = true,
                    Event::OutputDone => output_done = true,
                    Event::StderrDone => stderr_done = true,
                    Event::Invalid => anyhow::bail!("Invalid speech process response"),
                    Event::Frame(frame) => {
                        ensure!(!terminal, "Unexpected frame after speech completion");
                        match frame {
                            Frame::Progress { message, fraction } => {
                                ensure!(
                                    message.len() <= 8000 && fraction.is_finite() && fraction <= 1.,
                                    "Invalid speech progress"
                                );
                                observer.checkpoint(if fraction < 0. {
                                    None
                                } else {
                                    Some(fraction)
                                })?;
                            }
                            Frame::Done { speech_job } => {
                                ensure!(
                                    speech_job.receipt == SpeechReceipt::for_work(work),
                                    "Speech acknowledgement identity changed"
                                );
                                terminal = true;
                            }
                            Frame::Error { message } => {
                                let _ = message;
                                anyhow::bail!("Speech worker failed");
                            }
                        }
                    }
                }
            }
            if !exited {
                if let Some(status) = running.child.as_mut().unwrap().try_wait()? {
                    // The validated native publisher ends its owned Unix group
                    // after flushing the receipt. Exit alone is not evidence;
                    // the closed acknowledgement and durable receipt are.
                    let _ = status;
                    exited = true;
                }
            }
            if exited && input_done && output_done && stderr_done {
                ensure!(terminal, "Speech process returned no receipt");
                return Ok(());
            }
            if stopping.is_none() && (stop.is_requested() || Instant::now() >= deadline) {
                running.child.as_mut().unwrap().request_stop()?;
                stopping = Some(Instant::now());
            }
            if stopping.is_some_and(|at: Instant| at.elapsed() >= Duration::from_secs(2)) {
                running.child.as_mut().unwrap().kill()?;
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounded_speech_frames_reject_partial_invalid_and_oversized_output() {
        for bytes in [
            b"not-json\n".to_vec(),
            b"{\"event\":\"progress\"}".to_vec(),
            vec![b'x'; 65_537],
        ] {
            let (sender, _receiver) = mpsc::sync_channel(16);
            assert!(frames(std::io::Cursor::new(bytes), &sender).is_err());
        }
        let (sender, receiver) = mpsc::sync_channel(16);
        frames(
            std::io::Cursor::new(
                b"{\"event\":\"progress\",\"message\":\"fixture\",\"fraction\":0.2}\n",
            ),
            &sender,
        )
        .unwrap();
        assert!(matches!(
            receiver.recv().unwrap(),
            Event::Frame(Frame::Progress { fraction: 0.2, .. })
        ));
    }
}
