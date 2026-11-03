//! Native-only speech queue port. Inputs contain private settings and attempt
//! identity; no renderer command accepts these types or arbitrary backend paths.
use crate::{
    models::HostError,
    queue_budget::{FixedDeadline, RequestBudget},
    queue_models::{HistoryCursor, JobState},
};
use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpeechInput {
    pub version: u8,
    pub operation_id: String,
    pub attempt_token: String,
    pub meeting_id: String,
    pub input_revision: String,
    pub settings: serde_json::Value,
}
#[derive(Serialize)]
#[serde(
    tag = "action",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum SpeechCommand {
    EnqueueCheck {},
    GetCheck {
        job_id: String,
    },
    RunCheck {
        job_id: String,
    },
    CancelCheck {
        job_id: String,
        expected_attempt: u64,
    },
    Prepare {
        meeting_id: String,
    },
    Enqueue {
        input: SpeechInput,
    },
    Get {
        job_id: String,
    },
    History {
        after: Option<HistoryCursor>,
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
/// Grant-free history model. Never add frozen settings or private receipts here.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SpeechJobSummary {
    pub id: String,
    pub meeting_id: Option<String>,
    pub state: JobState,
    pub progress: f64,
    pub attempt: u64,
    pub cancel_requested: bool,
    pub created_at: Option<f64>,
}
/// Historical preflight attempt, not a permanent runtime readiness grant.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CheckSummary {
    pub id: String,
    pub state: JobState,
    pub progress: f64,
    pub attempt: u64,
    pub cancel_requested: bool,
    pub created_at: Option<f64>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SpeechReply {
    pub check: Option<CheckSummary>,
    pub prepared: Option<SpeechInput>,
    pub job: Option<SpeechJobSummary>,
    #[serde(default)]
    pub jobs: Vec<SpeechJobSummary>,
    pub total: Option<u64>,
    pub has_more: Option<bool>,
    pub next_cursor: Option<HistoryCursor>,
    pub deduplicated: Option<bool>,
    pub examined: Option<usize>,
    pub unresolved: Option<usize>,
}
pub trait SpeechQueue: Send + Sync {
    fn execute(&self, command: SpeechCommand) -> Result<SpeechReply, HostError> {
        self.execute_with_budget(
            command,
            &FixedDeadline(Instant::now() + Duration::from_secs(12)),
        )
    }
    fn execute_with_budget(
        &self,
        command: SpeechCommand,
        budget: &dyn RequestBudget,
    ) -> Result<SpeechReply, HostError>;
    /// Stop/reap the owner before resolving receipts or acquiring another lease.
    fn shutdown(&self);
}
