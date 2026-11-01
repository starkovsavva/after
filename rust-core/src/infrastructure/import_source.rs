//! Read-only native file grant. Unlike private-library files, external sources
//! must never have their permissions changed. Refuse replacements and devices.
use anyhow::{ensure, Result};
use std::{
    fs::{File, OpenOptions},
    path::Path,
};

pub(crate) fn open(path: &Path) -> Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    ensure!(metadata.is_file(), "Expected an ordinary import source");
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        ensure!(
            metadata.file_attributes() & 0x400 == 0,
            "Linked import source changed"
        );
    }
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ordinary_sources_are_read_only_and_directories_are_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("source.wav");
        std::fs::write(&path, b"source unchanged").unwrap();
        assert_eq!(open(&path).unwrap().metadata().unwrap().len(), 16);
        assert_eq!(std::fs::read(&path).unwrap(), b"source unchanged");
        assert!(open(temp.path()).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn fifo_and_replacement_symlink_do_not_block_or_get_followed() {
        use std::os::unix::{ffi::OsStrExt, fs::symlink};
        let temp = tempfile::tempdir().unwrap();
        let fifo = temp.path().join("source.wav");
        let name = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        assert!(open(&fifo).is_err());
        let source = temp.path().join("ordinary.wav");
        std::fs::write(&source, b"ordinary").unwrap();
        let link = temp.path().join("replacement.wav");
        symlink(&source, &link).unwrap();
        assert!(open(&link).is_err());
    }
}
