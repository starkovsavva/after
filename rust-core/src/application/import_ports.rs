//! Durable import inputs and execution contracts. File publication and queue
//! persistence remain separate effects, joined by an exact receipt identity.
use super::imports::ImportObserver;
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};

pub(crate) const IMPORT_JOB_KIND: &str = "desktop-import";

/// One attempt owns this control; never reuse it for a later attempt. Owner
/// shutdown is interruption, distinct from a user's durable cancellation.
#[derive(Default)]
pub(crate) struct ImportStop {
    cancelled: AtomicBool,
    stopping: AtomicBool,
}
impl ImportStop {
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
    pub fn shutdown(&self) {
        self.stopping.store(true, Ordering::Release);
    }
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }
    pub fn is_stopping(&self) -> bool {
        self.stopping.load(Ordering::Acquire)
    }
    pub fn is_requested(&self) -> bool {
        self.is_cancelled() || self.is_stopping()
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ImportInput {
    pub operation_id: String,
    pub attempt_token: String,
    pub source_path: PathBuf,
    pub title: Option<String>,
}
impl ImportInput {
    pub fn validate(&self) -> Result<()> {
        for id in [&self.operation_id, &self.attempt_token] {
            ensure!(
                id.len() == 36 && uuid::Uuid::parse_str(id).is_ok(),
                "Invalid import identity"
            );
        }
        ensure!(
            self.source_path.is_absolute(),
            "Import source must be absolute"
        );
        ensure!(
            self.source_path
                .to_str()
                .is_some_and(|value| value.len() <= 32760 && !value.contains('\0')),
            "Invalid import source"
        );
        ensure!(
            self.title
                .as_ref()
                .is_none_or(|value| value.len() <= 2000 && !value.contains('\0')),
            "Invalid import title"
        );
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ImportOutcome {
    Succeeded,
    Cancelled,
    Failed,
    Interrupted,
}
impl ImportOutcome {
    pub fn state(self) -> &'static str {
        match self {
            Self::Succeeded => "succeeded",
            Self::Cancelled => "cancelled",
            Self::Failed => "failed",
            Self::Interrupted => "interrupted",
        }
    }
}

pub(crate) trait ImportJobStore: Send + Sync {
    /// Persist against the same attempt; return its current cancellation flag.
    fn progress(&self, id: &str, attempt: u64, fraction: f64) -> Result<bool>;
    fn finish(&self, id: &str, attempt: u64, outcome: ImportOutcome) -> Result<()>;
}
pub(crate) trait ImportWorker: Send + Sync {
    /// Only a receipt with both exact identifiers is authoritative. An I/O error
    /// means unknown, never evidence that publication did not happen.
    fn committed(&self, input: &ImportInput) -> Result<bool>;
    /// Ok means the receipt was published; observers must not run after that.
    fn import(&self, input: &ImportInput, observer: &mut dyn ImportObserver) -> Result<()>;
}
