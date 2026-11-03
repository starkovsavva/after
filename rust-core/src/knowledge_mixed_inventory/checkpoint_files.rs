//! Platform filesystem adapters for the derived checkpoint. The query/schema
//! policy stays portable; Unix retains strict modes and Windows uses protected
//! ACLs, no-reparse handles and a pinned SQLite connection.
use super::*;
use rusqlite::OpenFlags;

#[cfg(unix)]
pub(super) fn open(
    directory: &Path,
    scope: &str,
) -> Result<(crate::platform_fs::GuardedConnection, bool)> {
    use rusqlite::Connection;
    use std::fs::{DirBuilder, OpenOptions};
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
    let directory = directory.to_owned();
    match fs::symlink_metadata(&directory) {
        Ok(info) => ensure!(
            info.is_dir() && !info.file_type().is_symlink(),
            "Недопустимый каталог индекса"
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            DirBuilder::new().mode(0o700).create(&directory)?
        }
        Err(error) => return Err(error.into()),
    }
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
    let path = directory.join(format!("meetings-{scope}.sqlite"));
    // SQLite may recover an interrupted transaction from one of these
    // files during open. Never follow an unrelated link as a journal.
    for suffix in ["-journal", "-wal", "-shm"] {
        let sidecar = directory.join(format!("meetings-{scope}.sqlite{suffix}"));
        match fs::symlink_metadata(sidecar) {
            Ok(info) => ensure!(
                info.is_file()
                    && !info.file_type().is_symlink()
                    && info.nlink() == 1
                    && info.permissions().mode() & 0o077 == 0,
                "Недопустимый служебный файл индекса"
            ),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    let empty_or_new = match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)
    {
        Ok(file) => {
            file.set_permissions(fs::Permissions::from_mode(0o600))?;
            file.sync_all()?;
            true
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let info = fs::symlink_metadata(&path)?;
            ensure!(
                info.is_file() && !info.file_type().is_symlink(),
                "Недопустимый файл индекса"
            );
            ensure!(
                info.nlink() == 1,
                "Файл индекса не должен иметь жёстких ссылок"
            );
            ensure!(
                info.permissions().mode() & 0o077 == 0,
                "Файл индекса не является приватным"
            );
            info.len() == 0
        }
        Err(error) => return Err(error.into()),
    };
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW;
    let connection = Connection::open_with_flags(path, flags)?;
    Ok((connection, empty_or_new))
}

#[cfg(windows)]
pub(super) fn open(
    directory: &Path,
    scope: &str,
) -> Result<(crate::platform_fs::GuardedConnection, bool)> {
    crate::platform_fs::private_directory(directory)?;
    let _directory_guard = crate::platform_fs::pin_directory(directory)?;
    for suffix in ["-journal", "-wal", "-shm"] {
        let sidecar = directory.join(format!("meetings-{scope}.sqlite{suffix}"));
        if crate::platform_fs::ordinary_single_file(&sidecar)? {
            // Existing owned sidecars receive the same protected ACL used by
            // canonical Windows stores, before SQLite can recover from them.
            crate::platform_fs::secure_existing(&sidecar)?;
        }
    }
    let path = directory.join(format!("meetings-{scope}.sqlite"));
    let empty_or_new = match crate::platform_fs::open_private(&path, true) {
        Ok(file) => {
            file.sync_all()?;
            true
        }
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::AlreadyExists) =>
        {
            crate::platform_fs::ordinary_single_file(&path)?;
            let file = crate::platform_fs::open_private(&path, false)?;
            file.metadata()?.len() == 0
        }
        Err(error) => return Err(error),
    };
    let connection = crate::platform_fs::sqlite_connection(
        &path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    Ok((connection, empty_or_new))
}
