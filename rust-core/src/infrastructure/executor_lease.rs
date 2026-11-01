//! Lifetime ownership for the import executor. Keep the lock file in place:
//! unlinking it would allow a second process to lock a different inode.
use anyhow::Result;
use std::{
    fs::{File, TryLockError},
    path::{Path, PathBuf},
};

pub(crate) struct ImportExecutorLease {
    _file: File,
    _root: crate::platform_fs::DirectoryGuard,
    root: PathBuf,
}

impl ImportExecutorLease {
    pub(crate) fn root(&self) -> &Path {
        &self.root
    }
}

pub(crate) fn try_acquire(root: &Path) -> Result<Option<ImportExecutorLease>> {
    crate::platform_fs::private_directory(root)?;
    let root = std::fs::canonicalize(root)?;
    let guard = crate::platform_fs::pin_directory(&root)?;
    let path = root.join(".desktop-import-executor.lock");
    crate::platform_fs::ordinary_single_file(&path)?;
    let file = crate::platform_fs::open_private(&path, false)?;
    match file.try_lock() {
        Ok(()) => Ok(Some(ImportExecutorLease {
            _file: file,
            _root: guard,
            root,
        })),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Error(error)) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ownership_is_exclusive_per_library_and_released_on_drop() {
        let root = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        let one = try_acquire(root.path()).unwrap().unwrap();
        assert!(try_acquire(root.path()).unwrap().is_none());
        let independent = try_acquire(other.path()).unwrap().unwrap();
        drop(one);
        assert!(try_acquire(root.path()).unwrap().is_some());
        drop(independent);
        assert!(root.path().join(".desktop-import-executor.lock").is_file());
    }

    #[test]
    fn unexpected_lock_objects_are_preserved_and_rejected() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join(".desktop-import-executor.lock");
        std::fs::create_dir(&path).unwrap();
        assert!(try_acquire(root.path()).is_err());
        assert!(path.is_dir());
    }

    #[cfg(unix)]
    #[test]
    fn linked_lock_files_cannot_change_external_data_or_permissions() {
        use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let source = outside.path().join("keep.txt");
        std::fs::write(&source, b"unchanged").unwrap();
        std::fs::set_permissions(&source, std::fs::Permissions::from_mode(0o644)).unwrap();
        let before = std::fs::metadata(&source).unwrap();
        let lock = root.path().join(".desktop-import-executor.lock");
        symlink(&source, &lock).unwrap();
        assert!(try_acquire(root.path()).is_err());
        std::fs::remove_file(&lock).unwrap();
        std::fs::hard_link(&source, &lock).unwrap();
        assert!(try_acquire(root.path()).is_err());
        assert_eq!(std::fs::read(&source).unwrap(), b"unchanged");
        assert_eq!(std::fs::metadata(&source).unwrap().mode(), before.mode());
    }
}
