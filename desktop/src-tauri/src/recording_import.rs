//! Native application policy for stopped captures. Canonical queue identity is
//! durable before Run; receipts are checked before source repair on recovery.
use crate::{
    import_queue::{
        ImportInput, ImportJob, ImportQueue, ImportQueueSession, JobState, QueueCommand,
    },
    imports::ImportReservation,
    models::{HostError, Meeting},
    worker_host::ImportWork,
};
use std::{path::Path, sync::atomic::AtomicBool};

pub(crate) trait CapturedRecording {
    fn session_id(&self) -> Result<&str, HostError>;
    fn source(&self) -> &Path;
    fn finalize(&mut self) -> Result<(), HostError>;
    fn acknowledge(&self) -> Result<(), HostError>;
}
pub(crate) trait RecordingLibrary {
    fn open_queue(&self) -> Result<Box<dyn ImportQueueSession>, HostError>;
    fn committed(&self, work: &ImportWork) -> Result<Option<Meeting>, HostError>;
    fn resume(
        &self,
        queue: &dyn ImportQueueSession,
        job: ImportJob,
        cancelled: &AtomicBool,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Meeting, HostError>;
}
fn find(
    queue: &dyn ImportQueue,
    capture: &dyn CapturedRecording,
) -> Result<Option<ImportJob>, HostError> {
    let id = capture.session_id()?;
    let job = queue
        .execute(QueueCommand::Find {
            operation_id: id.into(),
        })?
        .job;
    if let Some(job) = &job {
        crate::queued_import::validate(job, &job.config.work())?;
        if job.object_id != id || job.config.source_path != capture.source() {
            return Err(HostError::new(
                "invalid_response",
                "The recording import identity is inconsistent.",
            ));
        }
    }
    Ok(job)
}
/// Listing can acknowledge a published capture, but cannot repair audio, create
/// an import identity, or start/retry work. Unknown outcomes stay recoverable.
pub(crate) fn reconcile(
    library: &dyn RecordingLibrary,
    queue: &dyn ImportQueue,
    capture: &dyn CapturedRecording,
) -> Result<bool, HostError> {
    let Some(job) = find(queue, capture)? else {
        return Ok(false);
    };
    if let Some(meeting) = library.committed(&job.config.work())? {
        if meeting.id != job.object_id {
            return Err(HostError::new(
                "invalid_response",
                "The recording receipt is inconsistent.",
            ));
        }
        capture.acknowledge()?;
        return Ok(true);
    }
    Ok(false)
}
pub(crate) fn save(
    library: &dyn RecordingLibrary,
    capture: &mut dyn CapturedRecording,
    reservation: ImportReservation,
    title: Option<String>,
    explicit_retry: bool,
) -> Result<Meeting, HostError> {
    if title
        .as_ref()
        .is_some_and(|value| value.len() > 2000 || value.contains('\0'))
    {
        return Err(HostError::invalid());
    }
    let queue = library.open_queue()?;
    let existing = find(&*queue, capture)?;
    if let Some(job) = &existing {
        if let Some(meeting) = library.committed(&job.config.work())? {
            if meeting.id != job.object_id {
                return Err(HostError::new(
                    "invalid_response",
                    "The recording receipt is inconsistent.",
                ));
            }
            // The canonical receipt remains authoritative if local ack fails.
            let _ = capture.acknowledge();
            return Ok(meeting);
        }
    }
    // No receipt publication was confirmed. Only an explicit stop/recover can
    // finalize WAV; this happens before creating the first queued identity.
    capture.finalize()?;
    let job = match existing {
        Some(job) => job,
        None => {
            let work = ImportWork {
                operation_id: capture.session_id()?.into(),
                attempt_token: uuid::Uuid::new_v4().to_string(),
                source: capture.source().into(),
                title,
            };
            queue
                .execute(QueueCommand::Enqueue {
                    input: ImportInput::from(&work),
                })?
                .job
                .ok_or_else(|| {
                    HostError::new("invalid_response", "Recording import is unavailable.")
                })?
        }
    };
    if !explicit_retry && !matches!(job.state, JobState::Queued | JobState::Succeeded) {
        return Err(HostError::new(
            "import_interrupted",
            "Recover this recording explicitly.",
        ));
    }
    let work = job.config.work();
    crate::queued_import::validate(&job, &work)?;
    if work.operation_id != capture.session_id()? || work.source != capture.source() {
        return Err(HostError::invalid());
    }
    let mut session = reservation.start(work.operation_id, work.attempt_token, "copying")?;
    let result = library.resume(&*queue, job, &session.cancelled, &mut |value| {
        session.fraction(value)
    });
    match &result {
        Ok(_) => {
            let _ = capture.acknowledge();
            session.finish("completed");
        }
        Err(error) if error.code == "cancelled" => session.finish("cancelled"),
        Err(_) => session.finish("failed"),
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        import_queue::{QueueReply, RequestBudget},
        imports::Imports,
    };
    use serde_json::{json, Value};
    use std::{
        cell::Cell,
        path::PathBuf,
        sync::{Arc, Mutex},
    };
    struct Capture {
        id: String,
        path: PathBuf,
        finalized: Cell<usize>,
        acks: Cell<usize>,
    }
    impl Capture {
        fn new() -> Self {
            Self {
                id: uuid::Uuid::new_v4().to_string(),
                path: std::env::temp_dir().join("private-capture.wav"),
                finalized: Cell::new(0),
                acks: Cell::new(0),
            }
        }
    }
    impl CapturedRecording for Capture {
        fn session_id(&self) -> Result<&str, HostError> {
            Ok(&self.id)
        }
        fn source(&self) -> &Path {
            &self.path
        }
        fn finalize(&mut self) -> Result<(), HostError> {
            self.finalized.set(self.finalized.get() + 1);
            Ok(())
        }
        fn acknowledge(&self) -> Result<(), HostError> {
            self.acks.set(self.acks.get() + 1);
            Ok(())
        }
    }
    struct Queue(Arc<Mutex<(Value, Vec<Value>)>>);
    impl ImportQueue for Queue {
        fn execute(&self, command: QueueCommand) -> Result<QueueReply, HostError> {
            let mut state = self.0.lock().unwrap();
            let value = serde_json::to_value(command).unwrap();
            state.1.push(value.clone());
            if value["action"] == "enqueue" {
                state.0 = json!({"id":uuid::Uuid::new_v4().to_string(),"objectID":value["input"]["operationId"],
                    "config":value["input"],"state":"queued","attempt":0,"progress":0.0,"cancelRequested":false});
            } else {
                assert_eq!(value["action"], "find");
            }
            Ok(serde_json::from_value(json!({"job":state.0})).unwrap())
        }
    }
    impl ImportQueueSession for Queue {
        fn execute_with_budget(
            &self,
            command: QueueCommand,
            _: &dyn RequestBudget,
        ) -> Result<QueueReply, HostError> {
            self.execute(command)
        }
        fn shutdown(&self) {}
    }
    struct Library {
        state: Arc<Mutex<(Value, Vec<Value>)>>,
        published: bool,
        unknown: bool,
        resumes: Cell<usize>,
    }
    fn meeting(id: &str) -> Meeting {
        serde_json::from_value(json!({"id":id,"title":"Capture","startedAt":null,"durationSeconds":null,"folderId":null,"hasTranscript":false,"hasSummary":false})).unwrap()
    }
    impl RecordingLibrary for Library {
        fn open_queue(&self) -> Result<Box<dyn ImportQueueSession>, HostError> {
            Ok(Box::new(Queue(self.state.clone())))
        }
        fn committed(&self, work: &ImportWork) -> Result<Option<Meeting>, HostError> {
            if self.unknown {
                return Err(HostError::new("engine_failure", "Unknown receipt"));
            }
            Ok(self.published.then(|| meeting(&work.operation_id)))
        }
        fn resume(
            &self,
            _: &dyn ImportQueueSession,
            job: ImportJob,
            _: &AtomicBool,
            progress: &mut dyn FnMut(f64),
        ) -> Result<Meeting, HostError> {
            self.resumes.set(self.resumes.get() + 1);
            progress(1.0);
            Ok(meeting(&job.object_id))
        }
    }
    fn library(capture: &Capture, existing: bool, published: bool, unknown: bool) -> Library {
        let job = if existing {
            json!({"id":uuid::Uuid::new_v4().to_string(),"objectID":capture.id,
            "config":{"operationId":capture.id,"attemptToken":uuid::Uuid::new_v4().to_string(),"sourcePath":capture.path,"title":"Original title"},
            "state":"interrupted","attempt":1,"progress":0.4,"cancelRequested":false})
        } else {
            Value::Null
        };
        Library {
            state: Arc::new(Mutex::new((job, vec![]))),
            published,
            unknown,
            resumes: Cell::new(0),
        }
    }
    #[test]
    fn published_recording_is_acknowledged_without_source_repair_enqueue_or_retry() {
        let mut capture = Capture::new();
        let library = library(&capture, true, true, false);
        let imports = Arc::new(Imports::default());
        assert_eq!(
            save(
                &library,
                &mut capture,
                imports.reserve().unwrap(),
                None,
                true
            )
            .unwrap()
            .id,
            capture.id
        );
        assert_eq!(capture.finalized.get(), 0);
        assert_eq!(capture.acks.get(), 1);
        assert_eq!(library.resumes.get(), 0);
        assert_eq!(library.state.lock().unwrap().1.len(), 1);
        assert!(!imports.active());
    }
    #[test]
    fn unknown_receipt_blocks_source_repair_and_keeps_the_attempt_unchanged() {
        let mut capture = Capture::new();
        let library = library(&capture, true, false, true);
        let imports = Arc::new(Imports::default());
        assert!(save(
            &library,
            &mut capture,
            imports.reserve().unwrap(),
            None,
            true
        )
        .is_err());
        assert_eq!(capture.finalized.get(), 0);
        assert_eq!(capture.acks.get(), 0);
        assert_eq!(library.resumes.get(), 0);
        assert_eq!(library.state.lock().unwrap().0["attempt"], 1);
        assert!(imports.reserve().is_ok());
    }
    #[test]
    fn first_save_uses_session_identity_and_persists_a_private_token_before_execution() {
        let mut capture = Capture::new();
        let library = library(&capture, false, false, false);
        let imports = Arc::new(Imports::default());
        save(
            &library,
            &mut capture,
            imports.reserve().unwrap(),
            Some("Captured title".into()),
            false,
        )
        .unwrap();
        let state = library.state.lock().unwrap();
        assert_eq!(state.0["objectID"], capture.id);
        assert_eq!(state.0["config"]["operationId"], capture.id);
        assert_ne!(state.0["config"]["attemptToken"], capture.id);
        assert_eq!(state.0["config"]["title"], "Captured title");
        assert_eq!(capture.finalized.get(), 1);
        assert_eq!(capture.acks.get(), 1);
        assert_eq!(library.resumes.get(), 1);
        assert_eq!(imports.status().phase, "completed");
    }
}
