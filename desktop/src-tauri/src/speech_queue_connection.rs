//! Native speech composition keeps verified resources alive through queue exit.
use crate::{
    models::HostError,
    native_queue_connection::{NativeQueueConnection, TIMEOUT},
    queue_budget::RequestBudget,
    speech_queue::{SpeechCommand, SpeechQueue, SpeechReply},
    speech_resources::VerifiedBackend,
};
use std::path::Path;

pub struct SpeechQueueConnection {
    connection: NativeQueueConnection,
    // Drop the process before releasing its source grant.
    backend: VerifiedBackend,
}
impl SpeechQueueConnection {
    pub(crate) fn open(
        engine: &Path,
        root: &Path,
        backend: VerifiedBackend,
    ) -> Result<Self, HostError> {
        backend.recheck()?;
        let command = crate::platform::speech_queue_command(engine, root, backend.directory())?;
        let connection = NativeQueueConnection::connect(command, TIMEOUT)?;
        // Ready follows the engine's complete receipt-only startup recovery.
        let owner = Self {
            connection,
            backend,
        };
        owner
            .backend
            .recheck()
            .inspect_err(|_| owner.connection.shutdown())?;
        Ok(owner)
    }
}
impl SpeechQueue for SpeechQueueConnection {
    fn execute_with_budget(
        &self,
        command: SpeechCommand,
        budget: &dyn RequestBudget,
    ) -> Result<SpeechReply, HostError> {
        if let Err(error) = self.backend.recheck() {
            self.connection.shutdown();
            return Err(error);
        }
        self.connection.execute(command, budget)
    }
    fn shutdown(&self) {
        self.connection.shutdown();
    }
}
