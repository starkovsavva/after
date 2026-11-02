//! Shared host resource path checks; no renderer-supplied filesystem access.
use crate::models::HostError;
use std::{fs, path::Path};
pub(crate) fn is_link_or_reparse(metadata: &fs::Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        return metadata.file_attributes() & 0x400 != 0; // FILE_ATTRIBUTE_REPARSE_POINT
    }
    #[cfg(not(windows))]
    {
        false
    }
}
pub(crate) fn ordinary_ancestors(path: &Path) -> Result<(), HostError> {
    #[cfg(windows)]
    {
        for ancestor in path.ancestors() {
            match fs::symlink_metadata(ancestor) {
                Ok(metadata) if metadata.is_dir() && !is_link_or_reparse(&metadata) => (),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                _ => {
                    return Err(HostError::new(
                        "invalid_configuration",
                        "The desktop location cannot contain links or reparse points.",
                    ))
                }
            }
        }
    }
    #[cfg(not(windows))]
    let _ = path;
    Ok(())
}
