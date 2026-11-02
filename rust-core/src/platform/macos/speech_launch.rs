//! Darwin helper/setup composition. Full CPython verification remains in the helper.
use crate::{
    application::speech_launch::{RuntimeGuard, SpeechLaunch},
    platform::apple_bundle::native_host_path,
};
use anyhow::{ensure, Result};
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
};
struct LegacyRuntime(PathBuf);
impl RuntimeGuard for LegacyRuntime {
    fn recheck(&self) -> Result<()> {
        ensure!(self.0.is_file(), "Сначала установите модели в настройках.");
        Ok(())
    }
}
pub(crate) fn worker(root: &Path, engine: &Path) -> Result<SpeechLaunch> {
    let interpreter = root.join("runtime/venv/bin/python");
    Ok(SpeechLaunch {
        executable: native_host_path(engine),
        arguments: vec![
            "--posle-python-host".into(),
            interpreter.clone().into_os_string(),
        ],
        guard: Some(Box::new(LegacyRuntime(interpreter))),
    })
}
pub(crate) fn setup(root: &Path, backend: &Path, engine: &Path) -> Result<SpeechLaunch> {
    Ok(SpeechLaunch {
        executable: "/bin/bash".into(),
        arguments: vec![
            OsString::from("-p"),
            backend.join("setup.sh").into_os_string(),
            root.as_os_str().to_owned(),
            native_host_path(engine).into_os_string(),
        ],
        guard: None,
    })
}
