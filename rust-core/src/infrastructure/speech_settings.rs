//! Capture settings once; filesystem/environment selection stays out of policy.
use crate::application::speech_launch::SpeechSettings;
use anyhow::Result;
use std::{io::Read, path::Path};

pub(crate) fn capture(root: &Path) -> Result<SpeechSettings> {
    match std::env::var("POSLE_JOB_SETTINGS") {
        Ok(snapshot) => return SpeechSettings::parse(snapshot.as_bytes()),
        Err(std::env::VarError::NotUnicode(_)) => {
            anyhow::bail!("Speech job settings must be UTF-8")
        }
        Err(std::env::VarError::NotPresent) => {}
    }
    let path = root.join("settings.json");
    match std::fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return SpeechSettings::parse(b"{}")
        }
        Err(error) => return Err(error.into()),
        Ok(_) => {}
    }
    let file = crate::platform_fs::open_read(&path)?;
    let mut bytes = Vec::new();
    file.take(256 * 1024 + 1).read_to_end(&mut bytes)?;
    SpeechSettings::parse(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn captured_selection_survives_settings_replacement_and_rejects_aliases() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("settings.json");
        std::fs::write(
            &path,
            br#"{"speechMode":"local","asrModelPath":"/selected/model"}"#,
        )
        .unwrap();
        let selected = capture(root.path()).unwrap();
        std::fs::write(&path, br#"{"speechMode":"cloud"}"#).unwrap();
        assert!(!selected.cloud());
        assert_eq!(selected.value()["asrModelPath"], "/selected/model");
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(selected.encoded()).unwrap(),
            *selected.value()
        );
        std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(root.path().join("missing"), &path).unwrap();
        assert!(capture(root.path()).is_err());
    }
}
