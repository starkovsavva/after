//! Pinned Linux CPython composition and generation installation. This does not
//! attest third-party packages, embedded ABI compatibility, models or ASR readiness.
pub use super::runtime_active::{validate_active, VerifiedRuntime};
pub use super::runtime_install::{install, install_cpu, InstalledRuntime};
use crate::infrastructure::runtime_tree::{Layout, Policy, Tree};
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::{path::Path, sync::OnceLock};

#[derive(Deserialize)]
pub(super) struct Artifact {
    #[serde(flatten)]
    pub policy: Policy,
    pub archive_url: String,
    pub archive_sha256: String,
    pub archive_size: u64,
}

pub const CHECK_MODE: &str = "--posle-check-python-runtime";
pub const INSTALL_MODE: &str = "--posle-install-python-runtime";
pub const VERIFY_MODE: &str = "--posle-verify-python-runtime";
const LAYOUT: Layout<'static> = Layout {
    required_files: &[
        "bin/python3.12",
        "lib/libpython3.12.so.1.0",
        "lib/python3.12/encodings/__init__.py",
    ],
    library: "lib/libpython3.12.so.1.0",
};

#[cfg(all(target_arch = "x86_64", target_env = "gnu"))]
pub(super) fn artifact() -> Result<&'static Artifact> {
    static POLICY: OnceLock<std::result::Result<Artifact, String>> = OnceLock::new();
    match POLICY.get_or_init(|| {
        serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../backend/python-runtime-linux-x86_64.json"
        )))
        .map_err(|_| "Invalid compiled Linux CPython inventory".to_owned())
    }) {
        Ok(policy) => Ok(policy),
        Err(error) => bail!("{error}"),
    }
}
#[cfg(not(all(target_arch = "x86_64", target_env = "gnu")))]
pub(super) fn artifact() -> Result<&'static Artifact> {
    bail!("No pinned CPython distribution is available for this Linux target.")
}

/// Used before executing even venv/ensurepip. Only the compiled inventory is a
/// trust root; an on-disk manifest cannot authorize different runtime contents.
pub fn verify_distribution(base: &Path) -> Result<()> {
    verified_tree(base)?.recheck()
}

pub(super) fn verified_tree(base: &Path) -> Result<Tree> {
    Tree::verify(base, &artifact()?.policy, LAYOUT)
        .context("Linux CPython inventory verification failed")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[cfg(all(target_arch = "x86_64", target_env = "gnu"))]
    fn compiled_policy_pins_the_linux_layout_and_exact_version() {
        let policy = &artifact().unwrap().policy;
        assert_eq!(policy.version, "3.12.16");
        assert_eq!(
            policy.directory,
            "cpython-3.12.16+20261026-x86_64-unknown-linux-gnu"
        );
        for required in LAYOUT.required_files {
            assert!(policy.files.iter().any(|file| file.path == *required));
        }
        assert!(policy.files.len() > 1000);
        assert!(!policy
            .files
            .iter()
            .any(|file| file.path.ends_with(".dylib")));
    }
    #[test]
    fn an_untrusted_or_incomplete_runtime_never_passes() {
        let root = tempfile::tempdir().unwrap();
        assert!(verify_distribution(root.path()).is_err());
        std::fs::write(root.path().join("python-runtime.json"), b"{}").unwrap();
        assert!(verify_distribution(root.path()).is_err());
        assert!(verify_distribution(Path::new("relative")).is_err());
    }
}
