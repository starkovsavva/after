//! Private speech work/receipt contract shared by preparation and execution.
use super::speech_launch::SpeechSettings;
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
pub(crate) const KIND: &str = "desktop-speech";
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SpeechWork {
    pub version: u8,
    pub operation_id: String,
    pub attempt_token: String,
    pub meeting_id: String,
    pub input_revision: String,
    pub settings: Value,
}
impl SpeechWork {
    pub(crate) fn validate(&self) -> Result<SpeechSettings> {
        ensure!(self.version == 1, "Unsupported speech request version");
        for id in [&self.operation_id, &self.attempt_token] {
            let parsed = uuid::Uuid::parse_str(id)?;
            ensure!(parsed.to_string() == *id, "Invalid speech identity");
        }
        ensure!(
            crate::domain::meeting_ids::valid(&self.meeting_id),
            "Invalid meeting identity"
        );
        ensure!(
            self.input_revision.len() == 64
                && self
                    .input_revision
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()),
            "Invalid speech revision"
        );
        let settings = SpeechSettings::parse(&serde_json::to_vec(&self.settings)?)?;
        ensure!(
            settings.value()["speechMode"].as_str() == Some("local"),
            "This executor requires explicit local speech mode"
        );
        ensure!(
            settings.value()["diarization"].as_bool() == Some(false),
            "This executor requires explicit diarization=false"
        );
        Ok(settings)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SpeechReceipt {
    pub version: u8,
    pub operation_id: String,
    pub attempt_token: String,
    pub meeting_id: String,
    pub input_revision: String,
    pub settings_revision: String,
}
impl SpeechReceipt {
    pub(crate) fn for_work(work: &SpeechWork) -> Self {
        Self {
            version: 1,
            operation_id: work.operation_id.clone(),
            attempt_token: work.attempt_token.clone(),
            meeting_id: work.meeting_id.clone(),
            input_revision: work.input_revision.clone(),
            settings_revision: format!(
                "{:x}",
                Sha256::digest(work.settings.to_string().as_bytes())
            ),
        }
    }
}

impl SpeechWork {
    pub(crate) fn from_job(job: &crate::domain::jobs::Job) -> Result<Self> {
        ensure!(
            job.kind == KIND && job.resource == "local-heavy" && !job.paid,
            "Speech belongs to another execution route"
        );
        let work: Self = serde_json::from_value(job.config.clone())?;
        work.validate()?;
        ensure!(
            work.operation_id == job.object_id && work.input_revision == job.input_revision,
            "Speech identity or revision changed"
        );
        Ok(work)
    }
}
