//! Native managed ONNX artifact facade. Installation/verification do not enable
//! model readiness or choose a model on behalf of a user or queued job.
pub use crate::domain::asr_models::InstalledAsrModel;
pub use crate::infrastructure::asr_model_store::{install, verify_selected, VerifiedModel};

use crate::application::speech_launch::RuntimeGuard;
use anyhow::Result;
use std::{io::Read, path::Path};
impl RuntimeGuard for VerifiedModel {
    fn recheck(&self) -> Result<()> {
        VerifiedModel::recheck(self)
    }
}
/// Bind managed-model selection to the same frozen snapshot used by the worker.
/// Explicit external models keep their existing local compatibility boundary.
pub(crate) fn selected_guard(root: &Path) -> Result<Option<Box<dyn RuntimeGuard>>> {
    let settings: serde_json::Value = match std::env::var("POSLE_JOB_SETTINGS") {
        Ok(snapshot) => {
            anyhow::ensure!(
                snapshot.len() <= 256 * 1024,
                "Speech job settings are too large"
            );
            serde_json::from_str(&snapshot)?
        }
        Err(std::env::VarError::NotUnicode(_)) => {
            anyhow::bail!("Speech job settings must be UTF-8")
        }
        Err(std::env::VarError::NotPresent) => {
            let path = root.join("settings.json");
            match std::fs::symlink_metadata(&path) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                Err(error) => return Err(error.into()),
                Ok(_) => {}
            }
            let mut file = crate::platform_fs::open_read(&path)?;
            let mut bytes = Vec::new();
            Read::by_ref(&mut file)
                .take(1024 * 1024 + 1)
                .read_to_end(&mut bytes)?;
            anyhow::ensure!(bytes.len() <= 1024 * 1024, "Speech settings are too large");
            serde_json::from_slice(&bytes)?
        }
    };
    anyhow::ensure!(settings.is_object(), "Speech settings must be an object");
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
    if crate::infrastructure::asr_model_store::is_managed_path(root, path)? {
        return Ok(Some(Box::new(verify_selected(root, path)?)));
    }
    Ok(None)
}
