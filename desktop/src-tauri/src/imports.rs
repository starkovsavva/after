//! Host-owned import sessions. Renderer sees progress and an opaque ID only.
use crate::{
    models::HostError,
    worker_host::{ImportPhase, ImportProgress, ImportWork},
};
use serde::Serialize;
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ImportStatus {
    pub operation_id: Option<String>,
    pub phase: String,
    pub copied_bytes: u64,
    pub total_bytes: u64,
    pub cancel_requested: bool,
}
struct State {
    status: ImportStatus,
    active: Option<Arc<AtomicBool>>,
}
pub(crate) struct Imports(Mutex<State>);
impl Default for Imports {
    fn default() -> Self {
        Self(Mutex::new(State {
            status: ImportStatus {
                phase: "idle".into(),
                ..Default::default()
            },
            active: None,
        }))
    }
}
impl Imports {
    pub fn status(&self) -> ImportStatus {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .status
            .clone()
    }
    pub fn active(&self) -> bool {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .active
            .is_some()
    }
    pub fn begin(self: &Arc<Self>) -> Result<ImportSession, HostError> {
        let mut state = self
            .0
            .lock()
            .map_err(|_| HostError::new("busy", "Import is unavailable."))?;
        if state.active.is_some() {
            return Err(HostError::new("busy", "An import is already running."));
        }
        let id = uuid::Uuid::new_v4().to_string();
        let cancelled = Arc::new(AtomicBool::new(false));
        state.status = ImportStatus {
            operation_id: Some(id.clone()),
            phase: "choosing".into(),
            ..Default::default()
        };
        state.active = Some(cancelled.clone());
        Ok(ImportSession {
            owner: self.clone(),
            id,
            token: uuid::Uuid::new_v4().to_string(),
            cancelled,
            finished: false,
        })
    }
    pub fn cancel(&self, id: &str) -> Result<ImportStatus, HostError> {
        let mut state = self.0.lock().map_err(|_| HostError::invalid())?;
        if state.status.operation_id.as_deref() != Some(id) {
            return Err(HostError::invalid());
        }
        if let Some(cancelled) = &state.active {
            cancelled.store(true, Ordering::Release);
            state.status.cancel_requested = true;
        }
        Ok(state.status.clone())
    }
}
pub(crate) struct ImportSession {
    owner: Arc<Imports>,
    id: String,
    token: String,
    pub cancelled: Arc<AtomicBool>,
    finished: bool,
}
impl ImportSession {
    pub fn work(&self, source: PathBuf) -> ImportWork {
        ImportWork {
            operation_id: self.id.clone(),
            attempt_token: self.token.clone(),
            source,
            title: None,
        }
    }
    pub fn progress(&self, progress: ImportProgress) {
        let mut state = self.owner.0.lock().unwrap_or_else(|e| e.into_inner());
        if state.status.operation_id.as_deref() == Some(&self.id) {
            state.status.phase = match progress.phase {
                ImportPhase::Copying => "copying",
                ImportPhase::Committing => "committing",
            }
            .into();
            state.status.copied_bytes = progress.copied_bytes;
            state.status.total_bytes = progress.total_bytes;
        }
    }
    pub fn finish(&mut self, phase: &str) {
        let mut state = self.owner.0.lock().unwrap_or_else(|e| e.into_inner());
        if state.status.operation_id.as_deref() == Some(&self.id) {
            state.status.phase = phase.into();
            if phase == "completed" {
                state.status.cancel_requested = false;
            }
            state.active = None;
        }
        self.finished = true;
    }
}
impl Drop for ImportSession {
    fn drop(&mut self) {
        if !self.finished {
            self.finish("failed");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cancellation_is_scoped_and_completed_results_win() {
        let imports = Arc::new(Imports::default());
        let mut one = imports.begin().unwrap();
        assert!(imports.begin().is_err());
        assert!(imports.cancel("unrelated").is_err());
        imports.cancel(&one.id).unwrap();
        assert!(one.cancelled.load(Ordering::Acquire));
        one.finish("completed");
        assert!(!imports.status().cancel_requested);
        assert!(!imports.active());
        let two = imports.begin().unwrap();
        assert!(imports.cancel(&one.id).is_err());
        drop(two);
        assert!(!imports.active());
        assert_eq!(imports.status().phase, "failed");
    }
}
