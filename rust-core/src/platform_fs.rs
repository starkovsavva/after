//! Filesystem boundary for the shared library. Windows uses real ACLs,
//! no-reparse handles, parent pinning, atomic replacement and kernel file locks.
//! Domain persistence, migrations, revisions and SQLite transactions stay shared.
use anyhow::{ensure, Result};
use std::{fs::{self, File}, path::Path};

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use windows::*;

#[cfg(unix)]
mod unix {
    use super::*;
    use std::fs::{DirBuilder, OpenOptions};
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
    pub struct DirectoryGuard { _handle: File }
    pub fn pin_directory(path: &Path) -> Result<DirectoryGuard> {
        let file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY).open(path)?;
        ensure!(file.metadata()?.is_dir(), "Expected an ordinary library directory");
        Ok(DirectoryGuard { _handle: file })
    }
    pub fn private_directory(path: &Path) -> Result<()> {
        if let Ok(info) = fs::symlink_metadata(path) { ensure!(info.is_dir() && !info.file_type().is_symlink(), "Expected an ordinary private directory"); }
        DirBuilder::new().recursive(true).mode(0o700).create(path)?;
        let guard = pin_directory(path)?;
        guard._handle.set_permissions(fs::Permissions::from_mode(0o700))?;
        Ok(())
    }
    pub fn create_private_directory(path: &Path) -> Result<()> { DirBuilder::new().mode(0o700).create(path)?; Ok(()) }
    pub fn open_read(path: &Path) -> Result<File> {
        let file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK).open(path)?;
        ensure!(file.metadata()?.is_file(), "Expected an ordinary library file");
        Ok(file)
    }
    pub fn open_private(path: &Path, create_new: bool) -> Result<File> {
        let mut options = OpenOptions::new();
        options.read(true).write(true).mode(0o600).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        if create_new { options.create_new(true); } else { options.create(true).truncate(false); }
        let file = options.open(path)?;
        ensure!(file.metadata()?.is_file(), "Expected an ordinary private file");
        secure_file(&file)?;
        Ok(file)
    }
    pub fn secure_file(file: &File) -> Result<()> { file.set_permissions(fs::Permissions::from_mode(0o600))?; Ok(()) }
    pub fn secure_existing(path: &Path) -> Result<()> { secure_file(&open_read(path)?) }
    pub fn ordinary_single_file(path: &Path) -> Result<bool> {
        match fs::symlink_metadata(path) {
            Ok(info) => { ensure!(info.is_file() && !info.file_type().is_symlink() && info.nlink()==1, "Expected one ordinary private file"); Ok(true) },
            Err(error) if error.kind()==std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error.into()),
        }
    }
    pub fn stamp(path: &Path) -> String {
        match fs::symlink_metadata(path) {
            Ok(m) if m.is_file() && !m.file_type().is_symlink() => format!("{}:{}:{}:{}:{}:{}",m.ino(),m.len(),m.mtime(),m.mtime_nsec(),m.ctime(),m.ctime_nsec()),
            Ok(_) => "not-regular".into(), Err(_) => "missing".into(),
        }
    }
    pub type GuardedConnection = rusqlite::Connection;
    pub fn sqlite_connection(path: &Path, flags: rusqlite::OpenFlags) -> Result<GuardedConnection> { Ok(rusqlite::Connection::open_with_flags(path, flags)?) }
}
#[cfg(unix)]
pub use unix::*;
