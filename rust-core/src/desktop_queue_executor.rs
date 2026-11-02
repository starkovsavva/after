//! Native composition root. One leased process owns both the queue and every
//! import thread; shutdown cancels and joins work before releasing that lease.
use crate::{
    application::{
        import_execution,
        import_ports::{
            ImportInput, ImportJobStore, ImportOutcome, ImportReceipts, ImportRecoveryOutcome,
            ImportRecoveryStore, ImportStop, ImportWorker,
        },
        import_recovery,
        imports::ImportObserver,
        jobs::{ClaimRequest, JobCommand, JobReply},
    },
    desktop_queue::{self, Request},
    domain::jobs::Job,
    infrastructure::executor_lease::ImportExecutorLease,
};
use anyhow::{bail, Result};
use serde_json::{json, Value};
use std::{
    sync::Arc,
    thread::{self, JoinHandle},
};

#[derive(Debug)]
pub(crate) struct ExecutorBusy;
impl std::fmt::Display for ExecutorBusy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Import executor is busy")
    }
}
impl std::error::Error for ExecutorBusy {}

pub(crate) struct Executor {
    active: Option<Active>,
    worker: Arc<dyn ImportWorker>,
    lease: Arc<ImportExecutorLease>,
}
struct Active {
    id: String,
    stop: Arc<ImportStop>,
    thread: Option<JoinHandle<Result<()>>>,
}
impl Active {
    fn join(mut self) -> Result<()> {
        match self.thread.take().unwrap().join() {
            Ok(result) => result,
            Err(_) => bail!("Import worker stopped unexpectedly"),
        }
    }
}
impl Drop for Active {
    fn drop(&mut self) {
        if let Some(thread) = self.thread.take() {
            self.stop.shutdown();
            let _ = thread.join();
        }
    }
}
impl Executor {
    pub fn new(lease: ImportExecutorLease) -> Self {
        let lease = Arc::new(lease);
        let worker = Arc::new(FileWorker {
            lease: lease.clone(),
        });
        Self {
            active: None,
            worker,
            lease,
        }
    }
    pub fn command(&mut self, request: Request) -> Result<Value> {
        if self
            .active
            .as_ref()
            .is_some_and(|active| active.thread.as_ref().unwrap().is_finished())
        {
            self.active.take().unwrap().join()?;
        }
        if self.active.is_some()
            && matches!(
                &request,
                Request::Run { .. }
                    | Request::Claim { .. }
                    | Request::Update { .. }
                    | Request::Retry { .. }
                    | Request::Recover {}
                    | Request::Reconcile { .. }
            )
        {
            return Err(ExecutorBusy.into());
        }
        if let Request::Reconcile { after_job_id } = request {
            if let Some(cursor) = &after_job_id {
                anyhow::ensure!(
                    !cursor.is_empty() && cursor.len() <= 512 && !cursor.contains('\0'),
                    "Invalid recovery cursor"
                );
            }
            let store = QueueStore {
                lease: self.lease.clone(),
            };
            let report =
                import_recovery::reconcile(&store, &*self.worker, after_job_id.as_deref())?;
            return Ok(json!({"reconciliation":report}));
        }
        if matches!(request, Request::Recover {}) {
            let store = QueueStore {
                lease: self.lease.clone(),
            };
            let mut cursor = None;
            let mut recovered = 0;
            loop {
                let report = import_recovery::reconcile(&store, &*self.worker, cursor.as_deref())?;
                recovered += report.published + report.interrupted + report.cancelled;
                if !report.has_more {
                    break;
                }
                cursor = report.next_cursor;
            }
            let mut result = desktop_queue::execute(self.lease.root(), Request::List {})?;
            result["recovered"] = json!(recovered);
            return Ok(result);
        }
        if let Request::Run { job_id } = request {
            return self.run(job_id);
        }
        let cancel_id = match &request {
            Request::Cancel { job_id, .. } => Some(job_id.clone()),
            _ => None,
        };
        let result = desktop_queue::execute(self.lease.root(), request)?;
        if result["job"]["cancelRequested"] == true {
            if let Some(active) = self
                .active
                .as_ref()
                .filter(|active| cancel_id.as_deref() == Some(&active.id))
            {
                active.stop.cancel();
            }
        }
        Ok(result)
    }
    fn run(&mut self, id: String) -> Result<Value> {
        desktop_queue::id(&id)?;
        let store = QueueStore {
            lease: self.lease.clone(),
        };
        let job = match desktop_queue::queue(self.lease.root()).execute(JobCommand::Claim(
            ClaimRequest {
                job_id: Some(id.clone()),
                allowed_resources: None,
                excluded_accounts: Vec::new(),
            },
        ))? {
            JobReply::Claimed(Some(job)) => job,
            JobReply::Claimed(None) => return Ok(json!({"job":null})),
            _ => bail!("Invalid queue claim reply"),
        };
        let control = Arc::new(ImportStop::default());
        let stop = control.clone();
        let worker = self.worker.clone();
        let claimed = job.clone();
        let thread = thread::Builder::new()
            .name("after-queued-import".into())
            .spawn(move || import_execution::execute(&store, &*worker, &claimed, &stop));
        match thread {
            Ok(thread) => {
                self.active = Some(Active {
                    id,
                    stop: control,
                    thread: Some(thread),
                })
            }
            Err(error) => {
                QueueStore {
                    lease: self.lease.clone(),
                }
                .finish(&job.id, job.attempt, ImportOutcome::Interrupted)?;
                return Err(error.into());
            }
        }
        Ok(json!({"job":job}))
    }
}
impl Drop for Executor {
    fn drop(&mut self) {
        // Explicit order: Arc/File field destruction alone does not join a
        // detached thread. No worker can publish after this owner releases.
        drop(self.active.take());
    }
}

struct QueueStore {
    lease: Arc<ImportExecutorLease>,
}
impl QueueStore {
    fn scoped(&self) -> crate::infrastructure::attempt_store::ScopedAttemptStore<'_> {
        crate::infrastructure::attempt_store::ScopedAttemptStore { root:self.lease.root(),kind:crate::application::import_ports::IMPORT_JOB_KIND,label:"Import" }
    }
}
impl ImportRecoveryStore for QueueStore {
    fn candidates(&self, after: Option<&str>, limit: usize) -> Result<Vec<Job>> { self.scoped().candidates(after,limit) }
    fn resolve(&self, observed: &Job, outcome: ImportRecoveryOutcome) -> Result<bool> { self.scoped().resolve(observed,outcome) }
}
impl ImportJobStore for QueueStore {
    fn progress(&self,id:&str,attempt:u64,fraction:f64)->Result<bool> { self.scoped().progress(id,attempt,fraction) }
    fn finish(&self,id:&str,attempt:u64,outcome:ImportOutcome)->Result<()> { self.scoped().finish(id,attempt,outcome) }
}
struct FileWorker {
    lease: Arc<ImportExecutorLease>,
}
impl ImportReceipts for FileWorker {
    fn committed(&self, input: &ImportInput) -> Result<bool> {
        Ok(crate::desktop_import::committed(
            self.lease.root(),
            &input.operation_id,
            &input.attempt_token,
        )?
        .is_some())
    }
}
impl ImportWorker for FileWorker {
    fn import(&self, input: &ImportInput, observer: &mut dyn ImportObserver) -> Result<()> {
        crate::desktop_import::import_observed(
            self.lease.root(),
            &input.source_path,
            "",
            input.title.as_deref(),
            Some(crate::desktop_import::ImportControl {
                operation: &input.operation_id,
                token: &input.attempt_token,
                observer,
            }),
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::imports::{ImportPhase, ImportProgress};
    use std::{
        path::Path,
        sync::{
            atomic::{AtomicBool, Ordering},
            mpsc, Mutex,
        },
        time::{Duration, Instant},
    };

    struct Paused {
        entered: mpsc::SyncSender<()>,
        resume: Mutex<mpsc::Receiver<()>>,
        published: AtomicBool,
    }
    impl ImportReceipts for Paused {
        fn committed(&self, _: &ImportInput) -> Result<bool> {
            Ok(self.published.load(Ordering::Acquire))
        }
    }
    impl ImportWorker for Paused {
        fn import(&self, _: &ImportInput, observer: &mut dyn ImportObserver) -> Result<()> {
            observer.checkpoint(ImportProgress {
                phase: ImportPhase::Copying,
                copied_bytes: 0,
                total_bytes: 1,
            })?;
            self.entered.send(())?;
            self.resume
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_secs(5))?;
            observer.checkpoint(ImportProgress {
                phase: ImportPhase::Committing,
                copied_bytes: 1,
                total_bytes: 1,
            })?;
            self.published.store(true, Ordering::Release);
            Ok(())
        }
    }
    fn paused() -> (Arc<Paused>, mpsc::Receiver<()>, mpsc::Sender<()>) {
        let (entered, ready) = mpsc::sync_channel(1);
        let (resume, gate) = mpsc::channel();
        (
            Arc::new(Paused {
                entered,
                resume: Mutex::new(gate),
                published: AtomicBool::new(false),
            }),
            ready,
            resume,
        )
    }
    fn owner(root: &Path) -> Executor {
        Executor::new(
            crate::infrastructure::executor_lease::try_acquire(root)
                .unwrap()
                .unwrap(),
        )
    }
    fn enqueue(owner: &mut Executor, root: &Path) -> (String, ImportInput) {
        let input = ImportInput {
            operation_id: uuid::Uuid::new_v4().to_string(),
            attempt_token: uuid::Uuid::new_v4().to_string(),
            source_path: root.join("synthetic.wav"),
            title: None,
        };
        let reply = owner
            .command(Request::Enqueue {
                input: input.clone(),
            })
            .unwrap();
        (reply["job"]["id"].as_str().unwrap().into(), input)
    }
    fn wait(owner: &mut Executor, id: &str, expected: &str) -> Value {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let job = owner.command(Request::Get { job_id: id.into() }).unwrap()["job"].clone();
            if job["state"] == expected {
                return job;
            }
            assert_eq!(job["state"], "running", "unexpected terminal state: {job}");
            assert!(Instant::now() < deadline, "worker did not finish");
            thread::yield_now();
        }
    }

    #[test]
    fn owner_drop_joins_the_worker_before_releasing_the_kernel_lease() {
        let root = tempfile::tempdir().unwrap();
        let mut executor = owner(root.path());
        let (worker, ready, resume) = paused();
        executor.worker = worker.clone();
        let (id, _) = enqueue(&mut executor, root.path());
        executor
            .command(Request::Run { job_id: id.clone() })
            .unwrap();
        ready.recv_timeout(Duration::from_secs(5)).unwrap();
        let stop = executor.active.as_ref().unwrap().stop.clone();
        let dropping = thread::spawn(move || drop(executor));
        let deadline = Instant::now() + Duration::from_secs(5);
        while !stop.is_stopping() {
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
        assert!(
            !dropping.is_finished(),
            "owner must join, not detach, its worker"
        );
        assert!(
            crate::infrastructure::executor_lease::try_acquire(root.path())
                .unwrap()
                .is_none()
        );
        resume.send(()).unwrap();
        dropping.join().unwrap();
        assert!(!worker.published.load(Ordering::Acquire));
        let mut successor = owner(root.path());
        let job = successor.command(Request::Get { job_id: id }).unwrap();
        assert_eq!(job["job"]["state"], "interrupted");
    }

    #[test]
    fn live_attempt_blocks_recovery_and_manual_completion_but_accepts_scoped_cancel() {
        let root = tempfile::tempdir().unwrap();
        let mut executor = owner(root.path());
        let (worker, ready, resume) = paused();
        executor.worker = worker.clone();
        let (id, _) = enqueue(&mut executor, root.path());
        executor
            .command(Request::Run { job_id: id.clone() })
            .unwrap();
        ready.recv_timeout(Duration::from_secs(5)).unwrap();
        let busy =
            crate::desktop::import_queue_envelope(&mut executor, json!({"action":"recover"}));
        assert_eq!(busy["error"]["code"], "busy");
        assert!(executor
            .command(Request::Update {
                job_id: id.clone(),
                expected_attempt: 1,
                state: desktop_queue::State::Succeeded,
                progress: 1.0
            })
            .unwrap_err()
            .is::<ExecutorBusy>());
        assert!(executor
            .command(Request::Cancel {
                job_id: id.clone(),
                expected_attempt: 2
            })
            .is_err());
        assert!(!executor.active.as_ref().unwrap().stop.is_cancelled());
        let cancelled = executor
            .command(Request::Cancel {
                job_id: id.clone(),
                expected_attempt: 1,
            })
            .unwrap();
        assert_eq!(cancelled["job"]["cancelRequested"], true);
        resume.send(()).unwrap();
        wait(&mut executor, &id, "cancelled");
        assert!(!worker.published.load(Ordering::Acquire));
    }

    #[test]
    fn unreadable_receipt_interrupts_without_copying_or_touching_existing_metadata() {
        let root = tempfile::tempdir().unwrap();
        let mut executor = owner(root.path());
        let (id, input) = enqueue(&mut executor, root.path());
        std::fs::write(&input.source_path, b"preserve original").unwrap();
        let directory = root.path().join("meetings").join(&input.operation_id);
        let meta = directory.join("meta.json");
        std::fs::create_dir_all(&meta).unwrap();
        executor
            .command(Request::Run { job_id: id.clone() })
            .unwrap();
        let job = wait(&mut executor, &id, "interrupted");
        assert_eq!(job["message"], "Import outcome requires reconciliation");
        assert_eq!(
            std::fs::read(&input.source_path).unwrap(),
            b"preserve original"
        );
        assert!(meta.is_dir());
        assert!(!directory.join("source.wav").exists());
    }

    #[test]
    fn recovery_resolution_cannot_overwrite_a_concurrent_cancel() {
        let root = tempfile::tempdir().unwrap();
        let mut executor = owner(root.path());
        let (id, _) = enqueue(&mut executor, root.path());
        executor
            .command(Request::Claim {
                job_id: Some(id.clone()),
            })
            .unwrap();
        let store = QueueStore {
            lease: executor.lease.clone(),
        };
        let observed = store.candidates(None, 64).unwrap().remove(0);
        executor
            .command(Request::Cancel {
                job_id: id.clone(),
                expected_attempt: 1,
            })
            .unwrap();
        assert!(!store
            .resolve(&observed, ImportRecoveryOutcome::Published)
            .unwrap());
        let current = store.candidates(None, 64).unwrap().remove(0);
        assert!(current.cancel_requested);
        assert_eq!(current.state, "running");
        assert!(store
            .resolve(&current, ImportRecoveryOutcome::Cancelled)
            .unwrap());
        assert_eq!(
            executor.command(Request::Get { job_id: id }).unwrap()["job"]["state"],
            "cancelled"
        );
    }
}
