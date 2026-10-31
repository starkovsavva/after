//! Runs the same host subprocess transport as native IPC, against a real engine
//! and a new synthetic data directory. No account, provider or existing library.
#![cfg(debug_assertions)]
use after_desktop::{
    bridge::LibraryBridge,
    models::{SaveFolderInput, SaveNoteInput},
};
use serde_json::json;
use std::path::PathBuf;

#[test]
#[ignore = "Set AFTER_TEST_ENGINE_PATH to the built canonical engine and run --ignored"]
fn canonical_engine_persists_scoped_notes_and_rejects_stale_edits() {
    let engine = PathBuf::from(
        std::env::var_os("AFTER_TEST_ENGINE_PATH")
            .expect("AFTER_TEST_ENGINE_PATH must point to a real posle-engine"),
    );
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path().join("isolated-library");
    let bridge = LibraryBridge::for_development(engine.clone(), root.clone()).unwrap();
    let initial = bridge.workspace().unwrap();
    assert!(initial.notes.is_empty() && initial.folders.is_empty() && initial.meetings.is_empty());
    assert!(initial.capabilities.library);
    assert!(initial.capabilities.import);
    assert!(initial.capabilities.tasks && initial.capabilities.cards);
    assert_eq!(initial.capabilities.recording, cfg!(windows));
    assert!(!initial.capabilities.assistant);
    let folder = bridge
        .save_folder(SaveFolderInput {
            id: None,
            name: "Английский".into(),
            expected_revision: None,
        })
        .unwrap();
    let note = bridge
        .save_note(SaveNoteInput {
            id: None,
            title: "Friday practice".into(),
            text: "Use phrasal verbs about travel.".into(),
            folder_id: Some(Some(folder.id.clone())),
            meeting_id: None,
            expected_revision: None,
        })
        .unwrap();
    assert_eq!(note.revision, 1);
    assert_eq!(note.folder_id.as_deref(), Some(folder.id.as_str()));
    let edit = SaveNoteInput {
        id: Some(note.id.clone()),
        title: note.title.clone(),
        text: "Updated useful phrasal verbs.".into(),
        folder_id: note.folder_id.clone().map(Some),
        meeting_id: None,
        expected_revision: Some(note.revision),
    };
    let saved = bridge.save_note(edit.clone()).unwrap();
    assert_eq!(saved.revision, 2);
    assert_eq!(bridge.save_note(edit).unwrap_err().code, "conflict");
    assert_eq!(
        bridge
            .save_folder(SaveFolderInput {
                id: Some(folder.id.clone()),
                name: "English".into(),
                expected_revision: Some(99)
            })
            .unwrap_err()
            .code,
        "conflict"
    );
    let results = bridge
        .search("phrasal".into(), Some(folder.id.clone()))
        .unwrap();
    assert!(results
        .hits
        .iter()
        .any(|hit| hit.note_id.as_deref() == Some(note.id.as_str()) || hit.id == note.id));
    let partial = SaveNoteInput {
        id: Some(note.id.clone()),
        title: saved.title.clone(),
        text: saved.text.clone(),
        folder_id: None,
        meeting_id: None,
        expected_revision: Some(saved.revision),
    };
    let preserved = bridge.save_note(partial).unwrap();
    assert_eq!(preserved.folder_id, note.folder_id);
    // A new host instance proves this is durable canonical storage, not UI state.
    let reopened = LibraryBridge::for_development(engine, root.clone())
        .unwrap()
        .workspace()
        .unwrap();
    assert_eq!(reopened.notes.len(), 1);
    assert_eq!(reopened.notes[0].text, saved.text);
    assert_eq!(reopened.notes[0].revision, 3);
    assert_eq!(reopened.folders[0].id, folder.id);
    assert!(root.join("core.sqlite").exists());
}

#[test]
#[ignore = "Set AFTER_TEST_ENGINE_PATH to the built canonical engine and run --ignored"]
fn tasks_and_cards_cross_real_host_transport_and_remain_isolated() {
    let engine = PathBuf::from(
        std::env::var_os("AFTER_TEST_ENGINE_PATH")
            .expect("AFTER_TEST_ENGINE_PATH must point to a real posle-engine"),
    );
    let fixture = tempfile::tempdir().unwrap();
    let first_root = fixture.path().join("first-private-library");
    let second_root = fixture.path().join("second-private-library");
    let first = LibraryBridge::for_development(engine.clone(), first_root.clone()).unwrap();
    let second = LibraryBridge::for_development(engine.clone(), second_root).unwrap();
    let op = |name: &str, args| first.feature_operation(name, args).unwrap();

    let created = op(
        "create_task",
        json!({"title":"Transport task","text":"Private agenda",
        "operationId":"create-task-1"}),
    );
    assert_eq!(created["title"], "Transport task");
    let task_id = created["id"].as_str().unwrap();
    let edit = json!({"taskId":task_id,"expectedRevision":created["revision"],
        "expectedSourceFingerprint":created["sourceFingerprint"],"operationId":"edit-task-1",
        "patch":{"status":"done","title":"Updated task"}});
    let updated = op("update_task", edit.clone());
    assert_eq!(updated["status"], "done");
    // Retrying the same operation cannot create a duplicate.
    assert_eq!(
        op("update_task", edit.clone())["revision"],
        updated["revision"]
    );
    let mut stale = edit;
    stale["operationId"] = json!("edit-task-2");
    assert_eq!(
        first
            .feature_operation("update_task", stale)
            .unwrap_err()
            .code,
        "conflict"
    );
    assert_eq!(
        second.feature_operation("list_tasks", json!({})).unwrap()["tasks"],
        json!([])
    );
    assert!(second
        .feature_operation("get_task", json!({"taskId":task_id}))
        .is_err());

    let saved = op(
        "save_card",
        json!({"front":"Hello","back":"Привет","newDeckTitle":"Transport deck"}),
    );
    let first_cards = op("list_cards", json!({}));
    let card = &first_cards["cards"][0];
    assert_eq!(card["card"]["front"], "Hello");
    let reference = json!({"meetingId":saved["meetingId"],"cardId":saved["card"]["id"],
        "expectedFingerprint":card["fingerprint"],"expectedReviewFingerprint":card["reviewFingerprint"]});
    assert_eq!(
        op("preview_card_review", reference.clone())["options"]
            .as_array()
            .unwrap()
            .len(),
        4
    );
    let mut review = reference;
    review["rating"] = json!(3);
    let receipt = op("review_card", review.clone());
    assert_eq!(receipt["state"]["count"], 1);
    assert_eq!(
        first
            .feature_operation("review_card", review)
            .unwrap_err()
            .code,
        "conflict"
    );
    op(
        "undo_card_review",
        json!({"meetingId":receipt["meetingID"],"undoId":receipt["undoID"]}),
    );
    assert!(op("list_cards", json!({}))["cards"][0]["review"].is_null());
    assert_eq!(
        second.feature_operation("list_cards", json!({})).unwrap()["cards"],
        json!([])
    );

    // A caller may choose only allowlisted operations and may never supply
    // agent commands, arbitrary file paths, roots or unrecognised fields.
    for (operation, args) in [
        ("task-agent-claim", json!({})),
        ("import_meeting", json!({"sourcePath":"C:\\private.wav"})),
        ("list_tasks", json!({"root":"C:\\outside"})),
        (
            "list_cards",
            json!({"command":"cards-import","path":"C:\\outside"}),
        ),
        (
            "update_task",
            json!({"taskId":task_id,"expectedRevision":updated["revision"],
            "operationId":"agent-1","patch":{"agentAccess":{"enabled":true}}}),
        ),
    ] {
        assert_eq!(
            first.feature_operation(operation, args).unwrap_err().code,
            "invalid_request"
        );
    }
    assert_eq!(
        first
            .feature_operation("list_cards", json!([]))
            .unwrap_err()
            .code,
        "invalid_request"
    );

    // Reopening the bridge verifies committed storage, not only process state.
    let reopened = LibraryBridge::for_development(engine, first_root).unwrap();
    assert_eq!(
        reopened.feature_operation("list_tasks", json!({})).unwrap()["tasks"][0]["title"],
        "Updated task"
    );
    assert_eq!(
        reopened.feature_operation("list_cards", json!({})).unwrap()["cards"][0]["card"]["back"],
        "Привет"
    );
}
