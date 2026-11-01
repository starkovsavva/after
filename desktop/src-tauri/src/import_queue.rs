//! Durable native queue port. These DTOs contain private file grants and receipts
//! and must never be returned to the renderer or registered as Tauri commands.
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
    Get {
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
    pub deduplicated: Option<bool>,
    pub recovered: Option<usize>,
}
pub trait ImportQueue: Send + Sync {
    fn execute(&self, command: QueueCommand) -> Result<QueueReply, HostError>;
}
