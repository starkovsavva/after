//! Build-pinned application Python source. This grant never claims that a speech
//! runtime/model is ready and is never a renderer DTO or user-selected path.
use crate::{
    host_files::{is_link_or_reparse, ordinary_ancestors},
    models::HostError,
};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::Read,
    path::{Path, PathBuf},
};
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    name: String,
    size: u64,
    sha256: String,
}
#[derive(Clone)]
pub(crate) struct BackendResources {
    directory: PathBuf,
    inventory: Vec<Entry>,
}
pub struct VerifiedBackend {
    resources: BackendResources,
    directory: File,
    files: Vec<File>,
}
fn unavailable() -> HostError {
    HostError::new(
        "speech_unavailable",
        "Speech resources are not installed for this desktop build.",
    )
}
fn integrity() -> HostError {
    HostError::new(
        "speech_integrity",
        "Speech resources failed their integrity check. Reinstall this desktop build.",
    )
}
impl BackendResources {
    pub(crate) fn bundled(directory: PathBuf) -> Self {
        Self {
            directory,
            inventory: serde_json::from_str(env!("AFTER_SPEECH_BACKEND_INVENTORY"))
                .expect("Build-pinned speech inventory"),
        }
    }
    fn check_layout(&self) -> Result<(), HostError> {
        if !self.directory.is_absolute() || self.inventory.is_empty() || self.inventory.len() > 32 {
            return Err(unavailable());
        }
        ordinary_ancestors(&self.directory).map_err(|_| integrity())?;
        let meta = fs::symlink_metadata(&self.directory).map_err(|_| unavailable())?;
        if !meta.is_dir() || is_link_or_reparse(&meta) {
            return Err(integrity());
        }
        let expected: std::collections::BTreeSet<_> =
            self.inventory.iter().map(|v| v.name.clone()).collect();
        if expected.len() != self.inventory.len() {
            return Err(integrity());
        }
        let actual = fs::read_dir(&self.directory)
            .map_err(|_| integrity())?
            .map(|v| {
                v.map_err(|_| integrity())
                    .and_then(|v| v.file_name().into_string().map_err(|_| integrity()))
            })
            .collect::<Result<std::collections::BTreeSet<_>, _>>()?;
        if actual != expected {
            return Err(integrity());
        }
        Ok(())
    }
    fn file(&self, entry: &Entry) -> Result<File, HostError> {
        if entry.name.is_empty()
            || Path::new(&entry.name).file_name().and_then(|v| v.to_str())
                != Some(entry.name.as_str())
            || !entry.name.ends_with(".py")
            || entry.size == 0
            || entry.size > 1024 * 1024
        {
            return Err(integrity());
        }
        let path = self.directory.join(&entry.name);
        let before = fs::symlink_metadata(&path).map_err(|_| integrity())?;
        if !before.is_file() || is_link_or_reparse(&before) {
            return Err(integrity());
        }
        let mut options = fs::OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.custom_flags(0x00200000);
        }
        let mut file = options.open(path).map_err(|_| integrity())?;
        let opened = file.metadata().map_err(|_| integrity())?;
        if !opened.is_file() || is_link_or_reparse(&opened) || opened.len() != entry.size {
            return Err(integrity());
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if opened.dev() != before.dev() || opened.ino() != before.ino() || opened.nlink() != 1 {
                return Err(integrity());
            }
        }
        let mut hash = Sha256::new();
        let mut buf = [0; 16 * 1024];
        let mut total = 0u64;
        loop {
            let count = file.read(&mut buf).map_err(|_| integrity())?;
            if count == 0 {
                break;
            }
            total += count as u64;
            if total > entry.size {
                return Err(integrity());
            }
            hash.update(&buf[..count]);
        }
        if total != entry.size || format!("{:x}", hash.finalize()) != entry.sha256 {
            return Err(integrity());
        }
        Ok(file)
    }
    pub(crate) fn verify(&self) -> Result<VerifiedBackend, HostError> {
        self.check_layout()?;
        let mut options = fs::OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW);
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            // BACKUP_SEMANTICS opens a directory; OPEN_REPARSE_POINT refuses traversal.
            options.custom_flags(0x02000000 | 0x00200000);
        }
        let directory = options.open(&self.directory).map_err(|_| integrity())?;
        let metadata = directory.metadata().map_err(|_| integrity())?;
        if !metadata.is_dir() || is_link_or_reparse(&metadata) {
            return Err(integrity());
        }
        let files = self
            .inventory
            .iter()
            .map(|entry| self.file(entry))
            .collect::<Result<Vec<_>, _>>()?;
        let verified = VerifiedBackend {
            resources: self.clone(),
            directory,
            files,
        };
        verified.recheck()?;
        Ok(verified)
    }
}
impl VerifiedBackend {
    pub fn directory(&self) -> &Path {
        &self.resources.directory
    }
    pub fn recheck(&self) -> Result<(), HostError> {
        self.resources.check_layout()?;
        let current = fs::symlink_metadata(&self.resources.directory).map_err(|_| integrity())?;
        let held = self.directory.metadata().map_err(|_| integrity())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if current.dev() != held.dev() || current.ino() != held.ino() {
                return Err(integrity());
            }
        }
        let _ = (&current, &held);
        for (entry, pinned) in self.resources.inventory.iter().zip(&self.files) {
            let file = self.resources.file(entry)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt;
                let current = file.metadata().map_err(|_| integrity())?;
                let held = pinned.metadata().map_err(|_| integrity())?;
                if current.dev() != held.dev() || current.ino() != held.ino() {
                    return Err(integrity());
                }
            }
            let _ = (&file, pinned);
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(directory: &Path) -> BackendResources {
        fs::write(
            directory.join("engine.py"),
            b"# synthetic source; never executed\n",
        )
        .unwrap();
        let content = fs::read(directory.join("engine.py")).unwrap();
        BackendResources {
            directory: directory.to_owned(),
            inventory: vec![Entry {
                name: "engine.py".into(),
                size: content.len() as u64,
                sha256: format!("{:x}", Sha256::digest(content)),
            }],
        }
    }
    #[test]
    fn verified_resources_reject_tampering_missing_and_unexpected_importable_files() {
        let root = tempfile::tempdir().unwrap();
        let resources = fixture(root.path());
        let grant = resources.verify().unwrap();
        assert_eq!(grant.directory(), root.path());
        fs::write(root.path().join("other.py"), b"# injected").unwrap();
        assert!(grant.recheck().is_err());
        fs::remove_file(root.path().join("other.py")).unwrap();
        fs::create_dir(root.path().join("__pycache__")).unwrap();
        assert!(grant.recheck().is_err());
        fs::remove_dir(root.path().join("__pycache__")).unwrap();
        let original = fs::read(root.path().join("engine.py")).unwrap();
        let mut changed = original.clone();
        changed[1] ^= 1;
        fs::write(root.path().join("engine.py"), &changed).unwrap();
        assert!(grant.recheck().is_err());
        fs::write(root.path().join("engine.py"), original).unwrap();
        assert!(grant.recheck().is_ok());
        fs::remove_file(root.path().join("engine.py")).unwrap();
        assert!(grant.recheck().is_err());
    }
    #[cfg(unix)]
    #[test]
    fn aliases_hardlinks_and_replaced_resource_directories_are_rejected() {
        let base = tempfile::tempdir().unwrap();
        let root = base.path().join("backend");
        fs::create_dir(&root).unwrap();
        let resources = fixture(&root);
        let grant = resources.verify().unwrap();
        let original = root.join("engine.py");
        let outside = base.path().join("outside.py");
        fs::rename(&original, &outside).unwrap();
        std::os::unix::fs::symlink(&outside, &original).unwrap();
        assert!(resources.verify().is_err());
        fs::remove_file(&original).unwrap();
        fs::hard_link(&outside, &original).unwrap();
        assert!(resources.verify().is_err());
        fs::remove_file(&original).unwrap();
        fs::rename(outside, &original).unwrap();
        fs::rename(&root, base.path().join("old")).unwrap();
        fs::create_dir(&root).unwrap();
        fixture(&root);
        assert!(grant.recheck().is_err());
    }
}
