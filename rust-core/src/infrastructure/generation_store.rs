//! Unix immutable-generation publication shared by runtime and model adapters.
//! No artifact selection, parsing, Python or ASR policy lives here.
use crate::infrastructure::runtime_tree::{absolute, open, relative};
use anyhow::{ensure, Context, Result};
use serde::Serialize;
use std::{
    fs::{self, File},
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
};
pub(crate) struct Candidate {
    pub(crate) directory: PathBuf,
    preserve: bool,
    pinned: File,
}
impl Candidate {
    pub(crate) fn recheck(&self) -> Result<()> {
        let held = self.pinned.metadata()?;
        let actual = fs::symlink_metadata(&self.directory)?;
        ensure!(
            actual.is_dir() && actual.dev() == held.dev() && actual.ino() == held.ino(),
            "Runtime candidate directory changed"
        );
        Ok(())
    }
}
impl Drop for Candidate {
    fn drop(&mut self) {
        if !self.preserve && self.recheck().is_ok() {
            let _ = remove_candidate(&self.directory);
        }
    }
}
fn remove_candidate(path: &Path) -> Result<()> {
    // Never follow venv aliases or distribution symlinks during cleanup.
    let directory = open(path, true)?;
    directory.set_permissions(fs::Permissions::from_mode(
        directory.metadata()?.mode() | 0o700,
    ))?;
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            remove_candidate(&entry.path())?;
        } else {
            fs::remove_file(entry.path())?;
        }
    }
    fs::remove_dir(path)?;
    Ok(())
}
pub(crate) fn owned_directory(path: &Path) -> Result<File> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::DirBuilder::new().mode(0o700).create(path)?;
        }
        Err(error) => return Err(error.into()),
        Ok(_) => {}
    }
    open(path, true)
}

pub(crate) struct GenerationStore {
    pub(crate) directory: PathBuf,
    pinned: File,
    lock: File,
}
impl Drop for GenerationStore {
    fn drop(&mut self) {
        let _ = self.lock.unlock();
    }
}
impl GenerationStore {
    pub(crate) fn open(root: &Path, scope: &str) -> Result<Self> {
        absolute(root)?;
        let _root = open(root, true)?;
        let mut directory = root.canonicalize()?;
        for component in relative(scope)?.components() {
            directory.push(component.as_os_str());
            owned_directory(&directory)?;
        }
        let pinned = open(&directory, true)?;
        let path = directory.join(".install.lock");
        crate::platform_fs::ordinary_single_file(&path)?;
        let lock = crate::platform_fs::open_private(&path, false)?;
        lock.try_lock()
            .context("An artifact installation is already active")?;
        Ok(Self {
            directory,
            pinned,
            lock,
        })
    }
    pub(crate) fn recheck(&self) -> Result<()> {
        let held = self.pinned.metadata()?;
        let current = fs::symlink_metadata(&self.directory)?;
        ensure!(
            current.is_dir() && current.dev() == held.dev() && current.ino() == held.ino(),
            "Generation store directory changed"
        );
        Ok(())
    }
    pub(crate) fn create_candidate(&self) -> Result<Candidate> {
        self.recheck()?;
        let directory = self.directory.join(uuid::Uuid::new_v4().to_string());
        crate::platform_fs::create_private_directory(&directory)?;
        Ok(Candidate {
            pinned: open(&directory, true)?,
            directory,
            preserve: false,
        })
    }
    pub(crate) fn publish(
        &self,
        candidate: &mut Candidate,
        receipt: &impl Serialize,
    ) -> Result<()> {
        ensure!(
            candidate.directory.parent() == Some(self.directory.as_path()),
            "Candidate belongs to a different generation store"
        );
        self.recheck()?;
        candidate.recheck()?;
        sync_tree(&candidate.directory)?;
        let active = self.directory.join("active.json");
        crate::platform_fs::ordinary_single_file(&active)?;
        let pending = candidate.directory.join("activation.json");
        let mut output = crate::platform_fs::open_private(&pending, true)?;
        serde_json::to_writer(&mut output, receipt)?;
        output.sync_all()?;
        self.recheck()?;
        candidate.recheck()?;
        candidate.preserve = true;
        fs::rename(&pending, &active)?;
        self.pinned
            .sync_all()
            .context("Artifact activation may be published; both generations were retained")?;
        Ok(())
    }
}
pub(crate) fn seal_distribution(path: &Path) -> Result<()> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        if kind.is_dir() {
            seal_distribution(&entry.path())?;
        } else if kind.is_file() {
            let file = crate::platform_fs::open_read(&entry.path())?;
            file.set_permissions(fs::Permissions::from_mode(file.metadata()?.mode() & !0o222))?;
        }
    }
    let directory = open(path, true)?;
    directory.set_permissions(fs::Permissions::from_mode(
        directory.metadata()?.mode() & !0o222,
    ))?;
    Ok(())
}

fn sync_tree(path: &Path) -> Result<()> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        if kind.is_dir() {
            sync_tree(&entry.path())?;
        } else if kind.is_file() {
            crate::platform_fs::open_read(&entry.path())?.sync_all()?;
        } else {
            ensure!(kind.is_symlink(), "Unexpected runtime filesystem entry");
        }
    }
    open(path, true)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_candidate_cannot_publish_into_a_different_artifact_scope() {
        let root = tempfile::tempdir().unwrap();
        let runtime = GenerationStore::open(root.path(), "runtime/python").unwrap();
        let model = GenerationStore::open(root.path(), "runtime/models").unwrap();
        let mut candidate = runtime.create_candidate().unwrap();
        assert!(model
            .publish(&mut candidate, &serde_json::json!({"wrong":true}))
            .is_err());
        assert!(!model.directory.join("active.json").exists());
        runtime
            .publish(&mut candidate, &serde_json::json!({"own":true}))
            .unwrap();
        assert!(runtime.directory.join("active.json").is_file());
    }
}
