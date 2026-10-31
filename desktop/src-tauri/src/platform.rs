//! Native adapters selected by the host, never by renderer input.
use std::path::PathBuf;

pub(crate) fn choose_media_file() -> Option<PathBuf> {
    rfd::FileDialog::new()
        .add_filter(
            "Audio and video",
            &[
                "mp4", "mov", "m4a", "mp3", "wav", "aiff", "aif", "caf", "flac", "ogg", "webm",
                "mkv", "aac",
            ],
        )
        .pick_file()
}

/// Explicit debug diagnostics; disabled in release and during ordinary use.
pub(crate) fn configure_diagnostics(window: &tauri::WebviewWindow) {
    #[cfg(all(debug_assertions, target_os = "linux"))]
    if std::env::var_os("AFTER_WEBVIEW_DIAGNOSTICS").as_deref() == Some(std::ffi::OsStr::new("1")) {
        let _ = window.with_webview(|webview| {
            use webkit2gtk::{SettingsExt, WebViewExt};
            if let Some(settings) = webview.inner().settings() {
                settings.set_enable_write_console_messages_to_stdout(true);
            }
        });
    }
    let _ = window;
}

pub(crate) fn report_error(error: &crate::models::HostError) {
    #[cfg(debug_assertions)]
    if std::env::var_os("AFTER_WEBVIEW_DIAGNOSTICS").as_deref() == Some(std::ffi::OsStr::new("1")) {
        eprintln!("Desktop operation failed: {}", error.code);
    }
    let _ = error;
}

/// Tauri recognises directories literally named `target`; custom Cargo output
/// directories need the same adjacent-resource resolution in development.
pub(crate) fn resource_dir(packaged: PathBuf) -> PathBuf {
    #[cfg(all(debug_assertions, target_os = "linux"))]
    if let Ok(executable) = std::env::current_exe() {
        if let Some(directory) = executable.parent() {
            return debug_resource_dir(packaged, directory);
        }
    }
    packaged
}

#[cfg(all(debug_assertions, target_os = "linux"))]
fn debug_resource_dir(packaged: PathBuf, directory: &std::path::Path) -> PathBuf {
    if !packaged
        .join("engine")
        .join(env!("AFTER_ENGINE_NAME"))
        .is_file()
        && directory.join(".cargo-lock").is_file()
        && std::fs::symlink_metadata(directory.join("engine").join(env!("AFTER_ENGINE_NAME")))
            .is_ok_and(|m| m.is_file() && !m.file_type().is_symlink())
    {
        directory.to_owned()
    } else {
        packaged
    }
}

#[cfg(all(test, debug_assertions, target_os = "linux"))]
mod tests {
    use super::*;
    #[test]
    fn custom_cargo_output_uses_adjacent_engine_without_overriding_packaged_resources() {
        let fixture = tempfile::tempdir().unwrap();
        let output = fixture.path().join("custom-build/debug");
        let packaged = fixture.path().join("system-resources");
        std::fs::create_dir_all(output.join("engine")).unwrap();
        std::fs::write(
            output.join("engine").join(env!("AFTER_ENGINE_NAME")),
            b"fixture",
        )
        .unwrap();
        assert_eq!(debug_resource_dir(packaged.clone(), &output), packaged);
        std::fs::write(output.join(".cargo-lock"), b"").unwrap();
        assert_eq!(debug_resource_dir(packaged.clone(), &output), output);
        std::fs::create_dir_all(packaged.join("engine")).unwrap();
        std::fs::write(
            packaged.join("engine").join(env!("AFTER_ENGINE_NAME")),
            b"packaged",
        )
        .unwrap();
        assert_eq!(debug_resource_dir(packaged.clone(), &output), packaged);
    }
}
