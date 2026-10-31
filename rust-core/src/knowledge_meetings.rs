//! Bounded, read-only snapshots of published meeting sources for the knowledge
//! organizer. A snapshot is not a grant: consumers must revalidate immediately
//! before publishing or opening it and must apply their own narrower scope.
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

const MAX_META: u64 = 1_048_576;
const MAX_TRANSCRIPT: u64 = 64 * 1_048_576;
const MAX_SUMMARY: u64 = 8 * 1_048_576;
const MAX_SEGMENTS: usize = 100_000;
const MAX_RESULTS_PER_MEETING: usize = 500;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct MeetingSource {
    pub kind: String,
    #[serde(rename = "meetingID")]
    pub meeting_id: String,
    #[serde(rename = "segmentID", skip_serializing_if = "Option::is_none")]
    pub segment_id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub item_index: Option<usize>,
    pub title: String,
    pub text: String,
    pub content_fingerprint: String,
    pub policy_fingerprint: String,
}

fn safe_read(path: &Path, limit: u64) -> Result<Option<Vec<u8>>> {
    let info = match fs::symlink_metadata(path) {
        Ok(info) => info,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
    };
    ensure!(info.is_file() && !info.file_type().is_symlink() && info.len() <= limit, "Недоступный файл встречи");
    let mut file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK).open(path)?;
    ensure!(file.metadata()?.is_file() && file.metadata()?.len() <= limit, "Недоступный файл встречи");
    let mut bytes = Vec::new();
    (&mut file).take(limit + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 <= limit, "Файл встречи слишком большой");
    Ok(Some(bytes))
}
fn digest(bytes: &[u8]) -> String { format!("{:x}", Sha256::digest(bytes)) }
fn shortened(value: &str, limit: usize) -> String {
    let mut end = value.len().min(limit);
    while !value.is_char_boundary(end) { end -= 1; }
    value[..end].to_owned()
}
fn profile(root: &Path, id: &str, folder: Option<&str>) -> Result<String> {
    let source = json!({"meetingID":id});
    let resolver = crate::ai::FeatureResolver::new(root)?;
    ensure!(resolver.features_for(&source)?.knowledge_base && resolver.in_scope(&source, &json!({"folderID":folder})),
        "Источник недоступен в выбранной области базы знаний");
    Ok(crate::ai::profile_for_input(root, &source)?.fingerprint)
}

/// Only persisted, fully published transcript segments and summaries whose
/// recorded dependency equals the exact transcript bytes are returned.
pub(crate) fn snapshot(root: &Path, id: &str, folder: Option<&str>) -> Result<(Vec<MeetingSource>, bool)> {
    ensure!(root.is_absolute(), "Нужен абсолютный путь библиотеки");
    let policy = profile(root, id, folder)?;
    let directory = crate::storage::meeting_directory(root, id)?;
    let (sources, partial) = {
        let _lock = crate::storage::meeting_lock(&directory)?;
        let meta = safe_read(&directory.join("meta.json"), MAX_META)?.context("Встреча недоступна")?;
        let meta: Value = serde_json::from_slice(&meta)?;
        ensure!(meta["id"].as_str() == Some(id) && meta["libraryKind"] != "cards" &&
            !matches!(meta["status"].as_str(), Some("recording" | "processing")), "Встреча ещё обрабатывается");
        let title = shortened(meta["title"].as_str().unwrap_or("Встреча"), 300);
        let raw = safe_read(&directory.join("transcript.json"), MAX_TRANSCRIPT)?.context("Нет опубликованного транскрипта")?;
        let transcript: Value = serde_json::from_slice(&raw)?;
        let segments = transcript["segments"].as_array().context("В транскрипте нет реплик")?;
        ensure!(segments.len() <= MAX_SEGMENTS, "Транскрипт слишком большой");
        let transcript_hash = digest(&raw);
        let mut count = HashMap::<u64, usize>::new();
        for item in segments { if let Some(id) = item["id"].as_u64() { *count.entry(id).or_default() += 1; } }
        let mut valid = HashSet::<u64>::new();
        let mut result = Vec::new();
        let mut partial = false;
        for item in segments {
            let (Some(segment), Some(start), Some(end), Some(text)) = (item["id"].as_u64(), item["start"].as_f64(), item["end"].as_f64(), item["text"].as_str()) else { partial = true; continue };
            if segment > i64::MAX as u64 || count.get(&segment) != Some(&1) || !start.is_finite() || !end.is_finite() || start < 0.0 || end < start || text.trim().is_empty() { partial = true; continue; }
            valid.insert(segment);
            // Reserve space for current summaries even for long meetings.
            if result.len() >= 400 { partial = true; continue; }
            if text.len() > 4000 { partial = true; }
            result.push(MeetingSource { kind:"transcript".into(), meeting_id:id.into(), segment_id:Some(segment), item_index:None,
                title:title.clone(), text:shortened(text, 4000), content_fingerprint:transcript_hash.clone(), policy_fingerprint:policy.clone() });
        }
        if let Some(summary_raw) = safe_read(&directory.join("summary.json"), MAX_SUMMARY)? {
            let summary: Value = serde_json::from_slice(&summary_raw)?;
            if summary["sourceFingerprint"].as_str() == Some(transcript_hash.as_str()) && summary["sourceStale"] != true {
                let version = digest(&summary_raw);
                let valid_refs = |value: &Value| value.as_array().is_some_and(|ids| !ids.is_empty() && ids.len() <= 10_000 && ids.iter().all(|id| id.as_u64().is_some_and(|id|valid.contains(&id))));
                let mut skipped_summary = summary["overviewStale"] == true ||
                    summary["items"].as_array().is_some_and(|items|items.len()>10_000) ||
                    (!summary["items"].is_null() && !summary["items"].is_array()) ||
                    (!summary["overview"].is_null() && !summary["overview"].is_string());
                let mut add = |text: &str, item_index: Option<usize>| {
                    if text.trim().is_empty() { return; }
                    if result.len() >= MAX_RESULTS_PER_MEETING { partial = true; return; }
                    if text.len() > 4000 { partial = true; }
                    result.push(MeetingSource { kind:"summary".into(), meeting_id:id.into(), segment_id:None, item_index,
                        title:title.clone(), text:shortened(text,4000), content_fingerprint:version.clone(), policy_fingerprint:policy.clone() });
                };
                if summary["overviewStale"] != true {
                    if let Some(text) = summary["overview"].as_str() {
                        if text.trim().is_empty() { skipped_summary = true; } else { add(text, None); }
                    }
                }
                for (index, item) in summary["items"].as_array().into_iter().flatten().take(10_000).enumerate() {
                    if valid_refs(&item["segmentIDs"]) {
                        if let Some(text) = item["text"].as_str().filter(|text|!text.trim().is_empty()) { add(text, Some(index)); }
                        else { skipped_summary = true; }
                    } else { skipped_summary = true; }
                }
                partial |= skipped_summary;
            } else { partial = true; }
        }
        (result, partial)
    };
    ensure!(profile(root, id, folder)? == policy, "Настройки источника изменились. Обновите результаты.");
    Ok((sources, partial))
}

/// Collect a bounded snapshot after applying each meeting's knowledge policy.
/// Callers must not treat truncation as a complete view of the library.
pub(crate) fn scan(root: &Path, folder: Option<&str>, limit: usize) -> Result<(Vec<MeetingSource>, bool)> {
    ensure!((1..=2_000).contains(&limit), "Некорректный лимит источников");
    let meetings = crate::storage::list_meetings(root)?;
    let resolver = crate::ai::FeatureResolver::new(root)?;
    let mut result = Vec::new();
    let mut partial = false;
    let mut examined = 0usize;
    for meeting in meetings {
        let Some(id) = meeting["id"].as_str() else { continue };
        let source = json!({"meetingID":id});
        if !resolver.in_scope(&source, &json!({"folderID":folder})) ||
            !resolver.features_for(&source).is_ok_and(|f|f.knowledge_base) { continue; }
        if examined >= 100 { partial = true; break; }
        examined += 1;
        match snapshot(root, id, folder) {
            Ok((sources, truncated)) => {
                partial |= truncated;
                for source in sources {
                    if result.len() == limit { partial = true; break; }
                    result.push(source);
                }
                if result.len() == limit { partial = true; break; }
            }
            Err(_) => { partial = true; }
        }
    }
    Ok((result, partial))
}

/// A link identifies an exact published content version, not a filesystem
/// incarnation. Restoring identical bytes under the same meeting ID restores
/// that version. Current permissions are always required; explicit unlink is
/// a separate durable tombstone and is never undone by source restoration.
/// A reference supplied by a client is never trusted as evidence on its own.
pub(crate) fn validate(root: &Path, source: &MeetingSource, folder: Option<&str>) -> bool {
    snapshot(root, &source.meeting_id, folder).is_ok_and(|(items, _)| items.into_iter().any(|current|
        current.kind == source.kind && current.segment_id == source.segment_id && current.item_index == source.item_index &&
        current.content_fingerprint == source.content_fingerprint &&
        current.title == source.title && current.text == source.text))
}

fn note(root: &Path, id: &str, revision: u64) -> Result<crate::notes::CapturedNote> {
    let note = crate::notes::load_note_snapshot(root, id)?;
    ensure!(note.kind == "note" && note.trashed_at.is_none() && note.revision == revision,
        "Заметка изменилась или недоступна. Обновите подсказки.");
    ensure!(crate::ai::FeatureResolver::new(root)?.features_for(&json!({"noteID":id}))?.knowledge_base,
        "База знаний выключена для этой заметки");
    Ok(note)
}

pub(crate) fn suggestions(root: &Path, input: &Value) -> Result<Value> {
    let id = input["noteID"].as_str().context("Нет идентификатора заметки")?;
    let revision = input["noteRevision"].as_u64().context("Нет версии заметки")?;
    let source = note(root, id, revision)?;
    let source_terms = crate::search::related_terms(&source.title, &source.text);
    if source_terms.len() < 2 { return Ok(json!({"items":[],"partial":false})); }
    let (candidates,partial) = scan(root, None, 2_000)?;
    let mut matches = candidates.into_iter().filter_map(|candidate| {
        let terms = crate::search::related_terms(&candidate.title,&candidate.text);
        let mut shared = source_terms.iter().filter_map(|(stem,(word,_))|
            terms.contains_key(stem).then_some(word.clone())).collect::<Vec<_>>();
        shared.sort(); shared.dedup();
        (shared.len() >= 2).then_some((shared.len(),candidate,shared))
    }).collect::<Vec<_>>();
    matches.sort_by(|a,b|b.0.cmp(&a.0).then_with(||a.1.meeting_id.cmp(&b.1.meeting_id))
        .then_with(||a.1.segment_id.cmp(&b.1.segment_id)));
    let mut meetings = HashSet::new();
    let mut result = Vec::new();
    for (_,candidate,shared) in matches {
        if meetings.contains(&candidate.meeting_id) || !validate(root,&candidate,None) { continue; }
        meetings.insert(candidate.meeting_id.clone());
        result.push(json!({"source":candidate,"sharedTerms":shared.into_iter().take(4).collect::<Vec<_>>() }));
        if result.len() == 3 { break; }
    }
    let current=note(root,id,revision)?;
    ensure!(serde_json::to_value(&source)? == serde_json::to_value(&current)?, "Заметка изменилась. Обновите подсказки.");
    Ok(json!({"items":result,"partial":partial}))
}

pub(crate) fn validate_for_note(root: &Path, input: &Value) -> Result<Value> {
    let id = input["noteID"].as_str().context("Нет идентификатора заметки")?;
    let revision = input["noteRevision"].as_u64().context("Нет версии заметки")?;
    note(root,id,revision)?;
    let source: MeetingSource = serde_json::from_value(input["source"].clone())?;
    Ok(json!({"valid":validate(root,&source,None)}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::atomic_json;

    fn fixture() -> tempfile::TempDir {
        let root = tempfile::tempdir().unwrap();
        atomic_json(&root.path().join("settings.json"), &json!({"features":{"knowledgeBase":true}})).unwrap();
        meeting(root.path(), "one");
        root
    }
    fn meeting(root: &Path, id: &str) {
        let dir = root.join("meetings").join(id);
        atomic_json(&dir.join("meta.json"), &json!({"id":id,"title":"Встреча","source":"audio.mp3","createdAt":1,"status":"ready"})).unwrap();
        atomic_json(&dir.join("transcript.json"), &json!({"segments":[
            {"id":1,"start":1,"end":2,"text":"Обсудили бюджет"},
            {"id":2,"start":2,"end":3,"text":"Проверить договор"}
        ]})).unwrap();
        let fp = digest(&fs::read(dir.join("transcript.json")).unwrap());
        atomic_json(&dir.join("summary.json"), &json!({"sourceFingerprint":fp,"overview":"Итоги встречи",
            "items":[{"text":"Проверить договор","segmentIDs":[2]},{"text":"Лишний вывод","segmentIDs":[999]}]})).unwrap();
    }
    #[test]
    fn published_sources_are_versioned_and_stale_summaries_are_excluded() {
        let root=fixture();
        let (sources,partial)=snapshot(root.path(),"one",None).unwrap();
        assert!(partial, "an item with invalid references is excluded, so coverage is partial");
        assert_eq!(sources.iter().filter(|s|s.kind=="transcript").count(),2);
        assert_eq!(sources.iter().filter(|s|s.kind=="summary").count(),2);
        assert!(!sources.iter().any(|s|s.text=="Лишний вывод"));
        assert!(sources.iter().all(|s|validate(root.path(),s,None)));
        let dir=root.path().join("meetings/one");
        atomic_json(&dir.join("transcript.json"),&json!({"segments":[{"id":1,"start":1,"end":2,"text":"Иной текст"}]})).unwrap();
        assert!(!validate(root.path(),&sources[0],None));
        let (changed,_)=snapshot(root.path(),"one",None).unwrap();
        assert!(!changed.iter().any(|s|s.kind=="summary"));
        atomic_json(&dir.join("summary.json"),&json!({"overview":"Старая запись без зависимости"})).unwrap();
        assert!(!snapshot(root.path(),"one",None).unwrap().0.iter().any(|s|s.kind=="summary"));
    }
    #[test]
    fn duplicate_ids_revocation_and_cross_folder_scope_fail_closed() {
        let root=fixture();
        let dir=root.path().join("meetings/one");
        let saved=snapshot(root.path(),"one",None).unwrap().0;
        atomic_json(&dir.join("transcript.json"),&json!({"segments":[
            {"id":1,"start":0,"end":1,"text":"A"},{"id":1,"start":1,"end":2,"text":"B"}]})).unwrap();
        let (duplicates,partial)=snapshot(root.path(),"one",None).unwrap();
        assert!(duplicates.is_empty());
        assert!(partial, "duplicate IDs must not appear as complete coverage");
        assert!(!validate(root.path(),&saved[0],None));
        assert!(snapshot(root.path(),"one",Some("other")).is_err());
        atomic_json(&root.path().join("settings.json"),&json!({"features":{"knowledgeBase":false}})).unwrap();
        assert!(!validate(root.path(),&saved[0],None));
        assert!(scan(root.path(),None,10).unwrap().0.is_empty());
    }
    #[test]
    fn blocked_meetings_cannot_occupy_the_result_limit() {
        let root=fixture();
        meeting(root.path(),"closed");
        crate::folders::save(root.path(),crate::folders::Folder{id:"closed-folder".into(),name:"Closed".into(),revision:0,
            overrides:json!({"features":{"knowledgeBase":false}})}).unwrap();
        crate::notes::save_context(root.path(),serde_json::from_value(json!({"meetingID":"closed","folderID":"closed-folder"})).unwrap()).unwrap();
        let (found,_)=scan(root.path(),None,1).unwrap();
        assert_eq!(found.len(),1);
        assert_eq!(found[0].meeting_id,"one");
        assert!(!scan(root.path(),Some("closed-folder"),10).unwrap().0.iter().any(|s|s.meeting_id=="closed"));
    }
    #[test]
    fn long_transcript_leaves_room_for_current_summary_and_symlinks_fail() {
        use std::os::unix::fs::symlink;
        let root=fixture();
        let dir=root.path().join("meetings/one");
        let segments=(0..500).map(|id|json!({"id":id,"start":id,"end":id+1,"text":"Данные"})).collect::<Vec<_>>();
        atomic_json(&dir.join("transcript.json"),&json!({"segments":segments})).unwrap();
        let fp=digest(&fs::read(dir.join("transcript.json")).unwrap());
        atomic_json(&dir.join("summary.json"),&json!({"sourceFingerprint":fp,"overview":"Итоги"})).unwrap();
        let (found,partial)=snapshot(root.path(),"one",None).unwrap();
        assert!(partial && found.iter().any(|s|s.kind=="summary"));
        fs::remove_file(dir.join("transcript.json")).unwrap();
        symlink(root.path().join("settings.json"),dir.join("transcript.json")).unwrap();
        assert!(snapshot(root.path(),"one",None).is_err());
    }
    #[test]
    fn restored_content_version_requires_current_permission() {
        let root=fixture();
        let source=snapshot(root.path(),"one",None).unwrap().0.remove(0);
        let directory=root.path().join("meetings/one");
        let meta=fs::read(directory.join("meta.json")).unwrap();
        let transcript=fs::read(directory.join("transcript.json")).unwrap();
        fs::remove_dir_all(&directory).unwrap();
        assert!(!validate(root.path(),&source,None));
        fs::create_dir_all(&directory).unwrap();
        fs::write(directory.join("meta.json"),meta).unwrap();
        fs::write(directory.join("transcript.json"),transcript).unwrap();
        assert!(validate(root.path(),&source,None),"exact restored content is the same linked version");
        atomic_json(&root.path().join("settings.json"),&json!({"features":{"knowledgeBase":false}})).unwrap();
        assert!(!validate(root.path(),&source,None),"restoration cannot restore permission");
    }

}
