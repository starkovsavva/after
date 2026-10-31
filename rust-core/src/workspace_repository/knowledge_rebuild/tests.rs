use super::*;
use std::sync::{Mutex, OnceLock};
static FAIL: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();
pub(super) fn fail_before_commit(root: &Path) -> Result<()> {
    let mut fail = FAIL.get_or_init(|| Mutex::new(None)).lock().unwrap();
    if fail.as_deref() == Some(root) {
        *fail = None;
        bail!("Injected rebuild transaction failure");
    }
    Ok(())
}
fn setup() -> tempfile::TempDir {
    let root = tempfile::tempdir().unwrap();
    crate::storage::atomic_json(
        &root.path().join("settings.json"),
        &json!({"features":{"knowledgeBase":true}}),
    )
    .unwrap();
    create(root.path(), "a", "One. Two.");
    create(root.path(), "b", "Three.");
    root
}
fn create(root: &Path, id: &str, text: &str) -> crate::notes::CapturedNote {
    crate::notes::save_note(root,serde_json::from_value(json!({"id":id,"kind":"note","text":text,"title":format!("Title {id}"),"createdAt":0,"updatedAt":0,"revision":0})).unwrap()).unwrap()
}
fn call(root: &Path, command: &str, mut input: Value) -> Result<Value> {
    input["command"] = json!(command);
    dispatch(root, &input)
}
fn prepared(root: &Path) -> Value {
    call(
        root,
        "kb-rebuild-prepare",
        json!({"noteIDs":["a","b"],"instruction":"Split, merge and edit my notes"}),
    )
    .unwrap()
}
fn proposal() -> Value {
    json!({"title":"Reorganize","summary":"Two source notes retained","edits":[{"noteID":"a","title":"Edited","text":"One corrected. Two."}],
    "newNotes":[{"key":"split","title":"One","text":"One.","sourceNoteIDs":["a"]},{"key":"merged","title":"Combined","text":"One and three.","sourceNoteIDs":["a","b"]}],
    "collections":[{"key":"group","name":"Ideas","members":[{"noteID":"a"},{"draftKey":"split"},{"draftKey":"merged"}]}],"links":[{"from":{"noteID":"a"},"to":{"noteID":"b"}}]})
}
fn review(root: &Path, draft: &Value, proposal: Value) -> Value {
    call(root,"kb-rebuild-preview",json!({"draftID":draft["draftID"],"expectedDraftRevision":draft["draftRevision"],"proposal":proposal})).unwrap()
}
fn apply_request(review: &Value) -> Value {
    json!({"draftID":review["draftID"],"expectedDraftRevision":review["draftRevision"],"operationID":uuid()})
}
fn snapshot(root: &Path) -> WorkspaceSnapshot {
    super::super::snapshot(root).unwrap()
}
fn note(root: &Path, id: &str) -> Value {
    raw_note(&snapshot(root), id).unwrap().clone()
}
fn edit(root: &Path, id: &str, value: &str) {
    let mut n = crate::notes::load_note_snapshot(root, id).unwrap();
    n.text = value.into();
    crate::notes::save_note(root, n).unwrap();
}
fn knowledge_rows(root: &Path) -> Value {
    locked(root,|_,c,_|Ok(json!({"links":knowledge::list_links(c)?,"groups":knowledge::list_collections(c)?,"state":knowledge::state(c)?}))).unwrap()
}
#[test]
fn prepare_preview_are_read_only_and_apply_undo_preserve_unknown_rich_fields() {
    let root = setup();
    let mut s = snapshot(root.path());
    s.value["unknownWorkspace"] = json!({"retained":true});
    let a = s.value["notes"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|n| n["id"] == "a")
        .unwrap();
    a["unknownFuture"] = json!({"nested":[1,"two"]});
    a["tags"] = json!(["keep"]);
    a["sourceURL"] = json!("https://example.invalid/retained-source");
    a["pinned"] = json!(true);
    a["attachments"] = json!([{"id":"fixture-attachment","name":"Fixture.txt","relativePath":"notes/attachments/fixture-attachment.txt","contentType":"text/plain","extractedText":"Attachment remains private to original"}]);
    let attachment = root.path().join("notes/attachments/fixture-attachment.txt");
    fs::create_dir_all(attachment.parent().unwrap()).unwrap();
    fs::write(&attachment, b"owned fixture attachment").unwrap();
    a["contentRTF"] = json!("opaque-rich-text");
    a["expansion"] = json!({"text":"old-derived"});
    super::super::compare_and_save(root.path(), s.revision, &s.value).unwrap();
    let before = snapshot(root.path());
    let old_a = note(root.path(), "a");
    let old_b = note(root.path(), "b");
    let draft = prepared(root.path());
    let kb_before = knowledge_rows(root.path());
    let preview = review(root.path(), &draft, proposal());
    assert_eq!(preview["beforeEdits"][0]["text"], "One. Two.");
    assert_eq!(snapshot(root.path()).value, before.value);
    assert_eq!(snapshot(root.path()).revision, before.revision);
    assert_eq!(knowledge_rows(root.path()), kb_before);
    let request = apply_request(&preview);
    let result = call(root.path(), "kb-rebuild-apply", request.clone()).unwrap();
    assert_eq!(
        call(root.path(), "kb-rebuild-apply", request.clone()).unwrap(),
        result
    );
    let changed = note(root.path(), "a");
    assert_eq!(changed["text"], "One corrected. Two.");
    assert_eq!(changed["unknownFuture"], old_a["unknownFuture"]);
    assert_eq!(changed["tags"], old_a["tags"]);
    let mut untouched = old_a.as_object().unwrap().clone();
    for key in [
        "title",
        "text",
        "revision",
        "updatedAt",
        "contentRTF",
        "expansion",
    ] {
        untouched.remove(key);
    }
    for (key, value) in untouched {
        assert_eq!(changed[&key], value, "Unrelated field {key} must survive");
    }
    assert_eq!(fs::read(&attachment).unwrap(), b"owned fixture attachment");
    assert_eq!(changed["contentRTF"], "");
    assert!(changed.get("expansion").is_none());
    assert_eq!(note(root.path(), "b"), old_b);
    for item in result["createdNotes"].as_array().unwrap() {
        let id = item["noteID"].as_str().unwrap();
        assert!(Uuid::parse_str(id).is_ok());
        assert_ne!(item["key"], item["noteID"]);
        assert!(
            !note(root.path(), id)["knowledgeRebuildOrigin"]["sourceNoteIDs"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }
    assert_eq!(
        snapshot(root.path()).value["notes"]
            .as_array()
            .unwrap()
            .len(),
        4
    );
    assert_eq!(
        knowledge_rows(root.path())["links"]
            .as_array()
            .unwrap()
            .len(),
        4
    );
    create(root.path(), "unrelated", "New unrelated note");
    edit(root.path(), "b", "Unrelated source edited after apply");
    let undone = call(
        root.path(),
        "kb-rebuild-undo",
        json!({"operationID":result["operationID"]}),
    )
    .unwrap();
    assert_eq!(undone["undone"], true);
    let restored = note(root.path(), "a");
    for field in [
        "text",
        "title",
        "contentRTF",
        "expansion",
        "unknownFuture",
        "tags",
    ] {
        assert_eq!(restored[field], old_a[field], "{field}");
    }
    assert!(restored["revision"].as_u64().unwrap() > changed["revision"].as_u64().unwrap());
    assert_eq!(
        note(root.path(), "b")["text"],
        "Unrelated source edited after apply"
    );
    assert_eq!(note(root.path(), "unrelated")["text"], "New unrelated note");
    assert_eq!(
        snapshot(root.path()).value["unknownWorkspace"],
        json!({"retained":true})
    );
    assert_eq!(knowledge_rows(root.path())["groups"], json!([]));
    assert_eq!(
        call(
            root.path(),
            "kb-rebuild-undo",
            json!({"operationID":result["operationID"]})
        )
        .unwrap(),
        undone
    );
    assert_eq!(
        call(root.path(), "kb-rebuild-apply", request).unwrap()["undone"],
        true
    );
    let history = call(root.path(), "kb-rebuild-history", json!({})).unwrap();
    assert_eq!(history["operations"][0]["canUndo"], false);
    let c = Connection::open(root.path().join(DATABASE)).unwrap();
    assert_eq!(
        c.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
}
#[test]
fn malformed_references_unknown_fields_duplicates_and_budgets_are_rejected() {
    let root = setup();
    let draft = prepared(root.path());
    let before = snapshot(root.path());
    let mut cases = Vec::new();
    let mut p = proposal();
    p["dangerousPath"] = json!("/tmp/file");
    cases.push(p);
    let mut p = proposal();
    p["edits"][0]["folderID"] = json!("other");
    cases.push(p);
    let mut p = proposal();
    p["edits"][0]["noteID"] = json!("outside");
    cases.push(p);
    let mut p = proposal();
    p["newNotes"][0]["sourceNoteIDs"] = json!(["a", "a"]);
    cases.push(p);
    let mut p = proposal();
    p["newNotes"][1]["key"] = json!("split");
    cases.push(p);
    let mut p = proposal();
    p["newNotes"][0]["key"] = json!("../path");
    cases.push(p);
    let mut p = proposal();
    p["collections"][0]["members"] = json!([{"noteID":"a","draftKey":"split"}]);
    cases.push(p);
    let mut p = proposal();
    p["collections"][0]["members"] = json!([{"noteID":"a"},{"noteID":"a"}]);
    cases.push(p);
    let mut p = proposal();
    p["links"] = json!([{"from":{"noteID":"a"},"to":{"noteID":"a"}}]);
    cases.push(p);
    let mut p = proposal();
    p["links"] = json!([{"from":{"draftKey":"split"},"to":{"noteID":"a"}}]);
    cases.push(p);
    let mut p = proposal();
    p["edits"][0]["text"] = json!("bad\0text");
    cases.push(p);
    let mut p = proposal();
    p["summary"] = json!("x".repeat(8001));
    cases.push(p);
    let mut p = proposal();
    p["newNotes"][0]["text"] = json!("x".repeat(100001));
    cases.push(p);
    let mut p = proposal();
    p["newNotes"] = json!((0..31)
        .map(|i| json!({"key":format!("n{i}"),"title":"N","text":"T","sourceNoteIDs":["a"]}))
        .collect::<Vec<_>>());
    cases.push(p);
    let mut p = proposal();
    p["edits"][0]["text"] = json!("x".repeat(99000));
    p["newNotes"][0]["text"] = json!("x".repeat(99000));
    cases.push(p);
    for p in cases {
        assert!(call(root.path(),"kb-rebuild-preview",json!({"draftID":draft["draftID"],"expectedDraftRevision":draft["draftRevision"],"proposal":p})).is_err());
    }
    assert!(call(
        root.path(),
        "kb-rebuild-prepare",
        json!({"noteIDs":["a","a"],"instruction":"Do"})
    )
    .is_err());
    assert!(call(
        root.path(),
        "kb-rebuild-prepare",
        json!({"noteIDs":["a"],"instruction":"x".repeat(4001)})
    )
    .is_err());
    assert!(call(
        root.path(),
        "kb-rebuild-prepare",
        json!({"noteIDs":["a"],"instruction":format!("{}edit"," ".repeat(4000))})
    )
    .is_err());
    assert_eq!(snapshot(root.path()).value, before.value);
}
#[test]
fn source_edits_old_writer_delete_recreate_and_stale_draft_cas_block_apply() {
    let root = setup();
    let draft = prepared(root.path());
    let preview = review(root.path(), &draft, proposal());
    assert!(call(
        root.path(),
        "kb-rebuild-preview",
        json!({"draftID":draft["draftID"],"expectedDraftRevision":0,"proposal":proposal()})
    )
    .is_err());
    let second = review(root.path(), &preview, proposal());
    assert!(call(root.path(), "kb-rebuild-apply", apply_request(&preview)).is_err());
    edit(root.path(), "b", "Changed");
    assert!(call(root.path(), "kb-rebuild-apply", apply_request(&second)).is_err());
    assert!(context(root.path(), draft["draftID"].as_str().unwrap()).is_err());
    let draft = prepared(root.path());
    let preview = review(root.path(), &draft, proposal());
    let original = note(root.path(), "a");
    // Emulate an older writer: its snapshot/outbox/entity catalogue updates do
    // not know about rebuild drafts. Recreate exact same bytes and revision.
    let directory = crate::notes::directory(root.path()).unwrap();
    let _lock = crate::notes::lock(&directory).unwrap();
    let mut c = open(&directory).unwrap();
    let before = initialize(&mut c, &directory).unwrap();
    let mut value = before.value.clone();
    value["notes"]
        .as_array_mut()
        .unwrap()
        .retain(|n| n["id"] != "a");
    fn old_write(
        c: &mut Connection,
        before: &WorkspaceSnapshot,
        value: Value,
        original: &Value,
        deleted: bool,
    ) -> WorkspaceSnapshot {
        let revision = before.revision + 1;
        let digest = hash(&value).unwrap();
        let tx = c.transaction().unwrap();
        tx.execute("UPDATE workspace_state SET revision=?1,fingerprint=?2,payload=?3,updated_at=?4 WHERE singleton=1",params![revision as i64,digest,serde_json::to_string(&value).unwrap(),now()]).unwrap();
        tx.execute("UPDATE workspace_entities SET workspace_revision=?1,entity_revision=?2,fingerprint=?3,deleted=?4 WHERE kind='note' AND entity_id='a'",params![revision as i64,original["revision"].as_i64().unwrap(),if deleted {String::new()}else{hash(original).unwrap()},deleted as i64]).unwrap();
        tx.execute("INSERT INTO workspace_outbox VALUES(?1,?2,'workspace.changed',?3,?4)",params![uuid(),revision as i64,now(),serde_json::to_string(&json!({"schemaVersion":1,"workspaceRevision":revision,"changes":[{"kind":"note","id":"a","change":if deleted{"delete"}else{"upsert"}}]})).unwrap()]).unwrap();
        tx.commit().unwrap();
        WorkspaceSnapshot {
            revision,
            fingerprint: digest,
            value,
        }
    }
    let deleted = old_write(&mut c, &before, value, &original, true);
    let mut value = deleted.value.clone();
    value["notes"]
        .as_array_mut()
        .unwrap()
        .push(original.clone());
    let recreated = old_write(&mut c, &deleted, value, &original, false);
    let saved = read_draft(&c, draft["draftID"].as_str().unwrap()).unwrap();
    assert!(
        !saved.context.invalidated,
        "Old writer does not know rebuild tables"
    );
    assert_eq!(raw_note(&recreated, "a").unwrap(), &original);
    assert!(
        check_sources(root.path(), &c, &recreated, &saved.context, true).is_err(),
        "Entity catalogue catches exact-content delete/recreate before cleanup"
    );
    drop(c);
    drop(_lock);
    assert!(call(root.path(), "kb-rebuild-apply", apply_request(&preview)).is_err());
}
#[test]
fn feature_revocation_trash_task_and_scope_fail_closed() {
    let root = setup();
    let draft = prepared(root.path());
    let preview = review(root.path(), &draft, proposal());
    crate::storage::atomic_json(
        &root.path().join("settings.json"),
        &json!({"features":{"knowledgeBase":false}}),
    )
    .unwrap();
    assert!(call(root.path(), "kb-rebuild-apply", apply_request(&preview)).is_err());
    crate::storage::atomic_json(
        &root.path().join("settings.json"),
        &json!({"features":{"knowledgeBase":true}}),
    )
    .unwrap();
    let n = crate::notes::load_note_snapshot(root.path(), "a").unwrap();
    crate::notes::trash_note(root.path(), "a", n.revision, false).unwrap();
    assert!(call(root.path(), "kb-rebuild-apply", apply_request(&preview)).is_err());
    let mut task = create(root.path(), "task", "Do task");
    task.kind = "task".into();
    crate::notes::save_note(root.path(), task).unwrap();
    assert!(call(
        root.path(),
        "kb-rebuild-prepare",
        json!({"noteIDs":["task"],"instruction":"edit"})
    )
    .is_err());
    assert!(call(
        root.path(),
        "kb-rebuild-prepare",
        json!({"noteIDs":["b"],"folderID":"missing","instruction":"edit"})
    )
    .is_err());
}
#[test]
fn undo_refuses_affected_note_or_collection_changes_but_preserves_receipt() {
    for change in ["note", "collection", "newDependency"] {
        let root = setup();
        let draft = prepared(root.path());
        let preview = review(root.path(), &draft, proposal());
        let result = call(root.path(), "kb-rebuild-apply", apply_request(&preview)).unwrap();
        if change == "note" {
            edit(root.path(), "a", "User edit after apply");
        } else if change == "collection" {
            let c = Connection::open(root.path().join(DATABASE)).unwrap();
            c.execute(
                "UPDATE kb_collections SET name='User renamed',revision=revision+1",
                [],
            )
            .unwrap();
        } else {
            let c = Connection::open(root.path().join(DATABASE)).unwrap();
            let created = result["createdNotes"][0]["noteID"].as_str().unwrap();
            c.execute(
                "INSERT INTO kb_links VALUES(?1,'b',?2,'manual_link','later',1,0,1,1)",
                params![uuid(), created],
            )
            .unwrap();
        }
        let before = snapshot(root.path()).value;
        let rows = knowledge_rows(root.path());
        assert!(call(
            root.path(),
            "kb-rebuild-undo",
            json!({"operationID":result["operationID"]})
        )
        .is_err());
        assert_eq!(snapshot(root.path()).value, before);
        assert_eq!(knowledge_rows(root.path()), rows);
        assert_eq!(
            call(root.path(), "kb-rebuild-history", json!({})).unwrap()["operations"][0]["canUndo"],
            false
        );
    }
}
#[test]
fn failed_apply_and_undo_roll_back_every_table_and_allow_retry() {
    let root = setup();
    let draft = prepared(root.path());
    let preview = review(root.path(), &draft, proposal());
    let request = apply_request(&preview);
    let before = snapshot(root.path());
    let rows = knowledge_rows(root.path());
    *FAIL.get_or_init(|| Mutex::new(None)).lock().unwrap() = Some(root.path().to_path_buf());
    assert!(call(root.path(), "kb-rebuild-apply", request.clone()).is_err());
    assert_eq!(snapshot(root.path()).value, before.value);
    assert_eq!(snapshot(root.path()).revision, before.revision);
    assert_eq!(knowledge_rows(root.path()), rows);
    assert_eq!(
        call(root.path(), "kb-rebuild-history", json!({})).unwrap()["operations"],
        json!([])
    );
    let applied = call(root.path(), "kb-rebuild-apply", request.clone()).unwrap();
    let before = snapshot(root.path());
    let rows = knowledge_rows(root.path());
    *FAIL.get().unwrap().lock().unwrap() = Some(root.path().to_path_buf());
    assert!(call(
        root.path(),
        "kb-rebuild-undo",
        json!({"operationID":applied["operationID"]})
    )
    .is_err());
    assert_eq!(snapshot(root.path()).value, before.value);
    assert_eq!(knowledge_rows(root.path()), rows);
    let mut conflict = request.clone();
    conflict["expectedDraftRevision"] = json!(99);
    assert!(call(root.path(), "kb-rebuild-apply", conflict).is_err());
    assert_eq!(
        call(root.path(), "kb-rebuild-apply", request).unwrap(),
        applied
    );
    call(
        root.path(),
        "kb-rebuild-undo",
        json!({"operationID":applied["operationID"]}),
    )
    .unwrap();
}
fn folder(root: &Path, id: &str, enabled: bool) {
    crate::folders::save(root,serde_json::from_value(json!({"id":id,"name":id,"revision":0,"overrides":{"features":{"knowledgeBase":enabled}}})).unwrap()).unwrap();
}
fn move_to(root: &Path, id: &str, folder: Option<&str>) {
    let mut n = crate::notes::load_note_snapshot(root, id).unwrap();
    n.folder_id = folder.map(str::to_owned);
    crate::notes::save_note(root, n).unwrap();
}
#[test]
fn folder_profile_scope_is_rechecked_and_new_notes_inherit_one_common_folder() {
    let root = setup();
    folder(root.path(), "project", true);
    folder(root.path(), "other", true);
    move_to(root.path(), "a", Some("project"));
    move_to(root.path(), "b", Some("project"));
    crate::storage::atomic_json(
        &root.path().join("settings.json"),
        &json!({"features":{"knowledgeBase":false}}),
    )
    .unwrap();
    let draft = call(
        root.path(),
        "kb-rebuild-prepare",
        json!({"noteIDs":["a","b"],"folderID":"project","instruction":"merge"}),
    )
    .unwrap();
    let preview = review(root.path(), &draft, proposal());
    let result = call(root.path(), "kb-rebuild-apply", apply_request(&preview)).unwrap();
    for new in result["createdNotes"].as_array().unwrap() {
        assert_eq!(
            note(root.path(), new["noteID"].as_str().unwrap())["folderID"],
            "project"
        );
    }
    call(
        root.path(),
        "kb-rebuild-undo",
        json!({"operationID":result["operationID"]}),
    )
    .unwrap();
    let draft = call(
        root.path(),
        "kb-rebuild-prepare",
        json!({"noteIDs":["a","b"],"folderID":"project","instruction":"merge"}),
    )
    .unwrap();
    let preview = review(root.path(), &draft, proposal());
    move_to(root.path(), "b", Some("other"));
    assert!(call(root.path(), "kb-rebuild-apply", apply_request(&preview)).is_err());
    let global = prepared(root.path());
    assert!(
        call(
            root.path(),
            "kb-rebuild-preview",
            json!({"draftID":global["draftID"],"expectedDraftRevision":0,"proposal":proposal()})
        )
        .is_err(),
        "Cross-profile merge must not silently move content"
    );
    move_to(root.path(), "b", Some("project"));
    let draft = prepared(root.path());
    let preview = review(root.path(), &draft, proposal());
    let data = crate::folders::workspace_snapshot(root.path()).unwrap();
    let mut f = data
        .folders
        .iter()
        .find(|f| f.id == "project")
        .unwrap()
        .clone();
    f.overrides = json!({"features":{"knowledgeBase":false}});
    crate::folders::save(root.path(), f).unwrap();
    assert!(call(root.path(), "kb-rebuild-apply", apply_request(&preview)).is_err());
    assert!(context(root.path(), draft["draftID"].as_str().unwrap()).is_err());
}
#[test]
fn title_only_edit_keeps_derived_fields_and_groups_only_publish_one_event() {
    let root = setup();
    let mut snapshot = snapshot(root.path());
    let a = snapshot.value["notes"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|n| n["id"] == "a")
        .unwrap();
    a["contentRTF"] = json!("rich");
    a["expansion"] = json!({"safe":"derived"});
    super::super::compare_and_save(root.path(), snapshot.revision, &snapshot.value).unwrap();
    let draft = prepared(root.path());
    let preview = review(
        root.path(),
        &draft,
        json!({"title":"Rename","summary":"","edits":[{"noteID":"a","title":"Renamed","text":"One. Two."}],"newNotes":[],"collections":[],"links":[]}),
    );
    call(root.path(), "kb-rebuild-apply", apply_request(&preview)).unwrap();
    assert_eq!(note(root.path(), "a")["contentRTF"], "rich");
    assert_eq!(
        note(root.path(), "a")["expansion"],
        json!({"safe":"derived"})
    );
    let draft = prepared(root.path());
    let preview = review(
        root.path(),
        &draft,
        json!({"title":"Group","summary":"","edits":[],"newNotes":[],"collections":[{"key":"collection","name":"My group","members":[{"noteID":"a"},{"noteID":"b"}]}],"links":[]}),
    );
    let before = super::snapshot(root.path()); // shadowed local name; workspace helper below
    let before = before.unwrap();
    let result = call(root.path(), "kb-rebuild-apply", apply_request(&preview)).unwrap();
    let after = super::snapshot(root.path()).unwrap();
    assert_eq!(after.value, before.value);
    assert_eq!(after.revision, before.revision + 1);
    assert_eq!(result["workspaceRevision"], after.revision);
}
#[test]
fn selection_output_edge_budgets_expiry_and_history_limit_are_enforced() {
    let root = setup();
    edit(root.path(), "a", &"x".repeat(60_000));
    assert!(call(
        root.path(),
        "kb-rebuild-prepare",
        json!({"noteIDs":["a"],"instruction":"edit"})
    )
    .is_err());
    edit(root.path(), "a", "One. Two.");
    for i in 0..29 {
        create(root.path(), &format!("n{i}"), "text");
    }
    let ids = (0..29)
        .map(|i| json!(format!("n{i}")))
        .chain([json!("a"), json!("b")])
        .collect::<Vec<_>>();
    assert!(call(
        root.path(),
        "kb-rebuild-prepare",
        json!({"noteIDs":ids,"instruction":"edit"})
    )
    .is_err());
    let draft = prepared(root.path());
    let mut p = proposal();
    p["newNotes"]=json!((0..30).map(|i|json!({"key":format!("new{i}"),"title":"New","text":"Text","sourceNoteIDs":["a","b"]})).collect::<Vec<_>>());
    p["collections"] = json!([]);
    assert!(
        call(
            root.path(),
            "kb-rebuild-preview",
            json!({"draftID":draft["draftID"],"expectedDraftRevision":0,"proposal":p})
        )
        .is_err(),
        "60 provenance plus explicit edge exceeds budget"
    );
    assert!(call(root.path(), "kb-rebuild-history", json!({"limit":51})).is_err());
    let c = Connection::open(root.path().join(DATABASE)).unwrap();
    let mut value: Value = serde_json::from_str(
        &c.query_row(
            "SELECT context FROM kb_rebuild_drafts WHERE id=?1",
            [draft["draftID"].as_str().unwrap()],
            |r| r.get::<_, String>(0),
        )
        .unwrap(),
    )
    .unwrap();
    value["createdAt"] = json!(now() - 8.0 * 86400.0);
    c.execute(
        "UPDATE kb_rebuild_drafts SET context=?1 WHERE id=?2",
        params![
            serde_json::to_string(&value).unwrap(),
            draft["draftID"].as_str().unwrap()
        ],
    )
    .unwrap();
    drop(c);
    assert!(context(root.path(), draft["draftID"].as_str().unwrap()).is_err());
}
#[test]
fn hard_delete_redacts_targeted_draft_and_receipt_and_retains_idempotency_tombstone() {
    let root = setup();
    let draft = prepared(root.path());
    let preview = review(root.path(), &draft, proposal());
    let result = call(root.path(), "kb-rebuild-apply", apply_request(&preview)).unwrap();
    let mut s = snapshot(root.path());
    s.value["notes"]
        .as_array_mut()
        .unwrap()
        .retain(|n| n["id"] != "a");
    super::super::compare_and_save(root.path(), s.revision, &s.value).unwrap();
    assert!(call(
        root.path(),
        "kb-rebuild-undo",
        json!({"operationID":result["operationID"]})
    )
    .is_err());
    let c = Connection::open(root.path().join(DATABASE)).unwrap();
    let (before,after,title,summary):(String,String,String,String)=c.query_row("SELECT before_value,after_value,title,summary FROM kb_rebuild_operations WHERE operation_id=?1",[result["operationID"].as_str().unwrap()],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).unwrap();
    assert_eq!(
        (before, after, title, summary),
        ("null".into(), "null".into(), "".into(), "".into())
    );
    let (context, saved_proposal): (String, Option<String>) = c
        .query_row(
            "SELECT context,proposal FROM kb_rebuild_drafts WHERE id=?1",
            [draft["draftID"].as_str().unwrap()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert!(
        !context.contains("One.")
            && !context.contains("Three.")
            && !context.contains("Split, merge")
    );
    assert!(saved_proposal.is_none());
    let hash: String = c
        .query_row(
            "SELECT request_hash FROM kb_rebuild_operations WHERE operation_id=?1",
            [result["operationID"].as_str().unwrap()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(hash.len(), 64);
    drop(c);
    assert_eq!(
        call(root.path(), "kb-rebuild-history", json!({})).unwrap()["operations"],
        json!([])
    );
    create(root.path(), "a", "Recreated source");
    let new_draft = prepared(root.path());
    let new_preview = review(root.path(), &new_draft, proposal());
    let mut reuse = apply_request(&new_preview);
    reuse["operationID"] = result["operationID"].clone();
    assert!(
        call(root.path(), "kb-rebuild-apply", reuse).is_err(),
        "Redaction retains operation ID tombstone"
    );
}
#[test]
fn concurrent_preview_cas_and_apply_replay_make_exactly_one_change() {
    let root = setup();
    let draft = prepared(root.path());
    let request =
        json!({"draftID":draft["draftID"],"expectedDraftRevision":0,"proposal":proposal()});
    let outcomes = std::thread::scope(|scope| {
        let first = scope.spawn(|| call(root.path(), "kb-rebuild-preview", request.clone()));
        let second = scope.spawn(|| call(root.path(), "kb-rebuild-preview", request.clone()));
        [first.join().unwrap(), second.join().unwrap()]
    });
    assert_eq!(outcomes.iter().filter(|r| r.is_ok()).count(), 1);
    let preview = outcomes.into_iter().find_map(Result::ok).unwrap();
    let request = apply_request(&preview);
    let before = snapshot(root.path());
    let outcomes = std::thread::scope(|scope| {
        let first = scope.spawn(|| call(root.path(), "kb-rebuild-apply", request.clone()));
        let second = scope.spawn(|| call(root.path(), "kb-rebuild-apply", request.clone()));
        [
            first.join().unwrap().unwrap(),
            second.join().unwrap().unwrap(),
        ]
    });
    assert_eq!(outcomes[0], outcomes[1]);
    assert_eq!(snapshot(root.path()).revision, before.revision + 1);
    assert_eq!(
        snapshot(root.path()).value["notes"]
            .as_array()
            .unwrap()
            .len(),
        4
    );
}
