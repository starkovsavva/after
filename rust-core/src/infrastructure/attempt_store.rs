//! Scoped SQLite lifecycle adapter. Caller retains its executor lease throughout
//! these operations and all worker joins; a kind filter alone is not ownership.
use crate::{
    application::{
        attempt_execution::{AttemptOutcome, AttemptStore},
        job_ports::{JobClock, JobQueueRepository},
        job_recovery::{RecoveryOutcome, RecoveryStore},
        jobs::{JobCommand, JobQueue, JobReply},
    },
    domain::jobs::{Job, JobMutation, JobUpdate, UpdateField},
    infrastructure::{
        job_context::{RandomJobIds, SystemJobClock},
        job_queue::SqliteJobQueue,
    },
};
use anyhow::{bail, Result};
use std::path::Path;
pub(crate) struct ScopedAttemptStore<'a> {
    pub root: &'a Path,
    pub kind: &'static str,
    pub label: &'static str,
}
impl ScopedAttemptStore<'_> {
    pub fn queue(&self) -> JobQueue<SqliteJobQueue<'_>, SystemJobClock, RandomJobIds> {
        JobQueue {
            repository: SqliteJobQueue { root: self.root },
            clock: SystemJobClock,
            ids: RandomJobIds,
            kind: Some(self.kind),
        }
    }
}
impl RecoveryStore for ScopedAttemptStore<'_> {
    fn candidates(&self, after: Option<&str>, limit: usize) -> Result<Vec<Job>> {
        self.queue()
            .repository
            .recovery_candidates(self.kind, after, limit)
    }
    fn resolve(&self, observed: &Job, outcome: RecoveryOutcome) -> Result<bool> {
        let queue = self.queue();
        queue.repository.transaction(|transaction| {
            if transaction.state(&observed.id)?.is_none() {
                return Ok(false);
            }
            let mut current = transaction.get(&observed.id)?;
            if current.kind != self.kind
                || !["running", "interrupted"].contains(&current.state.as_str())
                || serde_json::to_value(&current)? != serde_json::to_value(observed)?
            {
                return Ok(false);
            }
            match outcome {
                RecoveryOutcome::Published => {
                    current.state = "succeeded".into();
                    current.progress = 1.0;
                    current.cancel_requested = false;
                    current.message.clear();
                }
                RecoveryOutcome::Cancelled => {
                    current.state = "cancelled".into();
                    current.cancel_requested = false;
                    current.message = format!("{} cancelled", self.label);
                }
                RecoveryOutcome::Interrupted => {
                    current.state = "interrupted".into();
                    current.cancel_requested = false;
                    current.message = "Work was interrupted. Retry explicitly.".into();
                }
                RecoveryOutcome::Unresolved => {
                    current.state = "interrupted".into();
                    current.message = format!("{} outcome requires reconciliation", self.label);
                }
            }
            current.updated_at = queue.clock.now();
            transaction.save(&current)?;
            Ok(true)
        })
    }
}
impl AttemptStore for ScopedAttemptStore<'_> {
    fn progress(&self, id: &str, attempt: u64, fraction: f64) -> Result<bool> {
        match self.queue().execute(JobCommand::Mutate {
            id: id.into(),
            expected_attempt: Some(attempt),
            mutation: JobMutation::Update(JobUpdate {
                state: Some("running".into()),
                progress: UpdateField::Set(fraction),
                message: UpdateField::Unchanged,
                result: None,
            }),
        })? {
            JobReply::Job(job) => Ok(job.cancel_requested),
            _ => bail!("Invalid import progress reply"),
        }
    }
    fn finish(&self, id: &str, attempt: u64, outcome: AttemptOutcome) -> Result<()> {
        let message = match outcome {
            AttemptOutcome::Succeeded => String::new(),
            AttemptOutcome::Cancelled => format!("{} cancelled", self.label),
            AttemptOutcome::Failed => format!("{} failed", self.label),
            AttemptOutcome::Interrupted => {
                format!("{} outcome requires reconciliation", self.label)
            }
        };
        self.queue().execute(JobCommand::Mutate {
            id: id.into(),
            expected_attempt: Some(attempt),
            mutation: JobMutation::Update(JobUpdate {
                state: Some(outcome.state().into()),
                progress: if outcome == AttemptOutcome::Succeeded {
                    UpdateField::Set(1.0)
                } else {
                    UpdateField::Unchanged
                },
                message: UpdateField::Set(message.into()),
                result: None,
            }),
        })?;
        Ok(())
    }
}
