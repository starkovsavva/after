//! Host-owned import sessions. Renderer sees progress and an opaque ID only.
use crate::{models::HostError, worker_host::ImportWork};
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
    pub control_id: Option<String>,
    pub phase: String,
    pub copied_bytes: u64,
    pub total_bytes: u64,
    pub progress: Option<f64>,
    pub cancel_requested: bool,
}
struct State {
    status: ImportStatus,
    active: Option<Arc<AtomicBool>>,
    reserved: bool,
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
            reserved: false,
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
    pub fn reserve(self: &Arc<Self>) -> Result<ImportReservation, HostError> {
        let mut state = self
            .0
            .lock()
            .map_err(|_| HostError::new("busy", "Import is unavailable."))?;
        if state.active.is_some() || state.reserved {
            return Err(HostError::new(
                "busy",
                "An import operation is already in progress.",
            ));
        }
        state.reserved = true;
        Ok(ImportReservation {
            owner: self.clone(),
            consumed: false,
        })
    }
    pub fn begin(self: &Arc<Self>) -> Result<ImportSession, HostError> {
        self.reserve()?.start(
            uuid::Uuid::new_v4().to_string(),
            uuid::Uuid::new_v4().to_string(),
            "choosing",
        )
    }
    pub fn cancel(&self, id: &str, control_id: &str) -> Result<ImportStatus, HostError> {
        let mut state = self.0.lock().map_err(|_| HostError::invalid())?;
        if state.status.operation_id.as_deref() != Some(id)
            || state.status.control_id.as_deref() != Some(control_id)
        {
            return Err(HostError::invalid());
        }
        if let Some(cancelled) = &state.active {
            cancelled.store(true, Ordering::Release);
            state.status.cancel_requested = true;
        }
        Ok(state.status.clone())
    }
}
/// Serializes maintenance with import startup without presenting a fake active
/// import to the renderer. Dropping a failed reservation releases admission.
pub(crate) struct ImportReservation {
    owner: Arc<Imports>,
    consumed: bool,
}
impl ImportReservation {
    pub fn start(
        mut self,
        id: String,
        token: String,
        phase: &str,
    ) -> Result<ImportSession, HostError> {
        let mut state = self.owner.0.lock().map_err(|_| HostError::invalid())?;
        let cancelled = Arc::new(AtomicBool::new(false));
        state.reserved = false;
        state.status = ImportStatus {
            operation_id: Some(id.clone()),
            control_id: Some(uuid::Uuid::new_v4().to_string()),
            phase: phase.into(),
            ..Default::default()
        };
        state.active = Some(cancelled.clone());
        self.consumed = true;
        Ok(ImportSession {
            owner: self.owner.clone(),
            id,
            token,
            cancelled,
            finished: false,
        })
    }
}
impl Drop for ImportReservation {
    fn drop(&mut self) {
        if !self.consumed {
            self.owner
                .0
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .reserved = false;
        }
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
    pub fn fraction(&self, value: f64) {
        let mut state = self.owner.0.lock().unwrap_or_else(|e| e.into_inner());
        if state.status.operation_id.as_deref() == Some(&self.id) {
            state.status.progress = Some(value);
            state.status.phase = if value >= 1.0 {
                "committing"
            } else {
                "copying"
            }
            .into();
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
    fn maintenance_reservation_blocks_start_and_releases_without_fake_status() {
        let imports = Arc::new(Imports::default());
        let reservation = imports.reserve().unwrap();
        assert!(!imports.active());
        assert_eq!(imports.status().phase, "idle");
        assert!(imports.begin().is_err());
        assert!(imports.reserve().is_err());
        drop(reservation);
        let session = imports.begin().unwrap();
        assert!(imports.reserve().is_err());
        drop(session);
        assert!(imports.reserve().is_ok());
    }
    #[test]
    fn old_control_cannot_cancel_a_new_attempt_of_the_same_operation() {
        let imports = Arc::new(Imports::default());
        let mut first = imports.begin().unwrap();
        let operation = first.id.clone();
        let token = first.token.clone();
        let old_control = imports.status().control_id.unwrap();
        first.finish("failed");
        let second = imports
            .reserve()
            .unwrap()
            .start(operation.clone(), token, "copying")
            .unwrap();
        let new_control = imports.status().control_id.unwrap();
        assert_ne!(old_control, new_control);
        assert!(imports.cancel(&operation, &old_control).is_err());
        assert!(!second.cancelled.load(Ordering::Acquire));
        imports.cancel(&operation, &new_control).unwrap();
        assert!(second.cancelled.load(Ordering::Acquire));
    }
    #[test]
    fn cancellation_is_scoped_and_completed_results_win() {
        let imports = Arc::new(Imports::default());
        let mut one = imports.begin().unwrap();
        assert!(imports.begin().is_err());
        assert!(imports.cancel("unrelated", "unrelated").is_err());
        imports
            .cancel(&one.id, imports.status().control_id.as_deref().unwrap())
            .unwrap();
        assert!(one.cancelled.load(Ordering::Acquire));
        one.finish("completed");
        assert!(!imports.status().cancel_requested);
        assert!(!imports.active());
        let two = imports.begin().unwrap();
        assert!(imports.cancel(&one.id, "old-control").is_err());
        drop(two);
        assert!(!imports.active());
        assert_eq!(imports.status().phase, "failed");
    }
}
