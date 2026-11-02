//! Keep all directories open without FILE_SHARE_DELETE while recording or
//! importing. This prevents replacement by a junction between verification
//! and use; files are created exclusively inside the protected library root.
#[cfg(windows)]
use std::os::windows::{
    fs::{MetadataExt, OpenOptionsExt},
    io::AsRawHandle,
};
use std::{
    fs::{self, File, OpenOptions},
    path::{Component, Path, PathBuf},
};

#[derive(Debug)]
pub struct Guard {
    _handles: Vec<File>,
    _lease: Option<File>,
}
impl Drop for Guard {
    fn drop(&mut self) {
        // A concurrent fork can temporarily inherit the same open description
        // before CLOEXEC. Release ownership explicitly when this guard ends.
        if let Some(file) = &self._lease {
            let _ = file.unlock();
        }
    }
}
#[cfg(windows)]
fn open_directory(path: &Path) -> std::io::Result<File> {
    const FILE_LIST_DIRECTORY: u32 = 1;
    const FILE_READ_ATTRIBUTES: u32 = 0x80;
    const FILE_SHARE_READ_WRITE: u32 = 3;
    const FLAGS: u32 = 0x0200_0000 | 0x0020_0000; // BACKUP_SEMANTICS | OPEN_REPARSE_POINT
    let file = OpenOptions::new()
        .access_mode(FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES)
        .share_mode(FILE_SHARE_READ_WRITE)
        .custom_flags(FLAGS)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_dir() || metadata.file_attributes() & 0x400 != 0 {
        return Err(std::io::Error::other(
            "Recording directory is a link or reparse point",
        ));
    }
    Ok(file)
}
#[cfg(not(windows))]
fn open_directory(path: &Path) -> std::io::Result<File> {
    let m = fs::symlink_metadata(path)?;
    if !m.is_dir() || m.file_type().is_symlink() {
        return Err(std::io::Error::other("Recording directory is a link"));
    }
    File::open(path)
}
pub fn pin(path: &Path) -> std::io::Result<Guard> {
    if !path.is_absolute() {
        return Err(std::io::Error::other(
            "Recording directory must be absolute",
        ));
    }
    let mut current = PathBuf::new();
    let mut handles = Vec::new();
    for part in path.components() {
        current.push(part.as_os_str());
        if matches!(part, Component::ParentDir | Component::CurDir) {
            return Err(std::io::Error::other("Invalid recording directory"));
        }
        if matches!(part, Component::RootDir | Component::Normal(_)) {
            handles.push(open_directory(&current)?);
        }
    }
    Ok(Guard {
        _handles: handles,
        _lease: None,
    })
}
pub fn create(root: &Path, id: &str) -> std::io::Result<(PathBuf, Guard)> {
    let root_guard = pin(root)?;
    let captures = root.join("captures");
    match fs::create_dir(&captures) {
        Ok(()) => (),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => (),
        Err(e) => return Err(e),
    }
    let captures_guard = pin(&captures)?;
    let session = captures.join(id);
    fs::create_dir(&session)?;
    let session_guard = pin_session(&session)?;
    drop(captures_guard);
    drop(root_guard);
    Ok((session, session_guard))
}
/// Keep this sidecar inode in place. The lease covers capture/finalization/import;
/// locking source.wav itself would prevent the engine reading it on Windows.
pub fn pin_session(path: &Path) -> std::io::Result<Guard> {
    let mut guard = pin(path)?;
    let file = open_checked(&path.join(".capture-session.lock"), true, true)?;
    file.try_lock().map_err(|error| match error {
        std::fs::TryLockError::WouldBlock => {
            std::io::Error::new(std::io::ErrorKind::WouldBlock, "Recording session is busy")
        }
        std::fs::TryLockError::Error(error) => error,
    })?;
    guard._lease = Some(file);
    Ok(guard)
}
pub fn open_source(path: &Path, writable: bool) -> std::io::Result<File> {
    open_checked(path, writable, false)
}
fn open_checked(path: &Path, writable: bool, create: bool) -> std::io::Result<File> {
    // Inspect before opening, then validate the actual handle without following
    // links. Existing objects are preserved, including unexpected lock objects.
    match fs::symlink_metadata(path) {
        Ok(info) if !info.is_file() || info.file_type().is_symlink() => {
            return Err(std::io::Error::other("Recording file is unsafe"))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && create => {}
        Err(error) => return Err(error),
        _ => {}
    }
    let mut opts = OpenOptions::new();
    opts.read(true)
        .write(writable)
        .create(create)
        .truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    opts.share_mode(3).custom_flags(0x0020_0000);
    let f = opts.open(path)?;
    let m = f.metadata()?;
    if !m.is_file() {
        return Err(std::io::Error::other("Recording is not a regular file"));
    }
    #[cfg(windows)]
    {
        if m.file_attributes() & 0x400 != 0 {
            return Err(std::io::Error::other("Recording is a reparse point"));
        }
        use windows::Win32::{
            Foundation::HANDLE,
            Storage::FileSystem::{GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION},
        };
        let mut info = BY_HANDLE_FILE_INFORMATION::default();
        unsafe { GetFileInformationByHandle(HANDLE(f.as_raw_handle()), &mut info) }
            .map_err(std::io::Error::other)?;
        if info.nNumberOfLinks != 1 {
            return Err(std::io::Error::other("Recording has multiple links"));
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let named = fs::symlink_metadata(path)?;
        if m.nlink() != 1
            || named.file_type().is_symlink()
            || m.dev() != named.dev()
            || m.ino() != named.ino()
        {
            return Err(std::io::Error::other("Recording file identity changed"));
        }
    }
    Ok(f)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn session_lease_is_exclusive_and_the_lock_inode_is_retained() {
        let root = tempfile::tempdir().unwrap();
        let (path, one) = create(root.path(), &uuid::Uuid::new_v4().to_string()).unwrap();
        assert!(pin_session(&path).is_err());
        let inherited = one._lease.as_ref().unwrap().try_clone().unwrap();
        drop(one);
        assert!(path.join(".capture-session.lock").is_file());
        assert!(pin_session(&path).is_ok());
        drop(inherited);
    }
    #[cfg(unix)]
    #[test]
    fn linked_lock_objects_are_rejected_without_changing_external_files() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("external");
        fs::write(&source, b"keep").unwrap();
        fs::set_permissions(&source, fs::Permissions::from_mode(0o644)).unwrap();
        for hard_link in [false, true] {
            let dir = root.path().join(if hard_link { "hard" } else { "soft" });
            fs::create_dir(&dir).unwrap();
            let lock = dir.join(".capture-session.lock");
            if hard_link {
                fs::hard_link(&source, &lock).unwrap();
            } else {
                symlink(&source, &lock).unwrap();
            }
            assert!(pin_session(&dir).is_err());
        }
        assert_eq!(fs::read(&source).unwrap(), b"keep");
        assert_eq!(
            fs::metadata(&source).unwrap().permissions().mode() & 0o777,
            0o644
        );
    }
}

#[cfg(test)]
mod process_tests {
    use super::*;
    #[test]
    fn capture_lease_is_process_scoped() {
        if let Some(path) = std::env::var_os("AFTER_CAPTURE_LEASE_PATH") {
            let lease = pin_session(Path::new(&path));
            if std::env::var("AFTER_CAPTURE_LEASE_EXPECT_BUSY").unwrap() == "1" {
                assert_eq!(lease.err().unwrap().kind(), std::io::ErrorKind::WouldBlock);
            } else {
                assert!(lease.is_ok());
            }
            return;
        }
        let root = tempfile::tempdir().unwrap();
        let (path, lease) = create(root.path(), &uuid::Uuid::new_v4().to_string()).unwrap();
        let probe = |busy: bool| {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "capture::guard::process_tests::capture_lease_is_process_scoped",
                ])
                .env("AFTER_CAPTURE_LEASE_PATH", &path)
                .env(
                    "AFTER_CAPTURE_LEASE_EXPECT_BUSY",
                    if busy { "1" } else { "0" },
                )
                .output()
                .unwrap();
            assert!(String::from_utf8_lossy(&output.stdout).contains("1 passed"));
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
        };
        probe(true);
        drop(lease);
        probe(false);
        assert!(path.join(".capture-session.lock").is_file());
    }
}
