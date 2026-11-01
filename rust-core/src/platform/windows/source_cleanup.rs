//! The private agent broker is not available here yet. Only observed absence of
//! its store proves there is no derived state to clean; preserve any other data.
use anyhow::{bail, Result};
use std::{fs, io, path::Path};

pub(crate) fn reconcile_deleted_sources(root: &Path) -> Result<usize> {
    let path = root.join(crate::infrastructure::agent_store_layout::DATABASE);
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(0),
        Err(error) => Err(error.into()),
        Ok(_) => bail!("The private agent cleanup adapter is unavailable on this platform"),
    }
}
