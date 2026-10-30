use super::*;
use crate::storage::atomic_json;
use std::fs;

fn call(root: &Path, command: &str, arguments: Value) -> Value {
    handle_bytes(
        root,
        &serde_json::to_vec(&json!({"command":command,"arguments":arguments})).unwrap(),
    )
}
fn success(root: &Path, command: &str, arguments: Value) -> Value {
    let response = call(root, command, arguments);
    assert_eq!(response["ok"], true, "{response}");
    response["result"].clone()
}
fn folder(root: &Path, id: &str, name: &str) -> folders::Folder {
    folders::save(
        root,
        folders::Folder {
            id: id.into(),
            name: name.into(),
            revision: 0,
            overrides: json!({"features":{"cards":false},"cloudModel":"native-model"}),
        },
    )
    .unwrap()
}
fn meeting_fixture(root: &Path, id: &str, title: &str) -> std::path::PathBuf {
    let directory = storage::meeting_directory(root, id).unwrap();
    atomic_json(&directory.join("meta.json"),&json!({"id":id,"title":title,"createdAt":123.0,"duration":32.5,"source":"source.mp3","speakerNames":{"speaker_2":"Lead"},"focus":"private project context","future":"preserved"})).unwrap();
    atomic_json(&directory.join("transcript.json"),&json!({"segments":[{"id":1,"start":1.25,"end":4.5,"speaker":"speaker_2","text":"Synthetic migration context"}]})).unwrap();
    atomic_json(&directory.join("summary.json"),&json!({"overview":"Synthetic migration overview","items":[],"cards":[{"id":"old-card","front":"Keep","back":"Preserve","context":"Original","segmentIDs":[1]}],"generatedAt":1})).unwrap();
    directory
}
fn native_note(
    root: &Path,
    id: &str,
    folder_id: Option<&str>,
    meeting_id: Option<&str>,
) -> notes::CapturedNote {
    let note:notes::CapturedNote=serde_json::from_value(json!({"id":id,"title":"Native note","text":"Synthetic migration thought","kind":"important","createdAt":0,"updatedAt":0,"folderID":folder_id,"meetingID":meeting_id,"pinned":true,"tags":["native"],"owner":"Savva","contentRTF":"original-rich-text"})).unwrap();
    notes::save_note(root, note).unwrap()
}

#[test]
fn snapshot_and_detail_use_real_sqlite_and_do_not_expose_profiles_paths_or_cards() {
    let root = tempfile::tempdir().unwrap();
    let english = folder(root.path(), "english", "English");
    let directory = meeting_fixture(root.path(), "meeting", "Synthetic meeting");
    folders::assign_meeting(root.path(), "meeting", Some(&english.id), 0).unwrap();
    native_note(root.path(), "note", None, Some("meeting"));
    let before = fs::read(directory.join("summary.json")).unwrap();
    let workspace = success(root.path(), "get_workspace", json!({}));
    assert!(root.path().join("core.sqlite").is_file());
    assert_eq!(
        workspace["folders"],
        json!([{"id":"english","name":"English","revision":1}])
    );
    assert_eq!(workspace["meetings"][0]["folderId"], "english");
    assert_eq!(workspace["meetings"][0]["durationSeconds"], 32.5);
    assert_eq!(workspace["notes"][0]["folderId"], "english");
    assert_eq!(workspace["capabilities"]["recording"], false);
    assert_eq!(workspace["capabilities"]["library"], true);
    let serialized = workspace.to_string();
    for hidden in [
        "native-model",
        "private project context",
        "source.mp3",
        "original-rich-text",
        "old-card",
    ] {
        assert!(!serialized.contains(hidden));
    }
    let detail = success(root.path(), "get_meeting", json!({"meetingId":"meeting"}));
    assert_eq!(detail["summary"], "Synthetic migration overview");
    assert_eq!(
        detail["transcript"][0],
        json!({"start":1.25,"end":4.5,"speaker":"Lead","text":"Synthetic migration context"})
    );
    assert_eq!(detail["notes"][0]["id"], "note");
    assert_eq!(fs::read(directory.join("summary.json")).unwrap(), before);
    assert!(!detail.to_string().contains("old-card"));
}

#[test]
fn note_edits_preserve_hidden_fields_and_attachments_and_reject_stale_versions() {
    let root = tempfile::tempdir().unwrap();
    folder(root.path(), "work", "Work");
    meeting_fixture(root.path(), "meeting", "Meeting");
    let note = native_note(root.path(), "native-note", Some("work"), Some("meeting"));
    let source = root.path().join("attachment.txt");
    fs::write(&source, "Synthetic attachment").unwrap();
    let note = notes::attach(root.path(), &note.id, note.revision, &source).unwrap();
    let input = json!({"id":note.id,"title":"Edited title","text":"Edited plain text","expectedRevision":note.revision});
    let saved = success(root.path(), "save_note", json!({"input":input}));
    assert_eq!(saved["revision"], note.revision + 1);
    assert_eq!(saved["folderId"], "work");
    assert_eq!(saved["meetingId"], "meeting");
    let canonical = notes::load_note_snapshot(root.path(), &note.id).unwrap();
    assert_eq!(canonical.kind, "important");
    assert_eq!(canonical.attachments, note.attachments);
    assert_eq!(canonical.tags, note.tags);
    assert!(canonical.pinned);
    assert_eq!(canonical.owner, "Savva");
    assert_eq!(canonical.created_at, note.created_at);
    assert_eq!(canonical.content_rtf, "");
    let stale = call(root.path(), "save_note", json!({"input":input}));
    assert_eq!(stale["error"]["code"], "conflict");
    assert_eq!(
        notes::load_note_snapshot(root.path(), &note.id).unwrap(),
        canonical
    );
    assert_eq!(
        call(
            root.path(),
            "save_note",
            json!({"input":{"id":note.id,"title":"x","text":"x"}})
        )["error"]["code"],
        "invalid_request"
    );
    let unlinked = success(
        root.path(),
        "save_note",
        json!({"input":{"id":note.id,"title":"Standalone","text":"Edited plain text","folderId":null,"meetingId":null,"expectedRevision":canonical.revision}}),
    );
    assert!(unlinked["folderId"].is_null() && unlinked["meetingId"].is_null());
}

#[test]
fn folder_edits_preserve_profiles_and_rename_notes_with_canonical_cas() {
    let root = tempfile::tempdir().unwrap();
    let original = folder(root.path(), "work", "Work");
    let note = native_note(root.path(), "note", Some("work"), None);
    let input = json!({"id":"work","name":"Renamed","expectedRevision":original.revision});
    let saved = success(root.path(), "save_folder", json!({"input":input}));
    assert_eq!(saved["revision"], 2);
    let canonical = notes::list(root.path()).unwrap();
    assert_eq!(canonical.folders[0].overrides, original.overrides);
    assert_eq!(canonical.notes[0].folder, "Renamed");
    assert_eq!(canonical.notes[0].revision, note.revision + 1);
    assert_eq!(
        call(root.path(), "save_folder", json!({"input":input}))["error"]["code"],
        "conflict"
    );
    assert_eq!(
        call(
            root.path(),
            "save_folder",
            json!({"input":{"name":"Renamed"}})
        )["error"]["code"],
        "duplicate_name"
    );
    let created = success(
        root.path(),
        "save_folder",
        json!({"input":{"name":"New folder"}}),
    );
    assert!(Uuid::parse_str(created["id"].as_str().unwrap()).is_ok());
    assert_eq!(created["revision"], 1);
}

#[test]
fn search_filters_folder_before_count_and_limit_and_excludes_unported_entities() {
    let root = tempfile::tempdir().unwrap();
    folder(root.path(), "english", "English");
    folder(root.path(), "work", "Work");
    for (id, folder_id) in [("english-meeting", "english"), ("work-meeting", "work")] {
        meeting_fixture(root.path(), id, "Migration planning");
        folders::assign_meeting(root.path(), id, Some(folder_id), 0).unwrap();
        native_note(
            root.path(),
            &format!("{folder_id}-note"),
            Some(folder_id),
            Some(id),
        );
    }
    let result = success(
        root.path(),
        "search_library",
        json!({"query":"migration","folderId":"work","limit":1}),
    );
    assert_eq!(result["hits"].as_array().unwrap().len(), 1);
    assert_eq!(result["total"], 4); // title, transcript, overview, manual note
    assert_eq!(result["truncated"], true);
    assert_eq!(result["hits"][0]["noteId"], "work-note");
    let scoped = success(
        root.path(),
        "search_library",
        json!({"query":"migration","folderId":"english","limit":100}),
    );
    assert_eq!(scoped["total"], 4);
    assert!(scoped["hits"]
        .as_array()
        .unwrap()
        .iter()
        .all(|hit| hit["meetingId"] == "english-meeting"));
    let workspace = success(root.path(), "get_workspace", json!({"folderId":"work"}));
    assert_eq!(workspace["meetings"].as_array().unwrap().len(), 1);
    assert_eq!(workspace["notes"].as_array().unwrap().len(), 1);
    assert_eq!(workspace["folders"].as_array().unwrap().len(), 2);
    assert_eq!(
        call(
            root.path(),
            "search_library",
            json!({"query":"migration","folderId":"missing"})
        )["error"]["code"],
        "not_found"
    );
}

#[test]
fn bridge_rejects_generic_commands_paths_extra_fields_and_oversized_input() {
    let root = tempfile::tempdir().unwrap();
    for command in [
        "write",
        "read",
        "import",
        "trash-purge",
        "task-update",
        "voice-apply",
        "mcp",
    ] {
        assert_eq!(
            call(root.path(), command, json!({"path":"/tmp/secret"}))["error"]["code"],
            "unsupported_command"
        );
    }
    for arguments in [
        json!({"root":"/tmp/escape"}),
        json!({"folderId":"../escape"}),
        json!({"folderId":"bad/name"}),
    ] {
        assert_eq!(
            call(root.path(), "get_workspace", arguments)["error"]["code"],
            "invalid_request"
        );
    }
    let mut bytes = serde_json::to_vec(&json!({"command":"get_workspace"})).unwrap();
    bytes.resize(MAX_REQUEST_BYTES + 1, b' ');
    assert_eq!(
        handle_bytes(root.path(), &bytes)["error"]["code"],
        "invalid_request"
    );
    assert_eq!(
        handle_bytes(root.path(), b"{invalid")["error"]["code"],
        "invalid_request"
    );
    assert_eq!(
        call(Path::new("relative"), "get_workspace", json!({}))["error"]["code"],
        "invalid_request"
    );
    assert!(!root.path().join("core.sqlite").exists());
}

#[cfg(unix)]
#[test]
fn meeting_reader_refuses_symlinks_and_large_metadata_without_leaking_errors() {
    use std::os::unix::fs::symlink;
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let directory = meeting_fixture(root.path(), "meeting", "Meeting");
    let private = outside.path().join("sensitive.json");
    fs::write(&private, "secret sentinel contents").unwrap();
    fs::remove_file(directory.join("transcript.json")).unwrap();
    symlink(&private, directory.join("transcript.json")).unwrap();
    let failed = call(root.path(), "get_meeting", json!({"meetingId":"meeting"}));
    assert_eq!(failed["error"]["code"], "library_error");
    assert!(!failed.to_string().contains("sensitive") && !failed.to_string().contains("sentinel"));
    fs::remove_file(directory.join("transcript.json")).unwrap();
    let meta = fs::OpenOptions::new()
        .write(true)
        .open(directory.join("meta.json"))
        .unwrap();
    meta.set_len(1_048_577).unwrap();
    assert_eq!(
        call(root.path(), "get_meeting", json!({"meetingId":"meeting"}))["error"]["code"],
        "not_found"
    );
    assert!(success(root.path(), "get_workspace", json!({}))["meetings"]
        .as_array()
        .unwrap()
        .is_empty());
    fs::remove_file(directory.join("meta.json")).unwrap();
    fs::remove_dir_all(&directory).unwrap();
    symlink(outside.path(), &directory).unwrap();
    assert_eq!(
        call(root.path(), "get_meeting", json!({"meetingId":"meeting"}))["error"]["code"],
        "not_found"
    );
}

#[test]
fn stdio_produces_one_json_envelope_and_never_accepts_an_oversized_valid_prefix() {
    let root = tempfile::tempdir().unwrap();
    let mut output = Vec::new();
    run_stdio(
        root.path(),
        b"{\"command\":\"get_workspace\",\"arguments\":{}}".as_slice(),
        &mut output,
    )
    .unwrap();
    assert_eq!(output.iter().filter(|b| **b == b'\n').count(), 1);
    assert_eq!(
        serde_json::from_slice::<Value>(&output).unwrap()["ok"],
        true
    );
    let mut oversized = b"{\"command\":\"get_workspace\"}".to_vec();
    oversized.resize(MAX_REQUEST_BYTES + 1, b' ');
    output.clear();
    run_stdio(root.path(), oversized.as_slice(), &mut output).unwrap();
    assert_eq!(
        serde_json::from_slice::<Value>(&output).unwrap()["error"]["code"],
        "invalid_request"
    );
}

#[test]
fn oversized_workspace_fails_as_a_whole_without_returning_truncated_editable_text() {
    let root = tempfile::tempdir().unwrap();
    let note = native_note(root.path(), "first", None, None);
    let directory = notes::directory(root.path()).unwrap();
    {
        let _lock = notes::lock(&directory).unwrap();
        let mut workspace = notes::load(&directory).unwrap();
        workspace.notes.clear();
        for index in 0..90 {
            let mut copy = note.clone();
            copy.id = format!("note-{index}");
            copy.text = "x".repeat(100_000);
            workspace.notes.push(copy);
        }
        notes::persist(&directory, &workspace).unwrap();
    }
    let response = call(root.path(), "get_workspace", json!({}));
    assert_eq!(response["error"]["code"], "content_too_large");
    assert!(response.get("result").is_none());
    assert_eq!(
        notes::list(root.path()).unwrap().notes[89].text.len(),
        100_000
    );
}

#[test]
fn portable_search_does_not_route_native_card_decks_to_an_unsupported_meeting_view() {
    let root = tempfile::tempdir().unwrap();
    atomic_json(
        &root.path().join("settings.json"),
        &json!({"features":{"cards":true}}),
    )
    .unwrap();
    let directory = meeting_fixture(root.path(), "deck", "DeckExclusive");
    let mut meta = storage::regular_json(&directory.join("meta.json")).unwrap();
    meta["libraryKind"] = json!("cards");
    meta["source"] = json!("cards.tsv");
    atomic_json(&directory.join("meta.json"), &meta).unwrap();
    // Preserve the native search contract, including enabled card deck titles.
    assert_eq!(
        crate::search::search(root.path(), "DeckExclusive", "all", 40).unwrap()["total"],
        1
    );
    let portable = success(
        root.path(),
        "search_library",
        json!({"query":"DeckExclusive"}),
    );
    assert_eq!(portable["total"], 0);
    assert!(portable["hits"].as_array().unwrap().is_empty());
    assert_eq!(
        call(root.path(), "get_meeting", json!({"meetingId":"deck"}))["error"]["code"],
        "not_found"
    );
    let native = storage::regular_json(&directory.join("meta.json")).unwrap();
    assert_eq!(native, meta);
}
