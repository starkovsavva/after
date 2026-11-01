//! Queue-specific ports. A transaction session is valid only inside its callback;
//! all writes commit together on success and roll back on any returned error.
use crate::domain::jobs::{Job, JobQueueSnapshot};
use anyhow::Result;

pub(crate) enum JobSelection {
    /// Queued/running, in creation order with stable insertion-order ties.
    Active,
    /// Queued/blocked, in the same stable order (including transitive children).
    WaitingDependencies,
    /// All running attempts, regardless of history pagination.
    Running,
}

pub(crate) enum JobMatchScope {
    /// Match dedup key in queued/running/interrupted/blocked states.
    Pending,
    /// Earliest matching job in any state, including explicitly cancelled stages.
    AnyState,
}

pub(crate) trait JobQueueTransaction {
    fn selected(&self, selection: JobSelection) -> Result<Vec<Job>>;
    fn get(&self, id: &str) -> Result<Job>;
    fn state(&self, id: &str) -> Result<Option<String>>;
    fn matching(&self, job: &Job, scope: JobMatchScope) -> Result<Option<Job>>;
    fn active_count(&self) -> Result<u64>;
    fn paused_jobs(&self) -> Result<Vec<Job>>;
    fn save(&mut self, job: &Job) -> Result<()>;
    fn pause_account(&mut self, account: &str, job: &str) -> Result<()>;
    fn resume_account(&mut self, account: &str) -> Result<()>;
}

pub(crate) trait JobQueueRepository {
    /// All active jobs plus the latest 50 terminal/history rows, sorted by
    /// creation time. Count and paused failures use the same read snapshot;
    /// admission pauses must not disappear when a job leaves visible history.
    /// Filter before history pagination; counts and rows share one snapshot.
    fn snapshot(&self, kind: Option<&str>) -> Result<JobQueueSnapshot>;
    /// Bounded recovery pages independent of presentation history. Stable ID
    /// ordering allows a caller to advance past unresolved entries.
    fn recovery_candidates(
        &self,
        kind: &str,
        after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Job>>;
    fn get(&self, id: &str) -> Result<Job>;
    /// Serializes competing claims before reading admission state. The adapter
    /// must not split this callback into independently committed operations.
    fn transaction<T>(
        &self,
        action: impl FnOnce(&mut dyn JobQueueTransaction) -> Result<T>,
    ) -> Result<T>;
}

pub(crate) trait JobClock {
    fn now(&self) -> f64;
}

pub(crate) trait JobIds {
    fn next(&self) -> String;
}
