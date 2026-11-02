//! Native speech publication. Inference never writes the canonical meeting.
use super::speech_launch::SpeechSettings;
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::Path;

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
        for id in [&self.operation_id, &self.attempt_token, &self.meeting_id] {
            let parsed = uuid::Uuid::parse_str(id)?;
            ensure!(parsed.to_string() == *id, "Invalid speech identity");
        }
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

pub(crate) trait SpeechPublication {
    type Stage;
    fn committed(&self, work: &SpeechWork) -> Result<bool>;
    fn stage(&self, work: &SpeechWork) -> Result<Self::Stage>;
    fn directory(stage: &Self::Stage) -> &Path;
    /// Recheck input and outputs under the canonical meeting lock, then publish
    /// result and receipt together. Unknown outcomes must remain recoverable.
    fn publish(&self, work: &SpeechWork, stage: &Self::Stage) -> Result<SpeechReceipt>;
}
pub(crate) trait SpeechInference {
    fn transcribe(&self, directory: &Path, settings: SpeechSettings) -> Result<()>;
}
pub(crate) fn execute<P: SpeechPublication>(
    publication: &P,
    worker: &dyn SpeechInference,
    work: &SpeechWork,
) -> Result<SpeechReceipt> {
    let settings = work.validate()?;
    if publication.committed(work)? {
        return Ok(SpeechReceipt::for_work(work));
    }
    let result = (|| {
        let stage = publication.stage(work)?;
        worker.transcribe(P::directory(&stage), settings)?;
        publication.publish(work, &stage)
    })();
    match result {
        Ok(receipt) => Ok(receipt),
        Err(error) => {
            // A lost acknowledgement or a concurrent completion must never
            // turn an exact committed operation into a retry invitation.
            if publication.committed(work)? {
                Ok(SpeechReceipt::for_work(work))
            } else {
                Err(error)
            }
        }
    }
}
