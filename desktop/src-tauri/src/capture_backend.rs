//! Device capture port. No driver selection, recorder state or OS SDK lives here.
use serde::{Deserialize, Serialize};
use std::{path::Path, time::Duration};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CaptureMode {
    Microphone,
    MicrophoneAndSystem,
}
impl CaptureMode {
    pub fn parse(value: &str) -> Result<Self, String> {
        match value {
            "microphone" => Ok(Self::Microphone),
            "microphone_and_system" => Ok(Self::MicrophoneAndSystem),
            _ => Err("Invalid recording mode.".into()),
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Microphone => "microphone",
            Self::MicrophoneAndSystem => "microphone_and_system",
        }
    }
}
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct CaptureCapabilities {
    pub microphone: bool,
    pub system_audio: bool,
}
impl CaptureCapabilities {
    pub const NONE: Self = Self {
        microphone: false,
        system_audio: false,
    };
    pub const MICROPHONE: Self = Self {
        microphone: true,
        system_audio: false,
    };
    pub const MICROPHONE_AND_SYSTEM: Self = Self {
        microphone: true,
        system_audio: true,
    };
    pub fn supports(self, mode: CaptureMode) -> bool {
        self.microphone && (mode == CaptureMode::Microphone || self.system_audio)
    }
    pub fn modes(self) -> Vec<CaptureMode> {
        [CaptureMode::MicrophoneAndSystem, CaptureMode::Microphone]
            .into_iter()
            .filter(|mode| self.supports(*mode))
            .collect()
    }
}
pub(crate) struct CaptureRequest<'a> {
    /// Private, session-leased destination selected by the host.
    pub destination: &'a Path,
    pub mode: CaptureMode,
}
pub(crate) trait CaptureControl {
    /// Emit once, after streams and the recoverable output are ready.
    fn started(&mut self) -> Result<(), String>;
    /// Owner disappearance also requests stop. Backend must finish pending audio.
    fn wait_for_stop(&self, timeout: Duration) -> bool;
}
pub(crate) trait CaptureBackend: Send + Sync {
    fn capabilities(&self) -> CaptureCapabilities;
    /// Own device/clock/mixer cleanup until return, including a stop during init.
    fn record(
        &self,
        request: CaptureRequest<'_>,
        control: &mut dyn CaptureControl,
    ) -> Result<(), String>;
}
