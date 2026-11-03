//! Renderer-facing check sessions. Native queue grants and resource selection
//! stay behind an injected provider; failed mutations are never replayed.
use crate::{
    models::HostError,
    queue_models::JobState,
    speech_queue::{CheckSummary, SpeechCommand},
};
use std::sync::{Arc, Mutex};
#[derive(Default)]
struct State {
    current: Option<CheckSummary>,
}
pub(crate) struct SpeechChecks {
    session: Arc<crate::speech_session::SpeechSession>,
    state: Mutex<State>,
}
impl SpeechChecks {
    #[cfg(test)]
    pub fn new(
        provider: impl Fn() -> Result<Arc<dyn crate::speech_queue::SpeechQueue>, HostError>
            + Send
            + Sync
            + 'static,
    ) -> Self {
        Self::with_session(Arc::new(crate::speech_session::SpeechSession::new(
            provider,
        )))
    }
    pub fn with_session(session: Arc<crate::speech_session::SpeechSession>) -> Self {
        Self {
            session,
            state: Mutex::new(State::default()),
        }
    }
    fn request(&self, command: SpeechCommand) -> Result<Option<CheckSummary>, HostError> {
        self.session.execute(command).map(|reply| reply.check)
    }
    fn accept(
        &self,
        state: &mut State,
        reply: Option<CheckSummary>,
        id: Option<&str>,
    ) -> Result<CheckSummary, HostError> {
        let summary = reply.filter(|summary| {
            uuid::Uuid::parse_str(&summary.id).is_ok_and(|id| id.to_string() == summary.id)
                && id.is_none_or(|id| summary.id == id)
                && summary.progress.is_finite()
                && (0.0..=1.0).contains(&summary.progress)
                && summary.created_at.is_none_or(f64::is_finite)
        });
        let Some(summary) = summary else {
            self.session.invalidate();
            return Err(HostError::new(
                "invalid_response",
                "Invalid speech check response.",
            ));
        };
        state.current = Some(summary.clone());
        Ok(summary)
    }
    fn refresh(&self, state: &mut State) -> Result<Option<CheckSummary>, HostError> {
        let Some(current) = &state.current else {
            return Ok(None);
        };
        let id = current.id.clone();
        let reply = self.request(SpeechCommand::GetCheck { job_id: id.clone() })?;
        self.accept(state, reply, Some(&id)).map(Some)
    }
    pub fn status(&self) -> Result<Option<CheckSummary>, HostError> {
        let mut state = self.state.lock().map_err(|_| HostError::invalid())?;
        self.refresh(&mut state)
    }
    /// First action creates an attempt; queued attempts are run again only on
    /// another explicit action. Status reads never admit inference.
    pub fn start(&self) -> Result<CheckSummary, HostError> {
        let mut state = self.state.lock().map_err(|_| HostError::invalid())?;
        let current = self.refresh(&mut state)?;
        if current
            .as_ref()
            .is_some_and(|job| job.state == JobState::Running)
        {
            return Err(HostError::new("busy", "A speech check is already running."));
        }
        let check = if let Some(check) = current.filter(|job| job.state == JobState::Queued) {
            check
        } else {
            let reply = self.request(SpeechCommand::EnqueueCheck {})?;
            self.accept(&mut state, reply, None)?
        };
        let reply = self.request(SpeechCommand::RunCheck {
            job_id: check.id.clone(),
        })?;
        if reply.is_none() {
            return Ok(check);
        }
        self.accept(&mut state, reply, Some(&check.id))
    }
    pub fn cancel(&self, id: &str, attempt: u64) -> Result<CheckSummary, HostError> {
        let mut state = self.state.lock().map_err(|_| HostError::invalid())?;
        let current = self.refresh(&mut state)?.ok_or_else(HostError::invalid)?;
        if current.id != id || current.attempt != attempt {
            return Err(HostError::new(
                "conflict",
                "The speech check changed. Refresh before cancelling.",
            ));
        }
        let reply = self.request(SpeechCommand::CancelCheck {
            job_id: id.into(),
            expected_attempt: attempt,
        })?;
        self.accept(&mut state, reply, Some(id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        queue_budget::RequestBudget,
        speech_queue::{SpeechQueue, SpeechReply},
    };
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    struct Queue {
        current: Mutex<Option<CheckSummary>>,
        busy: AtomicBool,
        enqueues: AtomicUsize,
        runs: AtomicUsize,
        fail_enqueue: AtomicBool,
        stopped: AtomicBool,
    }
    impl Default for Queue {
        fn default() -> Self {
            Self {
                current: Mutex::new(None),
                busy: AtomicBool::new(false),
                enqueues: AtomicUsize::new(0),
                runs: AtomicUsize::new(0),
                fail_enqueue: AtomicBool::new(false),
                stopped: AtomicBool::new(false),
            }
        }
    }
    impl SpeechQueue for Queue {
        fn execute_with_budget(
            &self,
            command: SpeechCommand,
            _: &dyn RequestBudget,
        ) -> Result<SpeechReply, HostError> {
            let mut current = self.current.lock().unwrap();
            match command {
                SpeechCommand::EnqueueCheck {} => {
                    self.enqueues.fetch_add(1, Ordering::Relaxed);
                    if self.fail_enqueue.load(Ordering::Relaxed) {
                        return Err(HostError::new("engine_timeout", "Lost acknowledgement"));
                    }
                    *current = Some(CheckSummary {
                        id: uuid::Uuid::new_v4().to_string(),
                        state: JobState::Queued,
                        progress: 0.0,
                        attempt: 0,
                        cancel_requested: false,
                        created_at: Some(1.0),
                    });
                }
                SpeechCommand::GetCheck { job_id } => {
                    assert_eq!(current.as_ref().unwrap().id, job_id)
                }
                SpeechCommand::RunCheck { job_id } => {
                    assert_eq!(current.as_ref().unwrap().id, job_id);
                    self.runs.fetch_add(1, Ordering::Relaxed);
                    if self.busy.load(Ordering::Relaxed) {
                        return Ok(
                            serde_json::from_value(serde_json::json!({"check":null})).unwrap()
                        );
                    }
                    let job = current.as_mut().unwrap();
                    job.attempt += 1;
                    job.state = JobState::Running;
                }
                SpeechCommand::CancelCheck {
                    job_id,
                    expected_attempt,
                } => {
                    let job = current.as_mut().unwrap();
                    assert_eq!(job.id, job_id);
                    assert_eq!(job.attempt, expected_attempt);
                    job.state = JobState::Cancelled;
                }
                _ => panic!("unexpected command"),
            }
            Ok(serde_json::from_value(serde_json::json!({"check":&*current})).unwrap())
        }
        fn shutdown(&self) {
            self.stopped.store(true, Ordering::Relaxed);
        }
    }
    #[test]
    fn passive_status_never_opens_a_queue() {
        let state = SpeechChecks::new(|| panic!("passive read acquired ownership"));
        assert!(state.status().unwrap().is_none());
    }
    #[test]
    fn queued_check_only_runs_on_explicit_action_and_cancel_is_fenced() {
        let queue = Arc::new(Queue::default());
        queue.busy.store(true, Ordering::Relaxed);
        let source = queue.clone();
        let state = SpeechChecks::new(move || Ok(source.clone()));
        let first = state.start().unwrap();
        assert_eq!(first.state, JobState::Queued);
        state.status().unwrap();
        state.status().unwrap();
        assert_eq!(queue.runs.load(Ordering::Relaxed), 1);
        assert_eq!(queue.enqueues.load(Ordering::Relaxed), 1);
        queue.busy.store(false, Ordering::Relaxed);
        let running = state.start().unwrap();
        assert_eq!(running.id, first.id);
        assert_eq!(running.attempt, 1);
        assert_eq!(state.start().unwrap_err().code, "busy");
        assert_eq!(state.cancel(&running.id, 0).unwrap_err().code, "conflict");
        assert_eq!(
            state.cancel(&running.id, 1).unwrap().state,
            JobState::Cancelled
        );
        assert_eq!(queue.enqueues.load(Ordering::Relaxed), 1);
        let next = state.start().unwrap();
        assert_ne!(next.id, first.id);
        assert_eq!(state.cancel(&first.id, 1).unwrap_err().code, "conflict");
    }
    #[test]
    fn lost_enqueue_ack_is_never_replayed_by_status() {
        let queue = Arc::new(Queue::default());
        queue.fail_enqueue.store(true, Ordering::Relaxed);
        let source = queue.clone();
        let state = SpeechChecks::new(move || Ok(source.clone()));
        assert_eq!(state.start().unwrap_err().code, "engine_timeout");
        assert!(queue.stopped.load(Ordering::Relaxed));
        assert!(state.status().unwrap().is_none());
        assert_eq!(queue.enqueues.load(Ordering::Relaxed), 1);
    }
}
