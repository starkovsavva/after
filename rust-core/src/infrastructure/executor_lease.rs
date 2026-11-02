//! Lifetime ownership for the import executor. Keep the lock file in place:
//! unlinking it would allow a second process to lock a different inode.
use anyhow::Result;
use std::{
    fs::{File, TryLockError},
    path::{Path, PathBuf},
};

struct ExecutorLease {
    _file: File,
    _root: crate::platform_fs::DirectoryGuard,
    root: PathBuf,
}

impl Drop for ExecutorLease {
    fn drop(&mut self) {
        // Cooperative owners join every worker first. Explicit unlock also
        // releases transient fork duplicates in unrelated concurrent spawns.
        // Abrupt owner death skips Drop; a native publisher's inherited copy
        // then keeps the kernel lease until that publisher exits.
        let _ = self._file.unlock();
    }
}

impl ExecutorLease {
    pub(crate) fn root(&self) -> &Path {
        &self.root
    }
}

pub(crate) struct ImportExecutorLease(ExecutorLease);
pub(crate) struct SpeechExecutorLease(ExecutorLease);
impl ImportExecutorLease {
    pub(crate) fn root(&self) -> &Path {
        self.0.root()
    }
}
impl SpeechExecutorLease {
    pub(crate) fn root(&self) -> &Path {
        self.0.root()
    }
}
pub(crate) fn try_acquire(root: &Path) -> Result<Option<ImportExecutorLease>> {
    Ok(acquire(root, ".desktop-import-executor.lock")?.map(ImportExecutorLease))
}
pub(crate) fn try_acquire_speech(root: &Path) -> Result<Option<SpeechExecutorLease>> {
    Ok(acquire(root, ".desktop-speech-executor.lock")?.map(SpeechExecutorLease))
}

fn acquire(root: &Path, lock_name: &str) -> Result<Option<ExecutorLease>> {
    crate::platform_fs::private_directory(root)?;
    let root = std::fs::canonicalize(root)?;
    let guard = crate::platform_fs::pin_directory(&root)?;
    let path = root.join(lock_name);
    crate::platform_fs::ordinary_single_file(&path)?;
    let file = crate::platform_fs::open_private(&path, false)?;
    match file.try_lock() {
        Ok(()) => Ok(Some(ExecutorLease {
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

#[cfg(unix)]
impl SpeechExecutorLease {
    /// Duplicate only in the forked child. Never toggle CLOEXEC on the parent's
    /// shared descriptor while other workers may spawn concurrently.
    pub(crate) fn inherit(&self, command: &mut std::process::Command) -> Result<()> {
        use std::os::{
            fd::{AsRawFd, FromRawFd},
            unix::process::CommandExt,
        };
        let raw = unsafe { libc::fcntl(self.0._file.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 3) };
        if raw < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let inherited = unsafe { File::from_raw_fd(raw) };
        command.env("AFTER_SPEECH_LEASE_FD", raw.to_string());
        // The owned descriptor cannot collide with the spawn implementation's
        // pipes. Clearing CLOEXEC in the child does not change the parent table.
        unsafe {
            command.pre_exec(move || {
                if libc::fcntl(inherited.as_raw_fd(), libc::F_SETFD, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        Ok(())
    }
}

#[cfg(unix)]
pub(crate) fn inherited_speech(root: &Path) -> Result<Option<File>> {
    use std::os::{fd::FromRawFd, unix::fs::MetadataExt};
    let Some(value) = std::env::var_os("AFTER_SPEECH_LEASE_FD") else {
        return Ok(None);
    };
    let descriptor: i32 = value
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("Invalid inherited speech ownership"))?
        .parse()?;
    anyhow::ensure!(descriptor >= 3, "Invalid inherited speech ownership");
    let raw = unsafe { libc::fcntl(descriptor, libc::F_DUPFD_CLOEXEC, 3) };
    if raw < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let file = unsafe { File::from_raw_fd(raw) };
    let expected = crate::platform_fs::open_read(&root.join(".desktop-speech-executor.lock"))?;
    let actual = file.metadata()?;
    let pinned = expected.metadata()?;
    anyhow::ensure!(
        actual.is_file()
            && actual.nlink() == 1
            && actual.dev() == pinned.dev()
            && actual.ino() == pinned.ino(),
        "Speech executor lease changed"
    );
    file.try_lock()?;
    Ok(Some(file))
}

#[cfg(all(test, unix))]
mod speech_tests {
    use super::*;
    use std::process::{Command, Stdio};
    #[test]
    fn speech_and_import_ownership_are_independent_but_each_scope_is_exclusive() {
        let root = tempfile::tempdir().unwrap();
        let import = try_acquire(root.path()).unwrap().unwrap();
        let speech = try_acquire_speech(root.path()).unwrap().unwrap();
        assert!(try_acquire(root.path()).unwrap().is_none());
        assert!(try_acquire_speech(root.path()).unwrap().is_none());
        drop(import);
        assert!(try_acquire(root.path()).unwrap().is_some());
        assert!(try_acquire_speech(root.path()).unwrap().is_none());
        drop(speech);
        assert!(try_acquire_speech(root.path()).unwrap().is_some());
        assert!(root.path().join(".desktop-speech-executor.lock").is_file());
    }
    #[test]
    fn inherited_holder_helper() {
        let Some(root) = std::env::var_os("AFTER_TEST_SPEECH_HOLDER") else {
            return;
        };
        let root = Path::new(&root);
        let _guard = inherited_speech(root).unwrap().unwrap();
        std::fs::write(root.join("holder-ready"), std::process::id().to_string()).unwrap();
        let until = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while !root.join("release-holder").exists() && std::time::Instant::now() < until {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }
    #[test]
    fn abrupt_parent_helper() {
        let Some(root) = std::env::var_os("AFTER_TEST_SPEECH_PARENT") else {
            return;
        };
        let root = Path::new(&root);
        let lease = try_acquire_speech(root).unwrap().unwrap();
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                "infrastructure::executor_lease::speech_tests::inherited_holder_helper",
            ])
            .env("AFTER_TEST_SPEECH_HOLDER", root)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        lease.inherit(&mut command).unwrap();
        let mut child = command.spawn().unwrap();
        let until = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !root.join("holder-ready").exists() {
            if child.try_wait().unwrap().is_some() || std::time::Instant::now() >= until {
                let _ = child.kill();
                let _ = child.wait();
                panic!("lease holder did not start");
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        // Simulate process death: no Rust destructor or cooperative unlock.
        std::process::exit(0);
    }
    #[test]
    fn a_native_publisher_keeps_ownership_after_abrupt_owner_exit() {
        let root = tempfile::tempdir().unwrap();
        let status = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "infrastructure::executor_lease::speech_tests::abrupt_parent_helper",
            ])
            .env("AFTER_TEST_SPEECH_PARENT", root.path())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap();
        assert!(status.success());
        let held = try_acquire_speech(root.path()).unwrap().is_none();
        std::fs::write(root.path().join("release-holder"), b"release").unwrap();
        assert!(held, "abrupt owner exit released a live publisher's lease");
        let until = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            if try_acquire_speech(root.path()).unwrap().is_some() {
                break;
            }
            assert!(
                std::time::Instant::now() < until,
                "publisher did not release ownership"
            );
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }
}

#[cfg(unix)]
pub(crate) fn validate_publisher_group() -> Result<()> {
    anyhow::ensure!(
        unsafe { libc::getpgrp() } == unsafe { libc::getpid() },
        "Native publisher must lead its isolated group"
    );
    Ok(())
}

/// Binary-entry guard for a publisher created inside an owned native scope.
/// Drop terminates this isolated group, including unexpected remaining SDK or
/// FFmpeg children. The entry point must flush its final acknowledgement first.
/// It never targets a caller/terminal group: validated publishers lead the group.
#[cfg(unix)]
pub struct NativePublisherScope {
    _lease: std::fs::File,
}
#[cfg(unix)]
impl Drop for NativePublisherScope {
    fn drop(&mut self) {
        unsafe {
            libc::kill(-libc::getpid(), libc::SIGKILL);
        }
        std::process::abort();
    }
}
#[cfg(unix)]
pub(crate) fn native_publisher_scope(root: &Path) -> Result<Option<NativePublisherScope>> {
    let lease = inherited_speech(root)?;
    if let Some(lease) = lease {
        validate_publisher_group()?;
        Ok(Some(NativePublisherScope { _lease: lease }))
    } else {
        Ok(None)
    }
}
