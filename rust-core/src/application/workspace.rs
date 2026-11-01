//! Ordering and validation for canonical workspace operations. Concrete locking,
//! SQL and correction journal implementations are supplied by the composition root.
use super::ports::{WorkspaceLocks, WorkspaceRecovery, WorkspaceRepository};
use crate::domain::{
    workspace::{NotesWorkspace, WorkspaceEvent, WorkspaceSnapshot},
    workspace_validation::{consumer_id, validate_workspace},
};
use anyhow::{ensure, Context, Result};
use serde_json::Value;
use std::path::Path;

pub(crate) struct WorkspaceCoordinator<R, L, C> {
    pub repository: R,
    pub locks: L,
    pub recovery: C,
}

impl<R: WorkspaceRepository, L: WorkspaceLocks, C: WorkspaceRecovery>
    WorkspaceCoordinator<R, L, C>
{
    pub fn load_notes_locked(&self, directory: &Path) -> Result<NotesWorkspace> {
        self.recovery.recover_locked(directory)?;
        let snapshot = self.repository.load_locked(directory)?;
        serde_json::from_value(snapshot.value)
            .context("Не удалось прочитать заметки. База сохранена.")
    }
    pub fn persist_notes_locked(&self, directory: &Path, data: &NotesWorkspace) -> Result<()> {
        validate_workspace(data)?;
        self.repository.persist_locked(directory, data)?;
        Ok(())
    }
    pub fn snapshot(&self, root: &Path) -> Result<WorkspaceSnapshot> {
        let directory = self.locks.directory(root)?;
        let _guard = self.locks.lock(&directory)?;
        self.recovery.recover_locked(&directory)?;
        self.repository.load_locked(&directory)
    }
    pub fn compare_and_save(
        &self,
        root: &Path,
        revision: u64,
        value: &Value,
    ) -> Result<WorkspaceSnapshot> {
        let directory = self.locks.directory(root)?;
        let _guard = self.locks.lock(&directory)?;
        self.recovery.recover_locked(&directory)?;
        self.repository
            .compare_and_save_locked(&directory, revision, value)
    }
    pub fn pending_events(
        &self,
        root: &Path,
        consumer: &str,
        limit: usize,
    ) -> Result<Vec<WorkspaceEvent>> {
        consumer_id(consumer)?;
        ensure!((1..=500).contains(&limit), "Укажите от 1 до 500 событий");
        let directory = self.locks.directory(root)?;
        let _guard = self.locks.lock(&directory)?;
        self.recovery.recover_locked(&directory)?;
        self.repository
            .pending_events_locked(&directory, consumer, limit)
    }
    pub fn acknowledge_event(&self, root: &Path, consumer: &str, event: &str) -> Result<()> {
        consumer_id(consumer)?;
        ensure!(
            !event.is_empty() && event.len() <= 128,
            "Некорректный ID события"
        );
        let directory = self.locks.directory(root)?;
        let _guard = self.locks.lock(&directory)?;
        // Acknowledgements and receipt reads deliberately preserve the old
        // no-recovery behaviour; they must not trigger unrelated media changes.
        self.repository
            .acknowledge_event_locked(&directory, consumer, event)
    }
    pub fn operation_receipt(
        &self,
        root: &Path,
        namespace: &str,
        operation: &str,
    ) -> Result<Option<Value>> {
        let directory = self.locks.directory(root)?;
        let _guard = self.locks.lock(&directory)?;
        self.repository
            .operation_receipt_locked(&directory, namespace, operation)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::RefCell, path::PathBuf, rc::Rc};
    #[derive(Clone)]
    struct Fake {
        events: Rc<RefCell<Vec<&'static str>>>,
        fail_recovery: bool,
    }
    struct Guard(Rc<RefCell<Vec<&'static str>>>);
    impl Drop for Guard {
        fn drop(&mut self) {
            self.0.borrow_mut().push("unlock");
        }
    }
    impl WorkspaceLocks for Fake {
        type Guard = Guard;
        fn directory(&self, _: &Path) -> Result<PathBuf> {
            self.events.borrow_mut().push("directory");
            Ok(PathBuf::from("fixture"))
        }
        fn lock(&self, _: &Path) -> Result<Guard> {
            self.events.borrow_mut().push("lock");
            Ok(Guard(self.events.clone()))
        }
    }
    impl WorkspaceRecovery for Fake {
        fn recover_locked(&self, _: &Path) -> Result<()> {
            self.events.borrow_mut().push("recover");
            anyhow::ensure!(!self.fail_recovery, "recovery failed");
            Ok(())
        }
    }
    impl WorkspaceRepository for Fake {
        fn load_locked(&self, _: &Path) -> Result<WorkspaceSnapshot> {
            self.events.borrow_mut().push("load");
            Ok(WorkspaceSnapshot {
                revision: 1,
                fingerprint: String::new(),
                value: serde_json::to_value(crate::domain::workspace::defaults())?,
            })
        }
        fn persist_locked(&self, _: &Path, _: &NotesWorkspace) -> Result<WorkspaceSnapshot> {
            panic!("unexpected write")
        }
        fn compare_and_save_locked(
            &self,
            _: &Path,
            _: u64,
            _: &Value,
        ) -> Result<WorkspaceSnapshot> {
            panic!("unexpected write")
        }
        fn pending_events_locked(
            &self,
            _: &Path,
            _: &str,
            _: usize,
        ) -> Result<Vec<WorkspaceEvent>> {
            panic!("unexpected outbox read")
        }
        fn acknowledge_event_locked(&self, _: &Path, _: &str, _: &str) -> Result<()> {
            self.events.borrow_mut().push("ack");
            Ok(())
        }
        fn operation_receipt_locked(&self, _: &Path, _: &str, _: &str) -> Result<Option<Value>> {
            self.events.borrow_mut().push("receipt");
            Ok(None)
        }
    }
    fn coordinator(
        fail_recovery: bool,
    ) -> (
        WorkspaceCoordinator<Fake, Fake, Fake>,
        Rc<RefCell<Vec<&'static str>>>,
    ) {
        let fake = Fake {
            events: Rc::new(RefCell::new(vec![])),
            fail_recovery,
        };
        let events = fake.events.clone();
        (
            WorkspaceCoordinator {
                repository: fake.clone(),
                locks: fake.clone(),
                recovery: fake,
            },
            events,
        )
    }
    #[test]
    fn lock_lives_until_recovery_and_load_complete() {
        let (service, events) = coordinator(false);
        service.snapshot(Path::new("library")).unwrap();
        assert_eq!(
            *events.borrow(),
            vec!["directory", "lock", "recover", "load", "unlock"]
        );
    }
    #[test]
    fn recovery_failure_does_not_read_or_write_and_releases_lock() {
        let (service, events) = coordinator(true);
        assert!(service
            .compare_and_save(Path::new("library"), 1, &serde_json::json!({}))
            .is_err());
        assert_eq!(
            *events.borrow(),
            vec!["directory", "lock", "recover", "unlock"]
        );
    }
    #[test]
    fn invalid_outbox_input_is_rejected_before_opening_a_library() {
        let (service, events) = coordinator(false);
        assert!(service
            .pending_events(Path::new("library"), "../bad", 1)
            .is_err());
        assert!(service
            .pending_events(Path::new("library"), "good", 0)
            .is_err());
        assert!(service
            .acknowledge_event(Path::new("library"), "good", "")
            .is_err());
        assert!(events.borrow().is_empty());
    }
    #[test]
    fn receipts_and_acknowledgements_do_not_trigger_unrelated_recovery() {
        let (service, events) = coordinator(true);
        service
            .acknowledge_event(Path::new("library"), "consumer", "event")
            .unwrap();
        service
            .operation_receipt(Path::new("library"), "task", "operation")
            .unwrap();
        assert_eq!(
            *events.borrow(),
            vec![
                "directory",
                "lock",
                "ack",
                "unlock",
                "directory",
                "lock",
                "receipt",
                "unlock"
            ]
        );
    }
}
