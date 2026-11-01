//! Concrete workspace adapters selected by the compatibility composition root.
use super::{corrections, workspace_files, workspace_repository as store};
use crate::application::ports::{WorkspaceLocks, WorkspaceRecovery, WorkspaceRepository};
use crate::domain::workspace::{NotesWorkspace, WorkspaceEvent, WorkspaceSnapshot};
use anyhow::Result;
use serde_json::Value;
use std::{
    fs::File,
    path::{Path, PathBuf},
};

pub(crate) struct SqliteWorkspaceRepository;
pub(crate) struct FileWorkspaceLocks;
pub(crate) struct CorrectionJournal;

impl WorkspaceLocks for FileWorkspaceLocks {
    type Guard = File;
    fn directory(&self, root: &Path) -> Result<PathBuf> {
        workspace_files::directory(root)
    }
    fn lock(&self, directory: &Path) -> Result<File> {
        workspace_files::lock(directory)
    }
}
impl WorkspaceRecovery for CorrectionJournal {
    fn recover_locked(&self, directory: &Path) -> Result<()> {
        corrections::recover_notes_transaction(directory)
    }
}
impl WorkspaceRepository for SqliteWorkspaceRepository {
    fn load_locked(&self, directory: &Path) -> Result<WorkspaceSnapshot> {
        store::load_locked(directory)
    }
    fn persist_locked(&self, directory: &Path, data: &NotesWorkspace) -> Result<WorkspaceSnapshot> {
        store::persist_locked(directory, data)
    }
    fn compare_and_save_locked(
        &self,
        directory: &Path,
        revision: u64,
        value: &Value,
    ) -> Result<WorkspaceSnapshot> {
        store::compare_and_save_locked(directory, revision, value)
    }
    fn pending_events_locked(
        &self,
        directory: &Path,
        consumer: &str,
        limit: usize,
    ) -> Result<Vec<WorkspaceEvent>> {
        store::pending_events_locked(directory, consumer, limit)
    }
    fn acknowledge_event_locked(
        &self,
        directory: &Path,
        consumer: &str,
        event: &str,
    ) -> Result<()> {
        store::acknowledge_event_locked(directory, consumer, event)
    }
    fn operation_receipt_locked(
        &self,
        directory: &Path,
        namespace: &str,
        operation: &str,
    ) -> Result<Option<Value>> {
        store::operation_receipt_locked(directory, namespace, operation)
    }
}
