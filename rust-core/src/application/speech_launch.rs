//! Native launch contract; shared supervision owns the guard through child exit.
use anyhow::Result;
use std::{ffi::OsString, fmt, path::PathBuf};

pub(crate) trait RuntimeGuard: Send + Sync {
    fn recheck(&self) -> Result<()>;
}
impl fmt::Debug for dyn RuntimeGuard {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("RuntimeGuard")
    }
}
#[derive(Debug)]
pub(crate) struct SpeechLaunch {
    pub executable: PathBuf,
    pub arguments: Vec<OsString>,
    pub guard: Option<Box<dyn RuntimeGuard>>,
}

#[derive(Debug)]
pub(crate) struct RuntimeGuards(pub Vec<Box<dyn RuntimeGuard>>);
impl RuntimeGuard for RuntimeGuards {
    fn recheck(&self) -> Result<()> {
        for guard in &self.0 {
            guard.recheck()?;
        }
        Ok(())
    }
}

/// One immutable settings selection for authorization, model guards and backend.
pub(crate) struct SpeechSettings {
    value: serde_json::Value,
    encoded: String,
}
impl fmt::Debug for SpeechSettings {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SpeechSettings")
    }
}
impl SpeechSettings {
    pub(crate) fn parse(raw: &[u8]) -> Result<Self> {
        anyhow::ensure!(raw.len() <= 256 * 1024, "Speech job settings are too large");
        let value: serde_json::Value = serde_json::from_slice(raw)?;
        anyhow::ensure!(value.is_object(), "Speech settings must be an object");
        let encoded = serde_json::to_string(&value)?;
        anyhow::ensure!(
            encoded.len() <= 256 * 1024,
            "Speech job settings are too large"
        );
        Ok(Self { value, encoded })
    }
    pub(crate) fn value(&self) -> &serde_json::Value {
        &self.value
    }
    pub(crate) fn encoded(&self) -> &str {
        &self.encoded
    }
    pub(crate) fn cloud(&self) -> bool {
        self.value["speechMode"].as_str() == Some("cloud")
    }
}
