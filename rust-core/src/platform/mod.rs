//! Native runtime composition. macOS owns embedded speech; Linux currently
//! supplies pinned CPython inventory verification, not an execution/ASR adapter.
//! Each OS must supply its own verified distribution, loading and execution path.

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

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::python_runtime;
