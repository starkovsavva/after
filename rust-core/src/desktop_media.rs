//! Bounded random-access media reads for a host-owned streaming protocol.
//! A renderer supplies only the meeting ID, never a filesystem path.
use crate::{platform_fs, storage};
use anyhow::{ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::{
    io::{Read, Seek, SeekFrom},
    path::Path,
};

pub(crate) const MAX_CHUNK: u32 = 1024 * 1024;
const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
fn mime(name: &str) -> Option<&'static str> {
    match name.rsplit('.').next()?.to_ascii_lowercase().as_str() {
        "wav" => Some("audio/wav"),
        "mp3" => Some("audio/mpeg"),
        "m4a" => Some("audio/mp4"),
        "aac" => Some("audio/aac"),
        "flac" => Some("audio/flac"),
        "ogg" => Some("audio/ogg"),
        "aif" | "aiff" => Some("audio/aiff"),
        "caf" => Some("audio/x-caf"),
        "mp4" => Some("video/mp4"),
        "mov" => Some("video/quicktime"),
        "webm" => Some("video/webm"),
        "mkv" => Some("video/x-matroska"),
        _ => None,
    }
}
fn open_media(root: &Path, id: &str) -> Result<(std::fs::File, &'static str)> {
    let dir = storage::meeting_directory(root, id)?;
    let _pin = platform_fs::pin_directory(&dir)?;
    let meta = storage::regular_json_limited(&dir.join("meta.json"), 1_048_576)?;
    ensure!(meta["id"].as_str() == Some(id), "Invalid meeting metadata");
    // Native Mac recordings keep the mixed audio in source and the finished
    // screen recording in video.mp4. Prefer it only when metadata opts in and
    // the ordinary private video is actually available and non-empty.
    if meta["hasVideo"].as_bool() == Some(true) {
        if let Ok(video) = platform_fs::open_read(&dir.join("video.mp4")) {
            if video.metadata().is_ok_and(|info| info.len() > 0) {
                return Ok((video, "video/mp4"));
            }
        }
    }
    let name = meta["source"].as_str().context("Missing media")?;
    ensure!(
        !name.is_empty() && Path::new(name).file_name().and_then(|v| v.to_str()) == Some(name),
        "Invalid media name"
    );
    let content_type = mime(name).context("Unsupported media type")?;
    let file = platform_fs::open_read(&dir.join(name))?;
    Ok((file, content_type))
}
pub(crate) fn kind(root: &Path, id: &str) -> Option<&'static str> {
    let (file, content_type) = open_media(root, id).ok()?;
    if file.metadata().ok()?.len() == 0 {
        return None;
    }
    Some(if content_type.starts_with("video/") {
        "video"
    } else {
        "audio"
    })
}
pub(crate) fn read(root: &Path, id: &str, offset: u64, length: u32) -> Result<Value> {
    ensure!(
        length > 0 && length <= MAX_CHUNK && offset <= MAX_SAFE_INTEGER,
        "Invalid media range"
    );
    let (mut file, content_type) = open_media(root, id)?;
    let metadata = file.metadata()?;
    let total = metadata.len();
    ensure!(
        total <= MAX_SAFE_INTEGER && offset <= total,
        "Media range outside file"
    );
    file.seek(SeekFrom::Start(offset))?;
    let requested = u64::from(length).min(total - offset) as usize;
    let mut buffer = vec![0; requested];
    file.read_exact(&mut buffer)?;
    let after = file.metadata()?;
    ensure!(
        after.len() == total && metadata.modified().ok() == after.modified().ok(),
        "Media changed during read"
    );
    Ok(
        json!({"meetingId":id,"offset":offset,"totalBytes":total,"contentType":content_type,"dataBase64":STANDARD.encode(buffer)}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[test]
    fn native_video_is_preferred_only_when_marked_and_safe() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("source.wav");
        fs::write(&source, b"audio").unwrap();
        let meta = crate::desktop_import::import(root.path(), &source, "", None).unwrap();
        let id = meta["id"].as_str().unwrap();
        let dir = root.path().join("meetings").join(id);
        fs::write(dir.join("video.mp4"), b"video-payload").unwrap();
        assert_eq!(kind(root.path(), id), Some("audio"));
        let mut meta = meta.clone();
        meta["hasVideo"] = json!(true);
        storage::atomic_json(&dir.join("meta.json"), &meta).unwrap();
        assert_eq!(kind(root.path(), id), Some("video"));
        let video = read(root.path(), id, 0, 30).unwrap();
        assert_eq!(video["contentType"], "video/mp4");
        assert_eq!(
            STANDARD
                .decode(video["dataBase64"].as_str().unwrap())
                .unwrap(),
            b"video-payload"
        );
        fs::remove_file(dir.join("video.mp4")).unwrap();
        assert_eq!(kind(root.path(), id), Some("audio"));
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&source, dir.join("video.mp4")).unwrap();
            assert_eq!(kind(root.path(), id), Some("audio"));
            assert_eq!(
                read(root.path(), id, 0, 30).unwrap()["contentType"],
                "audio/wav"
            );
        }
    }
    #[test]
    fn chunks_seek_and_refuse_external_paths_and_bad_ranges() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("test.wav");
        fs::write(&source, b"synthetic-audio-content").unwrap();
        let result = crate::desktop_import::import(root.path(), &source, "", None).unwrap();
        let id = result["id"].as_str().unwrap();
        assert_eq!(kind(root.path(), id), Some("audio"));
        let value = read(root.path(), id, 10, 5).unwrap();
        assert_eq!(
            STANDARD
                .decode(value["dataBase64"].as_str().unwrap())
                .unwrap(),
            b"audio"
        );
        assert_eq!(value["offset"], 10);
        assert_eq!(value["totalBytes"], 23);
        assert_eq!(value["contentType"], "audio/wav");
        assert!(read(root.path(), id, 24, 5).is_err());
        assert!(read(root.path(), id, 0, MAX_CHUNK + 1).is_err());
        let dir = root.path().join("meetings").join(id);
        storage::atomic_json(
            &dir.join("meta.json"),
            &json!({"id":id,"source":"../../test.wav"}),
        )
        .unwrap();
        assert!(read(root.path(), id, 0, 1).is_err());
        assert_eq!(kind(root.path(), id), None);
        assert_eq!(fs::read(source).unwrap(), b"synthetic-audio-content");
    }
}
