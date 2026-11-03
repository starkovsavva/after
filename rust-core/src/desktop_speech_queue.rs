//! Leased native speech queue owner. No renderer request is registered here.
use crate::{
    application::{
        attempt_execution::{AttemptOutcome, AttemptStop, AttemptStore},
        job_ports::JobHistoryCursor,
        job_recovery,
        jobs::{ClaimRequest, JobCommand, JobReply},
        speech_execution::SpeechWork,
        speech_jobs::{self, SpeechJobWorker},
    },
    domain::jobs::{Job, JobMutation, JobResource},
    infrastructure::{attempt_store::ScopedAttemptStore, executor_lease::SpeechExecutorLease},
};
use anyhow::{bail, ensure, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    sync::Arc,
    thread::{self, JoinHandle},
};
#[derive(Deserialize)]
#[serde(
    tag = "action",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub(crate) enum Request {
    Meeting {meeting_id:String},
    Start {meeting_id:String},
    Resume {job_id:String,expected_attempt:u64},
    EnqueueCheck {},
    GetCheck {job_id:String},
    RunCheck {job_id:String},
    CancelCheck {job_id:String,expected_attempt:u64},
    Prepare { meeting_id: String },
    Enqueue {
        input: SpeechWork,
    },
    Get {
        job_id: String,
    },
    History {
        after: Option<JobHistoryCursor>,
    },
    Run {
        job_id: String,
    },
    Cancel {
        job_id: String,
        expected_attempt: u64,
    },
    Retry {
        job_id: String,
        expected_attempt: u64,
    },
    Reconcile {},
}
pub(crate) struct Executor {
    lease: Arc<SpeechExecutorLease>,
    worker: Arc<dyn SpeechJobWorker>,
    active: Option<Active>,
    halted: bool,
    checks: Option<crate::desktop_speech_checks::Checks>,
}
struct Active {
    id: String,
    attempt: u64,
    stop: Arc<AttemptStop>,
    thread: Option<JoinHandle<Result<()>>>,
}
impl Active {
    fn join(mut self) -> Result<()> {
        self.thread
            .take()
            .unwrap()
            .join()
            .map_err(|_| anyhow::anyhow!("Speech thread stopped unexpectedly"))?
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
impl Drop for Executor {
    fn drop(&mut self) {
        drop(self.active.take());
    }
}
impl Executor {
    pub fn new(lease: Arc<SpeechExecutorLease>, worker: Arc<dyn SpeechJobWorker>) -> Result<Self> {
        let owner = Self {
            lease,
            worker,
            active: None,
            halted: false,
            checks: None,
        };
        owner.reconcile()?;
        Ok(owner)
    }
    pub fn with_checks(lease:Arc<SpeechExecutorLease>,worker:Arc<dyn SpeechJobWorker>,checks:crate::desktop_speech_checks::Checks)->Result<Self> {
        let mut owner=Self::new(lease,worker)?;owner.checks=Some(checks);Ok(owner)
    }
    fn checks(&mut self)->Result<&mut crate::desktop_speech_checks::Checks>{self.checks.as_mut().ok_or_else(||anyhow::anyhow!("Speech preflight unavailable"))}
    fn store(&self) -> ScopedAttemptStore<'_> {
        ScopedAttemptStore {
            root: self.lease.root(),
            kind: speech_jobs::KIND,
            label: "Speech",
        }
    }
    fn reconcile(&self) -> Result<Value> {
        ensure!(self.active.is_none(), "Speech is still running");
        let mut after = None;
        let mut examined = 0usize;
        let mut unresolved = 0usize;
        loop {
            let report = job_recovery::reconcile(
                &self.store(),
                speech_jobs::KIND,
                |job| self.worker.committed(&speech_jobs::input(job)?),
                after.as_deref(),
            )?;
            examined += report.examined;
            unresolved += report.unresolved;
            if !report.has_more {
                break;
            }
            after = report.next_cursor;
        }
        Ok(json!({"examined":examined,"unresolved":unresolved}))
    }
    pub fn command(&mut self, request: Request) -> Result<Value> {
        if self
            .active
            .as_ref()
            .is_some_and(|active| active.thread.as_ref().unwrap().is_finished())
        {
            if let Err(error) = self.active.take().unwrap().join() {
                self.halted = true;
                return Err(error);
            }
        }
        match request {
            Request::EnqueueCheck {} => self.checks()?.enqueue(),
            Request::GetCheck {job_id} => self.checks()?.get(job_id),
            Request::RunCheck {job_id} => self.checks()?.run(job_id),
            Request::CancelCheck {job_id,expected_attempt} => self.checks()?.cancel(job_id,expected_attempt),
            Request::Prepare { meeting_id } => Ok(json!({"prepared":crate::speech_job::prepare(self.lease.root(), &meeting_id)?})),
            Request::Meeting {meeting_id} => Ok(json!({"job":crate::infrastructure::speech_submission::latest(self.lease.root(),&meeting_id)?.as_ref().map(summary)})),
            Request::Start {meeting_id} => {
                let submission=crate::application::speech_submission::submit(&crate::infrastructure::speech_submission::Submission{root:self.lease.root()},&meeting_id)?;
                let job=submission.job;
                if !submission.created || self.active.is_some() {return Ok(json!({"job":summary(&job)}));}
                let reply=self.run(job.id.clone())?;
                if reply["job"].is_null(){Ok(json!({"job":summary(&job)}))}else{Ok(reply)}
            }
            Request::Resume {job_id,expected_attempt} => {
                ensure!(self.active.is_none(),"Speech executor is busy");self.reconcile()?;
                let job=match self.store().queue().execute(JobCommand::Get{id:job_id.clone()})?{JobReply::Job(job)=>job,_=>bail!("Missing speech job")};
                ensure!(job.attempt==expected_attempt,"Speech attempt changed");
                if job.state=="succeeded" {return Ok(json!({"job":summary(&job)}));}
                if job.state!="queued" {self.command(Request::Retry {job_id:job_id.clone(),expected_attempt})?;}
                let queued=match self.store().queue().execute(JobCommand::Get{id:job_id.clone()})?{JobReply::Job(job)=>job,_=>bail!("Missing speech job")};
                let reply=self.run(job_id)?;if reply["job"].is_null(){Ok(json!({"job":summary(&queued)}))}else{Ok(reply)}
            }
            Request::Enqueue { input } => {
                let (job,deduplicated)=crate::application::speech_submission::enqueue(&crate::infrastructure::speech_submission::Submission{root:self.lease.root()},input)?;
                Ok(json!({"job":summary(&job),"deduplicated":deduplicated}))
            }
            Request::Get { job_id } => match self
                .store()
                .queue()
                .execute(JobCommand::Get { id: job_id })?
            {
                JobReply::Job(job) => Ok(json!({"job":summary(&job)})),
                _ => bail!("Invalid speech job reply"),
            },
            Request::History { after } => {
                let page = self.store().queue().history(after.as_ref())?;
                Ok(
                    json!({"jobs":page.jobs.iter().map(summary).collect::<Vec<_>>(),"total":page.total,"hasMore":page.next_cursor.is_some(),"nextCursor":page.next_cursor}),
                )
            }
            Request::Run { job_id } => self.run(job_id),
            Request::Cancel {
                job_id,
                expected_attempt,
            } => {
                let reply = self.store().queue().execute(JobCommand::Mutate {
                    id: job_id.clone(),
                    expected_attempt: Some(expected_attempt),
                    mutation: JobMutation::Cancel,
                })?;
                if let Some(active) = &self.active {
                    if active.id == job_id && active.attempt == expected_attempt {
                        active.stop.cancel();
                    }
                }
                match reply {
                    JobReply::Job(job) => Ok(json!({"job":summary(&job)})),
                    _ => bail!("Invalid speech cancel reply"),
                }
            }
            Request::Retry {
                job_id,
                expected_attempt,
            } => {
                ensure!(self.active.is_none(), "Speech is still running");
                let job = match self
                    .store()
                    .queue()
                    .execute(JobCommand::Get { id: job_id.clone() })?
                {
                    JobReply::Job(job) => job,
                    _ => bail!("Missing speech job"),
                };
                self.worker.committed(&speech_jobs::input(&job)?)?;
                match self.store().queue().execute(JobCommand::Mutate {
                    id: job_id,
                    expected_attempt: Some(expected_attempt),
                    mutation: JobMutation::Retry {
                        confirm_paid: false,
                    },
                })? {
                    JobReply::Job(job) => Ok(json!({"job":summary(&job)})),
                    _ => bail!("Invalid speech retry reply"),
                }
            }
            Request::Reconcile {} => self.reconcile(),
        }
    }
    fn run(&mut self, id: String) -> Result<Value> {
        ensure!(
            !self.halted && self.active.is_none(),
            "Speech executor is unavailable or busy"
        );
        let job = match self
            .store()
            .queue()
            .execute(JobCommand::Claim(ClaimRequest {
                job_id: Some(id),
                allowed_resources: Some(vec![JobResource::LocalHeavy]),
                excluded_accounts: Vec::new(),
            }))? {
            JobReply::Claimed(Some(job)) => job,
            JobReply::Claimed(None) => return Ok(json!({"job":null})),
            _ => bail!("Invalid speech claim reply"),
        };
        let lease = self.lease.clone();
        let worker = self.worker.clone();
        let claimed = job.clone();
        let control = Arc::new(AttemptStop::default());
        let stop = control.clone();
        let task = thread::Builder::new()
            .name("after-queued-speech".into())
            .spawn(move || {
                let store = ScopedAttemptStore {
                    root: lease.root(),
                    kind: speech_jobs::KIND,
                    label: "Speech",
                };
                speech_jobs::execute(&store, &*worker, &claimed, &stop)
            });
        match task {
            Ok(thread) => {
                self.active = Some(Active {
                    id: job.id.clone(),
                    attempt: job.attempt,
                    stop: control,
                    thread: Some(thread),
                });
                Ok(json!({"job":summary(&job)}))
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
    let meeting = speech_jobs::input(job).ok().map(|work| work.meeting_id);
    json!({"id":job.id,"meetingId":meeting,"state":job.state,"progress":job.progress,
        "attempt":job.attempt,"cancelRequested":job.cancel_requested,"createdAt":job.created_at})
}

#[cfg(test)]
mod tests {
    use crate::domain::jobs::JobDefinition;
    use super::*;
    use crate::{
        application::{job_recovery::RecoveryStore, speech_jobs::SpeechObserver},
        infrastructure::speech_publication::Publication,
    };
    use std::{
        path::Path,
        sync::{
            atomic::{AtomicBool, AtomicUsize, Ordering},
            mpsc, Mutex,
        },
        time::{Duration, Instant},
    };
    struct Paused {
        entered: mpsc::SyncSender<()>,
        resume: Mutex<mpsc::Receiver<()>>,
        published: AtomicBool,
        calls: AtomicUsize,
        finish_on_cancel: bool,
    }
    impl SpeechJobWorker for Paused {
        fn committed(&self, _: &SpeechWork) -> Result<bool> {
            Ok(self.published.load(Ordering::Acquire))
        }
        fn run(
            &self,
            _: &SpeechWork,
            stop: &AttemptStop,
            observer: &mut dyn SpeechObserver,
        ) -> Result<()> {
            self.calls.fetch_add(1, Ordering::Relaxed);
            observer.checkpoint(Some(0.2))?;
            self.entered.send(())?;
            loop {
                if self.resume.lock().unwrap().try_recv().is_ok() {
                    self.published.store(true, Ordering::Release);
                    return Ok(());
                }
                if stop.is_requested() {
                    if self.finish_on_cancel {
                        self.published.store(true, Ordering::Release);
                    }
                    bail!("synthetic worker stopped");
                }
                thread::sleep(Duration::from_millis(2));
            }
        }
    }
    fn worker(finish_on_cancel: bool) -> (Arc<Paused>, mpsc::Receiver<()>, mpsc::Sender<()>) {
        let (entered, ready) = mpsc::sync_channel(1);
        let (resume, gate) = mpsc::channel();
        (
            Arc::new(Paused {
                entered,
                resume: Mutex::new(gate),
                published: AtomicBool::new(false),
                calls: AtomicUsize::new(0),
                finish_on_cancel,
            }),
            ready,
            resume,
        )
    }
    fn input(root: &Path) -> SpeechWork {
        let id = uuid::Uuid::new_v4().to_string();
        let directory = crate::storage::meeting_directory(root, &id).unwrap();
        crate::platform_fs::create_private_directory(&directory).unwrap();
        crate::storage::atomic_json(
            &directory.join("meta.json"),
            &json!({"id":id,"source":"source.wav"}),
        )
        .unwrap();
        std::fs::write(directory.join("source.wav"), b"synthetic; never loaded").unwrap();
        SpeechWork {
            version: 1,
            operation_id: uuid::Uuid::new_v4().to_string(),
            attempt_token: uuid::Uuid::new_v4().to_string(),
            meeting_id: id.clone(),
            input_revision: Publication { root }.inspect(&id).unwrap(),
            settings: json!({"speechMode":"local","diarization":false}),
        }
    }
    #[test]
    fn meeting_start_reuses_pending_work_and_resume_fences_the_observed_attempt() {
        let root=tempfile::tempdir().unwrap();let seed=input(root.path());
        std::fs::write(root.path().join("settings.json"),json!({"speechMode":"local","diarization":false,"asrModelPath":"/selected/model"}).to_string()).unwrap();
        let (worker,ready,resume)=worker(false);let mut owner=owner(root.path(),worker.clone());
        let first=owner.command(Request::Start{meeting_id:seed.meeting_id.clone()}).unwrap()["job"].clone();let id=first["id"].as_str().unwrap().to_owned();
        ready.recv_timeout(Duration::from_secs(5)).unwrap();
        let repeated=owner.command(Request::Start{meeting_id:seed.meeting_id}).unwrap();assert_eq!(repeated["job"]["id"],id);assert_eq!(worker.calls.load(Ordering::Relaxed),1);
        assert!(owner.command(Request::Cancel{job_id:id.clone(),expected_attempt:0}).is_err());
        owner.command(Request::Cancel{job_id:id.clone(),expected_attempt:1}).unwrap();wait(&mut owner,&id,"cancelled");
        assert!(owner.command(Request::Resume{job_id:id.clone(),expected_attempt:0}).is_err());
        assert_eq!(owner.command(Request::Resume{job_id:id.clone(),expected_attempt:1}).unwrap()["job"]["attempt"],2);ready.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(owner.command(Request::Cancel{job_id:id.clone(),expected_attempt:1}).is_err());
        resume.send(()).unwrap();wait(&mut owner,&id,"succeeded");
        assert_eq!(owner.command(Request::Resume{job_id:id,expected_attempt:2}).unwrap()["job"]["state"],"succeeded");assert_eq!(worker.calls.load(Ordering::Relaxed),2);
    }
    fn owner(root: &Path, worker: Arc<dyn SpeechJobWorker>) -> Executor {
        Executor::new(
            Arc::new(
                crate::infrastructure::executor_lease::try_acquire_speech(root)
                    .unwrap()
                    .unwrap(),
            ),
            worker,
        )
        .unwrap()
    }
    fn enqueue(owner: &mut Executor, input: SpeechWork) -> String {
        owner.command(Request::Enqueue { input }).unwrap()["job"]["id"]
            .as_str()
            .unwrap()
            .into()
    }
    fn wait(owner: &mut Executor, id: &str, state: &str) -> Value {
        let until = Instant::now() + Duration::from_secs(5);
        loop {
            let reply = owner.command(Request::Get { job_id: id.into() }).unwrap()["job"].clone();
            if reply["state"] == state {
                return reply;
            }
            assert_eq!(reply["state"], "running", "{reply}");
            assert!(Instant::now() < until, "speech did not finish");
            thread::sleep(Duration::from_millis(2));
        }
    }
    #[test]
    fn live_speech_uses_durable_claim_cancel_fences_and_receipt_completion() {
        for committed in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let (worker, ready, _) = worker(committed);
            let mut owner = owner(root.path(), worker.clone());
            let work = input(root.path());
            let id = enqueue(&mut owner, work.clone());
            assert_eq!(enqueue(&mut owner, work), id);
            owner.command(Request::Run { job_id: id.clone() }).unwrap();
            ready.recv_timeout(Duration::from_secs(5)).unwrap();
            assert!(owner.command(Request::Reconcile {}).is_err());
            assert!(owner.command(Request::Run { job_id: id.clone() }).is_err());
            assert!(owner
                .command(Request::Cancel {
                    job_id: id.clone(),
                    expected_attempt: 0
                })
                .is_err());
            assert!(owner
                .active
                .as_ref()
                .is_some_and(|active| !active.stop.is_requested()));
            owner
                .command(Request::Cancel {
                    job_id: id.clone(),
                    expected_attempt: 1,
                })
                .unwrap();
            let job = wait(
                &mut owner,
                &id,
                if committed { "succeeded" } else { "cancelled" },
            );
            if committed {
                assert_eq!(job["progress"], 1.);
            }
            assert_eq!(worker.calls.load(Ordering::Relaxed), 1);
        }
    }
    #[test]
    fn owner_drop_interrupts_and_joins_before_releasing_its_scope() {
        let root = tempfile::tempdir().unwrap();
        let (worker, ready, _) = worker(false);
        let mut owner = owner(root.path(), worker.clone());
        let id = enqueue(&mut owner, input(root.path()));
        owner.command(Request::Run { job_id: id.clone() }).unwrap();
        ready.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(
            crate::infrastructure::executor_lease::try_acquire_speech(root.path())
                .unwrap()
                .is_none()
        );
        drop(owner);
        assert!(
            crate::infrastructure::executor_lease::try_acquire_speech(root.path())
                .unwrap()
                .is_some()
        );
        let store = ScopedAttemptStore {
            root: root.path(),
            kind: speech_jobs::KIND,
            label: "Speech",
        };
        let JobReply::Job(job) = store.queue().execute(JobCommand::Get { id }).unwrap() else {
            panic!()
        };
        assert_eq!(job.state, "interrupted");
        assert_eq!(worker.calls.load(Ordering::Relaxed), 1);
    }
    #[test]
    fn startup_reconciles_beyond_the_history_page_without_starting_workers() {
        let root = tempfile::tempdir().unwrap();
        let (worker, _, _) = worker(false);
        let mut first = owner(root.path(), worker.clone());
        for _ in 0..65 {
            let id = enqueue(&mut first, input(root.path()));
            let store = first.store();
            let JobReply::Claimed(Some(job)) = store
                .queue()
                .execute(JobCommand::Claim(ClaimRequest {
                    job_id: Some(id),
                    allowed_resources: None,
                    excluded_accounts: Vec::new(),
                }))
                .unwrap()
            else {
                panic!()
            };
            store
                .finish(&job.id, job.attempt, AttemptOutcome::Interrupted)
                .unwrap();
        }
        drop(first);
        worker.published.store(true, Ordering::Release);
        let mut second = owner(root.path(), worker.clone());
        let first_page = second.command(Request::History { after: None }).unwrap();
        assert_eq!(first_page["total"], 65);
        assert_eq!(first_page["jobs"].as_array().unwrap().len(), 50);
        assert!(first_page["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .all(|job| job["state"] == "succeeded"
                && job.get("config").is_none()
                && job.get("objectID").is_none()));
        let next = serde_json::from_value(first_page["nextCursor"].clone()).unwrap();
        let second_page = second
            .command(Request::History { after: Some(next) })
            .unwrap();
        assert_eq!(second_page["jobs"].as_array().unwrap().len(), 15);
        assert!(second.store().candidates(None, 64).unwrap().is_empty());
        assert_eq!(worker.calls.load(Ordering::Relaxed), 0);
    }
    #[test]
    fn speech_admission_observes_foreign_resource_claims_and_rows_hide_native_grants() {
        let root = tempfile::tempdir().unwrap();
        let (worker, _, _) = worker(false);
        let mut owner = owner(root.path(), worker);
        let work = input(root.path());
        let token = work.attempt_token.clone();
        let operation = work.operation_id.clone();
        let id = enqueue(&mut owner, work);
        let definition = JobDefinition {
            kind: "desktop-import".into(),
            object_id: uuid::Uuid::new_v4().to_string(),
            input_revision: "fixture".into(),
            config: json!({}),
            resource: JobResource::LocalHeavy,
            dependencies: Vec::new(),
            title: "foreign import".into(),
            paid: false,
        };
        let foreign = crate::desktop_queue::queue(root.path());
        let JobReply::Enqueued { job, .. } = foreign
            .execute(JobCommand::Enqueue {
                definition,
                follow_ups: Vec::new(),
            })
            .unwrap()
        else {
            panic!()
        };
        foreign
            .execute(JobCommand::Claim(ClaimRequest {
                job_id: Some(job.id),
                allowed_resources: None,
                excluded_accounts: Vec::new(),
            }))
            .unwrap();
        assert_eq!(
            owner.command(Request::Run { job_id: id.clone() }).unwrap()["job"],
            Value::Null
        );
        let row = owner
            .command(Request::Get { job_id: id })
            .unwrap()
            .to_string();
        assert!(
            !row.contains(&token)
                && !row.contains(&operation)
                && !row.contains("settings")
                && !row.contains("inputRevision")
        );
    }

    #[test]
    fn startup_reconciles_receipts_without_resuming_or_touching_foreign_scope() {
        let root = tempfile::tempdir().unwrap();
        let (worker, _, _) = worker(false);
        let mut first = owner(root.path(), worker.clone());
        let work = input(root.path());
        let id = enqueue(&mut first, work);
        let store = first.store();
        store
            .queue()
            .execute(JobCommand::Claim(ClaimRequest {
                job_id: Some(id.clone()),
                allowed_resources: None,
                excluded_accounts: Vec::new(),
            }))
            .unwrap();
        drop(first);
        worker.published.store(true, Ordering::Release);
        let mut second = owner(root.path(), worker.clone());
        let reply = second.command(Request::Get { job_id: id }).unwrap();
        assert_eq!(reply["job"]["state"], "succeeded");
        assert_eq!(reply["job"]["progress"], 1.);
        assert_eq!(worker.calls.load(Ordering::Relaxed), 0);
        assert!(second.store().candidates(None, 64).unwrap().is_empty());
        let mut foreign = crate::desktop_queue_executor::Executor::new(
            crate::infrastructure::executor_lease::try_acquire(root.path())
                .unwrap()
                .unwrap(),
        );
        let reply = foreign
            .command(crate::desktop_queue::Request::Enqueue {
                input: crate::application::import_ports::ImportInput {
                    operation_id: uuid::Uuid::new_v4().to_string(),
                    attempt_token: uuid::Uuid::new_v4().to_string(),
                    source_path: root.path().join("unused.wav"),
                    title: None,
                },
            })
            .unwrap();
        let id = reply["job"]["id"].as_str().unwrap().to_owned();
        assert!(second.command(Request::Get { job_id: id.clone() }).is_err());
        assert!(second
            .command(Request::Cancel {
                job_id: id,
                expected_attempt: 0
            })
            .is_err());
    }
}
