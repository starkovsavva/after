use super::*;
use crate::{notes, storage};
fn meeting(root: &Path, id: &str) {
    let dir = storage::meeting_directory(root, id).unwrap();
    storage::atomic_json(&dir.join("meta.json"),&json!({"id":id,"title":"Синк с руководителем","createdAt":1.0,"source":"source.wav","status":"ready"})).unwrap();
    fs::write(dir.join("source.wav"), b"audio-source").unwrap();
    storage::atomic_json(
        &dir.join("summary.json"),
        &json!({"overview":"Решения","items":[],"cards":[]}),
    )
    .unwrap();
}
fn note(root: &Path) -> crate::notes::CapturedNote {
    notes::save_note(
        root,
        serde_json::from_value(
            json!({"id":"note-1","text":"Идеи о пилоте","createdAt":0.0,"updatedAt":0.0}),
        )
        .unwrap(),
    )
    .unwrap()
}
fn change_request(root: &Path, kind: &str, key: &str, restore: bool, op: &str) -> Value {
    let v = snapshot(root, kind, key, restore).unwrap();
    json!({"kind":kind,"id":key,"restore":restore,"expectedFingerprint":v["fingerprint"],"operationID":op})
}
#[test]
fn meeting_roundtrip_retains_files_and_stale_preview_cannot_delete() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    meeting(root, "m1");
    let stale = change_request(root, "meeting", "m1", false, "old");
    storage::atomic_json(
        &storage::meeting_directory(root, "m1")
            .unwrap()
            .join("summary.json"),
        &json!({"overview":"Новое решение","items":[],"cards":[]}),
    )
    .unwrap();
    assert!(change(root, &stale).is_err());
    let request = change_request(root, "meeting", "m1", false, "delete-1");
    let output = change(root, &request).unwrap();
    assert_eq!(change(root, &request).unwrap(), output);
    assert!(storage::list_meetings(root).unwrap().is_empty());
    assert_eq!(list(root).unwrap()["entries"].as_array().unwrap().len(), 1);
    let restore = change_request(root, "meeting", "m1", true, "restore-1");
    change(root, &restore).unwrap();
    assert_eq!(storage::list_meetings(root).unwrap().len(), 1);
    assert_eq!(
        fs::read(
            storage::meeting_directory(root, "m1")
                .unwrap()
                .join("source.wav")
        )
        .unwrap(),
        b"audio-source"
    );
    assert!(list(root).unwrap()["entries"]
        .as_array()
        .unwrap()
        .is_empty());
}
#[test]
fn notes_reject_stale_versions_keep_deleted_time_and_expire() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    let original = note(root);
    let stale = change_request(root, "note", &original.id, false, "stale");
    let mut edited = original.clone();
    edited.text = "Другие мысли".into();
    let saved = notes::save_note(root, edited).unwrap();
    assert!(change(root, &stale).is_err());
    let deleted = notes::trash_note(root, &saved.id, saved.revision, false).unwrap();
    let again = notes::trash_note(root, &deleted.id, deleted.revision, false).unwrap();
    assert_eq!(again.trashed_at, deleted.trashed_at);
    let directory = notes::directory(root).unwrap();
    {
        let _lock = notes::lock(&directory).unwrap();
        let mut workspace = notes::load(&directory).unwrap();
        workspace.notes[0].trashed_at = Some(now() - RETENTION_SECONDS - 10.0);
        notes::persist(&directory, &workspace).unwrap();
    }
    assert!(notes::trash_note(root, &again.id, again.revision, true).is_err());
    assert!(snapshot(root, "note", &again.id, true).is_err());
    purge(root).unwrap();
    assert!(notes::list(root).unwrap().notes.is_empty());
}
#[test]
fn recording_cannot_be_trashed_and_symlink_cannot_be_followed() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    meeting(root, "m1");
    storage::update_meta(root, "m1", &json!({"status":"recording"})).unwrap();
    let request = change_request(root, "meeting", "m1", false, "no-recording");
    assert!(change(root, &request).is_err());
    let target = tempfile::tempdir().unwrap();
    let deleted = archived(root, "escape").unwrap();
    std::os::unix::fs::symlink(target.path(), deleted).unwrap();
    assert!(snapshot(root, "meeting", "escape", true).is_err());
    assert!(target.path().exists());
}
#[test]
fn move_receipt_recovers_after_sql_receipt_gap() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    meeting(root, "m1");
    let request = change_request(root, "meeting", "m1", false, "recover");
    let output = change(root, &request).unwrap();
    let directory = notes::directory(root).unwrap();
    {
        let _lock = notes::lock(&directory).unwrap();
        let mut w = notes::load(&directory).unwrap();
        w.voice_operations.retain(|r| r["trashDomain"] != true);
        notes::persist(&directory, &w).unwrap();
    }
    assert_eq!(change(root, &request).unwrap(), output);
}
#[test]
fn expired_meeting_is_purged_without_touching_active_meeting() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    meeting(root, "m1");
    meeting(root, "m2");
    change(
        root,
        &change_request(root, "meeting", "m1", false, "delete"),
    )
    .unwrap();
    let path = archived(root, "m1").unwrap();
    let mut state = manifest(&path).unwrap();
    state["deletedAt"] = json!(now() - RETENTION_SECONDS - 1.0);
    storage::atomic_json(&path.join(".posle-trash.json"), &state).unwrap();
    assert!(snapshot(root, "meeting", "m1", true).is_err());
    purge(root).unwrap();
    assert!(!path.exists());
    assert_eq!(storage::list_meetings(root).unwrap().len(), 1);
}
#[test]
fn source_task_tombstone_prevents_resurrection() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    meeting(root, "m1");
    let item = json!({"kind":"action","text":"Подготовить пилот","segmentIDs":[1]});
    let dir = storage::meeting_directory(root, "m1").unwrap();
    storage::atomic_json(
        &dir.join("summary.json"),
        &json!({"items":[item],"cards":[]}),
    )
    .unwrap();
    let mut n = note(root);
    n.kind = "task".into();
    n.task_origin = None;
    let n = notes::save_note(root, n).unwrap();
    let directory = notes::directory(root).unwrap();
    {
        let _lock = notes::lock(&directory).unwrap();
        let mut w = notes::load(&directory).unwrap();
        w.notes[0].task_origin = Some(
            json!({"meetingID":"m1","itemSignature":notes::task_signature(&item),"sourceText":"Подготовить пилот","segmentIDs":[1],"summaryTaskID":"action"}),
        );
        notes::persist(&directory, &w).unwrap();
    }
    notes::delete_note(root, &n.id, n.revision).unwrap();
    assert!(notes::tasks(root).unwrap()["tasks"]
        .as_array()
        .unwrap()
        .is_empty());
    assert!(notes::list(root).unwrap().notes[0].text.is_empty());
    let revision = notes::list(root).unwrap().notes[0].revision;
    assert_eq!(purge(root).unwrap()["removed"], 0);
    assert_eq!(notes::list(root).unwrap().notes[0].revision, revision);
}
