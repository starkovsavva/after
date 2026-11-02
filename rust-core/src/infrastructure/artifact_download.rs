//! Copy a reviewed artifact into a new private file before any parser/executor
//! consumes it. Local caches and HTTPS share the same size/hash boundary.
use anyhow::{ensure, Result};
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    path::Path,
    time::Duration,
};
pub(crate) fn copy_verified(
    source: Option<&Path>,
    url: &str,
    sha256: &str,
    size: u64,
    destination: &Path,
) -> Result<()> {
    let mut input: Box<dyn Read> = if let Some(source) = source {
        Box::new(crate::platform_fs::open_read(source)?)
    } else {
        let client = reqwest::blocking::Client::builder()
            .https_only(true)
            .timeout(Duration::from_secs(120))
            .build()?;
        Box::new(client.get(url).send()?.error_for_status()?)
    };
    let mut output = crate::platform_fs::open_private(destination, true)?;
    let mut digest = Sha256::new();
    let mut count = 0u64;
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = input.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        count = count
            .checked_add(read as u64)
            .ok_or_else(|| anyhow::anyhow!("Invalid artifact size"))?;
        ensure!(count <= size, "Pinned artifact size mismatch");
        output.write_all(&buffer[..read])?;
        digest.update(&buffer[..read]);
    }
    ensure!(
        count == size && format!("{:x}", digest.finalize()) == sha256,
        "Pinned artifact integrity mismatch"
    );
    output.sync_all()?;
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cached_artifacts_are_verified_and_never_replace_existing_destinations() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("source");
        let destination = root.path().join("destination");
        std::fs::write(&source, b"verified bytes").unwrap();
        let sha = format!("{:x}", Sha256::digest(b"verified bytes"));
        copy_verified(
            Some(&source),
            "https://unused.invalid",
            &sha,
            14,
            &destination,
        )
        .unwrap();
        assert_eq!(std::fs::read(&destination).unwrap(), b"verified bytes");
        assert!(copy_verified(
            Some(&source),
            "https://unused.invalid",
            &sha,
            14,
            &destination
        )
        .is_err());
        for (size, digest) in [(13, sha.as_str()), (15, sha.as_str()), (14, "wrong")] {
            let path = root.path().join(format!("bad-{size}-{digest}"));
            assert!(
                copy_verified(Some(&source), "https://unused.invalid", digest, size, &path)
                    .is_err()
            );
        }
    }
}
