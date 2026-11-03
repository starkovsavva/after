//! Native speech publication. Inference never writes the canonical meeting.
use super::speech_launch::SpeechSettings;
use anyhow::Result;
pub use super::speech_work::{SpeechWork,SpeechReceipt};
use std::path::Path;

pub(crate) trait SpeechPublication {
    type Stage;
    fn committed(&self, work: &SpeechWork) -> Result<bool>;
    fn stage(&self, work: &SpeechWork) -> Result<Self::Stage>;
    fn directory(stage: &Self::Stage) -> &Path;
    /// Recheck input and outputs under the canonical meeting lock, then publish
    /// result and receipt together. Unknown outcomes must remain recoverable.
    fn publish(&self, work: &SpeechWork, stage: &Self::Stage) -> Result<SpeechReceipt>;
}
pub(crate) trait SpeechInference {
    fn transcribe(&self, directory: &Path, settings: SpeechSettings) -> Result<()>;
}
pub(crate) fn execute<P: SpeechPublication>(
    publication: &P,
    worker: &dyn SpeechInference,
    work: &SpeechWork,
) -> Result<SpeechReceipt> {
    let settings = work.validate()?;
    if publication.committed(work)? {
        return Ok(SpeechReceipt::for_work(work));
    }
    let result = (|| {
        let stage = publication.stage(work)?;
        worker.transcribe(P::directory(&stage), settings)?;
        publication.publish(work, &stage)
    })();
    match result {
        Ok(receipt) => Ok(receipt),
        Err(error) => {
            // A lost acknowledgement or a concurrent completion must never
            // turn an exact committed operation into a retry invitation.
            if publication.committed(work)? {
                Ok(SpeechReceipt::for_work(work))
            } else {
                Err(error)
            }
        }
    }
}
