//! Receipt reconciliation shared by scoped executors; never runs a worker.
use crate::domain::jobs::Job;
use anyhow::{ensure, Result};
use serde::Serialize;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RecoveryOutcome {
    Published,
    Interrupted,
    Cancelled,
    Unresolved,
}

pub(crate) trait RecoveryStore {
    fn candidates(&self, after: Option<&str>, limit: usize) -> Result<Vec<Job>>;
    /// Compare all typed fields of the observed record inside the write transaction. False
    /// means another mutation won; never overwrite that newer state.
    fn resolve(&self, observed: &Job, outcome: RecoveryOutcome) -> Result<bool>;
}

pub(crate) const PAGE_SIZE: usize = 64;

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RecoveryReport {
    pub examined: usize,
    pub published: usize,
    pub interrupted: usize,
    pub cancelled: usize,
    pub unresolved: usize,
    pub stale: usize,
    pub has_more: bool,
    pub next_cursor: Option<String>,
}

pub(crate) fn reconcile(
    store: &dyn RecoveryStore,
    kind: &str,
    probe: impl Fn(&crate::domain::jobs::Job) -> Result<bool>,
    after: Option<&str>,
) -> Result<RecoveryReport> {
    let jobs = store.candidates(after, PAGE_SIZE)?;
    ensure!(
        jobs.len() <= PAGE_SIZE
            && jobs.windows(2).all(|pair| pair[0].id < pair[1].id)
            && jobs
                .first()
                .is_none_or(|job| after.is_none_or(|after| job.id.as_str() > after)),
        "Invalid recovery page"
    );
    let mut report = RecoveryReport {
        examined: jobs.len(),
        has_more: jobs.len() == PAGE_SIZE,
        next_cursor: jobs.last().map(|job| job.id.clone()),
        ..Default::default()
    };
    ensure!(
        jobs.iter().all(|job| job.kind == kind
            && ["running", "interrupted"].contains(&job.state.as_str())),
        "Unexpected recovery candidate"
    );
    for job in jobs {
        let receipt = probe(&job);
        let outcome = match receipt {
            Ok(true) => RecoveryOutcome::Published,
            Ok(false) if job.cancel_requested => RecoveryOutcome::Cancelled,
            Ok(false) if job.state == "running" => RecoveryOutcome::Interrupted,
            Ok(false) => continue,
            Err(_) => {
                report.unresolved += 1;
                if job.state == "interrupted" {
                    continue;
                }
                RecoveryOutcome::Unresolved
            }
        };
        if !store.resolve(&job, outcome)? {
            report.stale += 1;
            continue;
        }
        match outcome {
            RecoveryOutcome::Published => report.published += 1,
            RecoveryOutcome::Cancelled => report.cancelled += 1,
            RecoveryOutcome::Interrupted | RecoveryOutcome::Unresolved => report.interrupted += 1,
        }
    }
    Ok(report)
}
