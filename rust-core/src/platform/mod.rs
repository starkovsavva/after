//! Native runtime boundaries. The current application runtime is macOS-only;
//! this module does not make the Unix persistence/domain code Windows-ready.
//! Each future OS adapter must supply its own verified runtime policy and IPC.

#[cfg(target_os = "macos")]
mod macos;

#[cfg(target_os = "macos")]
pub use macos::{embedded_speech, python_runtime};
#[cfg(target_os = "macos")]
pub(crate) use macos::managed_embedding_transport;
#[cfg(target_os = "macos")]
pub(crate) use macos::filesystem::clone_model;

// clone_model is only a copy-on-write optimization: false selects the existing
// verified streamed-copy path, never successful installation by itself.
#[cfg(not(target_os = "macos"))]
pub(crate) fn clone_model(_source: &std::path::Path, _destination: &std::path::Path) -> bool {
    false
}
