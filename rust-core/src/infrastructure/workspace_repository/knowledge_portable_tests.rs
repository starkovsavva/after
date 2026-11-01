#![cfg(test)]
//! Shared-store regression scenarios: no Apple, Unix or semantic runtime APIs.
use serde_json::{json, Value};
use std::path::Path;

fn note(root: &Path, id: &str, text: &str) -> crate::notes::CapturedNote {
    crate::notes::save_note(
        root,
        serde_json::from_value(json!({"id":id,"kind":"note","text":text,
        "createdAt":0.0,"updatedAt":0.0,"revision":0}))
        .unwrap(),
    )
    .unwrap()
}
fn call(root: &Path, command: &str, mut input: Value) -> anyhow::Result<Value> {
    input["command"] = json!(command);
    crate::workspace_repository::knowledge_dispatch(root, &input)
}
fn enable(root: &Path) {
    crate::storage::atomic_json(
        &root.join("settings.json"),
        &json!({"features":{"knowledgeBase":true}}),
    )
    .unwrap();
}

#[test]
fn portable_extension_preserves_legacy_edits_and_prunes_links_before_identifier_reuse() {
    let root = tempfile::tempdir().unwrap();
    enable(root.path());
    let mut a = note(root.path(), "a", "First source");
    let b = note(root.path(), "b", "Second source");
    let before = crate::workspace_repository::snapshot(root.path()).unwrap();
    let snapshot = call(root.path(), "kb-snapshot", json!({"noteID":"a"})).unwrap();
    assert_eq!(snapshot["workspaceFingerprint"], before.fingerprint);
    let request = json!({"operationID":uuid::Uuid::new_v4().to_string(),
        "expectedWorkspaceRevision":snapshot["workspaceRevision"],"expectedKBRevision":snapshot["kbRevision"],
        "expectedFromRevision":a.revision,"expectedToRevision":b.revision,"fromID":"a","toID":"b","action":"add"});
    let committed = call(root.path(), "kb-link-change", request.clone()).unwrap();
    assert_eq!(
        call(root.path(), "kb-link-change", request.clone()).unwrap(),
        committed
    );
    a.text = "Updated by the ordinary editor".into();
    crate::notes::save_note(root.path(), a).unwrap();
    assert_eq!(
        call(root.path(), "kb-snapshot", json!({"noteID":"a"})).unwrap()["links"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    crate::notes::delete_note(root.path(), "b", b.revision).unwrap();
    note(
        root.path(),
        "b",
        "An unrelated replacement with the same ID",
    );
    assert!(
        call(root.path(), "kb-snapshot", json!({"noteID":"a"})).unwrap()["links"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let replay = call(root.path(), "kb-link-change", request).unwrap();
    assert_eq!(replay["redacted"], true);
    assert!(call(root.path(), "kb-snapshot", json!({"noteID":"a"})).unwrap()["links"].as_array().unwrap().is_empty());
    assert_eq!(crate::notes::list(root.path()).unwrap().notes.len(), 2);
    let connection = crate::platform_fs::sqlite_connection(
        &root.path().join("core.sqlite"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    assert_eq!(
        connection
            .pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn portable_extension_respects_live_queue_admission_and_backs_up_the_existing_ledger() {
    let root = tempfile::tempdir().unwrap();
    enable(root.path());
    note(root.path(), "a", "Keep this content");
    let queued = crate::jobs::dispatch(
        root.path(),
        &json!({"command":"job-enqueue","kind":"example","objectID":"fixture"}),
    )
    .unwrap();
    assert!(call(root.path(), "kb-snapshot", json!({"noteID":"a"})).is_err());
    assert!(!root.path().join(".knowledge-migration").exists());
    crate::jobs::dispatch(
        root.path(),
        &json!({"command":"job-cancel","jobID":queued["job"]["id"]}),
    )
    .unwrap();
    call(root.path(), "kb-snapshot", json!({"noteID":"a"})).unwrap();
    let journal: Value = serde_json::from_slice(
        &std::fs::read(root.path().join(".knowledge-migration/current.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(journal["state"], "committed");
    let backup = root
        .path()
        .join(".knowledge-migration")
        .join(journal["jobsBackup"].as_str().unwrap());
    let connection =
        crate::platform_fs::sqlite_connection(&backup, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
    assert_eq!(
        connection
            .query_row("SELECT state FROM jobs", [], |row| row.get::<_, String>(0))
            .unwrap(),
        "cancelled"
    );
    assert_eq!(
        crate::notes::list(root.path()).unwrap().notes[0].text,
        "Keep this content"
    );
}
