//! Explicit deployment workflow. Publication of each artifact is independent;
//! this never selects a model, changes settings or grants speech readiness.
use anyhow::Result;

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    Runtime,
    Model,
    Verify,
    Complete,
}
pub(crate) trait LocalSpeechInstallation {
    type Runtime;
    type Model;
    fn install_runtime(&mut self) -> Result<Self::Runtime>;
    fn install_model(&mut self) -> Result<Self::Model>;
    fn verify(&self, runtime: &Self::Runtime, model: &Self::Model) -> Result<()>;
}
pub(crate) fn install<P: LocalSpeechInstallation>(
    port: &mut P,
    mut report: impl FnMut(Stage),
) -> Result<(P::Runtime, P::Model)> {
    report(Stage::Runtime);
    let runtime = port.install_runtime()?;
    report(Stage::Model);
    let model = port.install_model()?;
    report(Stage::Verify);
    port.verify(&runtime, &model)?;
    report(Stage::Complete);
    Ok((runtime, model))
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::ensure;
    struct Port {
        fail: Option<Stage>,
        runtime_published: bool,
        model_published: bool,
    }
    impl LocalSpeechInstallation for Port {
        type Runtime = u32;
        type Model = u32;
        fn install_runtime(&mut self) -> Result<u32> {
            ensure!(self.fail != Some(Stage::Runtime), "runtime failure");
            self.runtime_published = true;
            Ok(10)
        }
        fn install_model(&mut self) -> Result<u32> {
            ensure!(self.runtime_published);
            ensure!(self.fail != Some(Stage::Model), "model failure");
            self.model_published = true;
            Ok(20)
        }
        fn verify(&self, runtime: &u32, model: &u32) -> Result<()> {
            ensure!((*runtime, *model) == (10, 20));
            ensure!(self.fail != Some(Stage::Verify), "verification failure");
            Ok(())
        }
    }
    #[test]
    fn failures_stop_progress_without_rolling_back_published_artifacts() {
        for (fail, expected, runtime, model) in [
            (Stage::Runtime, vec![Stage::Runtime], false, false),
            (
                Stage::Model,
                vec![Stage::Runtime, Stage::Model],
                true,
                false,
            ),
            (
                Stage::Verify,
                vec![Stage::Runtime, Stage::Model, Stage::Verify],
                true,
                true,
            ),
        ] {
            let mut port = Port {
                fail: Some(fail),
                runtime_published: false,
                model_published: false,
            };
            let mut stages = vec![];
            assert!(install(&mut port, |stage| stages.push(stage)).is_err());
            assert_eq!(stages, expected);
            assert_eq!(port.runtime_published, runtime);
            assert_eq!(port.model_published, model);
        }
    }
    #[test]
    fn completion_requires_verification_of_the_same_installation_receipts() {
        let mut port = Port {
            fail: None,
            runtime_published: false,
            model_published: false,
        };
        let mut stages = vec![];
        assert_eq!(
            install(&mut port, |stage| stages.push(stage)).unwrap(),
            (10, 20)
        );
        assert_eq!(
            stages,
            vec![Stage::Runtime, Stage::Model, Stage::Verify, Stage::Complete]
        );
    }
}
