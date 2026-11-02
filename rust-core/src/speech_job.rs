//! Native local speech execution facade; never a renderer metadata command.
pub use crate::application::speech_execution::{SpeechReceipt, SpeechWork};
use crate::application::{
    speech_execution::{self, SpeechInference},
    speech_launch::SpeechSettings,
};
use anyhow::Result;
use std::path::Path;
struct Worker<'a> {
    root: &'a Path,
    backend: &'a Path,
}
impl SpeechInference for Worker<'_> {
    fn transcribe(&self, directory: &Path, settings: SpeechSettings) -> Result<()> {
        crate::worker::run_worker_selected(
            self.root,
            self.backend,
            "transcribe",
            Some(directory),
            0,
            false,
            settings,
        )
    }
}
pub fn inspect(root: &Path, meeting: &str) -> Result<String> {
    crate::infrastructure::runtime_tree::absolute(root)?;
    let _root = crate::infrastructure::runtime_tree::open(root, true)?;
    crate::infrastructure::speech_publication::Publication { root }.inspect(meeting)
}
pub fn execute(root: &Path, backend: &Path, work: &SpeechWork) -> Result<SpeechReceipt> {
    crate::infrastructure::runtime_tree::absolute(root)?;
    let _root = crate::infrastructure::runtime_tree::open(root, true)?;
    speech_execution::execute(
        &crate::infrastructure::speech_publication::Publication { root },
        &Worker { root, backend },
        work,
    )
}
