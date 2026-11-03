//! Native composition for explicit local speech deployment. No settings write,
//! implicit model selection, inference, automatic startup work or readiness grant.
pub use crate::application::local_speech_install::Stage;

#[cfg(target_os = "linux")]
mod linux {
    use crate::{
        application::local_speech_install::{self, LocalSpeechInstallation},
        asr_model::{self, InstalledAsrModel},
        python_runtime::{self, InstalledRuntime},
    };
    use anyhow::{ensure, Result};
    use std::path::Path;
    struct Installation<'a> {
        root: &'a Path,
        python_archive: Option<&'a Path>,
        model_archive: Option<&'a Path>,
        wheelhouse: Option<&'a Path>,
    }
    impl LocalSpeechInstallation for Installation<'_> {
        type Runtime = InstalledRuntime;
        type Model = InstalledAsrModel;
        fn install_runtime(&mut self) -> Result<InstalledRuntime> {
            python_runtime::install_cpu(self.root, self.python_archive, self.wheelhouse)
        }
        fn install_model(&mut self) -> Result<InstalledAsrModel> {
            asr_model::install(self.root, self.model_archive)
        }
        fn verify(&self, runtime: &InstalledRuntime, model: &InstalledAsrModel) -> Result<()> {
            let selected = python_runtime::validate_active(self.root)?;
            ensure!(
                selected.installation().generation == runtime.generation,
                "Runtime activation changed during local speech installation"
            );
            let model_guard = asr_model::verify_selected(self.root, Path::new(&model.directory))?;
            selected.recheck()?;
            model_guard.recheck()
        }
    }
    /// Archive/cache inputs are native-only. Missing archives explicitly select
    /// the compiled artifact URLs; adapters verify their pinned inventories.
    pub fn install_cpu(
        root: &Path,
        python_archive: Option<&Path>,
        model_archive: Option<&Path>,
        wheelhouse: Option<&Path>,
        report: impl FnMut(super::Stage),
    ) -> Result<(InstalledRuntime, InstalledAsrModel)> {
        local_speech_install::install(
            &mut Installation {
                root,
                python_archive,
                model_archive,
                wheelhouse,
            },
            report,
        )
    }
}
#[cfg(target_os = "linux")]
pub use linux::install_cpu;
