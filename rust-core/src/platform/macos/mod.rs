//! Darwin implementations selected only by platform/mod.rs.
//! python_host.rs is included separately by the executable: its initialization
//! must run before worker threads and never belongs to the app's in-process host.

pub mod embedded_speech;
pub mod python_runtime;
pub(crate) mod managed_embedding_transport;
pub(super) mod filesystem;
