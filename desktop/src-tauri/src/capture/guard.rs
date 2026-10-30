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
    Ok(Guard { _handles: handles })
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
    let session_guard = pin(&session)?;
    drop(captures_guard);
    drop(root_guard);
    Ok((session, session_guard))
}
pub fn open_source(path: &Path, writable: bool) -> std::io::Result<File> {
    let mut opts = OpenOptions::new();
    opts.read(true).write(writable);
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
    #[cfg(not(windows))]
    if fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(std::io::Error::other("Recording is a link"));
    }
    Ok(f)
}
