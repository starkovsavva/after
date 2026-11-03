//! Progress port shared by native speech operations, independent of job policy.
use anyhow::Result;
pub(crate) trait SpeechObserver { fn checkpoint(&mut self, fraction: Option<f64>) -> Result<()>; }
