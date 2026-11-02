//! Durable native queue port. Input/job DTOs contain private grants and receipts;
//! never return them or QueueReply to the renderer. HistoryCursor and JobState
//! are grant-free values reused by the separate renderer read model.
use crate::{models::HostError, worker_host::ImportWork};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImportInput {
    pub operation_id: String,
    pub attempt_token: String,
    pub source_path: PathBuf,
    pub title: Option<String>,
}
impl From<&ImportWork> for ImportInput {
    fn from(work: &ImportWork) -> Self {
        Self {
            operation_id: work.operation_id.clone(),
            attempt_token: work.attempt_token.clone(),
            source_path: work.source.clone(),
            title: work.title.clone(),
        }
    }
}
impl ImportInput {
    pub fn work(&self) -> ImportWork {
        ImportWork {
            operation_id: self.operation_id.clone(),
            attempt_token: self.attempt_token.clone(),
            source: self.source_path.clone(),
            title: self.title.clone(),
        }
    }
}

/// Public pagination key contains no file grant or receipt capability.
#[derive(Clone, Serialize, Deserialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HistoryCursor {
    pub created_at: f64,
    pub id: String,
}
impl HistoryCursor {
    pub fn valid(&self) -> bool {
        self.created_at.is_finite()
            && self.id.len() == 36
            && uuid::Uuid::parse_str(&self.id).is_ok()
    }
    pub fn follows(&self, previous: &Self) -> bool {
        self.created_at < previous.created_at
            || (self.created_at == previous.created_at && self.id < previous.id)
    }
}

#[derive(Clone, Copy, Serialize, Deserialize, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
    Interrupted,
    Blocked,
}

#[derive(Serialize)]
#[serde(
    tag = "action",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum QueueCommand {
    Enqueue {
        input: ImportInput,
    },
    List,
    History {
        after: Option<HistoryCursor>,
    },
    Get {
        job_id: String,
    },
    /// Starts one admitted import inside the process owning the queue lease.
    Run {
        job_id: String,
    },
    Claim {
        job_id: Option<String>,
    },
    Cancel {
        job_id: String,
        expected_attempt: u64,
    },
    Retry {
        job_id: String,
        expected_attempt: u64,
    },
    Update {
        job_id: String,
        expected_attempt: u64,
        state: JobState,
        progress: f64,
    },
    /// Requires an exclusive desktop-import executor lease, not just a DB lock.
    Recover,
    /// Read-only receipt probes plus conditional ledger repair; no work starts.
    Reconcile {
        after_job_id: Option<String>,
    },
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportJob {
    pub id: String,
    #[serde(rename = "objectID")]
    pub object_id: String,
    pub state: JobState,
    pub progress: f64,
    pub attempt: u64,
    pub cancel_requested: bool,
    pub config: ImportInput,
}
/// Grant-free read model for history and recovery. Fetch/claim a job separately
/// when the native executor needs its private input.
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct JobSummary {
    pub id: String,
    pub created_at: Option<f64>,
    #[serde(rename = "objectID")]
    pub object_id: String,
    pub state: JobState,
    pub progress: f64,
    pub attempt: u64,
    pub cancel_requested: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueReply {
    pub job: Option<ImportJob>,
    #[serde(default)]
    pub jobs: Vec<JobSummary>,
    pub total: Option<u64>,
    pub has_more: Option<bool>,
    pub next_cursor: Option<HistoryCursor>,
    pub deduplicated: Option<bool>,
    pub recovered: Option<usize>,
    pub reconciliation: Option<ImportReconciliation>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImportReconciliation {
    pub examined: usize,
    pub published: usize,
    pub interrupted: usize,
    pub cancelled: usize,
    pub unresolved: usize,
    pub stale: usize,
    pub has_more: bool,
    pub next_cursor: Option<String>,
}
pub trait ImportQueue: Send + Sync {
    fn execute(&self, command: QueueCommand) -> Result<QueueReply, HostError>;
}

/// Supervisor capability: each RPC fits the remaining operation/cancel budget.
/// Shutdown must stop/reap the owner before receipt fallback or reconnection.
pub trait RequestBudget {
    fn deadline(&self) -> std::time::Instant;
}
pub struct FixedDeadline(pub std::time::Instant);
impl RequestBudget for FixedDeadline {
    fn deadline(&self) -> std::time::Instant {
        self.0
    }
}
pub trait ImportQueueSession: ImportQueue {
    fn execute_before(
        &self,
        command: QueueCommand,
        deadline: std::time::Instant,
    ) -> Result<QueueReply, HostError> {
        self.execute_with_budget(command, &FixedDeadline(deadline))
    }
    fn execute_with_budget(
        &self,
        command: QueueCommand,
        budget: &dyn RequestBudget,
    ) -> Result<QueueReply, HostError>;
    fn shutdown(&self);
}
