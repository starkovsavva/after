//! Managed model preparation/publish order, independent of OS and model SDK.
use anyhow::Result;
pub(crate) trait ModelInstallation {
    type Candidate;
    type Installed;
    fn stage(&mut self) -> Result<Self::Candidate>;
    fn verify(&mut self, candidate: &Self::Candidate) -> Result<()>;
    fn activate(&mut self, candidate: &mut Self::Candidate) -> Result<Self::Installed>;
}
pub(crate) fn install<P: ModelInstallation>(ports: &mut P) -> Result<P::Installed> {
    let mut candidate = ports.stage()?;
    ports.verify(&candidate)?;
    ports.activate(&mut candidate)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Ports {
        fail: &'static str,
        calls: Vec<&'static str>,
        published: bool,
    }
    impl Ports {
        fn step(&mut self, name: &'static str) -> Result<()> {
            self.calls.push(name);
            anyhow::ensure!(name != self.fail, "failure");
            Ok(())
        }
    }
    impl ModelInstallation for Ports {
        type Candidate = ();
        type Installed = ();
        fn stage(&mut self) -> Result<()> {
            self.step("stage")
        }
        fn verify(&mut self, _: &()) -> Result<()> {
            self.step("verify")
        }
        fn activate(&mut self, _: &mut ()) -> Result<()> {
            self.step("activate")?;
            self.published = true;
            Ok(())
        }
    }
    #[test]
    fn unverified_or_failed_candidates_cannot_be_published() {
        for fail in ["stage", "verify", "activate"] {
            let mut ports = Ports {
                fail,
                calls: vec![],
                published: false,
            };
            assert!(install(&mut ports).is_err());
            assert!(!ports.published);
            assert_eq!(ports.calls.last(), Some(&fail));
        }
        let mut ports = Ports {
            fail: "",
            calls: vec![],
            published: false,
        };
        install(&mut ports).unwrap();
        assert!(ports.published);
        assert_eq!(ports.calls, ["stage", "verify", "activate"]);
    }
}
