//! Composition of the native device adapter. Common lifecycle takes only a port.
use crate::capture_backend::{CaptureBackend, CaptureCapabilities, CaptureControl, CaptureRequest};
use std::sync::Arc;
#[cfg(windows)]
#[path = "capture/windows.rs"]
mod windows;

#[cfg(target_os = "linux")]
#[path = "capture/linux.rs"]
mod linux;

pub(crate) fn backend() -> Arc<dyn CaptureBackend> {
    #[cfg(windows)]
    {
        Arc::new(windows::WindowsCapture)
    }
    #[cfg(target_os = "linux")]
    {
        Arc::new(linux::LinuxMicrophone::new())
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Arc::new(UnavailableCapture)
    }
}
pub(crate) struct UnavailableCapture;
impl CaptureBackend for UnavailableCapture {
    fn capabilities(&self) -> CaptureCapabilities {
        CaptureCapabilities::NONE
    }
    fn record(&self, _: CaptureRequest<'_>, _: &mut dyn CaptureControl) -> Result<(), String> {
        Err("Recording is unavailable with the current capture backend.".into())
    }
}
