//! Persistent import queue composition over the shared native transport.
use crate::{
    import_queue::{ImportQueue, ImportQueueSession, QueueCommand, QueueReply, RequestBudget},
    models::HostError,
    native_queue_connection::{NativeQueueConnection, TIMEOUT},
};
use std::{
    path::Path,
    process::Command,
    time::{Duration, Instant},
};

pub struct QueueConnection(NativeQueueConnection);
fn protocol() -> HostError {
    HostError::new(
        "invalid_response",
        "The import queue returned an invalid response.",
    )
}
impl QueueConnection {
    pub(crate) fn open(engine: &Path, root: &Path) -> Result<Self, HostError> {
        let connection = Self::connect(engine, root, TIMEOUT)?;
        let mut cursor: Option<String> = None;
        loop {
            let reply = connection.execute(QueueCommand::Reconcile {
                after_job_id: cursor.clone(),
            })?;
            let report = reply.reconciliation.ok_or_else(protocol)?;
            if report.examined > 64 || (report.has_more && report.examined != 64) {
                return Err(protocol());
            }
            if report.stale > 0 {
                return Err(HostError::new(
                    "busy",
                    "The import queue changed during recovery. Reconnect before starting work.",
                ));
            }
            if !report.has_more {
                break;
            }
            let next = report
                .next_cursor
                .filter(|next| {
                    !next.is_empty()
                        && next.len() <= 512
                        && !next.contains('\0')
                        && cursor.as_ref().is_none_or(|previous| next > previous)
                })
                .ok_or_else(protocol)?;
            cursor = Some(next);
        }
        Ok(connection)
    }
    fn connect(engine: &Path, root: &Path, timeout: Duration) -> Result<Self, HostError> {
        let mut command = Command::new(engine);
        command
            .args(["desktop-import-queue", "--root"])
            .arg(root)
            .current_dir(root);
        NativeQueueConnection::connect(command, timeout).map(Self)
    }
}
impl ImportQueue for QueueConnection {
    fn execute(&self, command: QueueCommand) -> Result<QueueReply, HostError> {
        self.execute_before(command, Instant::now() + TIMEOUT)
    }
}
impl ImportQueueSession for QueueConnection {
    fn shutdown(&self) {
        self.0.shutdown();
    }
    fn execute_with_budget(
        &self,
        command: QueueCommand,
        budget: &dyn RequestBudget,
    ) -> Result<QueueReply, HostError> {
        self.0.execute(command, budget)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;
    #[cfg(unix)]
    fn fake(script: &str) -> (tempfile::TempDir, std::path::PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let engine = root.path().join("engine");
        // Execute the stable interpreter, not a freshly written executable:
        // concurrent forks can temporarily inherit a writer before CLOEXEC,
        // causing ETXTBSY for another test's script. The fixed protocol action
        // becomes the interpreter's script argument in this private fixture.
        std::fs::write(root.path().join("desktop-import-queue"), script).unwrap();
        std::os::unix::fs::symlink("/bin/sh", &engine).unwrap();
        (root, engine)
    }
    #[cfg(unix)]
    #[test]
    fn unresponsive_owner_times_out_and_connection_is_not_reused() {
        let (root, engine) =
            fake("printf '%s\\n' '{\"event\":\"ready\",\"version\":1}'\nexec sleep 30");
        let connection =
            QueueConnection::connect(&engine, root.path(), Duration::from_millis(200)).unwrap();
        assert_eq!(
            connection.execute(QueueCommand::List).err().unwrap().code,
            "engine_timeout"
        );
        assert_eq!(
            connection.execute(QueueCommand::List).err().unwrap().code,
            "engine_failure"
        );
    }
    #[cfg(unix)]
    #[test]
    fn supervisor_deadline_overrides_the_longer_rpc_timeout() {
        let (root, engine) =
            fake("printf '%s\\n' '{\"event\":\"ready\",\"version\":1}'\nexec sleep 30");
        let connection =
            QueueConnection::connect(&engine, root.path(), Duration::from_secs(5)).unwrap();
        let start = Instant::now();
        assert_eq!(
            connection
                .execute_before(QueueCommand::List, start + Duration::from_millis(50))
                .err()
                .unwrap()
                .code,
            "engine_timeout"
        );
        assert!(start.elapsed() < Duration::from_secs(2));
        assert_eq!(
            connection.execute(QueueCommand::List).err().unwrap().code,
            "engine_failure"
        );
    }

    #[cfg(unix)]
    #[test]
    fn cancellation_shortens_an_already_waiting_rpc_budget() {
        use std::sync::atomic::{AtomicBool, Ordering};
        struct Budget {
            cancelled: AtomicBool,
            start: Instant,
        }
        impl RequestBudget for Budget {
            fn deadline(&self) -> Instant {
                self.start
                    + if self.cancelled.load(Ordering::Acquire) {
                        Duration::from_millis(150)
                    } else {
                        Duration::from_secs(5)
                    }
            }
        }
        let (root, engine) =
            fake("printf '%s\\n' '{\"event\":\"ready\",\"version\":1}'\nexec sleep 30");
        let connection =
            QueueConnection::connect(&engine, root.path(), Duration::from_secs(5)).unwrap();
        let budget = Budget {
            cancelled: AtomicBool::new(false),
            start: Instant::now(),
        };
        thread::scope(|scope| {
            scope.spawn(|| {
                thread::sleep(Duration::from_millis(50));
                budget.cancelled.store(true, Ordering::Release);
            });
            assert_eq!(
                connection
                    .execute_with_budget(QueueCommand::List, &budget)
                    .err()
                    .unwrap()
                    .code,
                "engine_timeout"
            );
        });
        assert!(budget.start.elapsed() < Duration::from_secs(2));
        assert_eq!(
            connection.execute(QueueCommand::List).err().unwrap().code,
            "engine_failure"
        );
    }

    #[cfg(unix)]
    #[test]
    fn mismatched_reply_identity_closes_the_owner_connection() {
        let (root, engine) = fake("printf '%s\\n' '{\"event\":\"ready\",\"version\":1}'\nIFS= read -r request\nprintf '%s\\n' '{\"event\":\"reply\",\"version\":1,\"id\":\"wrong\",\"envelope\":{\"ok\":true,\"result\":{\"jobs\":[]}}}'\nexec sleep 30");
        let connection =
            QueueConnection::connect(&engine, root.path(), Duration::from_secs(3)).unwrap();
        assert_eq!(
            connection.execute(QueueCommand::List).err().unwrap().code,
            "invalid_response"
        );
        assert_eq!(
            connection.execute(QueueCommand::List).err().unwrap().code,
            "engine_failure"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_blocked_stdin_writer_cannot_defeat_the_request_deadline() {
        let (root, engine) =
            fake("printf '%s\\n' '{\"event\":\"ready\",\"version\":1}'\nexec sleep 30");
        let connection =
            QueueConnection::connect(&engine, root.path(), Duration::from_secs(1)).unwrap();
        let before = Instant::now();
        let oversized_grant = crate::import_queue::ImportInput {
            operation_id: uuid::Uuid::new_v4().to_string(),
            attempt_token: uuid::Uuid::new_v4().to_string(),
            source_path: std::path::PathBuf::from(format!("/{}", "x".repeat(180_000))),
            title: None,
        };
        assert_eq!(
            connection
                .execute(QueueCommand::Enqueue {
                    input: oversized_grant
                })
                .err()
                .unwrap()
                .code,
            "engine_timeout"
        );
        assert!(before.elapsed() < Duration::from_secs(5));
    }

    #[cfg(unix)]
    #[test]
    fn an_incompatible_startup_protocol_never_admits_requests() {
        let (root, engine) =
            fake("printf '%s\\n' '{\"event\":\"ready\",\"version\":2}'\nexec sleep 30");
        assert_eq!(
            QueueConnection::connect(&engine, root.path(), Duration::from_secs(1))
                .err()
                .unwrap()
                .code,
            "invalid_response"
        );
    }
}
