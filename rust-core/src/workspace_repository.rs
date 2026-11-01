//! Compatibility API and composition root for canonical workspace use cases.
//! SQL, locks and correction recovery are connected here, never inside domain.
use crate::application::workspace::WorkspaceCoordinator;
use crate::domain::workspace::NotesWorkspace;
use crate::infrastructure::workspace_adapters::{
    CorrectionJournal, FileWorkspaceLocks, SqliteWorkspaceRepository,
};
use anyhow::Result;
use serde_json::Value;
use std::path::Path;

pub use crate::domain::workspace::{WorkspaceEvent, WorkspaceSnapshot};
pub(crate) use crate::infrastructure::workspace_repository::{
    operation_receipt_locked, read_committed,
};

fn coordinator(
) -> WorkspaceCoordinator<SqliteWorkspaceRepository, FileWorkspaceLocks, CorrectionJournal> {
    WorkspaceCoordinator {
        repository: SqliteWorkspaceRepository,
        locks: FileWorkspaceLocks,
        recovery: CorrectionJournal,
    }
}
pub(crate) fn load_notes_locked(directory: &Path) -> Result<NotesWorkspace> {
    coordinator().load_notes_locked(directory)
}
pub(crate) fn persist_notes_locked(directory: &Path, data: &NotesWorkspace) -> Result<()> {
    coordinator().persist_notes_locked(directory, data)
}
pub fn snapshot(root: &Path) -> Result<WorkspaceSnapshot> {
    coordinator().snapshot(root)
}
pub fn compare_and_save(root: &Path, revision: u64, value: &Value) -> Result<WorkspaceSnapshot> {
    coordinator().compare_and_save(root, revision, value)
}
pub fn pending_events(root: &Path, consumer: &str, limit: usize) -> Result<Vec<WorkspaceEvent>> {
    coordinator().pending_events(root, consumer, limit)
}
pub fn acknowledge_event(root: &Path, consumer: &str, event: &str) -> Result<()> {
    coordinator().acknowledge_event(root, consumer, event)
}
pub fn operation_receipt(root: &Path, namespace: &str, operation: &str) -> Result<Option<Value>> {
    coordinator().operation_receipt(root, namespace, operation)
}

#[cfg(test)]
pub(crate) use crate::infrastructure::workspace_repository::MAX_WORKSPACE;

// Knowledge compatibility entry points share the canonical storage adapter.
pub use crate::infrastructure::workspace_repository::{knowledge_dispatch, knowledge_rebuild_dispatch};
pub(crate) use crate::infrastructure::workspace_repository::knowledge_rebuild_context;

pub(crate) fn load_locked(directory: &Path) -> Result<WorkspaceSnapshot> {
    coordinator().load_snapshot_locked(directory)
}
