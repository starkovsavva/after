//! Desktop-only import: the native host selects the source; the renderer cannot
//! invoke this operation with a path. Only a completed copy receives metadata.
use crate::{platform_fs, storage};
use anyhow::{ensure, Context, Result};
use chrono::Utc;
use serde_json::{json, Value};
use std::{
    fs::{self, File},
    io::Read,
    path::Path,
};
use uuid::Uuid;

const EXTENSIONS: &[&str] = &[
    "mp4", "mov", "m4a", "mp3", "wav", "aiff", "aif", "caf", "flac", "ogg", "webm", "mkv", "aac",
];
const MARKER: &str = ".after-import.lock";

// A global lock closes the gap between creating a marker and locking it.
fn imports_lock(meetings: &Path) -> Result<File> {
    let file = platform_fs::open_private(&meetings.join(".after-imports.lock"), false)?;
    file.lock()?;
    Ok(file)
}

// Only clean directories unambiguously marked as ours; never follow links or
// remove unfamiliar files. Live workers own an exclusive per-import lock.
fn clean_abandoned(meetings: &Path) -> Result<()> {
    for entry in fs::read_dir(meetings)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(id) = name.to_str() else { continue };
        if Uuid::parse_str(id).is_err() {
            continue;
        }
        let dir = entry.path();
        if !entry.file_type()?.is_dir() || fs::symlink_metadata(dir.join("meta.json")).is_ok() {
            continue;
        }
        let marker = dir.join(MARKER);
        if !fs::symlink_metadata(&marker).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink())
        {
            continue;
        }
        let Ok(pin) = platform_fs::pin_directory(&dir) else {
            continue;
        };
        let Ok(lock) = platform_fs::open_private(&marker, false) else {
            continue;
        };
        if lock.try_lock().is_err() {
            continue;
        }
        let mut owned = Vec::new();
        let mut safe = true;
        for file in fs::read_dir(&dir)? {
            let file = file?;
            let name = file.file_name();
            let Some(name) = name.to_str() else {
                safe = false;
                break;
            };
            if name == MARKER {
                continue;
            }
            let source = name
                .strip_prefix("source.")
                .is_some_and(|ext| EXTENSIONS.contains(&ext));
            let temporary = name
                .strip_prefix(".posle-")
                .and_then(|v| v.strip_suffix(".tmp"))
                .is_some_and(|id| Uuid::parse_str(id).is_ok());
            let kind = file.file_type()?;
            if !(source || temporary) || !kind.is_file() || kind.is_symlink() {
                safe = false;
                break;
            }
            owned.push(file.path());
        }
        if safe {
            for file in owned {
                if fs::remove_file(file).is_err() {
                    safe = false;
                    break;
                }
            }
        }
        drop(lock);
        if safe && fs::remove_file(&marker).is_ok() {
            drop(pin);
            let _ = fs::remove_dir(&dir);
        }
    }
    Ok(())
}

pub(crate) fn import(
    root: &Path,
    source: &Path,
    focus: &str,
    requested_title: Option<&str>,
) -> Result<Value> {
    ensure!(source.is_absolute(), "Expected an absolute source path");
    let source = source.canonicalize().context("Cannot open source")?;
    let extension = source
        .extension()
        .and_then(|v| v.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    ensure!(
        EXTENSIONS.contains(&extension.as_str()),
        "Unsupported media format"
    );
    let input = File::open(&source)?;
    let initial = input.metadata()?;
    ensure!(
        initial.is_file() && initial.len() > 0,
        "Expected a nonempty regular source file"
    );
    let meetings = root.join("meetings");
    platform_fs::private_directory(&meetings)?;
    let _meetings_pin = platform_fs::pin_directory(&meetings)?;
    let setup = imports_lock(&meetings)?;
    clean_abandoned(&meetings)?;
    let id = Uuid::new_v4().to_string();
    let directory = meetings.join(&id);
    platform_fs::create_private_directory(&directory)?;
    let lock = platform_fs::open_private(&directory.join(MARKER), true)?;
    lock.lock()?;
    drop(setup);
    let result = (|| -> Result<Value> {
        let filename = format!("source.{extension}");
        let mut output = platform_fs::open_private(&directory.join(&filename), true)?;
        let copied = std::io::copy(&mut (&input).take(initial.len()), &mut output)?;
        let final_info = input.metadata()?;
        ensure!(
            copied == initial.len()
                && final_info.len() == initial.len()
                && initial.modified().ok() == final_info.modified().ok(),
            "Source changed during import"
        );
        output.sync_all()?;
        let raw = requested_title.unwrap_or_else(|| {
            source
                .file_stem()
                .and_then(|v| v.to_str())
                .unwrap_or("Meeting")
        });
        let title: String = raw.chars().filter(|c| !c.is_control()).take(500).collect();
        let title = if title.trim().is_empty() {
            "Meeting"
        } else {
            title.trim()
        };
        let meta = json!({"id":id,"title":title,"createdAt":Utc::now().timestamp_millis() as f64 / 1000.0,
            "source":filename,"status":"imported","duration":0,"speakerNames":{},"completedTasks":[],"focus":focus,
            "recordingTracks":false,"hasVideo":false});
        storage::atomic_json(&directory.join("meta.json"), &meta)?;
        Ok(meta)
    })();
    drop(lock);
    if result.is_ok() {
        let _ = fs::remove_file(directory.join(MARKER));
    } else if let Ok(_setup) = imports_lock(&meetings) {
        let _ = clean_abandoned(&meetings);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn imports_copy_without_exposing_or_changing_original_and_commit_last() {
        let base = tempfile::tempdir().unwrap();
        let root = base.path().join("library");
        let source = base.path().join("Синтетическая встреча.wav");
        let bytes = b"synthetic wave bytes, no real recording";
        fs::write(&source, bytes).unwrap();
        let request =
            json!({"command":"import_meeting","arguments":{"sourcePath":source,"focus":""}});
        let response = crate::desktop::handle_bytes(&root, &serde_json::to_vec(&request).unwrap());
        assert_eq!(response["ok"], true, "{response}");
        assert!(!response.to_string().contains(source.to_str().unwrap()));
        let dto = &response["result"];
        assert_eq!(dto["title"], "Синтетическая встреча");
        assert!(dto["folderId"].is_null());
        assert_eq!(dto["hasMedia"], true);
        assert_eq!(dto["mediaKind"], "audio");
        let dir = root.join("meetings").join(dto["id"].as_str().unwrap());
        assert_eq!(fs::read(dir.join("source.wav")).unwrap(), bytes);
        assert_eq!(fs::read(&source).unwrap(), bytes);
        assert!(dir.join("meta.json").is_file());
        assert!(!dir.join(MARKER).exists());
        assert_eq!(storage::list_meetings(&root).unwrap().len(), 1);
        let invalid = crate::desktop::handle_bytes(
            &root,
            br#"{"command":"import_meeting","arguments":{"sourcePath":"relative.wav"}}"#,
        );
        assert_eq!(invalid["error"]["code"], "invalid_request");
    }

    #[test]
    fn orphan_cleanup_preserves_active_unknown_and_published_data() {
        let root = tempfile::tempdir().unwrap();
        let meetings = root.path().join("meetings");
        platform_fs::private_directory(&meetings).unwrap();
        let make = || {
            let dir = meetings.join(Uuid::new_v4().to_string());
            platform_fs::create_private_directory(&dir).unwrap();
            let lock = platform_fs::open_private(&dir.join(MARKER), true).unwrap();
            platform_fs::open_private(&dir.join("source.wav"), true)
                .unwrap()
                .write_all(b"partial")
                .unwrap();
            (dir, lock)
        };
        let (abandoned, unlocked) = make();
        drop(unlocked);
        let (active, held) = make();
        held.lock().unwrap();
        let (unknown, unlocked) = make();
        drop(unlocked);
        fs::write(unknown.join("valuable.txt"), b"keep").unwrap();
        let (published, unlocked) = make();
        drop(unlocked);
        fs::write(published.join("meta.json"), b"{}").unwrap();
        clean_abandoned(&meetings).unwrap();
        assert!(!abandoned.exists());
        assert!(active.join("source.wav").exists());
        assert!(unknown.join("valuable.txt").exists());
        assert!(published.join("meta.json").exists());
        drop(held);
    }
}
