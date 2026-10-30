//! Desktop-only import: the native host selects the source; the renderer cannot
//! invoke this operation with a path. Only a completed copy receives metadata.
use crate::{platform_fs, storage};
use anyhow::{ensure, Context, Result};
use chrono::Utc;
use serde_json::{json, Value};
use std::{
    fs::{self, File},
    io::{Read, Seek, SeekFrom},
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

// Only report a duration when the RIFF bounds, PCM format and data length
// agree. Invalid or compressed WAVs are imported unchanged with unknown duration.
fn wav_duration(file: &mut File) -> Option<f64> {
    fn u16le(b: &[u8]) -> u16 {
        u16::from_le_bytes(b.try_into().ok().unwrap())
    }
    fn u32le(b: &[u8]) -> u32 {
        u32::from_le_bytes(b.try_into().ok().unwrap())
    }
    let total = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(0)).ok()?;
    let mut header = [0u8; 12];
    file.read_exact(&mut header).ok()?;
    if &header[..4] != b"RIFF" || &header[8..] != b"WAVE" {
        return None;
    }
    let end = u64::from(u32le(&header[4..8])).checked_add(8)?;
    if end < 12 || end > total {
        return None;
    }
    let mut position = 12u64;
    let mut format = None;
    let mut data = None;
    for _ in 0..4096 {
        if position.checked_add(8)? > end {
            break;
        }
        file.seek(SeekFrom::Start(position)).ok()?;
        let mut chunk = [0u8; 8];
        file.read_exact(&mut chunk).ok()?;
        let size = u64::from(u32le(&chunk[4..8]));
        let start = position.checked_add(8)?;
        let next = start.checked_add(size)?.checked_add(size % 2)?;
        if next > end {
            return None;
        }
        if &chunk[..4] == b"fmt " && format.is_none() {
            if size < 16 {
                return None;
            }
            let mut bytes = [0u8; 40];
            let read = usize::try_from(size.min(40)).ok()?;
            file.read_exact(&mut bytes[..read]).ok()?;
            let tag = u16le(&bytes[0..2]);
            let channels = u16le(&bytes[2..4]);
            let rate = u32le(&bytes[4..8]);
            let bytes_per_second = u32le(&bytes[8..12]);
            let alignment = u16le(&bytes[12..14]);
            let bits = u16le(&bytes[14..16]);
            let supported = match tag {
                1 | 3 => true,
                0xfffe if read >= 40 && u16le(&bytes[16..18]) >= 22 => {
                    let subtype = u32le(&bytes[24..28]);
                    matches!(subtype, 1 | 3)
                        && bytes[28..40] == [0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113]
                }
                _ => false,
            };
            if !supported
                || channels == 0
                || rate == 0
                || bits == 0
                || bits % 8 != 0
                || u32::from(channels).checked_mul(u32::from(bits / 8))? != u32::from(alignment)
                || rate.checked_mul(u32::from(alignment))? != bytes_per_second
            {
                return None;
            }
            format = Some((bytes_per_second, alignment));
        } else if &chunk[..4] == b"data" && data.is_none() {
            data = Some(size);
        }
        if let (Some((bytes_per_second, alignment)), Some(bytes)) = (format, data) {
            if bytes % u64::from(alignment) != 0 {
                return None;
            }
            return Some(bytes as f64 / f64::from(bytes_per_second));
        }
        position = next;
    }
    None
}

// Older imported/recorded WAV meetings may have a zero duration in metadata.
// Probe only their own private source, without rewriting the saved meeting.
pub(crate) fn existing_wav_duration(root: &Path, id: &str, meta: &Value) -> Option<f64> {
    if meta["id"].as_str()? != id {
        return None;
    }
    let name = meta["source"].as_str()?;
    if Path::new(name).file_name()?.to_str()? != name
        || !name.to_ascii_lowercase().ends_with(".wav")
    {
        return None;
    }
    let directory = storage::meeting_directory(root, id).ok()?;
    let _pin = platform_fs::pin_directory(&directory).ok()?;
    let mut file = platform_fs::open_read(&directory.join(name)).ok()?;
    wav_duration(&mut file).filter(|duration| *duration > 0.0)
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
        let duration = if extension == "wav" {
            wav_duration(&mut output)
        } else {
            None
        };
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
            "source":filename,"status":"imported","duration":duration.unwrap_or(0.0),"speakerNames":{},"completedTasks":[],"focus":focus,
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

    fn synthetic_wav() -> Vec<u8> {
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&4046u32.to_le_bytes()); // 38 bytes of headers + 4000 data + 8-byte JUNK chunk
        wav.extend_from_slice(b"WAVEJUNK");
        wav.extend_from_slice(&1u32.to_le_bytes());
        wav.extend_from_slice(&[42, 0]); // odd sized chunk has one pad byte
        wav.extend_from_slice(b"fmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1000u32.to_le_bytes());
        wav.extend_from_slice(&2000u32.to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&4000u32.to_le_bytes());
        wav.extend_from_slice(&[0; 4000]);
        wav
    }

    #[test]
    fn imported_pcm_wav_reports_duration_unknown_formats_do_not() {
        let base = tempfile::tempdir().unwrap();
        let root = base.path().join("library");
        let source = base.path().join("clip.wav");
        let wav = synthetic_wav();
        assert_eq!(wav.len(), 4054);
        fs::write(&source, &wav).unwrap();
        let request = json!({"command":"import_meeting","arguments":{"sourcePath":source}});
        let response = crate::desktop::handle_bytes(&root, &serde_json::to_vec(&request).unwrap());
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["result"]["durationSeconds"], 2.0);
        let id = response["result"]["id"].as_str().unwrap();
        let canonical =
            storage::regular_json(&root.join("meetings").join(id).join("meta.json")).unwrap();
        assert_eq!(canonical["duration"], 2.0);
        let workspace = crate::desktop::handle_bytes(&root, br#"{"command":"get_workspace"}"#);
        assert_eq!(workspace["result"]["meetings"][0]["durationSeconds"], 2.0);
        let meta_path = root.join("meetings").join(id).join("meta.json");
        let mut old = canonical.clone();
        old["duration"] = json!(0);
        storage::atomic_json(&meta_path, &old).unwrap();
        let workspace = crate::desktop::handle_bytes(&root, br#"{"command":"get_workspace"}"#);
        assert_eq!(workspace["result"]["meetings"][0]["durationSeconds"], 2.0);
        assert_eq!(storage::regular_json(&meta_path).unwrap()["duration"], 0);

        assert_eq!(fs::read(&source).unwrap(), wav);

        let broken = base.path().join("broken.wav");
        let mut truncated = wav;
        truncated.truncate(truncated.len() - 1);
        fs::write(&broken, truncated).unwrap();
        let request = json!({"command":"import_meeting","arguments":{"sourcePath":broken}});
        let response = crate::desktop::handle_bytes(&root, &serde_json::to_vec(&request).unwrap());
        assert_eq!(response["ok"], true, "{response}");
        assert!(response["result"]["durationSeconds"].is_null());
        let mp3 = base.path().join("unknown.mp3");
        fs::write(&mp3, b"unknown format, not a real recording").unwrap();
        let request = json!({"command":"import_meeting","arguments":{"sourcePath":mp3}});
        let response = crate::desktop::handle_bytes(&root, &serde_json::to_vec(&request).unwrap());
        assert!(response["result"]["durationSeconds"].is_null());
    }

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
