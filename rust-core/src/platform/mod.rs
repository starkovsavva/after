//! Native runtime composition. macOS owns embedded speech; Linux currently
//! supplies verified standalone CPython execution. Speech dependencies and full
//! ASR integration still require separate platform verification.
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

pub(crate) mod apple_bundle;
#[cfg(any(target_os = "macos", all(unix, test)))]
#[path = "macos/speech_launch.rs"]
pub(crate) mod macos_speech;

#[cfg(unix)]
pub(crate) fn speech_launch(root: &std::path::Path) -> anyhow::Result<crate::application::speech_launch::SpeechLaunch> {
    #[cfg(target_os = "macos")]
    { macos_speech::worker(root, &std::env::current_exe()?) }
    #[cfg(target_os = "linux")]
    { linux::speech_launch::worker(root) }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    { anyhow::bail!("Speech runtime is unavailable on this platform") }
}
#[cfg(unix)]
pub(crate) fn speech_setup(root: &std::path::Path, backend: &std::path::Path) -> anyhow::Result<crate::application::speech_launch::SpeechLaunch> {
    #[cfg(target_os = "macos")]
    { macos_speech::setup(root, backend, &std::env::current_exe()?) }
    #[cfg(not(target_os = "macos"))]
    { let _ = (root, backend); anyhow::bail!("Full speech/model setup is not connected on this platform yet. Linux CPU dependencies can be installed through the native runtime profile.") }
}
