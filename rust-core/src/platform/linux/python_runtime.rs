//! Pinned Linux CPython inventory boundary. This does not execute Python or
//! attest venv dependencies, native ABI compatibility, models or ASR readiness.
use crate::infrastructure::runtime_tree::{Layout, Policy, Tree};
use anyhow::{bail, Context, Result};
use std::{path::Path, sync::OnceLock};

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
fn policy() -> Result<&'static Policy> {
    static POLICY: OnceLock<std::result::Result<Policy, String>> = OnceLock::new();
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
fn policy() -> Result<&'static Policy> {
    bail!("No pinned CPython distribution is available for this Linux target.")
}

/// Used before executing even venv/ensurepip. Only the compiled inventory is a
/// trust root; an on-disk manifest cannot authorize different runtime contents.
pub fn verify_distribution(base: &Path) -> Result<()> {
    Tree::verify(base, policy()?, LAYOUT)
        .context("Linux CPython inventory verification failed")?
        .recheck()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[cfg(all(target_arch = "x86_64", target_env = "gnu"))]
    fn compiled_policy_pins_the_linux_layout_and_exact_version() {
        let policy = policy().unwrap();
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
