//! Shared attempt controls and persistence ports; no executor-specific rules.
use anyhow::Result;
use std::sync::atomic::{AtomicBool, Ordering};
/// One attempt owns this control; never reuse it for a later attempt. Owner
/// shutdown is interruption, distinct from a user's durable cancellation.
#[derive(Default)]
pub(crate) struct AttemptStop {
    cancelled: AtomicBool,
    stopping: AtomicBool,
}
impl AttemptStop {
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum AttemptOutcome {
    Succeeded,
    Cancelled,
    Failed,
    Interrupted,
}
impl AttemptOutcome {
    pub fn state(self) -> &'static str {
        match self {
            Self::Succeeded => "succeeded",
            Self::Cancelled => "cancelled",
            Self::Failed => "failed",
            Self::Interrupted => "interrupted",
        }
    }
}

pub(crate) trait AttemptStore: Send + Sync {
    /// Persist against the same attempt; return its current cancellation flag.
    fn progress(&self, id: &str, attempt: u64, fraction: f64) -> Result<bool>;
    fn finish(&self, id: &str, attempt: u64, outcome: AttemptOutcome) -> Result<()>;
}
