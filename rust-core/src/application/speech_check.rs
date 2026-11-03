//! Explicit synthetic preflight work, independent of meeting publication.
use super::{
    attempt_execution::{AttemptOutcome, AttemptStop, AttemptStore},
    speech_launch::SpeechSettings,
    speech_progress::SpeechObserver,
};
use crate::domain::jobs::Job;
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
pub(crate) const KIND: &str = "desktop-speech-check";
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CheckWork {
    pub version: u8,
    pub operation_id: String,
    pub attempt_token: String,
    pub settings: Value,
}
impl CheckWork {
    pub(crate) fn validate(&self) -> Result<SpeechSettings> {
        ensure!(self.version == 1, "Invalid check version");
        for id in [&self.operation_id, &self.attempt_token] {
            ensure!(
                uuid::Uuid::parse_str(id)?.to_string() == *id,
                "Invalid check identity"
            );
        }
        ensure!(
            crate::domain::speech_settings::local_snapshot(&self.settings)? == self.settings,
            "Check settings must contain only local selection"
        );
        SpeechSettings::parse(&serde_json::to_vec(&self.settings)?)
    }
    pub(crate) fn revision(&self) -> String {
        format!("{:x}", Sha256::digest(self.settings.to_string().as_bytes()))
    }
}
#[derive(Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CheckCompletion {
    pub operation_id: String,
    pub attempt_token: String,
    pub settings_revision: String,
    pub local_inference_verified: bool,
    pub media_verified: bool,
    pub diarization_verified: bool,
}
impl CheckCompletion {
    pub(crate) fn for_work(work: &CheckWork) -> Self {
        Self {
            operation_id: work.operation_id.clone(),
            attempt_token: work.attempt_token.clone(),
            settings_revision: work.revision(),
            local_inference_verified: true,
            media_verified: true,
            diarization_verified: false,
        }
    }
}
pub(crate) trait CheckWorker: Send + Sync {
    /// Return only after all native/SDK descendants have stopped.
    fn run_check(
        &self,
        work: &CheckWork,
        stop: &AttemptStop,
        observer: &mut dyn SpeechObserver,
    ) -> Result<()>;
}
pub(crate) fn input(job: &Job) -> Result<CheckWork> {
    ensure!(
        job.kind == KIND && job.resource == "local-heavy" && !job.paid,
        "Check belongs to another scope"
    );
    let work: CheckWork = serde_json::from_value(job.config.clone())?;
    work.validate()?;
    ensure!(
        work.operation_id == job.object_id && work.revision() == job.input_revision,
        "Check identity changed"
    );
    Ok(work)
}
pub(crate) fn execute(
    store: &dyn AttemptStore,
    worker: &dyn CheckWorker,
    job: &Job,
    stop: &AttemptStop,
) -> Result<()> {
    ensure!(
        job.state == "running" && job.attempt > 0,
        "Check is not running"
    );
    struct Observer<'a> {
        store: &'a dyn AttemptStore,
        job: &'a Job,
        stop: &'a AttemptStop,
    }
    impl SpeechObserver for Observer<'_> {
        fn checkpoint(&mut self, fraction: Option<f64>) -> Result<()> {
            ensure!(!self.stop.is_requested(), "Check stopped");
            if let Some(value) = fraction {
                ensure!(
                    value.is_finite() && (0.0..=1.0).contains(&value),
                    "Invalid check progress"
                );
                if self.store.progress(&self.job.id, self.job.attempt, value)? {
                    self.stop.cancel();
                }
            }
            ensure!(!self.stop.is_requested(), "Check stopped");
            Ok(())
        }
    }
    let result = (|| {
        ensure!(!stop.is_requested(), "Check stopped");
        let work = input(job)?;
        worker.run_check(&work, stop, &mut Observer { store, job, stop })
    })();
    let outcome = if stop.is_cancelled() {
        AttemptOutcome::Cancelled
    } else if stop.is_stopping() {
        AttemptOutcome::Interrupted
    } else if result.is_ok() {
        AttemptOutcome::Succeeded
    } else {
        AttemptOutcome::Failed
    };
    store.finish(&job.id, job.attempt, outcome)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn private_completion_binds_identity_and_only_minimal_selection_is_accepted() {
        let mut work = CheckWork {
            version: 1,
            operation_id: uuid::Uuid::new_v4().to_string(),
            attempt_token: uuid::Uuid::new_v4().to_string(),
            settings: serde_json::json!({"speechMode":"local","diarization":false,"asrModelPath":"/selected/model"}),
        };
        work.validate().unwrap();
        let completion = CheckCompletion::for_work(&work);
        work.attempt_token = uuid::Uuid::new_v4().to_string();
        assert!(completion != CheckCompletion::for_work(&work));
        work.settings["asrModelPath"] = Value::String("/changed/model".into());
        assert!(completion.settings_revision != work.revision());
        work.settings["apiKey"] = Value::String("private-fixture".into());
        assert!(work.validate().is_err());
    }
}
