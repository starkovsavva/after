//! Persisted local selection and canonical source revision adapter.
use crate::application::speech_preparation::SpeechInputs;
use anyhow::{ensure, Result};
use serde_json::Value;
use std::path::{Component, Path};
pub(crate) struct Inputs<'a> {
    pub root: &'a Path,
}
impl SpeechInputs for Inputs<'_> {
    fn settings(&self) -> Result<Value> {
        let selected = super::speech_settings::capture(self.root)?;
        let frozen = crate::domain::speech_settings::local_snapshot(selected.value())?;
        let path = Path::new(frozen["asrModelPath"].as_str().unwrap());
        ensure!(
            path.is_absolute()
                && !path
                    .components()
                    .any(|part| matches!(part, Component::ParentDir)),
            "ASR model path must be absolute without parent traversal"
        );
        Ok(frozen)
    }
    fn revision(&self, meeting: &str) -> Result<String> {
        super::speech_publication::Publication { root: self.root }.inspect(meeting)
    }
    fn identity(&self) -> String {
        uuid::Uuid::new_v4().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn persisted_selection_rejects_relative_home_alias_and_parent_traversal() {
        let fixture = tempfile::tempdir().unwrap();
        for path in ["relative/model", "~/model", "/selected/../outside"] {
            std::fs::write(
                fixture.path().join("settings.json"),
                serde_json::json!({
                "speechMode":"local","diarization":false,"asrModelPath":path})
                .to_string(),
            )
            .unwrap();
            assert!(Inputs {
                root: fixture.path()
            }
            .settings()
            .unwrap_err()
            .to_string()
            .contains("absolute"));
        }
    }
}
