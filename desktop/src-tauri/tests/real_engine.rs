//! Runs the same host subprocess transport as native IPC, against a real engine
//! and a new synthetic data directory. No account, provider or existing library.
#![cfg(debug_assertions)]
use after_desktop::{
    bridge::LibraryBridge,
    models::{SaveFolderInput, SaveNoteInput},
};
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
    assert!(!initial.capabilities.recording && !initial.capabilities.assistant);
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
