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
