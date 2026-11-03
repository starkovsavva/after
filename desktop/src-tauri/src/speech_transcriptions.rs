//! Meeting-based transcription controls. The renderer supplies no settings,
//! paths or receipt tokens; native submission captures and validates those.
use crate::{
    models::{validate_id, HostError},
    speech_queue::{SpeechCommand, SpeechJobSummary},
    speech_session::SpeechSession,
};
use std::sync::Arc;

pub(crate) struct SpeechTranscriptions {
    session: Arc<SpeechSession>,
}
impl SpeechTranscriptions {
    pub fn new(session: Arc<SpeechSession>) -> Self {
        Self { session }
    }
    fn accept(
        &self,
        job: Option<SpeechJobSummary>,
        meeting: &str,
        id: Option<&str>,
    ) -> Result<Option<SpeechJobSummary>, HostError> {
        if job.as_ref().is_some_and(|job| {
            !uuid::Uuid::parse_str(&job.id).is_ok_and(|id| id.to_string() == job.id)
                || job.meeting_id.as_deref() != Some(meeting)
                || id.is_some_and(|id| id != job.id)
                || !job.progress.is_finite()
                || !(0.0..=1.0).contains(&job.progress)
                || !job.created_at.is_some_and(f64::is_finite)
        }) {
            self.session.invalidate();
            return Err(HostError::new(
                "invalid_response",
                "Invalid transcription response.",
            ));
        }
        Ok(job)
    }
    fn required(
        &self,
        job: Option<SpeechJobSummary>,
        meeting: &str,
        id: Option<&str>,
    ) -> Result<SpeechJobSummary, HostError> {
        match self.accept(job, meeting, id)? {
            Some(job) => Ok(job),
            None => {
                self.session.invalidate();
                Err(HostError::new(
                    "invalid_response",
                    "Transcription response is missing.",
                ))
            }
        }
    }
    pub fn status(&self, meeting: &str) -> Result<Option<SpeechJobSummary>, HostError> {
        validate_id(meeting)?;
        let reply = self.session.execute(SpeechCommand::Meeting {
            meeting_id: meeting.into(),
        })?;
        self.accept(reply.job, meeting, None)
    }
    pub fn start(&self, meeting: &str) -> Result<SpeechJobSummary, HostError> {
        validate_id(meeting)?;
        let reply = self.session.execute(SpeechCommand::Start {
            meeting_id: meeting.into(),
        })?;
        self.required(reply.job, meeting, None)
    }
    pub fn control(
        &self,
        meeting: &str,
        id: &str,
        attempt: u64,
        resume: bool,
    ) -> Result<SpeechJobSummary, HostError> {
        validate_id(meeting)?;
        if !uuid::Uuid::parse_str(id).is_ok_and(|parsed| parsed.to_string() == id) {
            return Err(HostError::invalid());
        }
        let reply = self
            .session
            .execute(SpeechCommand::Get { job_id: id.into() })?;
        let current = self.required(reply.job, meeting, Some(id))?;
        if current.attempt != attempt {
            return Err(HostError::new(
                "conflict",
                "The transcription changed. Refresh before continuing.",
            ));
        }
        // The engine checks expectedAttempt again inside the mutation; this
        // observation additionally binds the requested job to its meeting.
        let command = if resume {
            SpeechCommand::Resume {
                job_id: id.into(),
                expected_attempt: attempt,
            }
        } else {
            SpeechCommand::Cancel {
                job_id: id.into(),
                expected_attempt: attempt,
            }
        };
        let reply = self.session.execute(command)?;
        self.required(reply.job, meeting, Some(id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        queue_budget::RequestBudget,
        speech_queue::{SpeechQueue, SpeechReply},
    };
    use serde_json::json;
    use std::sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Mutex,
    };
    const ID: &str = "11111111-1111-4111-8111-111111111111";
    struct Queue {
        job: Mutex<Option<serde_json::Value>>,
        commands: Mutex<Vec<String>>,
        stopped: AtomicUsize,
        fail_start: AtomicBool,
    }
    impl Queue {
        fn new() -> Self {
            Self {
                job: Mutex::new(None),
                commands: Mutex::new(vec![]),
                stopped: AtomicUsize::new(0),
                fail_start: AtomicBool::new(false),
            }
        }
    }
    impl SpeechQueue for Queue {
        fn execute_with_budget(
            &self,
            command: SpeechCommand,
            _: &dyn RequestBudget,
        ) -> Result<SpeechReply, HostError> {
            let value = serde_json::to_value(command).unwrap();
            let action = value["action"].as_str().unwrap();
            self.commands.lock().unwrap().push(action.into());
            if action == "start" && self.fail_start.load(Ordering::Relaxed) {
                return Err(HostError::new(
                    "engine_timeout",
                    "Synthetic lost acknowledgement",
                ));
            }
            let mut job = self.job.lock().unwrap();
            let mut reply = json!({});
            match action {
                "start" => {
                    job.get_or_insert_with(|| json!({"id":ID,"meetingId":value["meetingId"],"state":"queued","progress":0.0,"attempt":0,"cancelRequested":false,"createdAt":1.0}));
                    reply["job"] = job.clone().unwrap();
                }
                "meeting" | "get" => reply["job"] = job.clone().unwrap_or(serde_json::Value::Null),
                "resume" => {
                    let job = job.as_mut().unwrap();
                    assert_eq!(value["expectedAttempt"], job["attempt"]);
                    job["attempt"] = json!(job["attempt"].as_u64().unwrap() + 1);
                    job["state"] = json!("running");
                    reply["job"] = job.clone();
                }
                "cancel" => {
                    let job = job.as_mut().unwrap();
                    job["state"] = json!("cancelled");
                    reply["job"] = job.clone();
                }
                "enqueue_check" | "run_check" => {
                    reply["check"] = json!({"id":ID,"state":"running","progress":0.0,"attempt":1,"cancelRequested":false,"createdAt":1.0})
                }
                _ => panic!("unexpected action {action}"),
            }
            Ok(serde_json::from_value(reply).unwrap())
        }
        fn shutdown(&self) {
            self.stopped.fetch_add(1, Ordering::Relaxed);
        }
    }
    fn setup() -> (Arc<Queue>, Arc<AtomicUsize>, Arc<SpeechSession>) {
        let queue = Arc::new(Queue::new());
        let opens = Arc::new(AtomicUsize::new(0));
        let provider_queue = queue.clone();
        let provider_opens = opens.clone();
        let session = Arc::new(SpeechSession::new(move || {
            provider_opens.fetch_add(1, Ordering::Relaxed);
            Ok(provider_queue.clone())
        }));
        (queue, opens, session)
    }
    #[test]
    fn consumers_share_one_owner_and_only_explicit_controls_resume_work() {
        let (queue, opens, session) = setup();
        let checks = crate::speech_checks::SpeechChecks::with_session(session.clone());
        let transcriptions = SpeechTranscriptions::new(session);
        assert!(checks.status().unwrap().is_none());
        assert_eq!(opens.load(Ordering::Relaxed), 0);
        assert!(transcriptions.status("Meeting_A").unwrap().is_none());
        checks.start().unwrap();
        let first = transcriptions.start("Meeting_A").unwrap();
        assert_eq!(transcriptions.start("Meeting_A").unwrap().id, first.id);
        assert_eq!(
            transcriptions.status("Meeting_A").unwrap().unwrap().attempt,
            0
        );
        assert_eq!(
            transcriptions
                .control("Meeting_A", ID, 1, true)
                .unwrap_err()
                .code,
            "conflict"
        );
        assert!(!queue
            .commands
            .lock()
            .unwrap()
            .iter()
            .any(|action| action == "resume"));
        assert_eq!(
            transcriptions
                .control("Meeting_A", ID, 0, true)
                .unwrap()
                .attempt,
            1
        );
        assert_eq!(
            transcriptions
                .control("Meeting_A", ID, 0, false)
                .unwrap_err()
                .code,
            "conflict"
        );
        assert_eq!(
            transcriptions
                .control("Meeting_A", ID, 1, false)
                .unwrap()
                .state,
            crate::queue_models::JobState::Cancelled
        );
        assert_eq!(opens.load(Ordering::Relaxed), 1);
    }
    #[test]
    fn invalid_input_and_cross_meeting_replies_never_reach_mutation() {
        let (queue, opens, session) = setup();
        let state = SpeechTranscriptions::new(session);
        assert!(state.start("../outside").is_err());
        assert_eq!(opens.load(Ordering::Relaxed), 0);
        state.start("Meeting_A").unwrap();
        assert_eq!(
            state.control("Meeting_B", ID, 0, true).unwrap_err().code,
            "invalid_response"
        );
        assert_eq!(queue.stopped.load(Ordering::Relaxed), 1);
        assert!(!queue
            .commands
            .lock()
            .unwrap()
            .iter()
            .any(|action| action == "resume"));
    }
    #[test]
    fn a_lost_start_acknowledgement_is_not_automatically_replayed() {
        let (queue, opens, session) = setup();
        let state = SpeechTranscriptions::new(session);
        queue.fail_start.store(true, Ordering::Relaxed);
        assert_eq!(state.start("Meeting_A").unwrap_err().code, "engine_timeout");
        assert_eq!(*queue.commands.lock().unwrap(), vec!["start"]);
        assert_eq!(queue.stopped.load(Ordering::Relaxed), 1);
        assert!(state.status("Meeting_A").unwrap().is_none());
        assert_eq!(opens.load(Ordering::Relaxed), 2);
        assert_eq!(*queue.commands.lock().unwrap(), vec!["start", "meeting"]);
    }
}
