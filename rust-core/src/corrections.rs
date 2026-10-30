//! Compare-and-save corrections preserve source timing, history and generated content.
use crate::storage::{atomic_json, meeting_directory, meeting_lock};
use anyhow::{ensure, Context, Result};
use chrono::Utc;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs::{self, OpenOptions},
    io::Read,
    path::Path,
};
use uuid::Uuid;

const MAX_FILE: u64 = 32 * 1_048_576;
pub fn fingerprint(value: &Value) -> Result<String> {
    Ok(format!("{:x}", Sha256::digest(serde_json::to_vec(value)?)))
}
fn read(path: &Path) -> Result<Option<Value>> {
    read_limited(path, MAX_FILE)
}
fn read_limited(path: &Path, limit: u64) -> Result<Option<Value>> {
    let info = match fs::symlink_metadata(path) {
        Ok(info) => info,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    ensure!(
        info.is_file() && !info.file_type().is_symlink() && info.len() <= limit,
        "Некорректный файл встречи"
    );
    let file = crate::platform_fs::open_read(path)?;
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 <= limit, "Файл встречи слишком большой");
    Ok(Some(serde_json::from_slice(&bytes).context(
        "Не удалось прочитать данные встречи. Исходный файл сохранён.",
    )?))
}
fn snapshot(directory: &Path) -> Result<Value> {
    let transcript = read(&directory.join("transcript.json"))?;
    let summary = read(&directory.join("summary.json"))?;
    ensure!(
        transcript.as_ref().is_none_or(Value::is_object)
            && summary.as_ref().is_none_or(Value::is_object),
        "Некорректные данные встречи"
    );
    Ok(
        json!({"transcriptFingerprint":transcript.as_ref().map(fingerprint).transpose()?.unwrap_or_default(),
        "summaryFingerprint":summary.as_ref().map(fingerprint).transpose()?.unwrap_or_default(),"transcript":transcript,"summary":summary}),
    )
}
fn text(value: &Value, key: &str, max: usize, empty: bool) -> Result<String> {
    let text = value[key]
        .as_str()
        .with_context(|| format!("Нет поля: {key}"))?
        .trim();
    ensure!(
        (empty || !text.is_empty()) && text.len() <= max && !text.contains('\0'),
        "Некорректное поле: {key}"
    );
    Ok(text.into())
}
fn compare(current: &Value, expected: &str) -> Result<()> {
    ensure!(
        expected.len() == 64 && expected.bytes().all(|b| b.is_ascii_hexdigit()),
        "Нет версии исходного текста"
    );
    ensure!(
        fingerprint(current)? == expected,
        "Данные изменились. Откройте правку заново, чтобы сохранить актуальную версию."
    );
    Ok(())
}
fn history(directory: &Path, kind: &str, before: &Value, after: &Value) -> Result<()> {
    let path = directory
        .join("correction-history")
        .join(format!("{}.json", Uuid::new_v4()));
    atomic_json(
        &path,
        &json!({"kind":kind,"createdAt":Utc::now().timestamp_millis() as f64/1000.0,"before":before,"afterFingerprint":fingerprint(after)?}),
    )
}
fn segment_save(directory: &Path, value: &Value) -> Result<()> {
    let mut transcript =
        read(&directory.join("transcript.json"))?.context("Сначала распознайте встречу")?;
    compare(
        &transcript,
        value["expectedFingerprint"].as_str().unwrap_or(""),
    )?;
    let segment_id = value["segmentID"].as_u64().context("Нет номера реплики")?;
    let corrected = text(value, "text", 32_000, false)?;
    let speaker = text(value, "speaker", 128, false)?;
    let segments = transcript["segments"]
        .as_array()
        .context("В транскрипте нет реплик")?;
    let mut ids = HashSet::new();
    for segment in segments {
        let id = segment["id"]
            .as_u64()
            .context("Некорректный номер реплики")?;
        ensure!(ids.insert(id), "Повторный номер реплики");
    }
    let meta = read(&directory.join("meta.json"))?;
    let known_speaker = segments
        .iter()
        .any(|segment| segment["speaker"].as_str() == Some(&speaker))
        || meta
            .as_ref()
            .and_then(|meta| meta["speakerNames"].as_object())
            .is_some_and(|names| names.contains_key(&speaker));
    ensure!(known_speaker, "Выберите существующего собеседника");
    let index = segments
        .iter()
        .position(|segment| segment["id"].as_u64() == Some(segment_id))
        .context("Реплика больше недоступна")?;
    if segments[index]["text"].as_str() == Some(&corrected)
        && segments[index]["speaker"].as_str() == Some(&speaker)
    {
        return Ok(());
    }
    let before = transcript.clone();
    let entry = transcript["segments"][index]
        .as_object_mut()
        .context("Некорректная реплика")?;
    entry.insert("text".into(), json!(corrected));
    entry.insert("speaker".into(), json!(speaker));
    entry.insert("manuallyEdited".into(), json!(true));
    transcript["editedAt"] = json!(Utc::now().timestamp_millis() as f64 / 1000.0);
    transcript["revision"] = json!(before["revision"]
        .as_u64()
        .unwrap_or(0)
        .checked_add(1)
        .context("Слишком много правок транскрипта")?);
    let summary = read(&directory.join("summary.json"))?;
    ensure!(
        summary.as_ref().is_none_or(Value::is_object),
        "Некорректный файл конспекта"
    );
    let stale_summary = summary.as_ref().map(|summary| {
        let mut summary = summary.clone();
        summary["sourceStale"] = json!(true);
        summary["sourceChangedAt"] = transcript["editedAt"].clone();
        summary
    });
    ensure!(
        serde_json::to_vec(&transcript)?.len() as u64 <= MAX_FILE,
        "Транскрипт слишком большой"
    );
    // History is durable before any replacement. A failure marking the summary
    // leaves the transcript untouched. A later transcript-write failure leaves
    // only a conservative stale indication, never falsely current facts.
    history(directory, "transcript", &before, &transcript)?;
    if let Some(summary) = stale_summary {
        atomic_json(&directory.join("summary.json"), &summary)?;
    }
    atomic_json(&directory.join("transcript.json"), &transcript)
}
fn item_save(root: &Path, directory: &Path, notes_dir: &Path, value: &Value) -> Result<()> {
    let mut summary =
        read(&directory.join("summary.json"))?.context("Сначала создайте конспект")?;
    compare(
        &summary,
        value["expectedFingerprint"].as_str().unwrap_or(""),
    )?;
    let index = value["itemIndex"]
        .as_u64()
        .and_then(|index| usize::try_from(index).ok())
        .context("Нет номера факта")?;
    let corrected = text(value, "text", 32_000, false)?;
    let owner = text(value, "owner", 512, true)?;
    let due = text(value, "due", 512, true)?;
    let items = summary["items"]
        .as_array()
        .context("В конспекте нет фактов")?;
    let item = items.get(index).context("Факт больше недоступен")?;
    if item["text"].as_str() == Some(&corrected)
        && item["owner"].as_str().unwrap_or("") == owner
        && item["due"].as_str().unwrap_or("") == due
    {
        return Ok(());
    }
    let before = summary.clone();
    let item = summary["items"][index]
        .as_object_mut()
        .context("Некорректный факт")?;
    item.insert("text".into(), json!(corrected));
    item.insert("owner".into(), json!(owner));
    item.insert("due".into(), json!(due));
    item.insert("manuallyEdited".into(), json!(true));
    summary["manuallyEdited"] = json!(true);
    summary["overviewStale"] = json!(true);
    summary["overviewClaims"] = json!([]);
    summary["editedAt"] = json!(Utc::now().timestamp_millis() as f64 / 1000.0);
    ensure!(
        serde_json::to_vec(&summary)?.len() as u64 <= MAX_FILE,
        "Конспект слишком большой"
    );
    history(directory, "summary", &before, &summary)?;
    if before["items"][index]["kind"] != "action" {
        return atomic_json(&directory.join("summary.json"), &summary);
    }
    let mut workspace = crate::notes::load(notes_dir)?;
    let before_workspace = Some(crate::workspace_repository::load_locked(notes_dir)?.value);
    let old = &before["items"][index];
    let new = &summary["items"][index];
    let old_signature = crate::notes::task_signature(old);
    let new_signature = crate::notes::task_signature(new);
    let meeting_id = value["meetingID"].as_str().context("Нет ID встречи")?;
    let mut changed = false;
    for note in &mut workspace.notes {
        if !note.task_origin.as_ref().is_some_and(|origin| {
            origin["meetingID"] == meeting_id && origin["itemSignature"] == old_signature
        }) {
            continue;
        }
        if note.text == old["text"].as_str().unwrap_or("") {
            note.text = corrected.clone();
            note.content_rtf.clear();
            note.expansion = None;
        }
        if note.owner == old["owner"].as_str().unwrap_or("") {
            note.owner = owner.clone();
        }
        if note.due == old["due"].as_str().unwrap_or("") {
            note.due = due.clone();
        }
        let origin = note.task_origin.as_mut().context("Нет источника задачи")?;
        origin["itemSignature"] = json!(new_signature);
        origin["sourceText"] = new["text"].clone();
        origin["segmentIDs"] = new["segmentIDs"].clone();
        origin["summaryTaskID"] = json!(format!("summary:{meeting_id}:{new_signature}"));
        note.revision = note
            .revision
            .checked_add(1)
            .context("Слишком большая ревизия задачи")?;
        note.updated_at = Utc::now().timestamp_millis() as f64 / 1000.0;
        ensure!(note.history.len() < 1000, "История задачи заполнена");
        note.history.push(json!({"id":Uuid::new_v4().to_string(),"createdAt":note.updated_at,"text":"Уточнён исходный пункт конспекта"}));
        changed = true;
    }
    crate::notes::validate_workspace(&workspace)?;
    let meta_path = directory.join("meta.json");
    let before_meta = read(&meta_path)?;
    ensure!(
        before_meta.as_ref().is_some_and(Value::is_object),
        "Метаданные встречи недоступны. Исходные данные сохранены."
    );
    let mut after_meta = before_meta.clone();
    let old_refs = old["segmentIDs"]
        .as_array()
        .context("Некорректные ссылки задачи")?
        .iter()
        .map(|id| id.as_u64().context("Некорректная ссылка"))
        .collect::<Result<Vec<_>>>()?;
    let prefix = old_refs
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("-");
    let old_id = format!(
        "action-{prefix}-{}",
        old["text"].as_str().context("Нет текста задачи")?
    );
    let new_id = format!("action-{prefix}-{corrected}");
    if let Some(meta) = &mut after_meta {
        if let Some(completed) = meta["completedTasks"].as_array_mut() {
            for id in completed {
                if id.as_str() == Some(&old_id) {
                    *id = json!(new_id);
                }
            }
        }
    }
    let journal = json!({"meetingID":meeting_id,"beforeSummary":before,"afterSummary":summary,"beforeWorkspace":before_workspace,"afterWorkspace":serde_json::to_value(&workspace)?,"notesChanged":changed,"beforeMeta":before_meta,"afterMeta":after_meta});
    ensure!(
        serde_json::to_vec(&journal)?.len() as u64 <= MAX_FILE * 4 + 2 * 1_048_576,
        "Транзакция правки слишком большая"
    );
    let journal_path = notes_dir.join("correction-pending.json");
    atomic_json(&journal_path, &journal)?;
    finish_transaction(root, notes_dir, directory, &journal)?;
    fs::remove_file(journal_path)?;
    Ok(())
}

fn matches_either(actual: &Option<Value>, before: &Value, after: &Value) -> bool {
    let actual = actual.as_ref().unwrap_or(&Value::Null);
    actual == before || actual == after
}
fn finish_transaction(
    _root: &Path,
    notes_dir: &Path,
    directory: &Path,
    journal: &Value,
) -> Result<()> {
    ensure!(
        journal["beforeSummary"].is_object() && journal["afterSummary"].is_object(),
        "Некорректный журнал правки конспекта"
    );
    ensure!(
        journal["beforeMeta"].is_object() && journal["afterMeta"].is_object(),
        "Некорректный журнал правки встречи"
    );
    let summary = read(&directory.join("summary.json"))?;
    let meta = read(&directory.join("meta.json"))?;
    ensure!(matches_either(&summary,&journal["beforeSummary"],&journal["afterSummary"]),"После прерывания конспект изменился. История правки сохранена; автоматическое восстановление остановлено.");
    ensure!(
        matches_either(&meta, &journal["beforeMeta"], &journal["afterMeta"]),
        "После прерывания встреча изменилась. История правки сохранена."
    );
    let notes_changed = journal["notesChanged"].as_bool() == Some(true);
    let workspace: crate::notes::NotesWorkspace =
        serde_json::from_value(journal["afterWorkspace"].clone())?;
    crate::notes::validate_workspace(&workspace)?;
    if notes_changed {
        let current_snapshot = crate::workspace_repository::load_locked(notes_dir)?;
        let current = current_snapshot.value;
        let normalized = |value: &Value| -> Result<Value> {
            if value.is_null() { return Ok(Value::Null); }
            let workspace: crate::notes::NotesWorkspace = serde_json::from_value(value.clone())?;
            Ok(serde_json::to_value(workspace)?)
        };
        let current = Some(normalized(&current)?);
        let originally_absent = journal["beforeWorkspace"].is_null() && current_snapshot.revision == 1
            && current.as_ref() == Some(&serde_json::to_value(crate::notes::defaults())?);
        ensure!(originally_absent || matches_either(&current,&normalized(&journal["beforeWorkspace"])? ,&normalized(&journal["afterWorkspace"])?),"После прерывания задача изменилась. История правки сохранена; автоматическое восстановление остановлено.");
    }
    if notes_changed {
        crate::notes::persist(notes_dir, &workspace)?;
    }
    atomic_json(&directory.join("summary.json"), &journal["afterSummary"])?;
    if journal["afterMeta"] != journal["beforeMeta"] {
        atomic_json(&directory.join("meta.json"), &journal["afterMeta"])?;
    }
    Ok(())
}
/// Caller owns the notes lock; acquire the meeting lock only after it.
pub(crate) fn recover_notes_transaction(notes_dir: &Path) -> Result<()> {
    let path = notes_dir.join("correction-pending.json");
    let Some(journal) = read_limited(&path, MAX_FILE * 4 + 2 * 1_048_576)? else {
        return Ok(());
    };
    let root = notes_dir.parent().context("Нет папки библиотеки")?;
    let id = journal["meetingID"]
        .as_str()
        .context("Некорректная транзакция правки")?;
    let directory = meeting_directory(root, id)?;
    let _lock = meeting_lock(&directory)?;
    finish_transaction(root, notes_dir, &directory, &journal)?;
    fs::remove_file(path)?;
    Ok(())
}
pub fn dispatch(root: &Path, value: &Value) -> Result<Value> {
    let id = value["meetingID"].as_str().context("Нет ID встречи")?;
    let directory = meeting_directory(root, id)?;
    let notes_dir = crate::notes::directory(root)?;
    let _notes_lock = crate::notes::lock(&notes_dir)?;
    recover_notes_transaction(&notes_dir)?;
    let _lock = meeting_lock(&directory)?;
    match value["command"].as_str().unwrap_or("") {
        "meeting-content-snapshot" => {}
        "transcript-segment-save" => segment_save(&directory, value)?,
        "summary-item-save" => item_save(root, &directory, &notes_dir, value)?,
        _ => anyhow::bail!("Неизвестная команда правки"),
    }
    snapshot(&directory)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    fn fixture() -> tempfile::TempDir {
        let root = tempfile::tempdir().unwrap();
        let directory = meeting_directory(root.path(), "meeting").unwrap();
        atomic_json(&directory.join("meta.json"),&json!({"id":"meeting","title":"Fictional meeting","source":"source.mp3","createdAt":1.0,"speakerNames":{"speaker_2":"Анна"},"completedTasks":[]})).unwrap();
        atomic_json(&directory.join("transcript.json"),&json!({"duration":10,"model":"asr","segments":[{"id":7,"start":1.25,"end":3.5,"speaker":"speaker_1","text":"Old words","overlap":false}],"future":"keep"})).unwrap();
        atomic_json(&directory.join("summary.json"),&json!({"overview":"Original overview","overviewClaims":[{"text":"Claim","itemIndices":[0]}],"items":[{"kind":"action","text":"Original task","owner":"Анна","due":"Friday","segmentIDs":[7]}],"cards":[{"id":"preserved","front":"Phrase"}],"generatedAt":1})).unwrap();
        root
    }
    fn snapshot_for(root: &Path) -> Value {
        dispatch(
            root,
            &json!({"command":"meeting-content-snapshot","meetingID":"meeting"}),
        )
        .unwrap()
    }
    #[test]
    fn correction_preserves_ids_times_audio_metadata_and_generated_material() {
        let root = fixture();
        let before = snapshot_for(root.path());
        let after=dispatch(root.path(),&json!({"command":"transcript-segment-save","meetingID":"meeting","segmentID":7,"text":"Corrected words","speaker":"speaker_2","expectedFingerprint":before["transcriptFingerprint"]})).unwrap();
        let segment = &after["transcript"]["segments"][0];
        assert_eq!(segment["start"], 1.25);
        assert_eq!(segment["end"], 3.5);
        assert_eq!(segment["id"], 7);
        assert_eq!(segment["speaker"], "speaker_2");
        assert_eq!(after["transcript"]["future"], "keep");
        assert_eq!(after["summary"]["items"], before["summary"]["items"]);
        assert_eq!(after["summary"]["cards"], before["summary"]["cards"]);
        assert_eq!(after["summary"]["sourceStale"], true);
        let history_path = fs::read_dir(root.path().join("meetings/meeting/correction-history"))
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        assert_eq!(
            read(&history_path).unwrap().unwrap()["before"],
            before["transcript"]
        );
    }
    #[test]
    fn stale_and_unknown_speaker_corrections_never_overwrite() {
        let root = fixture();
        let before = snapshot_for(root.path());
        let mut input = json!({"command":"transcript-segment-save","meetingID":"meeting","segmentID":7,"text":"New words","speaker":"missing","expectedFingerprint":before["transcriptFingerprint"]});
        assert!(dispatch(root.path(), &input).is_err());
        assert_eq!(snapshot_for(root.path()), before);
        input["speaker"] = json!("speaker_1");
        dispatch(root.path(), &input).unwrap();
        let committed = snapshot_for(root.path());
        assert!(dispatch(root.path(), &input).is_err());
        assert_eq!(snapshot_for(root.path()), committed);
    }
    #[test]
    fn fact_edit_preserves_evidence_and_cards_but_invalidates_old_overview_links() {
        let root = fixture();
        let before = snapshot_for(root.path());
        let after=dispatch(root.path(),&json!({"command":"summary-item-save","meetingID":"meeting","itemIndex":0,"text":"Changed task","owner":"Майкл","due":"Monday","expectedFingerprint":before["summaryFingerprint"]})).unwrap();
        assert_eq!(after["summary"]["items"][0]["segmentIDs"], json!([7]));
        assert_eq!(after["summary"]["items"][0]["kind"], "action");
        assert_eq!(after["summary"]["cards"], before["summary"]["cards"]);
        assert_eq!(after["summary"]["overview"], before["summary"]["overview"]);
        assert_eq!(after["summary"]["overviewStale"], true);
        assert_eq!(after["summary"]["overviewClaims"], json!([]));
        assert_eq!(after["transcript"], before["transcript"]);
    }
    #[test]
    fn no_op_does_not_create_history_and_symlinks_are_rejected() {
        let root = fixture();
        let before = snapshot_for(root.path());
        let unchanged=dispatch(root.path(),&json!({"command":"transcript-segment-save","meetingID":"meeting","segmentID":7,"text":"Old words","speaker":"speaker_1","expectedFingerprint":before["transcriptFingerprint"]})).unwrap();
        assert_eq!(unchanged, before);
        assert!(!root
            .path()
            .join("meetings/meeting/correction-history")
            .exists());
        let directory = root.path().join("meetings/meeting");
        let original = directory.join("original.json");
        fs::rename(directory.join("transcript.json"), &original).unwrap();
        std::os::unix::fs::symlink(original, directory.join("transcript.json")).unwrap();
        assert!(dispatch(
            root.path(),
            &json!({"command":"meeting-content-snapshot","meetingID":"meeting"})
        )
        .is_err());
    }
    #[test]
    fn simultaneous_corrections_have_one_winner() {
        let root = fixture();
        let before = snapshot_for(root.path());
        let mut handles = vec![];
        for name in ["First", "Second"] {
            let path = root.path().to_owned();
            let expected = before["transcriptFingerprint"].clone();
            handles.push(std::thread::spawn(move||dispatch(&path,&json!({"command":"transcript-segment-save","meetingID":"meeting","segmentID":7,"text":name,"speaker":"speaker_1","expectedFingerprint":expected}))));
        }
        assert_eq!(
            handles
                .into_iter()
                .map(|handle| handle.join().unwrap())
                .filter(Result::is_ok)
                .count(),
            1
        );
    }
    #[test]
    fn action_correction_keeps_one_canonical_task_and_user_overrides() {
        let root = fixture();
        let before = snapshot_for(root.path());
        let notes_dir = crate::notes::directory(root.path()).unwrap();
        let mut workspace = crate::notes::list(root.path()).unwrap();
        let old = &before["summary"]["items"][0];
        let signature = crate::notes::task_signature(old);
        let note:crate::notes::CapturedNote=serde_json::from_value(json!({"id":"canonical","kind":"task","text":"My independently edited task","owner":"My owner","due":"Friday","completed":true,"createdAt":1,"updatedAt":1,"revision":2,"meetingID":"meeting","taskOrigin":{"meetingID":"meeting","itemSignature":signature,"sourceText":old["text"],"segmentIDs":[7],"summaryTaskID":format!("summary:meeting:{signature}")},"subtasks":[{"id":"sub","text":"Subtask","completed":true}],"history":[{"id":"previous","createdAt":1,"text":"User addition"}]})).unwrap();
        workspace.notes.push(note);
        crate::notes::persist(&notes_dir, &workspace).unwrap();
        let after=dispatch(root.path(),&json!({"command":"summary-item-save","meetingID":"meeting","itemIndex":0,"text":"Corrected task","owner":"New owner","due":"Monday","expectedFingerprint":before["summaryFingerprint"]})).unwrap();
        let workspace = crate::notes::list(root.path()).unwrap();
        let note = &workspace.notes[0];
        assert_eq!(note.id, "canonical");
        assert_eq!(note.text, "My independently edited task");
        assert_eq!(note.owner, "My owner");
        assert_eq!(note.due, "Monday");
        assert!(note.completed);
        assert_eq!(note.subtasks.len(), 1);
        assert_eq!(note.history.len(), 2);
        assert_eq!(note.revision, 3);
        assert_eq!(
            note.task_origin.as_ref().unwrap()["sourceText"],
            "Corrected task"
        );
        assert_eq!(
            note.task_origin.as_ref().unwrap()["itemSignature"],
            crate::notes::task_signature(&after["summary"]["items"][0])
        );
        assert_eq!(
            crate::notes::tasks(root.path()).unwrap()["tasks"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert!(!notes_dir.join("correction-pending.json").exists());
    }
    #[test]
    fn action_correction_preserves_legacy_completion_for_changed_text() {
        let root = fixture();
        let directory = root.path().join("meetings/meeting");
        let mut meta = read(&directory.join("meta.json")).unwrap().unwrap();
        meta["completedTasks"] = json!(["action-7-Original task"]);
        atomic_json(&directory.join("meta.json"), &meta).unwrap();
        let before = snapshot_for(root.path());
        dispatch(root.path(),&json!({"command":"summary-item-save","meetingID":"meeting","itemIndex":0,"text":"Corrected task","owner":"Анна","due":"Friday","expectedFingerprint":before["summaryFingerprint"]})).unwrap();
        let tasks = crate::notes::tasks(root.path()).unwrap();
        assert_eq!(tasks["tasks"][0]["completed"], true);
        assert_eq!(tasks["tasks"][0]["text"], "Corrected task");
    }
    #[test]
    fn interrupted_summary_and_task_transaction_recovers_before_next_note_read() {
        let root = fixture();
        let before = snapshot_for(root.path());
        let directory = root.path().join("meetings/meeting");
        let notes_dir = crate::notes::directory(root.path()).unwrap();
        let workspace = crate::notes::list(root.path()).unwrap();
        let workspace = serde_json::to_value(workspace).unwrap();
        let mut after = before["summary"].clone();
        after["items"][0]["text"] = json!("Committed correction");
        let meta = read(&directory.join("meta.json")).unwrap().unwrap();
        let journal = json!({"meetingID":"meeting","beforeSummary":before["summary"],"afterSummary":after,"beforeWorkspace":null,"afterWorkspace":workspace,"notesChanged":true,"beforeMeta":meta,"afterMeta":meta});
        atomic_json(&notes_dir.join("correction-pending.json"), &journal).unwrap();
        atomic_json(&directory.join("summary.json"), &after).unwrap();
        crate::notes::list(root.path()).unwrap();
        assert_eq!(
            read(&directory.join("summary.json")).unwrap().unwrap(),
            after
        );
        assert!(notes_dir.join("workspace.json").exists());
        assert!(!notes_dir.join("correction-pending.json").exists());
        atomic_json(&notes_dir.join("correction-pending.json"), &journal).unwrap();
        let drift = json!({"overview":"Someone else's new result"});
        atomic_json(&directory.join("summary.json"), &drift).unwrap();
        assert!(crate::notes::list(root.path()).is_err());
        assert_eq!(
            read(&directory.join("summary.json")).unwrap().unwrap(),
            drift
        );
        assert!(notes_dir.join("correction-pending.json").exists());
    }
}
