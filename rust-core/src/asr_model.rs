//! Native managed ONNX artifact facade. Installation/verification do not enable
//! model readiness or choose a model on behalf of a user or queued job.
pub use crate::domain::asr_models::InstalledAsrModel;
pub use crate::infrastructure::asr_model_store::{install, verify_selected, VerifiedModel};

use crate::application::speech_launch::RuntimeGuard;
use anyhow::Result;
use std::path::Path;
impl RuntimeGuard for VerifiedModel {
    fn recheck(&self) -> Result<()> {
        VerifiedModel::recheck(self)
    }
}
/// Bind managed-model selection to the same frozen snapshot used by the worker.
/// Explicit external models keep their existing local compatibility boundary.
pub(crate) fn selected_guard(
    root: &Path,
    settings: &crate::application::speech_launch::SpeechSettings,
) -> Result<Option<Box<dyn RuntimeGuard>>> {
    let settings = settings.value();
    if settings.get("speechMode").and_then(|v| v.as_str()) == Some("cloud") {
        return Ok(None);
    }
    let Some(path) = settings
        .get("asrModelPath")
        .and_then(|v| v.as_str())
        .filter(|v| !v.trim().is_empty())
    else {
        return Ok(None);
    };
    let path = Path::new(path.trim());
    anyhow::ensure!(
        path.is_absolute(),
        "ASR model path must be absolute; expand home aliases before selection"
    );
    if crate::infrastructure::asr_model_store::is_managed_path(root, path)? {
        return Ok(Some(Box::new(verify_selected(root, path)?)));
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn relative_and_home_alias_selections_cannot_bypass_native_model_guards() {
        let root = tempfile::tempdir().unwrap();
        for path in ["~/runtime/asr-models/model", "relative/model"] {
            let value = serde_json::json!({"speechMode":"local", "asrModelPath":path});
            let settings = crate::application::speech_launch::SpeechSettings::parse(
                &serde_json::to_vec(&value).unwrap(),
            )
            .unwrap();
            assert!(selected_guard(root.path(), &settings).is_err());
        }
    }
}
