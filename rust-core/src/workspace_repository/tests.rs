use super::*;
use std::os::unix::fs::{symlink, PermissionsExt};

fn note(id: &str, text: &str) -> crate::notes::CapturedNote {
    serde_json::from_value(json!({"id":id,"text":text,"createdAt":0.0,"updatedAt":0.0})).unwrap()
}
fn directory(root: &Path) -> PathBuf {
    crate::notes::directory(root).unwrap()
}
fn legacy(root: &Path, value: &Value) -> Vec<u8> {
    let bytes = serde_json::to_vec_pretty(value).unwrap();
    fs::write(directory(root).join("workspace.json"), &bytes).unwrap();
    bytes
}
fn minimal() -> Value {
    json!({"notes":[],"templates":[],"contexts":[]})
}
fn connection(root: &Path) -> Connection {
    open(&directory(root)).unwrap()
}

#[test]
fn migration_imports_exactly_once_preserves_original_bytes_and_all_forward_fields() {
    let root = tempfile::tempdir().unwrap();
    let data = json!({"notes":[{"id":"n","kind":"task","text":"Original","createdAt":1.0,"updatedAt":1.0,"revision":1,
        "attachments":[{"id":"a","name":"A","relativePath":"notes/attachments/a.txt","contentType":"text/plain","extractedText":"x","futureAttachment":{"value":17}}],
        "futureNote":{"nested":[1,2,3]}}],"templates":[{"id":"t","name":"T","body":"Body","revision":1,"futureTemplate":true}],
        "contexts":[{"meetingID":"meeting","project":"P","futureContext":"keep"}],
        "taskWorkspaces":[{"noteID":"n","status":"todo","source":"local","futureTask":"keep","agentAccess":{"enabled":false,"futureAccess":9},
          "materials":[{"id":"material","kind":"note","noteID":"n","title":"Thought","createdAt":1.0,"futureMaterial":{"keep":true}}]}],
        "futureTop":{"keep":true}});
    let original = legacy(root.path(), &data);
    let first = snapshot(root.path()).unwrap();
    let mut migrated=data.clone();migrated["folders"]=json!([]);
    assert_eq!(first.value, migrated);
    assert_eq!(
        fs::read(directory(root.path()).join(BACKUP)).unwrap(),
        original
    );
    let saved = crate::notes::list(root.path()).unwrap().notes.remove(0);
    let mut edited = saved.clone();
    edited.text = "New text".into();
    crate::notes::save_note(root.path(), edited).unwrap();
    let current = snapshot(root.path()).unwrap();
    assert_eq!(current.value["futureTop"], data["futureTop"]);
    assert_eq!(
        current.value["notes"][0]["futureNote"],
        data["notes"][0]["futureNote"]
    );
    assert_eq!(
        current.value["notes"][0]["attachments"][0]["futureAttachment"],
        data["notes"][0]["attachments"][0]["futureAttachment"]
    );
    assert_eq!(current.value["taskWorkspaces"][0]["futureTask"], "keep");
    assert_eq!(
        current.value["taskWorkspaces"][0]["agentAccess"]["futureAccess"],
        9
    );
    assert_eq!(
        current.value["taskWorkspaces"][0]["materials"][0]["futureMaterial"]["keep"],
        true
    );
    assert_eq!(current.value["templates"][0]["futureTemplate"], true);
    assert_eq!(current.value["contexts"][0]["futureContext"], "keep");
    // Editing or deleting the compatibility export never changes canonical data.
    fs::write(directory(root.path()).join("workspace.json"), &original).unwrap();
    assert_eq!(
        crate::notes::list(root.path()).unwrap().notes[0].text,
        "New text"
    );
    fs::remove_file(directory(root.path()).join("workspace.json")).unwrap();
    assert_eq!(snapshot(root.path()).unwrap().revision, current.revision);
    assert_eq!(
        fs::read(directory(root.path()).join(BACKUP)).unwrap(),
        original
    );
}

#[test]
fn unknown_fields_follow_ids_when_reordered_and_deleted_entities_stay_deleted() {
    let root = tempfile::tempdir().unwrap();
    let data = json!({"notes":[{"id":"a","text":"A","createdAt":0.0,"updatedAt":0.0,"future":1},{"id":"b","text":"B","createdAt":0.0,"updatedAt":0.0,"future":2}],"futureTop":"yes"});
    legacy(root.path(), &data);
    let first = snapshot(root.path()).unwrap();
    let mut known = serde_json::to_value(crate::notes::list(root.path()).unwrap()).unwrap();
    known["notes"].as_array_mut().unwrap().reverse();
    let second = compare_and_save(root.path(), first.revision, &known).unwrap();
    assert_eq!(second.value["notes"][0]["id"], "b");
    assert_eq!(second.value["notes"][0]["future"], 2);
    let mut known = serde_json::to_value(crate::notes::list(root.path()).unwrap()).unwrap();
    known["notes"].as_array_mut().unwrap().remove(1);
    let third = compare_and_save(root.path(), second.revision, &known).unwrap();
    assert_eq!(third.value["notes"].as_array().unwrap().len(), 1);
    let conn = connection(root.path());
    assert_eq!(
        conn.query_row(
            "SELECT deleted FROM workspace_entities WHERE kind='note' AND entity_id='a'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        1
    );
    assert_eq!(third.value["futureTop"], "yes");
    // The untouched pre-migration backup cannot bring deleted entities back.
    fs::copy(
        directory(root.path()).join(BACKUP),
        directory(root.path()).join("workspace.json"),
    )
    .unwrap();
    assert_eq!(
        snapshot(root.path()).unwrap().value["notes"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn canonical_commit_atomically_writes_receipts_metadata_and_outbox() {
    let root = tempfile::tempdir().unwrap();
    let first = snapshot(root.path()).unwrap();
    let mut value = first.value.clone();
    value["notes"] =
        json!([{"id":"n","text":"SENSITIVE-TEXT","createdAt":0.0,"updatedAt":1.0,"revision":1}]);
    value["taskOperations"] = json!([{"operationID":"operation-one","fingerprint":"input","result":{"saved":true},"undone":false}]);
    let saved = compare_and_save(root.path(), first.revision, &value).unwrap();
    assert_eq!(saved.revision, first.revision + 1);
    assert_eq!(
        operation_receipt(root.path(), "task", "operation-one")
            .unwrap()
            .unwrap()["result"]["saved"],
        true
    );
    let events = pending_events(root.path(), "semantic", 500).unwrap();
    let event = events.last().unwrap();
    assert_eq!(event.revision, saved.revision);
    assert_eq!(event.payload["changes"][0]["id"], "n");
    assert!(!serde_json::to_string(event)
        .unwrap()
        .contains("SENSITIVE-TEXT"));
    let conn = connection(root.path());
    assert_eq!(
        conn.query_row(
            "SELECT workspace_revision FROM operation_receipts WHERE operation_id='operation-one'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap() as u64,
        saved.revision
    );
    assert_eq!(
        conn.query_row(
            "SELECT workspace_revision FROM workspace_entities WHERE kind='note' AND entity_id='n'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap() as u64,
        saved.revision
    );
}

#[test]
fn outbox_failure_rolls_back_workspace_and_receipt_and_is_recoverable() {
    let root = tempfile::tempdir().unwrap();
    let first = snapshot(root.path()).unwrap();
    let conn = connection(root.path());
    conn.execute_batch("CREATE TRIGGER fail_outbox BEFORE INSERT ON workspace_outbox BEGIN SELECT RAISE(ABORT,'injected outbox failure'); END;").unwrap();
    let mut value = first.value.clone();
    value["notes"] =
        json!([{"id":"n","text":"not committed","createdAt":0.0,"updatedAt":1.0,"revision":1}]);
    value["voiceOperations"] = json!([{"operationID":"voice-one","createdAt":1.0}]);
    assert!(compare_and_save(root.path(), first.revision, &value).is_err());
    let after = snapshot(root.path()).unwrap();
    assert_eq!(after.revision, first.revision);
    assert_eq!(after.value, first.value);
    assert!(operation_receipt(root.path(), "voice", "voice-one")
        .unwrap()
        .is_none());
    assert_eq!(
        conn.query_row(
            "SELECT count(*) FROM workspace_entities WHERE kind='note'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    conn.execute_batch("DROP TRIGGER fail_outbox").unwrap();
    assert_eq!(
        compare_and_save(root.path(), first.revision, &value)
            .unwrap()
            .revision,
        first.revision + 1
    );
}

#[test]
fn replay_is_noop_and_receipt_updates_undo_in_same_transaction() {
    let root = tempfile::tempdir().unwrap();
    let first = snapshot(root.path()).unwrap();
    let mut value = first.value.clone();
    value["taskOperations"] = json!([{"operationID":"op","undone":false}]);
    let saved = compare_and_save(root.path(), first.revision, &value).unwrap();
    assert_eq!(
        compare_and_save(root.path(), saved.revision, &saved.value)
            .unwrap()
            .revision,
        saved.revision
    );
    assert_eq!(pending_events(root.path(), "c", 500).unwrap().len(), 2);
    value["taskOperations"][0]["undone"] = json!(true);
    let undone = compare_and_save(root.path(), saved.revision, &value).unwrap();
    assert_eq!(
        operation_receipt(root.path(), "task", "op")
            .unwrap()
            .unwrap()["undone"],
        true
    );
    assert_eq!(
        pending_events(root.path(), "c", 500)
            .unwrap()
            .last()
            .unwrap()
            .revision,
        undone.revision
    );
}

#[test]
fn consumers_acknowledge_independently_idempotently_and_only_real_events() {
    let root = tempfile::tempdir().unwrap();
    crate::notes::save_note(root.path(), note("n", "Text")).unwrap();
    let original = pending_events(root.path(), "semantic", 500).unwrap();
    acknowledge_event(root.path(), "semantic", &original[0].id).unwrap();
    acknowledge_event(root.path(), "semantic", &original[0].id).unwrap();
    assert_eq!(
        pending_events(root.path(), "semantic", 500).unwrap().len(),
        original.len() - 1
    );
    assert_eq!(
        pending_events(root.path(), "tracker", 500).unwrap().len(),
        original.len()
    );
    assert!(acknowledge_event(root.path(), "semantic", "not-found").is_err());
    assert!(pending_events(root.path(), "../escape", 1).is_err());
    assert!(pending_events(root.path(), "semantic", 501).is_err());
}

#[test]
fn stale_revision_cannot_overwrite_another_process_or_drop_its_changes() {
    let root = tempfile::tempdir().unwrap();
    let first = snapshot(root.path()).unwrap();
    let mut value = first.value.clone();
    value["futureTop"] = json!("stale edit");
    crate::notes::save_note(root.path(), note("n", "Latest note")).unwrap();
    assert!(compare_and_save(root.path(), first.revision, &value).is_err());
    assert_eq!(
        crate::notes::list(root.path()).unwrap().notes[0].text,
        "Latest note"
    );
}

#[test]
fn parallel_first_use_and_cas_save_allow_exactly_one_winner() {
    let root = tempfile::tempdir().unwrap();
    let mut threads = vec![];
    for _ in 0..8 {
        let root = root.path().to_owned();
        threads.push(std::thread::spawn(move || snapshot(&root).unwrap()));
    }
    for thread in threads {
        assert_eq!(thread.join().unwrap().revision, 1);
    }
    let first = snapshot(root.path()).unwrap();
    let mut threads = vec![];
    for i in 0..8 {
        let root = root.path().to_owned();
        let mut value = first.value.clone();
        value["editedBy"] = json!(i);
        let revision = first.revision;
        threads.push(std::thread::spawn(move || {
            compare_and_save(&root, revision, &value)
        }));
    }
    assert_eq!(
        threads
            .into_iter()
            .map(|thread| thread.join().unwrap())
            .filter(Result::is_ok)
            .count(),
        1
    );
    assert_eq!(snapshot(root.path()).unwrap().revision, 2);
}

#[test]
fn invalid_or_oversized_legacy_never_becomes_canonical_or_overwrites_original() {
    let root = tempfile::tempdir().unwrap();
    let path = directory(root.path()).join("workspace.json");
    fs::write(&path, b"{invalid").unwrap();
    assert!(snapshot(root.path()).is_err());
    assert_eq!(fs::read(&path).unwrap(), b"{invalid");
    assert!(!directory(root.path()).join(BACKUP).exists());
    assert!(!directory(root.path()).join(MARKER).exists());
    fs::write(&path, serde_json::to_vec(&minimal()).unwrap()).unwrap();
    assert!(snapshot(root.path()).is_ok());
    let root = tempfile::tempdir().unwrap();
    let path = directory(root.path()).join("workspace.json");
    File::create(&path)
        .unwrap()
        .set_len(MAX_WORKSPACE + 1)
        .unwrap();
    assert!(snapshot(root.path()).is_err());
    assert_eq!(fs::metadata(path).unwrap().len(), MAX_WORKSPACE + 1);
}

#[test]
fn missing_or_corrupt_database_never_reimports_old_backup_or_export() {
    let root = tempfile::tempdir().unwrap();
    legacy(root.path(), &minimal());
    crate::notes::save_note(root.path(), note("n", "Saved")).unwrap();
    fs::remove_file(root.path().join(DATABASE)).unwrap();
    assert!(snapshot(root.path())
        .unwrap_err()
        .to_string()
        .contains("повторный импорт"));
    assert!(!root.path().join(DATABASE).exists());
    let root = tempfile::tempdir().unwrap();
    legacy(root.path(), &minimal());
    snapshot(root.path()).unwrap();
    fs::write(root.path().join(DATABASE), b"corrupt database").unwrap();
    assert!(snapshot(root.path()).is_err());
    assert_eq!(
        fs::read(root.path().join(DATABASE)).unwrap(),
        b"corrupt database"
    );
}

#[test]
fn fingerprint_corruption_is_detected_without_importing_derived_json() {
    let root = tempfile::tempdir().unwrap();
    snapshot(root.path()).unwrap();
    let conn = connection(root.path());
    conn.execute("UPDATE workspace_state SET payload=?1", ["{}"])
        .unwrap();
    assert!(snapshot(root.path())
        .unwrap_err()
        .to_string()
        .contains("контрольная сумма"));
}

#[test]
fn database_backup_and_live_sidecars_are_private_and_symlinks_are_rejected() {
    let root = tempfile::tempdir().unwrap();
    legacy(root.path(), &minimal());
    snapshot(root.path()).unwrap();
    let conn = connection(root.path());
    conn.execute(
        "INSERT INTO workspace_metadata(key,value) VALUES('permission-test','value')",
        [],
    )
    .unwrap();
    for path in [
        root.path().join(DATABASE),
        root.path().join("core.sqlite-wal"),
        root.path().join("core.sqlite-shm"),
        directory(root.path()).join(BACKUP),
        directory(root.path()).join(MARKER),
    ] {
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600,
            "{}",
            path.display()
        );
    }
    for name in [
        "core.sqlite",
        "core.sqlite-wal",
        "core.sqlite-shm",
        "core.sqlite-journal",
    ] {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let target = outside.path().join("keep");
        fs::write(&target, b"untouched").unwrap();
        symlink(&target, root.path().join(name)).unwrap();
        assert!(snapshot(root.path()).is_err());
        assert_eq!(fs::read(target).unwrap(), b"untouched");
    }
    for name in [BACKUP, MARKER, "workspace.json"] {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let target = outside.path().join("keep");
        fs::write(&target, b"untouched").unwrap();
        if name == BACKUP {
            legacy(root.path(), &minimal());
        }
        symlink(&target, directory(root.path()).join(name)).unwrap();
        assert!(snapshot(root.path()).is_err());
        assert_eq!(fs::read(target).unwrap(), b"untouched");
    }
}

#[test]
fn writer_busy_waits_for_existing_sqlite_transaction_then_commits_once() {
    let root = tempfile::tempdir().unwrap();
    let first = snapshot(root.path()).unwrap();
    let mut conn = connection(root.path());
    let transaction = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let thread_root = root.path().to_owned();
    let thread = std::thread::spawn(move || {
        tx.send(()).unwrap();
        crate::notes::save_note(&thread_root, note("n", "After busy"))
    });
    rx.recv().unwrap();
    std::thread::sleep(Duration::from_millis(150));
    assert!(!thread.is_finished());
    transaction.commit().unwrap();
    assert!(thread.join().unwrap().is_ok());
    assert_eq!(snapshot(root.path()).unwrap().revision, first.revision + 1);
    assert_eq!(crate::notes::list(root.path()).unwrap().notes.len(), 1);
}

#[test]
fn migration_transaction_failure_can_retry_without_partial_state_or_second_import() {
    let root = tempfile::tempdir().unwrap();
    let original = legacy(root.path(), &minimal());
    let conn = connection(root.path());
    conn.execute_batch("CREATE TRIGGER fail_migration BEFORE INSERT ON workspace_outbox BEGIN SELECT RAISE(ABORT,'injected migration failure'); END;").unwrap();
    assert!(snapshot(root.path()).is_err());
    assert_eq!(
        conn.query_row("SELECT count(*) FROM workspace_state", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        fs::read(directory(root.path()).join("workspace.json")).unwrap(),
        original
    );
    assert_eq!(
        fs::read(directory(root.path()).join(BACKUP)).unwrap(),
        original
    );
    assert!(!directory(root.path()).join(MARKER).exists());
    conn.execute_batch("DROP TRIGGER fail_migration").unwrap();
    assert_eq!(snapshot(root.path()).unwrap().revision, 1);
    assert_eq!(
        pending_events(root.path(), "semantic", 500).unwrap().len(),
        1
    );
}

#[test]
fn legacy_known_aliases_do_not_reappear_as_unknown_stale_values() {
    let root = tempfile::tempdir().unwrap();
    legacy(
        root.path(),
        &json!({"notes":[{"id":"n","text":"Legacy","createdAt":0.0,"updatedAt":0.0,"sourceUrl":"https://example.org/old","contentRtf":"old-rich","futureField":"keep"}],
        "contexts":[{"meetingId":"one","templateId":"purchases"}]}),
    );
    let first = snapshot(root.path()).unwrap();
    assert_eq!(
        first.value["notes"][0]["sourceURL"],
        "https://example.org/old"
    );
    assert!(first.value["notes"][0].get("sourceUrl").is_none());
    assert!(first.value["contexts"][0].get("meetingId").is_none());
    let mut edited = crate::notes::list(root.path()).unwrap().notes.remove(0);
    edited.source_url = "https://example.org/new".into();
    edited.content_rtf.clear();
    crate::notes::save_note(root.path(), edited).unwrap();
    let saved = snapshot(root.path()).unwrap();
    assert_eq!(
        saved.value["notes"][0]["sourceURL"],
        "https://example.org/new"
    );
    assert_eq!(saved.value["notes"][0]["contentRTF"], "");
    assert!(saved.value["notes"][0].get("sourceUrl").is_none());
    assert_eq!(saved.value["notes"][0]["futureField"], "keep");
}

#[test]
fn clearing_known_skipped_fields_does_not_restore_old_receipts_or_optional_values() {
    let root = tempfile::tempdir().unwrap();
    let first = snapshot(root.path()).unwrap();
    let mut value = first.value.clone();
    value["voicePlans"] = json!([{"planID":"p","status":"ready"}]);
    let saved = compare_and_save(root.path(), first.revision, &value).unwrap();
    let mut workspace = crate::notes::list(root.path()).unwrap();
    workspace.voice_plans.clear();
    let dir = directory(root.path());
    let _lock = crate::notes::lock(&dir).unwrap();
    let empty = persist_locked(&dir, &workspace).unwrap();
    assert!(empty.revision > saved.revision);
    assert!(empty.value.get("voicePlans").is_none());
}

#[test]
fn receipt_id_cannot_be_reused_after_workspace_retention_or_changed_payload() {
    let root = tempfile::tempdir().unwrap();
    let first = snapshot(root.path()).unwrap();
    let mut value = first.value.clone();
    value["taskOperations"] = json!([{"operationID":"op","fingerprint":"original"}]);
    let saved = compare_and_save(root.path(), first.revision, &value).unwrap();
    value["taskOperations"] = json!([]);
    let retained = compare_and_save(root.path(), saved.revision, &value).unwrap();
    value["taskOperations"] = json!([{"operationID":"op","fingerprint":"different"}]);
    assert!(compare_and_save(root.path(), retained.revision, &value).is_err());
    assert_eq!(snapshot(root.path()).unwrap().revision, retained.revision);
    assert_eq!(
        operation_receipt(root.path(), "task", "op")
            .unwrap()
            .unwrap()["fingerprint"],
        "original"
    );
}

#[test]
fn missing_canonical_row_never_silently_reimports_derived_json() {
    let root = tempfile::tempdir().unwrap();
    snapshot(root.path()).unwrap();
    let conn = connection(root.path());
    conn.execute("DELETE FROM workspace_state", []).unwrap();
    assert!(snapshot(root.path())
        .unwrap_err()
        .to_string()
        .contains("Повторный импорт"));
    assert_eq!(
        conn.query_row("SELECT count(*) FROM workspace_state", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
}

#[cfg(target_os = "macos")]
#[test]
fn system_tmp_alias_is_supported_while_the_database_leaf_still_rejects_symlinks() {
    let directory = tempfile::Builder::new()
        .prefix("posle-core-alias-")
        .tempdir_in("/private/tmp")
        .unwrap();
    let alias = Path::new("/tmp").join(directory.path().file_name().unwrap());
    let first = snapshot(&alias).unwrap();
    crate::notes::save_note(&alias, note("n", "Same private directory")).unwrap();
    assert_eq!(
        snapshot(directory.path()).unwrap().revision,
        first.revision + 1
    );
    assert_eq!(
        crate::notes::list(directory.path()).unwrap().notes[0].text,
        "Same private directory"
    );
}


#[test]
fn existing_sqlite_payload_migrates_legacy_note_folders_once_with_entity_events() {
    let root=tempfile::tempdir().unwrap();
    let first=snapshot(root.path()).unwrap();let mut old=first.value;
    old.as_object_mut().unwrap().remove("folders");
    old["notes"]=json!([{"id":"old-note","text":"Фразы","folder":"Английский","createdAt":0,"updatedAt":0,"revision":1,"future":{"kept":true}}]);
    let old=compare_and_save(root.path(),first.revision,&old).unwrap();
    let current=crate::notes::list(root.path()).unwrap();
    assert_eq!(current.folders.len(),1);assert_eq!(current.folders[0].name,"Английский");
    assert_eq!(current.notes[0].folder_id.as_deref(),Some(current.folders[0].id.as_str()));
    let migrated=snapshot(root.path()).unwrap();assert!(migrated.revision>old.revision);
    assert_eq!(migrated.value["notes"][0]["future"]["kept"],true);
    assert_eq!(snapshot(root.path()).unwrap().revision,migrated.revision);
    let connection=connection(root.path());
    assert_eq!(connection.query_row("SELECT COUNT(*) FROM workspace_entities WHERE kind='folder' AND deleted=0",[],|row|row.get::<_,i64>(0)).unwrap(),1);
    assert!(pending_events(root.path(),"folder-test",100).unwrap().iter().any(|event|event.kind=="workspace.folders-migrated"));
}
