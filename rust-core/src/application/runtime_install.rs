//! Runtime preparation order; filesystem, network, processes and publication
//! belong to an adapter. A failed candidate must never replace the active one.
use anyhow::Result;

pub(crate) trait RuntimeInstallation {
    /// Owns cleanup of unactivated state; retain data after uncertain publication.
    type Candidate;
    type Installed;
    fn stage(&mut self) -> Result<Self::Candidate>;
    fn verify_distribution(&mut self, candidate: &Self::Candidate) -> Result<()>;
    fn prepare_environment(&mut self, candidate: &Self::Candidate) -> Result<()>;
    fn verify_environment(&mut self, candidate: &Self::Candidate) -> Result<()>;
    /// Publish only a fully verified generation. Keep both generations if the
    /// acknowledgement becomes uncertain after publication; never delete active data.
    fn activate(&mut self, candidate: &mut Self::Candidate) -> Result<Self::Installed>;
}

pub(crate) fn install<P: RuntimeInstallation>(ports: &mut P) -> Result<P::Installed> {
    let mut candidate = ports.stage()?;
    ports.verify_distribution(&candidate)?;
    ports.prepare_environment(&candidate)?;
    ports.verify_environment(&candidate)?;
    ports.activate(&mut candidate)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Ports {
        calls: Vec<&'static str>,
        fail: &'static str,
        active: &'static str,
    }
    impl Ports {
        fn step(&mut self, name: &'static str) -> Result<()> {
            self.calls.push(name);
            anyhow::ensure!(self.fail != name, "injected failure");
            Ok(())
        }
    }
    impl RuntimeInstallation for Ports {
        type Candidate = ();
        type Installed = ();
        fn stage(&mut self) -> Result<()> {
            self.step("stage")
        }
        fn verify_distribution(&mut self, _: &()) -> Result<()> {
            self.step("distribution")
        }
        fn prepare_environment(&mut self, _: &()) -> Result<()> {
            self.step("prepare")
        }
        fn verify_environment(&mut self, _: &()) -> Result<()> {
            self.step("environment")
        }
        fn activate(&mut self, _: &mut ()) -> Result<()> {
            self.step("activate")?;
            self.active = "new";
            Ok(())
        }
    }
    #[test]
    fn every_preparation_failure_preserves_the_active_generation() {
        for fail in [
            "stage",
            "distribution",
            "prepare",
            "environment",
            "activate",
        ] {
            let mut ports = Ports {
                calls: vec![],
                fail,
                active: "previous",
            };
            assert!(install(&mut ports).is_err());
            assert_eq!(ports.active, "previous");
            assert_eq!(ports.calls.last(), Some(&fail));
        }
        let mut ports = Ports {
            calls: vec![],
            fail: "",
            active: "previous",
        };
        install(&mut ports).unwrap();
        assert_eq!(ports.active, "new");
        assert_eq!(
            ports.calls,
            [
                "stage",
                "distribution",
                "prepare",
                "environment",
                "activate"
            ]
        );
    }
}
