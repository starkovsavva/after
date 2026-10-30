//! Compact source snapshots keep complete transcripts out of the UI bridge.
use crate::storage::{meeting_directory, meeting_lock};
use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, OpenOptions},
    io::Read,
    os::unix::fs::OpenOptionsExt,
    path::Path,
};

// Match the existing search reader's source bounds, including long meetings.
const MAX_META: u64 = 1_048_576;
const MAX_TRANSCRIPT: u64 = 64 * 1_048_576;
const MAX_SUMMARY: u64 = 8 * 1_048_576;
const MAX_SEGMENT_IDS: usize = 100_000;

fn read(path: &Path, limit: u64) -> Result<Option<Value>> {
    let info = match fs::symlink_metadata(path) {
        Ok(info) => info,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    ensure!(
        info.is_file() && !info.file_type().is_symlink() && info.len() <= limit,
        "Некорректный файл источника"
    );
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let opened = file.metadata()?;
    ensure!(opened.is_file() && opened.len() <= limit, "Файл источника слишком большой");
    let mut bytes = Vec::with_capacity(opened.len() as usize);
    (&mut file).take(limit + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 <= limit, "Файл источника слишком большой");
    Ok(Some(serde_json::from_slice(&bytes).context("Не удалось прочитать источник")?))
}

pub fn snapshot(root: &Path, input: &Value) -> Result<Value> {
    let meeting_id = input["meetingID"].as_str().context("Нет ID встречи")?;
    let raw_ids = input["segmentIDs"].as_array().context("Нужен список номеров реплик")?;
    ensure!(raw_ids.len() <= MAX_SEGMENT_IDS, "Слишком много номеров реплик");
    let include_summary = match input.get("includeSummary") {
        Some(value) => value.as_bool().context("Некорректный запрос конспекта")?,
        None => false,
    };
    let mut requested = HashSet::with_capacity(raw_ids.len());
    let mut ordered = Vec::with_capacity(raw_ids.len());
    for value in raw_ids {
        let id = value.as_i64().filter(|id| *id >= 0).context("Некорректный номер реплики")?;
        if requested.insert(id) { ordered.push(id); }
    }

    let directory = meeting_directory(root, meeting_id)?;
    // The lock also serializes trash moves and source corrections. A missing
    // directory fails here rather than recreating a deleted meeting.
    let _lock = meeting_lock(&directory)?;
    let meeting = read(&directory.join("meta.json"), MAX_META)?.context("Встреча больше недоступна")?;
    ensure!(meeting.is_object() && meeting["id"].as_str() == Some(meeting_id), "Некорректная встреча");
    let transcript = read(&directory.join("transcript.json"), MAX_TRANSCRIPT)?
        .context("Транскрипт больше недоступен")?;
    let segments = transcript["segments"].as_array().context("В транскрипте нет реплик")?;
    let mut found = HashMap::with_capacity(ordered.len());
    for segment in segments {
        if let Some(id) = segment["id"].as_i64().filter(|id| requested.contains(id)) {
            // Preserve the existing Swift first(where:) behavior for legacy
            // transcripts with duplicate IDs, without scanning per citation.
            found.entry(id).or_insert(segment);
        }
    }
    let selected: Vec<_> = ordered.into_iter().filter_map(|id| found.remove(&id)).collect();
    let mut output = json!({"meeting": meeting, "segments": selected});
    if include_summary {
        let summary = read(&directory.join("summary.json"), MAX_SUMMARY)?;
        ensure!(summary.as_ref().is_none_or(Value::is_object), "Некорректный конспект");
        output["summary"] = json!(summary);
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{request, storage::atomic_json};

    fn fixture() -> tempfile::TempDir {
        let root = tempfile::tempdir().unwrap();
        let directory = meeting_directory(root.path(), "meeting").unwrap();
        atomic_json(&directory.join("meta.json"), &json!({"id":"meeting", "title":"Generated source", "source":"source.mp3", "createdAt":1, "future":"metadata preserved"})).unwrap();
        atomic_json(&directory.join("transcript.json"), &json!({"segments":[
            {"id":7,"start":1,"end":2,"speaker":"speaker_1","text":"First seven","overlap":false,"future":"preserved"},
            {"id":2,"start":3,"end":4,"speaker":"speaker_2","text":"Two","overlap":false},
            {"id":7,"start":5,"end":6,"speaker":"speaker_1","text":"Duplicate seven","overlap":false}
        ],"unneededTranscriptField":"not returned"})).unwrap();
        atomic_json(&directory.join("summary.json"), &json!({"overview":"Generated overview", "future":true})).unwrap();
        root
    }
    fn input(root: &Path) -> Value {
        json!({"root":root,"command":"source-snapshot","meetingID":"meeting","segmentIDs":[2,7,2,99,7]})
    }

    #[test]
    fn compact_snapshot_preserves_request_order_and_first_duplicate_values() {
        let root = fixture();
        let result = request(&input(root.path())).unwrap();
        assert_eq!(result["segments"].as_array().unwrap().len(), 2);
        assert_eq!(result["segments"][0]["id"], 2);
        assert_eq!(result["segments"][1]["text"], "First seven");
        assert_eq!(result["segments"][1]["future"], "preserved");
        assert_eq!(result["meeting"]["future"], "metadata preserved");
        assert!(result.get("summary").is_none());
        assert!(result.get("transcript").is_none());
        let mut empty = input(root.path());
        empty["segmentIDs"] = json!([]);
        assert_eq!(request(&empty).unwrap()["segments"], json!([]));
    }

    #[test]
    fn long_transcript_returns_only_requested_segments_and_accepts_swift_int_bounds() {
        let root = fixture();
        let mut segments: Vec<_> = (0..20_000).map(|id| json!({"id":id,"text":format!("Generated segment {id}")})).collect();
        segments.push(json!({"id":i64::MAX,"text":"Largest Swift Int"}));
        atomic_json(&root.path().join("meetings/meeting/transcript.json"), &json!({"segments":segments})).unwrap();
        let mut query = input(root.path());
        query["segmentIDs"] = json!([19_999,0,i64::MAX,10_000,50_000,19_999]);
        let result = request(&query).unwrap();
        let returned: Vec<_> = result["segments"].as_array().unwrap().iter().map(|segment| segment["id"].as_i64().unwrap()).collect();
        assert_eq!(returned, [19_999,0,i64::MAX,10_000]);
        assert!(serde_json::to_vec(&result).unwrap().len() < 1_000);
    }

    #[test]
    fn summary_is_optional_and_read_only_when_requested() {
        let root = fixture();
        let summary_path = root.path().join("meetings/meeting/summary.json");
        let mut query = input(root.path());
        query["includeSummary"] = json!(true);
        assert_eq!(request(&query).unwrap()["summary"], json!({"overview":"Generated overview","future":true}));
        fs::remove_file(&summary_path).unwrap();
        assert!(request(&query).unwrap()["summary"].is_null());
        fs::write(&summary_path, b"damaged").unwrap();
        query["includeSummary"] = json!(false);
        assert!(request(&query).is_ok());
        query["includeSummary"] = json!(true);
        assert!(request(&query).is_err());
        atomic_json(&summary_path, &json!([])).unwrap();
        assert!(request(&query).is_err());
    }

    #[test]
    fn malformed_inputs_fail_before_reading_sources() {
        let root = fixture();
        for ids in [Value::Null, json!(1), json!("7"), json!([1,"2"]), json!([true]), json!([1.0]), json!([-1]), json!([9_223_372_036_854_775_808_u64])] {
            let mut query = input(root.path());
            query["segmentIDs"] = ids;
            assert!(request(&query).is_err(), "{query}");
        }
        let mut query = input(root.path());
        query.as_object_mut().unwrap().remove("segmentIDs");
        assert!(request(&query).is_err());
        for include in [Value::Null, json!(0), json!("true"), json!([])] {
            query = input(root.path());
            query["includeSummary"] = include;
            assert!(request(&query).is_err());
        }
        query = input(root.path());
        query["segmentIDs"] = json!(vec![7; MAX_SEGMENT_IDS + 1]);
        assert!(request(&query).is_err());
        query["segmentIDs"] = json!(vec![7; MAX_SEGMENT_IDS]);
        assert_eq!(request(&query).unwrap()["segments"].as_array().unwrap().len(), 1);
        for id in ["", "../meeting", "a/b"] {
            query = input(root.path());
            query["meetingID"] = json!(id);
            assert!(request(&query).is_err());
        }
        query = input(root.path());
        query["root"] = json!("relative");
        assert!(request(&query).is_err());
    }

    #[test]
    fn unavailable_or_malformed_meeting_sources_are_rejected() {
        for name in ["meta.json", "transcript.json"] {
            let root = fixture();
            fs::remove_file(root.path().join("meetings/meeting").join(name)).unwrap();
            assert!(request(&input(root.path())).is_err());
        }
        for (name, malformed) in [("meta.json", json!({"id":"other"})), ("meta.json", json!([])), ("transcript.json", json!({"segments":{}})), ("transcript.json", Value::Null)] {
            let root = fixture();
            atomic_json(&root.path().join("meetings/meeting").join(name), &malformed).unwrap();
            assert!(request(&input(root.path())).is_err());
        }
        let root = fixture();
        let active = root.path().join("meetings/meeting");
        let deleted = root.path().join("deleted-meeting");
        fs::rename(&active, &deleted).unwrap();
        assert!(request(&input(root.path())).is_err());
        assert!(!active.exists(), "Reading must not recreate a deleted meeting");
    }

    #[test]
    fn linked_directories_and_source_files_cannot_escape_the_library() {
        use std::os::unix::fs::symlink;
        for name in ["meta.json", "transcript.json", "summary.json"] {
            let root = fixture();
            let target = tempfile::NamedTempFile::new().unwrap();
            fs::write(target.path(), b"{}").unwrap();
            let path = root.path().join("meetings/meeting").join(name);
            fs::remove_file(&path).unwrap();
            symlink(target.path(), &path).unwrap();
            let mut query = input(root.path());
            query["includeSummary"] = json!(true);
            assert!(request(&query).is_err(), "linked {name}");
            assert_eq!(fs::read(target.path()).unwrap(), b"{}");
        }
        for name in ["meeting", "meetings", "root"] {
            let root = fixture();
            let outside = tempfile::tempdir().unwrap();
            let path = match name {
                "meeting" => root.path().join("meetings/meeting"),
                "meetings" => root.path().join("meetings"),
                _ => root.path().to_path_buf(),
            };
            fs::remove_dir_all(&path).unwrap();
            symlink(outside.path(), &path).unwrap();
            assert!(request(&input(root.path())).is_err(), "linked {name}");
            assert!(fs::read_dir(outside.path()).unwrap().next().is_none());
        }
    }

    #[test]
    fn oversized_source_files_are_rejected_without_allocating_their_contents() {
        for (name, limit) in [("meta.json", MAX_META), ("transcript.json", MAX_TRANSCRIPT), ("summary.json", MAX_SUMMARY)] {
            let root = fixture();
            let path = root.path().join("meetings/meeting").join(name);
            let file = OpenOptions::new().write(true).open(path).unwrap();
            file.set_len(limit + 1).unwrap();
            let mut query = input(root.path());
            query["includeSummary"] = json!(true);
            assert!(request(&query).is_err(), "oversized {name}");
        }
    }
}
