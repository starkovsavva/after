//! Native worker port; only host-selected grants become ImportWork.
use crate::models::{HostError, Meeting};
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::atomic::AtomicBool};
pub struct ImportWork {
    pub operation_id: String,
    pub attempt_token: String,
    pub source: PathBuf,
    pub title: Option<String>,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ImportPhase {
    Copying,
    Committing,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImportProgress {
    pub phase: ImportPhase,
    pub copied_bytes: u64,
    pub total_bytes: u64,
}
pub trait WorkerHost: Send + Sync {
    fn import(
        &self,
        work: &ImportWork,
        cancelled: &AtomicBool,
        progress: &mut dyn FnMut(ImportProgress),
    ) -> Result<Meeting, HostError>;
}
