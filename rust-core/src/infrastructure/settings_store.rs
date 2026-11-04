//! Bounded persisted settings and a shared cooperating-writer lock. Never use
//! environment job overrides here and never expose private snapshots to the UI.
use anyhow::{ensure, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::Read,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};
const LIMIT: usize = 256 * 1024;
pub(crate) struct Snapshot {
    pub value: Value,
    pub revision: String,
}
pub(crate) struct Store {
    root: PathBuf,
    handle: File,
}
struct Lock(File);
impl Drop for Lock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}
impl Store {
    pub fn open(root: &Path) -> Result<Self> {
        super::runtime_tree::absolute(root)?;
        crate::platform_fs::private_directory(root)?;
        let handle = super::runtime_tree::open(root, true)?;
        let store = Self {
            root: root.canonicalize()?,
            handle,
        };
        store.recheck()?;
        Ok(store)
    }
    pub fn root(&self) -> &Path {
        &self.root
    }
    fn recheck(&self) -> Result<()> {
        let current = fs::symlink_metadata(&self.root)?;
        let held = self.handle.metadata()?;
        super::runtime_tree::secure(&current)?;
        ensure!(
            current.is_dir() && current.dev() == held.dev() && current.ino() == held.ino(),
            "Settings root changed"
        );
        Ok(())
    }
    fn lock(&self) -> Result<Lock> {
        self.recheck()?;
        let path = self.root.join(".settings.lock");
        crate::platform_fs::ordinary_single_file(&path)?;
        let file = crate::platform_fs::open_private(&path, false)?;
        file.lock()?;
        let lock = Lock(file);
        let held = lock.0.metadata()?;
        let current = fs::symlink_metadata(&path)?;
        super::runtime_tree::secure(&held)?;
        ensure!(
            held.nlink() == 1
                && current.is_file()
                && !current.file_type().is_symlink()
                && held.dev() == current.dev()
                && held.ino() == current.ino(),
            "Settings lock changed"
        );
        self.recheck()?;
        Ok(lock)
    }
    pub fn snapshot(&self) -> Result<Snapshot> {
        self.recheck()?;
        let path = self.root.join("settings.json");
        if !crate::platform_fs::ordinary_single_file(&path)? {
            return Ok(Snapshot {
                value: json!({}),
                revision: format!("{:x}", Sha256::digest(b"after-settings-v1:missing")),
            });
        }
        let file = super::runtime_tree::open(&path, false)?;
        ensure!(
            file.metadata()?.len() <= LIMIT as u64 && file.metadata()?.nlink() == 1,
            "Invalid settings file"
        );
        let mut bytes = vec![];
        file.take(LIMIT as u64 + 1).read_to_end(&mut bytes)?;
        ensure!(bytes.len() <= LIMIT, "Settings are too large");
        let value: Value = serde_json::from_slice(&bytes)?;
        ensure!(value.is_object(), "Settings must be an object");
        let mut hash = Sha256::new();
        hash.update(b"after-settings-v1:present:");
        hash.update(&bytes);
        Ok(Snapshot {
            value,
            revision: format!("{:x}", hash.finalize()),
        })
    }
    fn write_locked(&self, value: &Value) -> Result<String> {
        ensure!(
            value.is_object() && serde_json::to_vec_pretty(value)?.len() < LIMIT,
            "Invalid or oversized settings"
        );
        self.recheck()?;
        crate::platform_fs::ordinary_single_file(&self.root.join("settings.json"))?;
        crate::storage::atomic_json(&self.root.join("settings.json"), value)?;
        self.recheck()?;
        let committed = self.snapshot()?;
        ensure!(committed.value == *value, "Settings changed after commit");
        Ok(committed.revision)
    }
    pub fn replace(&self, value: &Value) -> Result<String> {
        let _lock = self.lock()?;
        self.write_locked(value)
    }
    pub fn compare_replace(
        &self,
        expected: &str,
        value: &Value,
        verify: impl FnOnce() -> Result<()>,
    ) -> Result<String> {
        let _lock = self.lock()?;
        ensure!(
            self.snapshot()?.revision == expected,
            "Settings changed; refresh before selecting a model"
        );
        verify()?;
        // Verification can be expensive; re-observe legacy/out-of-process writes.
        ensure!(
            self.snapshot()?.revision == expected,
            "Settings changed during model verification"
        );
        self.write_locked(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_selection_preserves_latest_settings_and_unknown_fields() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::open(root.path()).unwrap();
        let absent = store.snapshot().unwrap();
        store.replace(&json!({})).unwrap();
        assert_ne!(absent.revision, store.snapshot().unwrap().revision);
        let first = store.snapshot().unwrap();
        let latest = json!({"future":{"keep":true},"speechMode":"cloud","private":"fixture"});
        store.replace(&latest).unwrap();
        assert!(store
            .compare_replace(&first.revision, &json!({"speechMode":"local"}), || panic!(
                "stale work must not verify models"
            ))
            .is_err());
        assert_eq!(store.snapshot().unwrap().value, latest);
        let observed = store.snapshot().unwrap();
        assert!(store
            .compare_replace(&observed.revision, &json!({}), || {
                crate::storage::atomic_json(
                    &root.path().join("settings.json"),
                    &json!({"legacyChange":true}),
                )
            })
            .is_err());
        assert_eq!(
            store.snapshot().unwrap().value,
            json!({"legacyChange":true})
        );
    }
    #[test]
    fn ffi_settings_writer_waits_for_the_same_selection_commit_lock() {
        use std::{sync::mpsc, thread, time::Duration};
        let root = tempfile::tempdir().unwrap();
        let store = Store::open(root.path()).unwrap();
        store.replace(&json!({"before":true})).unwrap();
        let expected = store.snapshot().unwrap().revision;
        let (ready, held) = mpsc::channel();
        let (release, permit) = mpsc::channel();
        let selection_root = root.path().to_owned();
        let selection = thread::spawn(move || {
            Store::open(&selection_root).unwrap().compare_replace(
                &expected,
                &json!({"selected":true}),
                || {
                    ready.send(()).unwrap();
                    permit.recv().unwrap();
                    Ok(())
                },
            )
        });
        held.recv_timeout(Duration::from_secs(5)).unwrap();
        let writer_root = root.path().to_owned();
        let (starting, started) = mpsc::channel();
        let (done, finished) = mpsc::channel();
        let writer = thread::spawn(move || {
            starting.send(()).unwrap();
            let result = crate::request(
                &json!({"root":writer_root,"command":"write","path":"settings.json","value":{"after":true}}),
            );
            done.send(()).unwrap();
            result
        });
        started.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(finished.recv_timeout(Duration::from_millis(100)).is_err());
        release.send(()).unwrap();
        selection.join().unwrap().unwrap();
        writer.join().unwrap().unwrap();
        assert_eq!(store.snapshot().unwrap().value, json!({"after":true}));
    }
    #[test]
    fn aliases_are_not_replaced_and_invalid_settings_are_not_read() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::open(root.path()).unwrap();
        let path = root.path().join("settings.json");
        let outside = root.path().join("outside");
        fs::write(&outside, b"{}").unwrap();
        std::os::unix::fs::symlink(&outside, &path).unwrap();
        assert!(store.snapshot().is_err());
        assert!(store.replace(&json!({})).is_err());
        fs::remove_file(&path).unwrap();
        fs::hard_link(&outside, &path).unwrap();
        assert!(store.snapshot().is_err());
        assert!(store.replace(&json!({})).is_err());
        fs::remove_file(&path).unwrap();
        for data in [b"[]".to_vec(), b"broken".to_vec(), vec![b' '; LIMIT + 1]] {
            fs::write(&path, &data).unwrap();
            assert!(store.snapshot().is_err());
        }
        assert_eq!(fs::read(outside).unwrap(), b"{}");
    }
}
