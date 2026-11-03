//! Preflight lifecycle composed by the leased speech owner, never startup inference.
use crate::{
    application::{
        attempt_execution::{AttemptOutcome, AttemptStop, AttemptStore},
        jobs::{ClaimRequest, JobCommand, JobReply},
        speech_check::{self, CheckWork, CheckWorker},
    },
    domain::jobs::{Job, JobDefinition, JobMutation, JobResource},
    infrastructure::{attempt_store::ScopedAttemptStore, executor_lease::SpeechExecutorLease},
};
use anyhow::{bail, ensure, Result};
use serde_json::{json, Value};
use std::{
    sync::Arc,
    thread::{self, JoinHandle},
};
pub(crate) struct Checks {
    lease: Arc<SpeechExecutorLease>,
    worker: Arc<dyn CheckWorker>,
    active: Option<Active>,
    halted: bool,
}
struct Active {
    id: String,
    attempt: u64,
    stop: Arc<AttemptStop>,
    task: Option<JoinHandle<Result<()>>>,
}
impl Drop for Active {
    fn drop(&mut self) {
        self.stop.shutdown();
        if let Some(task) = self.task.take() {
            let _ = task.join();
        }
    }
}
impl Drop for Checks {
    fn drop(&mut self) {
        drop(self.active.take());
    }
}
impl Checks {
    pub fn new(lease: Arc<SpeechExecutorLease>, worker: Arc<dyn CheckWorker>) -> Result<Self> {
        let checks = Self {
            lease,
            worker,
            active: None,
            halted: false,
        };
        let mut after = None;
        loop {
            let report = crate::application::job_recovery::reconcile(
                &checks.store(),
                speech_check::KIND,
                |_| Ok(false),
                after.as_deref(),
            )?;
            ensure!(report.stale == 0, "Check recovery changed concurrently");
            if !report.has_more {
                break;
            }
            after = report.next_cursor;
        }
        Ok(checks)
    }
    fn store(&self) -> ScopedAttemptStore<'_> {
        ScopedAttemptStore {
            root: self.lease.root(),
            kind: speech_check::KIND,
            label: "Speech check",
        }
    }
    fn reap(&mut self) -> Result<()> {
        if self
            .active
            .as_ref()
            .is_some_and(|active| active.task.as_ref().unwrap().is_finished())
        {
            let mut active = self.active.take().unwrap();
            if !matches!(active.task.take().unwrap().join(), Ok(Ok(()))) {
                self.halted = true;
                bail!("Check executor stopped unexpectedly");
            }
        }
        Ok(())
    }
    pub fn enqueue(&mut self) -> Result<Value> {
        self.reap()?;
        let captured = crate::infrastructure::speech_settings::capture(self.lease.root())?;
        let work = CheckWork {
            version: 1,
            operation_id: uuid::Uuid::new_v4().to_string(),
            attempt_token: uuid::Uuid::new_v4().to_string(),
            settings: crate::domain::speech_settings::local_snapshot(captured.value())?,
        };
        work.validate()?;
        let definition = JobDefinition {
            kind: speech_check::KIND.into(),
            object_id: work.operation_id.clone(),
            input_revision: work.revision(),
            config: serde_json::to_value(work)?,
            resource: JobResource::LocalHeavy,
            dependencies: Vec::new(),
            title: "Check local speech".into(),
            paid: false,
        };
        match self.store().queue().execute(JobCommand::Enqueue {
            definition,
            follow_ups: Vec::new(),
        })? {
            JobReply::Enqueued { job, .. } => Ok(json!({"check":summary(&job)})),
            _ => bail!("Invalid check enqueue"),
        }
    }
    pub fn get(&mut self, id: String) -> Result<Value> {
        self.reap()?;
        match self.store().queue().execute(JobCommand::Get { id })? {
            JobReply::Job(job) => Ok(json!({"check":summary(&job)})),
            _ => bail!("Invalid check lookup"),
        }
    }
    pub fn cancel(&mut self, id: String, attempt: u64) -> Result<Value> {
        self.reap()?;
        let result = self.store().queue().execute(JobCommand::Mutate {
            id: id.clone(),
            expected_attempt: Some(attempt),
            mutation: JobMutation::Cancel,
        })?;
        if let Some(active) = &self.active {
            if active.id == id && active.attempt == attempt {
                active.stop.cancel();
            }
        }
        match result {
            JobReply::Job(job) => Ok(json!({"check":summary(&job)})),
            _ => bail!("Invalid check cancellation"),
        }
    }
    pub fn run(&mut self, id: String) -> Result<Value> {
        self.reap()?;
        ensure!(!self.halted && self.active.is_none(), "Check executor busy");
        let job = match self
            .store()
            .queue()
            .execute(JobCommand::Claim(ClaimRequest {
                job_id: Some(id),
                allowed_resources: Some(vec![JobResource::LocalHeavy]),
                excluded_accounts: Vec::new(),
            }))? {
            JobReply::Claimed(Some(job)) => job,
            JobReply::Claimed(None) => return Ok(json!({"check":null})),
            _ => bail!("Invalid check claim"),
        };
        let stop = Arc::new(AttemptStop::default());
        let control = stop.clone();
        let lease = self.lease.clone();
        let worker = self.worker.clone();
        let claimed = job.clone();
        match thread::Builder::new()
            .name("after-speech-check".into())
            .spawn(move || {
                speech_check::execute(
                    &ScopedAttemptStore {
                        root: lease.root(),
                        kind: speech_check::KIND,
                        label: "Speech check",
                    },
                    &*worker,
                    &claimed,
                    &stop,
                )
            }) {
            Ok(task) => {
                self.active = Some(Active {
                    id: job.id.clone(),
                    attempt: job.attempt,
                    stop: control,
                    task: Some(task),
                });
                Ok(json!({"check":summary(&job)}))
            }
            Err(error) => {
                self.store()
                    .finish(&job.id, job.attempt, AttemptOutcome::Interrupted)?;
                Err(error.into())
            }
        }
    }
}
fn summary(job: &Job) -> Value {
    json!({"id":job.id,"state":job.state,"progress":job.progress,"attempt":job.attempt,"cancelRequested":job.cancel_requested,"createdAt":job.created_at})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::speech_progress::SpeechObserver;
    use std::{
        sync::{
            atomic::{AtomicUsize, Ordering},
            mpsc, Mutex,
        },
        time::{Duration, Instant},
    };
    struct Paused {
        entered: mpsc::SyncSender<()>,
        resume: Mutex<mpsc::Receiver<()>>,
        calls: AtomicUsize,
    }
    impl CheckWorker for Paused {
        fn run_check(
            &self,
            _: &CheckWork,
            stop: &AttemptStop,
            observer: &mut dyn SpeechObserver,
        ) -> Result<()> {
            self.calls.fetch_add(1, Ordering::Relaxed);
            observer.checkpoint(Some(0.2))?;
            self.entered.send(())?;
            loop {
                if stop.is_requested() {
                    bail!("stopped");
                }
                if self.resume.lock().unwrap().try_recv().is_ok() {
                    return Ok(());
                }
                thread::sleep(Duration::from_millis(2));
            }
        }
    }
    fn worker() -> (Arc<Paused>, mpsc::Receiver<()>, mpsc::Sender<()>) {
        let (entered, ready) = mpsc::sync_channel(1);
        let (resume, go) = mpsc::channel();
        (
            Arc::new(Paused {
                entered,
                resume: Mutex::new(go),
                calls: AtomicUsize::new(0),
            }),
            ready,
            resume,
        )
    }
    fn owner(root: &std::path::Path, worker: Arc<dyn CheckWorker>) -> Checks {
        Checks::new(
            Arc::new(
                crate::infrastructure::executor_lease::try_acquire_speech(root)
                    .unwrap()
                    .unwrap(),
            ),
            worker,
        )
        .unwrap()
    }
    fn wait(owner: &mut Checks, id: &str, state: &str) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let job = owner.get(id.into()).unwrap();
            if job["check"]["state"] == state {
                return;
            }
            assert_eq!(job["check"]["state"], "running");
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(2));
        }
    }
    #[test]
    fn checks_share_global_admission_fence_cancel_and_join_before_lease_release() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("settings.json"),json!({"speechMode":"local","diarization":false,"asrModelPath":"/synthetic/model","apiKey":"private-check-fixture"}).to_string()).unwrap();
        let (worker, ready, _resume) = worker();
        let mut checks = owner(root.path(), worker.clone());
        let check = checks.enqueue().unwrap()["check"].clone();
        let id = check["id"].as_str().unwrap();
        let stored = match checks
            .store()
            .queue()
            .execute(JobCommand::Get { id: id.into() })
            .unwrap()
        {
            JobReply::Job(job) => job,
            _ => panic!("missing check"),
        };
        assert!(!stored.config.to_string().contains("private-check-fixture"));
        assert!(!stored.config.to_string().contains("apiKey"));
        assert!(!check.to_string().contains("settings"));
        assert!(!check.to_string().contains("private-check-fixture"));
        let foreign = ScopedAttemptStore {
            root: root.path(),
            kind: "foreign-test",
            label: "Foreign",
        };
        let definition = JobDefinition {
            kind: "foreign-test".into(),
            object_id: uuid::Uuid::new_v4().to_string(),
            input_revision: "fixture".into(),
            config: json!({}),
            resource: JobResource::LocalHeavy,
            dependencies: vec![],
            title: "Synthetic".into(),
            paid: false,
        };
        let foreign_id = match foreign
            .queue()
            .execute(JobCommand::Enqueue {
                definition,
                follow_ups: vec![],
            })
            .unwrap()
        {
            JobReply::Enqueued { job, .. } => job.id,
            _ => panic!("enqueue"),
        };
        foreign
            .queue()
            .execute(JobCommand::Claim(ClaimRequest {
                job_id: Some(foreign_id.clone()),
                allowed_resources: Some(vec![JobResource::LocalHeavy]),
                excluded_accounts: vec![],
            }))
            .unwrap();
        assert!(checks.run(id.into()).unwrap()["check"].is_null());
        assert_eq!(worker.calls.load(Ordering::Relaxed), 0);
        foreign
            .finish(&foreign_id, 1, AttemptOutcome::Succeeded)
            .unwrap();
        assert_eq!(checks.run(id.into()).unwrap()["check"]["attempt"], 1);
        ready.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(checks.cancel(id.into(), 0).is_err());
        assert_eq!(checks.get(id.into()).unwrap()["check"]["state"], "running");
        checks.cancel(id.into(), 1).unwrap();
        wait(&mut checks, id, "cancelled");
        let second = checks.enqueue().unwrap()["check"]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        checks.run(second.clone()).unwrap();
        ready.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(
            crate::infrastructure::executor_lease::try_acquire_speech(root.path())
                .unwrap()
                .is_none()
        );
        drop(checks);
        let mut successor = owner(root.path(), worker.clone());
        assert_eq!(
            successor.get(second).unwrap()["check"]["state"],
            "interrupted"
        );
        assert_eq!(
            successor.get(id.into()).unwrap()["check"]["state"],
            "cancelled"
        );
        assert_eq!(worker.calls.load(Ordering::Relaxed), 2);
        let speech = ScopedAttemptStore {
            root: root.path(),
            kind: "desktop-speech",
            label: "Speech",
        };
        assert!(speech
            .queue()
            .execute(JobCommand::Get { id: id.into() })
            .is_err());
        assert!(!root.path().join("meetings").exists());
    }
}
