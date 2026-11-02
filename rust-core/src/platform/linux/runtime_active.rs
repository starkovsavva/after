//! Select one verified generation. Atomic replacement of active.json affects
//! later selections, never an already retained generation. No package attestation.
use super::{
    python_runtime::{artifact, verified_tree},
    runtime_install::InstalledRuntime,
};
use crate::infrastructure::{
    runtime_tree::{absolute, open, secure, stamp, Tree},
    runtime_venv::VenvBinding,
};
use anyhow::{ensure, Context, Result};
use std::{
    fs::{self, File},
    io::Read,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

struct DirectoryIdentity {
    path: PathBuf,
    file: File,
}
impl DirectoryIdentity {
    fn pin(path: PathBuf) -> Result<Self> {
        Ok(Self {
            file: open(&path, true)?,
            path,
        })
    }
    fn recheck(&self) -> Result<()> {
        let held = self.file.metadata()?;
        let current = fs::symlink_metadata(&self.path)?;
        secure(&current)?;
        ensure!(
            current.is_dir() && current.dev() == held.dev() && current.ino() == held.ino(),
            "Selected runtime directory changed"
        );
        Ok(())
    }
}
pub struct VerifiedRuntime {
    installed: InstalledRuntime,
    directories: Vec<DirectoryIdentity>,
    tree: Tree,
    venv: VenvBinding,
}
impl VerifiedRuntime {
    pub fn installation(&self) -> &InstalledRuntime {
        &self.installed
    }
    pub fn interpreter(&self) -> &Path {
        &self.installed.interpreter
    }
    /// Call immediately before execution while retaining this guard through
    /// process ownership. A new active pointer does not invalidate this one.
    pub fn recheck(&self) -> Result<()> {
        for directory in &self.directories {
            directory.recheck()?;
        }
        self.tree.recheck()?;
        self.venv.recheck()
    }
}
fn validate_receipt(installed: &InstalledRuntime, scope: &Path) -> Result<PathBuf> {
    let id = uuid::Uuid::parse_str(&installed.generation).context("Invalid runtime generation")?;
    ensure!(
        id.get_version_num() == 4 && id.to_string() == installed.generation,
        "Invalid runtime generation"
    );
    ensure!(
        installed.schema_version == 1
            && installed.target == "x86_64-unknown-linux-gnu"
            && installed.version == artifact()?.policy.version,
        "Runtime target or version mismatch"
    );
    let directory = scope.join(&installed.generation);
    ensure!(
        installed.interpreter == directory.join("venv/bin/python"),
        "Active interpreter is outside the selected generation"
    );
    Ok(directory)
}

pub fn validate_active(root: &Path) -> Result<VerifiedRuntime> {
    artifact()?;
    absolute(root)?;
    let _root = open(root, true)?;
    let root = root.canonicalize()?;
    let scope = root.join("runtime/linux-python");
    let mut directories = Vec::new();
    for path in [&root, &root.join("runtime"), &scope] {
        directories.push(DirectoryIdentity::pin(path.to_owned())?);
    }
    let mut active =
        open(&scope.join("active.json"), false).context("No active Linux Python runtime")?;
    let before = active.metadata()?;
    ensure!(
        before.nlink() == 1 && before.len() <= 8192,
        "Invalid active runtime record"
    );
    let mut bytes = Vec::new();
    Read::by_ref(&mut active)
        .take(8193)
        .read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= 8192 && stamp(&before) == stamp(&active.metadata()?),
        "Active runtime changed while reading"
    );
    let installed: InstalledRuntime =
        serde_json::from_slice(&bytes).context("Invalid active runtime record")?;
    let generation = validate_receipt(&installed, &scope)?;
    directories.push(DirectoryIdentity::pin(generation.clone())?);
    let base = generation.join("python");
    let tree = verified_tree(&base)?;
    let venv = VenvBinding::verify(&generation.join("venv"), &base, &artifact()?.policy.version)?;
    let runtime = VerifiedRuntime {
        installed,
        directories,
        tree,
        venv,
    };
    runtime.recheck()?;
    Ok(runtime)
}

#[cfg(all(test, target_arch = "x86_64", target_env = "gnu"))]
mod tests {
    use super::*;
    fn receipt(scope: &Path) -> InstalledRuntime {
        let generation = uuid::Uuid::new_v4().to_string();
        InstalledRuntime {
            schema_version: 1,
            target: "x86_64-unknown-linux-gnu".into(),
            version: artifact().unwrap().policy.version.clone(),
            interpreter: scope.join(&generation).join("venv/bin/python"),
            generation,
        }
    }
    #[test]
    fn receipt_cannot_redirect_selection_or_cross_target_and_version_boundaries() {
        let root = tempfile::tempdir().unwrap();
        let valid = receipt(root.path());
        assert!(validate_receipt(&valid, root.path()).is_ok());
        for change in 0..5 {
            let mut invalid = valid.clone();
            match change {
                0 => invalid.generation = "../outside".into(),
                1 => invalid.interpreter = PathBuf::from("/usr/bin/python3"),
                2 => invalid.target = "aarch64-apple-darwin".into(),
                3 => invalid.version = "3.12.15".into(),
                _ => invalid.schema_version = 2,
            }
            assert!(validate_receipt(&invalid, root.path()).is_err());
        }
    }
    #[test]
    fn directory_identity_allows_pointer_updates_but_rejects_directory_replacement() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("scope");
        fs::create_dir(&path).unwrap();
        let pinned = DirectoryIdentity::pin(path.clone()).unwrap();
        fs::write(path.join("pending"), b"new selection").unwrap();
        fs::rename(path.join("pending"), path.join("active.json")).unwrap();
        pinned.recheck().unwrap();
        fs::rename(&path, root.path().join("moved")).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(pinned.recheck().is_err());
    }
    #[test]
    fn linked_and_oversized_active_records_cannot_select_an_interpreter() {
        let root = tempfile::tempdir().unwrap();
        let scope = root.path().join("runtime/linux-python");
        fs::create_dir_all(&scope).unwrap();
        let outside = tempfile::NamedTempFile::new().unwrap();
        let active = scope.join("active.json");
        std::os::unix::fs::symlink(outside.path(), &active).unwrap();
        assert!(validate_active(root.path()).is_err());
        fs::remove_file(&active).unwrap();
        fs::hard_link(outside.path(), &active).unwrap();
        assert!(validate_active(root.path()).is_err());
        fs::remove_file(&active).unwrap();
        fs::write(&active, vec![b' '; 8193]).unwrap();
        assert!(validate_active(root.path()).is_err());
    }
}

#[cfg(all(
    test,
    feature = "linux-runtime-fixture",
    target_arch = "x86_64",
    target_env = "gnu"
))]
mod real_fixture {
    use super::*;
    #[test]
    fn selected_generation_survives_atomic_activation_of_a_different_generation() {
        let root = PathBuf::from(
            std::env::var_os("AFTER_TEST_ACTIVE_RUNTIME_ROOT")
                .expect("Run scripts/check-linux-python-runtime.py"),
        );
        let fixture = root.parent().unwrap();
        assert!(fixture.join("runtime-fixture-only").is_file());
        let selected = validate_active(&root).unwrap();
        let original_id = selected.installation().generation.clone();
        let active = root.join("runtime/linux-python/active.json");
        struct Restore {
            path: PathBuf,
            bytes: Vec<u8>,
        }
        impl Drop for Restore {
            fn drop(&mut self) {
                fs::write(&self.path, &self.bytes).unwrap();
            }
        }
        let _restore = Restore {
            path: active.clone(),
            bytes: fs::read(&active).unwrap(),
        };
        let replacement = fixture.join("first-runtime-receipt.json");
        let pending = active.with_file_name("test-activation.json");
        fs::write(&pending, fs::read(replacement).unwrap()).unwrap();
        fs::rename(&pending, &active).unwrap();
        let next = validate_active(&root).unwrap();
        assert_ne!(next.installation().generation, original_id);
        selected.recheck().unwrap();
        assert_eq!(selected.installation().generation, original_id);
        assert!(selected.interpreter().is_file());
    }
}
