//! Narrow contracts for a workspace operation. Locked methods never acquire
//! another workspace lock or initiate journal recovery.
use crate::domain::workspace::{NotesWorkspace, WorkspaceEvent, WorkspaceSnapshot};
use anyhow::Result;
use serde_json::Value;
use std::path::{Path, PathBuf};

pub(crate) trait WorkspaceLocks {
    type Guard;
    fn directory(&self, root: &Path) -> Result<PathBuf>;
    fn lock(&self, directory: &Path) -> Result<Self::Guard>;
}

pub(crate) trait WorkspaceRecovery {
    fn recover_locked(&self, directory: &Path) -> Result<()>;
}

pub(crate) trait WorkspaceRepository {
    fn load_locked(&self, directory: &Path) -> Result<WorkspaceSnapshot>;
    fn persist_locked(&self, directory: &Path, data: &NotesWorkspace) -> Result<WorkspaceSnapshot>;
    fn compare_and_save_locked(
        &self,
        directory: &Path,
        revision: u64,
        value: &Value,
    ) -> Result<WorkspaceSnapshot>;
    fn pending_events_locked(
        &self,
        directory: &Path,
        consumer: &str,
        limit: usize,
    ) -> Result<Vec<WorkspaceEvent>>;
    fn acknowledge_event_locked(&self, directory: &Path, consumer: &str, event: &str)
        -> Result<()>;
    fn operation_receipt_locked(
        &self,
        directory: &Path,
        namespace: &str,
        operation: &str,
    ) -> Result<Option<Value>>;
}
