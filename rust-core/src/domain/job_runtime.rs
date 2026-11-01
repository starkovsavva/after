//! Portable live-attempt coordinator. The serialized state belongs to one
//! native host actor, is never persisted, and contains no worker configuration.
//! Decisions describe effects; the host executes them serially. SQLite remains
//! authoritative for claims, attempt CAS, dependencies and account quota pauses.
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AttemptKey {
    #[serde(rename = "jobID")]
    pub job_id: String,
    pub attempt: u64,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct LiveAttempt {
    attempt: u64,
    cancelled: bool,
    last_progress_ms: Option<u64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RuntimeState {
    version: u8,
    started: bool,
    stopping: bool,
    halted: bool,
    recording: bool,
    signing_out: BTreeSet<String>,
    active: BTreeMap<String, LiveAttempt>,
}

impl Default for RuntimeState {
    fn default() -> Self {
        Self {
            version: 1,
            started: false,
            stopping: false,
            halted: false,
            recording: false,
            signing_out: BTreeSet::new(),
            active: BTreeMap::new(),
        }
    }
}

#[derive(Deserialize, Serialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub(crate) enum RuntimeEvent {
    Start,
    Ready,
    Status,
    Claim,
    Recording {
        recording: bool,
    },
    SignOut {
        account: String,
        closing: bool,
    },
    Claimed {
        key: AttemptKey,
    },
    Progress {
        key: AttemptKey,
        now_ms: u64,
        is_progress: bool,
        message: Option<String>,
        fraction: Option<f64>,
    },
    Finish {
        key: AttemptKey,
        outcome: WorkerOutcome,
        cancelled: bool,
    },
    Cancel {
        #[serde(rename = "jobID")]
        job_id: String,
    },
    Halt,
    Shutdown,
}

#[derive(Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum WorkerOutcome {
    Committed,
    Cancelled,
    Failed { message: String },
}

impl RuntimeEvent {
    /// Normalize worker failures before applying the transport byte budget.
    /// Otherwise a large NSError/provider description could halt the queue
    /// instead of publishing its bounded failed status.
    pub fn bounded(mut self) -> Self {
        if let Self::Finish {
            outcome: WorkerOutcome::Failed { message },
            ..
        } = &mut self
        {
            *message = bounded_failure(message);
        }
        self
    }
}

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RuntimeDecision {
    pub accepted: bool,
    pub recover: bool,
    pub discard: Option<RuntimeDiscard>,
    pub stopping: bool,
    pub claim: Option<RuntimeClaim>,
    pub update: Option<RuntimeUpdate>,
    pub cancel: Vec<AttemptKey>,
    pub deliver_cancelled: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RuntimeClaim {
    allowed_resources: Vec<&'static str>,
    excluded_accounts: Vec<String>,
}

#[derive(Serialize)]
pub(crate) struct RuntimeDiscard {
    kind: &'static str,
    states: Vec<&'static str>,
}

fn ephemeral_drafts() -> RuntimeDiscard {
    RuntimeDiscard {
        kind: "dictate",
        states: vec!["queued", "interrupted", "blocked"],
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RuntimeUpdate {
    #[serde(rename = "jobID")]
    pub job_id: String,
    pub expected_attempt: u64,
    pub state: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

impl RuntimeState {
    fn validate(&self) -> Result<()> {
        ensure!(
            self.version == 1 && self.active.len() <= 256 && self.signing_out.len() <= 128,
            "Некорректное состояние исполнителя очереди"
        );
        for (id, attempt) in &self.active {
            validate_key(&AttemptKey {
                job_id: id.clone(),
                attempt: attempt.attempt,
            })?;
        }
        for account in &self.signing_out {
            validate_account(account)?;
        }
        Ok(())
    }

    pub fn transition(mut self, event: RuntimeEvent) -> Result<(Self, RuntimeDecision)> {
        self.validate()?;
        let mut decision = RuntimeDecision::default();
        match event {
            RuntimeEvent::Status => {}
            RuntimeEvent::Start => {
                ensure!(
                    self.active.is_empty() || self.started,
                    "Нельзя восстанавливать живые попытки"
                );
                // Ready is acknowledged only after recovery/ephemeral cleanup
                // succeed. A failed start can therefore be retried safely.
                decision.recover = !self.started;
                if !self.started {
                    decision.discard = Some(ephemeral_drafts());
                }
            }
            RuntimeEvent::Ready => {
                self.started = true;
            }
            RuntimeEvent::Recording { recording } => {
                self.recording = recording;
            }
            RuntimeEvent::SignOut { account, closing } => {
                validate_account(&account)?;
                if closing {
                    self.signing_out.insert(account);
                } else {
                    self.signing_out.remove(&account);
                }
            }
            RuntimeEvent::Claim => {
                if self.started && !self.stopping && !self.halted {
                    decision.claim = Some(RuntimeClaim {
                        allowed_resources: if self.recording {
                            vec!["cloud", "light"]
                        } else {
                            vec!["local-heavy", "cloud", "light"]
                        },
                        excluded_accounts: self.signing_out.iter().cloned().collect(),
                    });
                }
            }
            RuntimeEvent::Claimed { key } => {
                validate_key(&key)?;
                ensure!(
                    self.started
                        && !self.stopping
                        && !self.halted
                        && !self.active.contains_key(&key.job_id),
                    "Нельзя присоединить попытку к исполнителю"
                );
                self.active.insert(
                    key.job_id,
                    LiveAttempt {
                        attempt: key.attempt,
                        ..LiveAttempt::default()
                    },
                );
                decision.accepted = true;
            }
            RuntimeEvent::Progress {
                key,
                now_ms,
                is_progress,
                message,
                fraction,
            } => {
                validate_key(&key)?;
                if let Some(attempt) = self
                    .active
                    .get_mut(&key.job_id)
                    .filter(|attempt| attempt.attempt == key.attempt && !self.halted)
                {
                    let throttled = is_progress
                        && attempt
                            .last_progress_ms
                            .is_some_and(|last| now_ms >= last && now_ms - last < 150);
                    if !throttled {
                        attempt.last_progress_ms = Some(now_ms);
                        decision.accepted = true;
                        decision.update = Some(RuntimeUpdate {
                            job_id: key.job_id,
                            expected_attempt: key.attempt,
                            state: "running",
                            progress: fraction
                                .filter(|value| value.is_finite() && *value >= 0.0)
                                .map(|value| value.min(1.0)),
                            message,
                        });
                    }
                }
            }
            RuntimeEvent::Cancel { job_id } => {
                if let Some(attempt) = self.active.get_mut(&job_id) {
                    attempt.cancelled = true;
                    decision.cancel.push(AttemptKey {
                        job_id,
                        attempt: attempt.attempt,
                    });
                }
            }
            RuntimeEvent::Finish {
                key,
                outcome,
                cancelled,
            } => {
                validate_key(&key)?;
                if let Some(attempt) = self
                    .active
                    .get(&key.job_id)
                    .filter(|attempt| attempt.attempt == key.attempt)
                {
                    let cancelled = cancelled
                        || attempt.cancelled
                        || matches!(outcome, WorkerOutcome::Cancelled);
                    let (state, message) = match outcome {
                        // Committed publication wins even if cancel arrived later.
                        WorkerOutcome::Committed => ("succeeded", "Готово".into()),
                        _ if cancelled && self.stopping => (
                            "interrupted",
                            "Работа прервалась при закрытии приложения.".into(),
                        ),
                        _ if cancelled => ("cancelled", "Отменено".into()),
                        WorkerOutcome::Failed { message } => ("failed", bounded_failure(&message)),
                        WorkerOutcome::Cancelled => unreachable!(),
                    };
                    decision.accepted = true;
                    decision.deliver_cancelled = cancelled && state != "succeeded";
                    decision.update = Some(RuntimeUpdate {
                        job_id: key.job_id.clone(),
                        expected_attempt: key.attempt,
                        state,
                        progress: None,
                        message: Some(message),
                    });
                    self.active.remove(&key.job_id);
                }
            }
            RuntimeEvent::Halt => {
                self.halted = true;
            }
            RuntimeEvent::Shutdown => {
                self.stopping = true;
                decision.discard = Some(ephemeral_drafts());
                for (id, attempt) in &mut self.active {
                    attempt.cancelled = true;
                    decision.cancel.push(AttemptKey {
                        job_id: id.clone(),
                        attempt: attempt.attempt,
                    });
                }
            }
        }
        self.validate()?;
        decision.stopping = self.stopping;
        Ok((self, decision))
    }
}

fn validate_key(key: &AttemptKey) -> Result<()> {
    ensure!(
        !key.job_id.is_empty()
            && key.job_id.len() <= 128
            && !key.job_id.contains('\0')
            && key.attempt > 0,
        "Некорректная попытка исполнителя"
    );
    Ok(())
}
fn validate_account(account: &str) -> Result<()> {
    ensure!(
        !account.is_empty() && account.len() <= 512 && !account.contains('\0'),
        "Некорректная учётная запись исполнителя"
    );
    Ok(())
}
fn bounded_failure(message: &str) -> String {
    let mut result = String::new();
    for character in message.chars().take(1000) {
        if character == '\0' || result.len() + character.len_utf8() > 2000 {
            break;
        }
        result.push(character);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, to_value, Value};

    fn step(state: RuntimeState, event: Value) -> (RuntimeState, RuntimeDecision) {
        state
            .transition(serde_json::from_value(event).unwrap())
            .unwrap()
    }
    fn ready() -> RuntimeState {
        step(RuntimeState::default(), json!({"type":"ready"})).0
    }
    fn active() -> RuntimeState {
        step(
            ready(),
            json!({"type":"claimed","key":{"jobID":"a","attempt":2}}),
        )
        .0
    }
    #[test]
    fn start_acknowledges_recovery_only_after_success() {
        let (state, first) = step(RuntimeState::default(), json!({"type":"start"}));
        assert!(first.recover);
        assert!(first.discard.is_some());
        let (state, retry) = step(state, json!({"type":"start"}));
        assert!(retry.recover);
        let (state, _) = step(state, json!({"type":"ready"}));
        let (_, second) = step(state, json!({"type":"start"}));
        assert!(!second.recover);
        assert!(second.discard.is_none());
    }
    #[test]
    fn recording_signout_halt_and_shutdown_close_the_correct_admission() {
        let (_, before_start) = step(RuntimeState::default(), json!({"type":"claim"}));
        assert!(before_start.claim.is_none());
        let (state, _) = step(ready(), json!({"type":"recording","recording":true}));
        let (state, _) = step(
            state,
            json!({"type":"signOut","account":"one","closing":true}),
        );
        let (state, claim) = step(state, json!({"type":"claim"}));
        let claim = claim.claim.unwrap();
        assert_eq!(claim.allowed_resources, ["cloud", "light"]);
        assert_eq!(claim.excluded_accounts, ["one"]);
        let (state, _) = step(
            state,
            json!({"type":"signOut","account":"one","closing":false}),
        );
        let (state, _) = step(state, json!({"type":"recording","recording":false}));
        let (state, claim) = step(state, json!({"type":"claim"}));
        assert_eq!(
            claim.claim.unwrap().allowed_resources,
            ["local-heavy", "cloud", "light"]
        );
        let (_, stop) = step(
            step(state.clone(), json!({"type":"shutdown"})).0,
            json!({"type":"claim"}),
        );
        let (_, halt) = step(
            step(state, json!({"type":"halt"})).0,
            json!({"type":"claim"}),
        );
        assert!(stop.claim.is_none() && halt.claim.is_none());
    }
    #[test]
    fn stale_callbacks_do_not_change_the_live_attempt() {
        let state = active();
        let before = to_value(&state).unwrap();
        let (state, progress) = step(
            state,
            json!({"type":"progress","key":{"jobID":"a","attempt":1},"nowMs":100,"isProgress":true,"fraction":0.5}),
        );
        assert!(!progress.accepted && progress.update.is_none());
        let (state, finish) = step(
            state,
            json!({"type":"finish","key":{"jobID":"a","attempt":1},"outcome":{"type":"committed"},"cancelled":false}),
        );
        assert!(!finish.accepted && finish.update.is_none());
        assert_eq!(to_value(&state).unwrap(), before);
        assert!(state
            .transition(RuntimeEvent::Claimed {
                key: AttemptKey {
                    job_id: "a".into(),
                    attempt: 3
                }
            })
            .is_err());
    }
    #[test]
    fn progress_uses_monotonic_throttling_and_normalizes_fractions() {
        let event = |now, is_progress, fraction| json!({"type":"progress","key":{"jobID":"a","attempt":2},"nowMs":now,"isProgress":is_progress,"fraction":fraction});
        let (state, first) = step(active(), event(100, true, 0.2));
        assert_eq!(first.update.unwrap().progress, Some(0.2));
        let (state, throttled) = step(state, event(120, true, 0.3));
        assert!(!throttled.accepted);
        let (state, status) = step(state, event(200, false, -1.0));
        assert!(status.accepted);
        assert!(status.update.unwrap().progress.is_none());
        let (_, clamped) = step(state, event(350, true, 4.0));
        assert_eq!(clamped.update.unwrap().progress, Some(1.0));
    }
    #[test]
    fn committed_result_wins_over_cancel_and_shutdown() {
        let (state, cancel) = step(active(), json!({"type":"cancel","jobID":"a"}));
        assert_eq!(cancel.cancel[0].attempt, 2);
        let (state, shutdown) = step(state, json!({"type":"shutdown"}));
        assert!(shutdown.stopping && shutdown.discard.is_some());
        let (state, finish) = step(
            state,
            json!({"type":"finish","key":{"jobID":"a","attempt":2},"outcome":{"type":"committed"},"cancelled":true}),
        );
        assert_eq!(finish.update.unwrap().state, "succeeded");
        assert!(!finish.deliver_cancelled);
        assert!(state.active.is_empty());
    }
    #[test]
    fn shutdown_interruption_and_cancelled_delivery_are_separate_from_failure() {
        for (shutdown, cancelled, outcome, expected) in [
            (
                false,
                false,
                json!({"type":"failed","message":"model unavailable"}),
                "failed",
            ),
            (
                false,
                true,
                json!({"type":"failed","message":"stopped"}),
                "cancelled",
            ),
            (true, false, json!({"type":"cancelled"}), "interrupted"),
        ] {
            let state = if shutdown {
                step(active(), json!({"type":"shutdown"})).0
            } else {
                active()
            };
            let (_, finish) = step(
                state,
                json!({"type":"finish","key":{"jobID":"a","attempt":2},"outcome":outcome,"cancelled":cancelled}),
            );
            assert_eq!(finish.update.unwrap().state, expected);
            assert_eq!(finish.deliver_cancelled, expected != "failed");
        }
    }
    #[test]
    fn unicode_failure_always_fits_the_durable_message_limit() {
        let (_, finish) = step(
            active(),
            json!({"type":"finish","key":{"jobID":"a","attempt":2},"outcome":{"type":"failed","message":"🦀".repeat(1000)},"cancelled":false}),
        );
        let message = finish.update.unwrap().message.unwrap();
        assert_eq!(message.len(), 2000);
        assert!(!message.contains('\0'));
    }
    #[test]
    fn runtime_state_roundtrip_is_bounded_versioned_and_configuration_free() {
        let state = active();
        let value = to_value(&state).unwrap();
        let restored: RuntimeState = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(to_value(restored).unwrap(), value);
        let mut future = value.clone();
        future["version"] = json!(2);
        assert!(serde_json::from_value::<RuntimeState>(future)
            .unwrap()
            .transition(RuntimeEvent::Status)
            .is_err());
        let mut secret = value;
        secret["config"] = json!({"apiKey":"never here"});
        assert!(serde_json::from_value::<RuntimeState>(secret).is_err());
    }
}
