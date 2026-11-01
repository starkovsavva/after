//! Private workspace paths and process-wide locking adapter.
use anyhow::{ensure, Context, Result};
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::{
    fs::{self, DirBuilder, File},
    path::{Path, PathBuf},
};
#[cfg(unix)]
pub(crate) fn private_directory(path: &Path) -> Result<()> {
    if let Ok(info) = fs::symlink_metadata(path) {
        ensure!(
            info.is_dir() && !info.file_type().is_symlink(),
            "Папка заметок не должна быть ссылкой"
        );
    }
    DirBuilder::new().recursive(true).mode(0o700).create(path)?;
    let info = fs::symlink_metadata(path)?;
    ensure!(
        info.is_dir() && !info.file_type().is_symlink(),
        "Некорректная папка заметок"
    );
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}
#[cfg(windows)]
pub(crate) fn private_directory(path: &Path) -> Result<()> {
    crate::platform_fs::private_directory(path)
}
pub(crate) fn directory(root: &Path) -> Result<PathBuf> {
    ensure!(
        root.is_absolute(),
        "Папка данных должна иметь абсолютный путь"
    );
    private_directory(root)?;
    let directory = root.join("notes");
    private_directory(&directory)?;
    Ok(directory)
}
pub(crate) fn lock(directory: &Path) -> Result<File> {
    let path = directory.join(".workspace.lock");
    if let Ok(info) = fs::symlink_metadata(&path) {
        ensure!(
            info.is_file() && !info.file_type().is_symlink(),
            "Некорректная блокировка заметок"
        );
    }
    let file = crate::platform_fs::open_private(&path, false)?;
    crate::platform_fs::secure_file(&file)?;
    file.lock().context("Не удалось заблокировать заметки")?;
    Ok(file)
}
