//! Shared lazy native ownership for speech consumers. Reading UI state alone
//! does not open a session; a failed mutation is never automatically replayed.
use crate::{
    models::HostError,
    speech_queue::{SpeechCommand, SpeechQueue, SpeechReply},
};
use std::sync::{Arc, Mutex};
type Provider = dyn Fn() -> Result<Arc<dyn SpeechQueue>, HostError> + Send + Sync;
pub(crate) struct SpeechSession {
    provider: Box<Provider>,
    queue: Mutex<Option<Arc<dyn SpeechQueue>>>,
}
impl SpeechSession {
    pub fn new(
        provider: impl Fn() -> Result<Arc<dyn SpeechQueue>, HostError> + Send + Sync + 'static,
    ) -> Self {
        Self {
            provider: Box::new(provider),
            queue: Mutex::new(None),
        }
    }
    pub fn execute(&self, command: SpeechCommand) -> Result<SpeechReply, HostError> {
        let mut cached = self.queue.lock().map_err(|_| HostError::invalid())?;
        let queue = if let Some(queue) = &*cached {
            queue.clone()
        } else {
            let queue = (self.provider)()?;
            *cached = Some(queue.clone());
            queue
        };
        match queue.execute(command) {
            Ok(reply) => Ok(reply),
            Err(error) => {
                if matches!(
                    error.code.as_str(),
                    "engine_failure"
                        | "engine_timeout"
                        | "invalid_response"
                        | "speech_integrity"
                        | "speech_unavailable"
                ) {
                    queue.shutdown();
                    *cached = None;
                }
                Err(error)
            }
        }
    }
    pub fn invalidate(&self) {
        if let Some(queue) = self
            .queue
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take()
        {
            queue.shutdown();
        }
    }
}
