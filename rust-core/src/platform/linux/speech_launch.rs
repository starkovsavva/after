//! Verified standalone CPython execution; no Darwin PyConfig or helper naming.
use super::python_runtime::{validate_active, VerifiedRuntime};
use crate::application::speech_launch::{RuntimeGuard, SpeechLaunch};
use anyhow::Result;
use std::path::Path;
impl RuntimeGuard for VerifiedRuntime {
    fn recheck(&self) -> Result<()> {
        VerifiedRuntime::recheck(self)
    }
}
pub(crate) fn worker(root: &Path) -> Result<SpeechLaunch> {
    let runtime = validate_active(root)?;
    Ok(SpeechLaunch {
        executable: runtime.interpreter().to_owned(),
        arguments: ["-B", "-u", "-E", "-s"]
            .into_iter()
            .map(Into::into)
            .collect(),
        guard: Some(Box::new(runtime)),
    })
}
