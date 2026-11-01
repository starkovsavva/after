//! Bounded transfer policy over stream/observer ports; no paths or OS APIs.
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ImportPhase {
    Copying,
    Committing,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ImportProgress {
    pub phase: ImportPhase,
    pub copied_bytes: u64,
    pub total_bytes: u64,
}

#[derive(Debug)]
pub(crate) struct ImportCancelled;
impl std::fmt::Display for ImportCancelled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Import cancelled")
    }
}
impl std::error::Error for ImportCancelled {}

pub(crate) trait ImportObserver {
    /// A cancelled/unavailable observer rejects the next transfer/publication
    /// checkpoint. No fallible checkpoint runs after metadata publication.
    fn checkpoint(&mut self, progress: ImportProgress) -> Result<()>;
}

pub(crate) fn copy(
    input: &mut impl Read,
    output: &mut impl Write,
    total: u64,
    observer: &mut dyn ImportObserver,
) -> Result<u64> {
    let mut copied = 0;
    let mut buffer = vec![0; 256 * 1024];
    observer.checkpoint(ImportProgress {
        phase: ImportPhase::Copying,
        copied_bytes: 0,
        total_bytes: total,
    })?;
    while copied < total {
        let limit = usize::try_from((total - copied).min(buffer.len() as u64))?;
        let read = match input.read(&mut buffer[..limit]) {
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        ensure!(read > 0, "Source changed during import");
        output.write_all(&buffer[..read])?;
        copied += read as u64;
        observer.checkpoint(ImportProgress {
            phase: ImportPhase::Copying,
            copied_bytes: copied,
            total_bytes: total,
        })?;
    }
    Ok(copied)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Observer {
        cancel_at: Option<u64>,
        seen: Vec<u64>,
    }
    impl ImportObserver for Observer {
        fn checkpoint(&mut self, value: ImportProgress) -> Result<()> {
            self.seen.push(value.copied_bytes);
            if self.cancel_at.is_some_and(|at| value.copied_bytes >= at) {
                return Err(ImportCancelled.into());
            }
            Ok(())
        }
    }
    #[test]
    fn copy_is_bounded_and_cancellable_between_chunks() {
        let source = vec![42; 700_000];
        let mut input = source.as_slice();
        let mut output = Vec::new();
        let mut observer = Observer {
            cancel_at: Some(256 * 1024),
            seen: Vec::new(),
        };
        assert!(
            copy(&mut input, &mut output, source.len() as u64, &mut observer)
                .unwrap_err()
                .is::<ImportCancelled>()
        );
        assert_eq!(output.len(), 256 * 1024);
        assert_eq!(observer.seen, [0, 256 * 1024]);
        let mut output = Vec::new();
        observer.cancel_at = None;
        copy(&mut source.as_slice(), &mut output, 500_000, &mut observer).unwrap();
        assert_eq!(output, source[..500_000]);
    }
    #[test]
    fn short_source_and_observer_failure_never_report_completion() {
        let mut observer = Observer {
            cancel_at: None,
            seen: Vec::new(),
        };
        assert!(copy(&mut &b"short"[..], &mut Vec::new(), 100, &mut observer).is_err());
        observer.cancel_at = Some(0);
        let mut destination = Vec::new();
        assert!(copy(&mut &b"source"[..], &mut destination, 6, &mut observer).is_err());
        assert!(destination.is_empty());
    }
}
