//! Managed-model verification and protected settings commit adapter.
use crate::application::speech_selection::{SelectionPort, Settings};
use anyhow::Result;
use serde_json::Value;
use std::path::Path;
pub(crate) struct Selection {
    store: super::settings_store::Store,
}
impl Selection {
    pub fn candidate(&self) -> Result<Option<crate::domain::asr_models::InstalledAsrModel>> {
        self.store.snapshot()?;
        super::asr_model_store::candidate(self.store.root())
    }
    pub fn new(root: &Path) -> Result<Self> {
        Ok(Self {
            store: super::settings_store::Store::open(root)?,
        })
    }
}
impl SelectionPort for Selection {
    type Guard = super::asr_model_store::VerifiedModel;
    fn settings(&self) -> Result<Settings> {
        let snapshot = self.store.snapshot()?;
        Ok(Settings {
            value: snapshot.value,
            revision: snapshot.revision,
        })
    }
    fn model(&self, generation: &str) -> Result<(String, Self::Guard)> {
        let (path, guard) =
            super::asr_model_store::verified_generation(self.store.root(), generation)?;
        Ok((
            path.into_os_string()
                .into_string()
                .map_err(|_| anyhow::anyhow!("Model path must be UTF-8"))?,
            guard,
        ))
    }
    fn commit(&self, expected: &str, value: &Value, guard: &Self::Guard) -> Result<String> {
        self.store
            .compare_replace(expected, value, || guard.recheck())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selection_keeps_the_observed_root_identity_across_port_calls() {
        let fixture = tempfile::tempdir().unwrap();
        let root = fixture.path().join("library");
        let selection = Selection::new(&root).unwrap();
        let before = selection.settings().unwrap();
        std::fs::rename(&root, fixture.path().join("held-library")).unwrap();
        crate::platform_fs::private_directory(&root).unwrap();
        crate::storage::atomic_json(&root.join("settings.json"), &before.value).unwrap();
        assert!(selection.settings().is_err());
        assert_eq!(
            crate::storage::regular_json(&root.join("settings.json")).unwrap(),
            before.value
        );
    }
}
