//! Native application controller. Queue/process ownership is supplied through a
//! port; this module neither reads source files nor launches a process.
use crate::{
    import_queue::{
        ImportInput, ImportJob, ImportQueueSession, JobState, QueueCommand, RequestBudget,
    },
    models::HostError,
    worker_host::ImportWork,
};
use std::{
    cell::Cell,
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant},
};

pub(crate) struct Policy {
    pub deadline: Duration,
    pub cancel_grace: Duration,
    pub poll: Duration,
}
impl Default for Policy {
    fn default() -> Self {
        Self {
            deadline: Duration::from_secs(30 * 60),
            cancel_grace: Duration::from_secs(3),
            poll: Duration::from_millis(100),
        }
    }
}
/// Shared by every RPC and polling wait. Observing cancellation once fixes its
/// grace deadline; a slow response cannot restart the grace period.
struct Budget<'a> {
    cancelled: &'a AtomicBool,
    end: Instant,
    grace: Duration,
    stopping: Cell<Option<Instant>>,
}
impl RequestBudget for Budget<'_> {
    fn deadline(&self) -> Instant {
        let now = Instant::now();
        if self.stopping.get().is_none()
            && (self.cancelled.load(Ordering::Acquire) || now >= self.end)
        {
            self.stopping
                .set(Some(if now >= self.end { self.end } else { now }));
        }
        self.stopping
            .get()
            .map(|start| start + self.grace)
            .unwrap_or(self.end)
    }
}
fn failed() -> HostError {
    HostError::new(
        "import_failed",
        "Could not import this file. The original was preserved.",
    )
}
fn invalid() -> HostError {
    HostError::new(
        "invalid_response",
        "The import queue returned an invalid response.",
    )
}
fn stopped(cancelled: &AtomicBool) -> HostError {
    if cancelled.load(Ordering::Acquire) {
        HostError::new("cancelled", "Import cancelled.")
    } else {
        HostError::new("engine_timeout", "The import exceeded its time limit.")
    }
}
fn validate(job: &ImportJob, work: &ImportWork) -> Result<(), HostError> {
    if uuid::Uuid::parse_str(&job.id).is_err()
        || job.object_id != work.operation_id
        || job.config.operation_id != work.operation_id
        || job.config.attempt_token != work.attempt_token
        || job.config.source_path != work.source
        || job.config.title != work.title
        || !job.progress.is_finite()
        || !(0.0..=1.0).contains(&job.progress)
    {
        return Err(invalid());
    }
    Ok(())
}
/// Always stops the owner before returning. Caller resolves the exact receipt
/// after this boundary, including lost replies and late cancellation.
pub(crate) fn execute(
    queue: &dyn ImportQueueSession,
    work: &ImportWork,
    cancelled: &AtomicBool,
    progress: &mut dyn FnMut(f64),
    policy: Policy,
) -> Result<(), HostError> {
    let result = run(queue, work, cancelled, progress, policy);
    queue.shutdown();
    result
}
fn run(
    queue: &dyn ImportQueueSession,
    work: &ImportWork,
    cancelled: &AtomicBool,
    progress: &mut dyn FnMut(f64),
    policy: Policy,
) -> Result<(), HostError> {
    if cancelled.load(Ordering::Acquire) {
        return Err(stopped(cancelled));
    }
    let budget = Budget {
        cancelled,
        end: Instant::now() + policy.deadline,
        grace: policy.cancel_grace,
        stopping: Cell::new(None),
    };
    let mut job = queue
        .execute_with_budget(
            QueueCommand::Enqueue {
                input: ImportInput::from(work),
            },
            &budget,
        )?
        .job
        .ok_or_else(invalid)?;
    validate(&job, work)?;
    if job.state == JobState::Succeeded {
        return Ok(());
    }
    // No automatic retry of failed/interrupted attempts, or adoption of a running attempt.
    if job.state != JobState::Queued {
        return Err(failed());
    }
    let id = job.id.clone();
    budget.deadline();
    if budget.stopping.get().is_some() {
        queue.execute_with_budget(
            QueueCommand::Cancel {
                job_id: id,
                expected_attempt: job.attempt,
            },
            &budget,
        )?;
        return Err(stopped(cancelled));
    }
    job = queue
        .execute_with_budget(QueueCommand::Run { job_id: id.clone() }, &budget)?
        .job
        .ok_or_else(|| {
            HostError::new("busy", "The import is queued. Resources are unavailable.")
        })?;
    validate(&job, work)?;
    if job.id != id || job.state != JobState::Running || job.attempt == 0 {
        return Err(invalid());
    }
    let attempt = job.attempt;
    let mut previous = 0.0;
    let mut cancel_sent = false;
    loop {
        if job.id != id || job.attempt != attempt || job.progress < previous {
            return Err(invalid());
        }
        validate(&job, work)?;
        previous = job.progress;
        progress(job.progress);
        match job.state {
            JobState::Succeeded => return Ok(()),
            JobState::Cancelled => return Err(stopped(cancelled)),
            JobState::Failed => return Err(failed()),
            JobState::Interrupted => {
                return Err(HostError::new(
                    "import_interrupted",
                    "Import was interrupted. Retry explicitly.",
                ))
            }
            JobState::Running => {}
            _ => return Err(invalid()),
        }
        let now = Instant::now();
        let limit = budget.deadline();
        if !cancel_sent && budget.stopping.get().is_some() {
            cancel_sent = true;
            job = queue
                .execute_with_budget(
                    QueueCommand::Cancel {
                        job_id: id.clone(),
                        expected_attempt: attempt,
                    },
                    &budget,
                )?
                .job
                .ok_or_else(invalid)?;
            continue;
        }
        if now >= limit {
            return Err(stopped(cancelled));
        }
        thread::sleep(policy.poll.min(limit.saturating_duration_since(now)));
        // Re-enter the loop to initiate cancellation before a post-deadline Get.
        if Instant::now() >= limit {
            if budget.stopping.get().is_some() {
                return Err(stopped(cancelled));
            }
            continue;
        }
        job = queue
            .execute_with_budget(QueueCommand::Get { job_id: id.clone() }, &budget)?
            .job
            .ok_or_else(invalid)?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::import_queue::{ImportQueue, QueueReply};
    use serde_json::{json, Value};
    use std::{collections::VecDeque, sync::Mutex};
    struct Queue {
        replies: Mutex<VecDeque<Result<QueueReply, HostError>>>,
        commands: Mutex<Vec<Value>>,
        stopped: AtomicBool,
    }
    impl Queue {
        fn new(replies: Vec<Value>) -> Self {
            Self {
                replies: Mutex::new(
                    replies
                        .into_iter()
                        .map(|value| Ok(serde_json::from_value(value).unwrap()))
                        .collect(),
                ),
                commands: Mutex::default(),
                stopped: AtomicBool::new(false),
            }
        }
    }
    impl ImportQueue for Queue {
        fn execute(&self, _: QueueCommand) -> Result<QueueReply, HostError> {
            panic!("unbounded RPC")
        }
    }
    impl ImportQueueSession for Queue {
        fn execute_with_budget(
            &self,
            command: QueueCommand,
            budget: &dyn RequestBudget,
        ) -> Result<QueueReply, HostError> {
            assert!(budget.deadline() > Instant::now());
            self.commands
                .lock()
                .unwrap()
                .push(serde_json::to_value(command).unwrap());
            self.replies
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected RPC")
        }
        fn shutdown(&self) {
            self.stopped.store(true, Ordering::Release);
        }
    }
    fn work() -> ImportWork {
        ImportWork {
            operation_id: uuid::Uuid::new_v4().to_string(),
            attempt_token: uuid::Uuid::new_v4().to_string(),
            source: std::env::temp_dir().join("private.wav"),
            title: None,
        }
    }
    fn job(work: &ImportWork, state: &str, attempt: u64, progress: f64) -> Value {
        json!({"job":{"id":"11111111-1111-4111-8111-111111111111", "objectID":work.operation_id,
            "config":ImportInput::from(work), "state":state, "attempt":attempt, "progress":progress,"cancelRequested":false}})
    }
    fn policy() -> Policy {
        Policy {
            poll: Duration::ZERO,
            ..Default::default()
        }
    }
    #[test]
    fn published_attempt_wins_late_cancel_and_owner_stops_before_receipt_lookup() {
        let work = work();
        let queue = Queue::new(vec![
            job(&work, "queued", 0, 0.0),
            job(&work, "running", 1, 0.0),
            job(&work, "succeeded", 1, 1.0),
        ]);
        let cancelled = AtomicBool::new(false);
        let mut values = Vec::new();
        execute(
            &queue,
            &work,
            &cancelled,
            &mut |value| {
                values.push(value);
                cancelled.store(true, Ordering::Release);
            },
            policy(),
        )
        .unwrap();
        assert_eq!(values, [0.0, 1.0]);
        assert_eq!(queue.commands.lock().unwrap()[2]["action"], "cancel");
        assert_eq!(queue.commands.lock().unwrap()[2]["expectedAttempt"], 1);
        assert!(queue.stopped.load(Ordering::Acquire));
    }
    #[test]
    fn interrupted_history_is_never_retried_and_foreign_input_is_rejected() {
        let work = work();
        for reply in [
            job(&work, "interrupted", 1, 0.4),
            job(&self::work(), "queued", 0, 0.0),
        ] {
            let queue = Queue::new(vec![reply]);
            assert!(execute(
                &queue,
                &work,
                &AtomicBool::new(false),
                &mut |_| {},
                policy()
            )
            .is_err());
            assert_eq!(queue.commands.lock().unwrap().len(), 1);
            assert!(queue.stopped.load(Ordering::Acquire));
        }
    }
    #[test]
    fn stale_attempt_and_regressed_progress_cannot_complete_the_operation() {
        let work = work();
        for reply in [
            job(&work, "succeeded", 2, 1.0),
            job(&work, "running", 1, 0.1),
        ] {
            let queue = Queue::new(vec![
                job(&work, "queued", 0, 0.0),
                job(&work, "running", 1, 0.5),
                reply,
            ]);
            assert_eq!(
                execute(
                    &queue,
                    &work,
                    &AtomicBool::new(false),
                    &mut |_| {},
                    policy()
                )
                .unwrap_err()
                .code,
                "invalid_response"
            );
            assert!(queue.stopped.load(Ordering::Acquire));
        }
    }
    #[test]
    fn deadline_cancellation_has_a_separate_bounded_grace_and_never_runs_again() {
        let work = work();
        let queue = Queue::new(vec![
            job(&work, "queued", 0, 0.0),
            job(&work, "running", 1, 0.0),
            job(&work, "running", 1, 0.0),
        ]);
        let policy = Policy {
            deadline: Duration::from_millis(10),
            cancel_grace: Duration::from_millis(10),
            poll: Duration::from_secs(1),
        };
        assert_eq!(
            execute(&queue, &work, &AtomicBool::new(false), &mut |_| {}, policy)
                .unwrap_err()
                .code,
            "engine_timeout"
        );
        let actions: Vec<_> = queue
            .commands
            .lock()
            .unwrap()
            .iter()
            .map(|command| command["action"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(actions, ["enqueue", "run", "cancel"]);
        assert!(queue.stopped.load(Ordering::Acquire));
    }
    #[test]
    fn cancelled_before_admission_does_not_enqueue_or_copy() {
        let queue = Queue::new(vec![]);
        assert_eq!(
            execute(
                &queue,
                &work(),
                &AtomicBool::new(true),
                &mut |_| {},
                policy()
            )
            .unwrap_err()
            .code,
            "cancelled"
        );
        assert!(queue.commands.lock().unwrap().is_empty());
        assert!(queue.stopped.load(Ordering::Acquire));
    }
}
