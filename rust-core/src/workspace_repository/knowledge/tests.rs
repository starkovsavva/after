use super::*;
use std::sync::{Mutex, OnceLock, mpsc};
use std::time::Duration as WaitDuration;

type SuggestionPause = (PathBuf, mpsc::Sender<()>, mpsc::Receiver<()>);
static SUGGESTION_PAUSE: OnceLock<Mutex<Option<SuggestionPause>>> = OnceLock::new();
pub(super) fn pause_before_suggestion_publication(root: &Path) {
    let slot=SUGGESTION_PAUSE.get_or_init(||Mutex::new(None));
    let pause={ let mut guard=slot.lock().unwrap();
        if guard.as_ref().is_some_and(|(path,_,_)|path==root) { guard.take() } else { None }
    };
    if let Some((_,reached,resume))=pause {
        reached.send(()).unwrap();
        resume.recv_timeout(WaitDuration::from_secs(10)).expect("resume suggestion test");
    }
}
static TOPIC_PAUSE: std::sync::OnceLock<Mutex<Option<(PathBuf,std::sync::mpsc::Sender<()>,std::sync::mpsc::Receiver<()>)>>> = std::sync::OnceLock::new();
pub(super) fn pause_before_topic_publication(root: &Path) {
    let slot=TOPIC_PAUSE.get_or_init(||Mutex::new(None));
    let pause={let mut guard=slot.lock().unwrap(); if guard.as_ref().is_some_and(|(path,_,_)|path==root) {guard.take()} else {None}};
    if let Some((_,reached,resume))=pause {reached.send(()).unwrap(); resume.recv_timeout(WaitDuration::from_secs(10)).unwrap();}
}

fn setup(root: &Path) {
    crate::storage::atomic_json(&root.join("settings.json"),
        &json!({"features":{"knowledgeBase":true}})).unwrap();
}
fn create(root: &Path, id: &str, text: &str) -> crate::notes::CapturedNote {
    let note=serde_json::from_value(json!({"id":id,"kind":"note","text":text,
        "createdAt":0.0,"updatedAt":0.0,"revision":0})).unwrap();
    crate::notes::save_note(root,note).unwrap()
}
fn call(root: &Path, command: &str, mut input: Value) -> Result<Value> {
    input["command"]=json!(command);
    dispatch(root,&input)
}
fn snapshot(root: &Path, note_id: &str) -> Value {
    call(root,"kb-snapshot",json!({"noteID":note_id})).unwrap()
}
// Test-only emulation of a link persisted by an earlier build, including its
// historical profile fingerprint. Public routes revalidate content and access.
fn historical_meeting_link(root:&Path,note:&crate::notes::CapturedNote,source:&crate::knowledge_meetings::MeetingSource)->Value {
    let s=snapshot(root,&note.id);
    let request=json!({"action":"add","operationID":uuid(),"noteID":note.id,"noteRevision":note.revision,
        "expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"],"source":source});
    let directory=crate::notes::directory(root).unwrap(); let _lock=crate::notes::lock(&directory).unwrap();
    let mut connection=open(&directory).unwrap(); let workspace=initialize(&mut connection,&directory).unwrap();
    change_meeting_link(root,&mut connection,&workspace,&request,Some(source)).unwrap()
}
fn link_request(s: &Value, from: &crate::notes::CapturedNote, to: &crate::notes::CapturedNote) -> Value {
    json!({"operationID":uuid(),"expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"],
        "expectedFromRevision":from.revision,"expectedToRevision":to.revision,
        "fromID":from.id,"toID":to.id,"action":"add"})
}
#[test]
fn migration_backup_links_backlinks_replay_and_old_editor_preserve_data() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let a=create(root.path(),"a","Первая заметка");
    let b=create(root.path(),"b","Вторая заметка");
    let old=crate::workspace_repository::snapshot(root.path()).unwrap();
    let s=snapshot(root.path(),"a");
    let connection=Connection::open(root.path().join(DATABASE)).unwrap();
    assert_eq!(connection.pragma_query_value(None,"user_version",|row|row.get::<_,i64>(0)).unwrap(), 1);
    assert!(has_extension(&connection).unwrap());
    drop(connection);
    assert_eq!(s["workspaceRevision"],old.revision);
    assert_eq!(s["workspaceFingerprint"],old.fingerprint);
    assert_eq!(s["kbRevision"],0);
    let journal: Value=serde_json::from_slice(&fs::read(root.path().join(MIGRATION_DIR).join(JOURNAL)).unwrap()).unwrap();
    assert_eq!(journal["state"],"committed");
    check_backup(&backup_path(&migration_dir(root.path()).unwrap(),&journal,"coreBackup").unwrap(),old.revision,&old.fingerprint).unwrap();
    let request=link_request(&s,&a,&b);
    let result=call(root.path(),"kb-link-change",request.clone()).unwrap();
    assert_eq!(result["workspaceRevision"],old.revision+1);
    assert_eq!(result["kbRevision"],1);
    assert_eq!(call(root.path(),"kb-link-change",request.clone()).unwrap(),result);
    let mut changed=request.clone(); changed["action"]=json!("remove");
    assert!(call(root.path(),"kb-link-change",changed).is_err());
    assert_eq!(snapshot(root.path(),"a")["links"].as_array().unwrap().len(),1);
    assert_eq!(snapshot(root.path(),"b")["links"].as_array().unwrap().len(),1);
    let mut edit=a.clone(); edit.text="Отредактировано старым редактором".into();
    let edited=crate::notes::save_note(root.path(),edit).unwrap();
    assert_eq!(snapshot(root.path(),"a")["links"].as_array().unwrap().len(),1);
    let stale=link_request(&s,&edited,&b);
    assert!(call(root.path(),"kb-link-change",stale).is_err());
    let deleted=crate::notes::trash_note(root.path(),"b",b.revision,false).unwrap();
    assert!(snapshot(root.path(),"a")["links"].as_array().unwrap().is_empty());
    crate::notes::trash_note(root.path(),"b",deleted.revision,true).unwrap();
    assert_eq!(snapshot(root.path(),"a")["links"].as_array().unwrap().len(),1);
}
#[test]
fn feature_off_and_active_jobs_never_migrate_or_remove_data() {
    let root=tempfile::tempdir().unwrap();
    let a=create(root.path(),"a","Содержимое");
    assert!(call(root.path(),"kb-snapshot",json!({"noteID":"a"})).is_err());
    assert!(call(root.path(),"kb-meeting-backlinks",json!({"meetingID":"fixture"})).is_err());
    let core=Connection::open(root.path().join(DATABASE)).unwrap();
    assert_eq!(core.pragma_query_value(None,"user_version",|r|r.get::<_,i64>(0)).unwrap(),1);
    drop(core);
    setup(root.path());
    let jobs=Connection::open(root.path().join("jobs.sqlite")).unwrap();
    jobs.execute_batch("CREATE TABLE jobs(id TEXT PRIMARY KEY,state TEXT NOT NULL); INSERT INTO jobs VALUES('running','running'); PRAGMA user_version=2;").unwrap();
    drop(jobs);
    assert!(call(root.path(),"kb-snapshot",json!({"noteID":"a"})).is_err());
    let core=Connection::open(root.path().join(DATABASE)).unwrap();
    assert_eq!(core.pragma_query_value(None,"user_version",|r|r.get::<_,i64>(0)).unwrap(),1);
    drop(core);
    let jobs=Connection::open(root.path().join("jobs.sqlite")).unwrap();
    jobs.execute("UPDATE jobs SET state='done'",[]).unwrap(); drop(jobs);
    snapshot(root.path(),"a");
    let journal:Value=serde_json::from_slice(&fs::read(root.path().join(MIGRATION_DIR).join(JOURNAL)).unwrap()).unwrap();
    assert!(backup_path(&root.path().join(MIGRATION_DIR),&journal,"jobsBackup").unwrap().is_file());
    crate::storage::atomic_json(&root.path().join("settings.json"),&json!({"features":{"knowledgeBase":false}})).unwrap();
    assert!(call(root.path(),"kb-snapshot",json!({"noteID":"a"})).is_err());
    assert_eq!(crate::notes::load_note_snapshot(root.path(),"a").unwrap().text,a.text);
}
#[test]
fn interrupted_commit_is_recovered_and_future_schema_is_rejected() {
    let root=tempfile::tempdir().unwrap(); setup(root.path()); create(root.path(),"a","Данные");
    snapshot(root.path(),"a");
    let path=root.path().join(MIGRATION_DIR).join(JOURNAL);
    let mut journal:Value=serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    journal["state"]=json!("prepared");
    write_journal(&path,&journal).unwrap();
    // Model a crash after the schema commit but before finalization.
    let connection=Connection::open(root.path().join(DATABASE)).unwrap();
    connection.execute("DELETE FROM workspace_metadata WHERE key=?1",[FINALIZED_KEY]).unwrap();
    drop(connection);
    assert!(crate::workspace_repository::read_committed(root.path()).is_err());
    crate::workspace_repository::snapshot(root.path()).unwrap();
    let recovered:Value=serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(recovered["state"],"committed");
    let connection=Connection::open(root.path().join(DATABASE)).unwrap();
    // Development-only v2 builds from the previous implementation are not
    // silently interpreted as the compatible v1 extension.
    connection.pragma_update(None,"user_version",2).unwrap(); drop(connection);
    assert!(crate::workspace_repository::snapshot(root.path()).is_err());
    assert!(crate::workspace_repository::read_committed(root.path()).is_err());
}
#[test]
fn finalized_library_survives_backup_cleanup_but_interrupted_migration_requires_backup() {
    let root=tempfile::tempdir().unwrap(); setup(root.path()); create(root.path(),"a","Данные");
    snapshot(root.path(),"a");
    let directory=root.path().join(MIGRATION_DIR);
    let path=directory.join(JOURNAL);
    let mut journal:Value=serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    let backup=backup_path(&directory,&journal,"coreBackup").unwrap();
    // Simulate an interrupted schema commit: the backup is mandatory until
    // the recovery journal has been committed and the marker recorded.
    journal["state"]=json!("prepared");
    write_journal(&path,&journal).unwrap();
    let connection=Connection::open(root.path().join(DATABASE)).unwrap();
    connection.execute("DELETE FROM workspace_metadata WHERE key=?1",[FINALIZED_KEY]).unwrap();
    drop(connection);
    let saved=fs::read(&backup).unwrap();
    fs::remove_file(&backup).unwrap();
    assert!(crate::workspace_repository::snapshot(root.path()).is_err());
    assert!(crate::workspace_repository::read_committed(root.path()).is_err());
    fs::write(&backup,saved).unwrap();
    crate::workspace_repository::snapshot(root.path()).unwrap();
    // After recovery is durably finalized neither the backup nor journal is
    // required to keep reading, editing, and using the existing data.
    fs::remove_dir_all(&directory).unwrap();
    let mut note=crate::notes::load_note_snapshot(root.path(),"a").unwrap();
    assert_eq!(note.text,"Данные");
    note.text="Изменённые данные".into();
    crate::notes::save_note(root.path(),note).unwrap();
    assert_eq!(crate::notes::load_note_snapshot(root.path(),"a").unwrap().text,"Изменённые данные");
    assert!(crate::workspace_repository::read_committed(root.path()).is_ok());
    assert!(call(root.path(),"kb-snapshot",json!({"noteID":"a"})).is_ok());
}
#[test]
fn interrupted_migration_does_not_accept_later_knowledge_decisions() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let a=create(root.path(),"a","Первая");
    let b=create(root.path(),"b","Вторая");
    let before=snapshot(root.path(),"a");
    call(root.path(),"kb-link-change",link_request(&before,&a,&b)).unwrap();
    let path=root.path().join(MIGRATION_DIR).join(JOURNAL);
    let mut journal:Value=serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    journal["state"]=json!("prepared");
    write_journal(&path,&journal).unwrap();
    let connection=Connection::open(root.path().join(DATABASE)).unwrap();
    connection.execute("DELETE FROM workspace_metadata WHERE key=?1",[FINALIZED_KEY]).unwrap();
    drop(connection);
    assert!(crate::workspace_repository::snapshot(root.path()).is_err());
    assert!(crate::workspace_repository::read_committed(root.path()).is_err());
    let connection=Connection::open(root.path().join(DATABASE)).unwrap();
    assert_eq!(connection.query_row("SELECT COUNT(*) FROM kb_links", [], |r|r.get::<_,i64>(0)).unwrap(),1);
}
#[test]
fn undo_is_atomic_replay_safe_and_does_not_overwrite_later_changes() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let a=create(root.path(),"a","А"); let b=create(root.path(),"b","Б");
    let first=snapshot(root.path(),"a");
    let request=link_request(&first,&a,&b);
    let result=call(root.path(),"kb-link-change",request.clone()).unwrap();
    let undo=json!({"operationID":uuid(),"targetOperationID":request["operationID"],
        "expectedWorkspaceRevision":result["workspaceRevision"],"expectedKBRevision":result["kbRevision"]});
    let undone=call(root.path(),"kb-undo",undo.clone()).unwrap();
    assert_eq!(undone["link"]["deleted"],true);
    assert_eq!(call(root.path(),"kb-undo",undo).unwrap(),undone);
    assert_eq!(call(root.path(),"kb-link-change",request).unwrap()["undone"],true);
    assert!(snapshot(root.path(),"a")["links"].as_array().unwrap().is_empty());
    let restored=snapshot(root.path(),"a");
    let added=call(root.path(),"kb-link-change",link_request(&restored,&a,&b)).unwrap();
    let later=snapshot(root.path(),"a");
    let remove=json!({"operationID":uuid(),"expectedWorkspaceRevision":later["workspaceRevision"],"expectedKBRevision":later["kbRevision"],
        "expectedFromRevision":a.revision,"expectedToRevision":b.revision,"fromID":"a","toID":"b","action":"remove"});
    call(root.path(),"kb-link-change",remove).unwrap();
    let current=snapshot(root.path(),"a");
    let old_undo=json!({"operationID":uuid(),"targetOperationID":added["operationID"],
        "expectedWorkspaceRevision":current["workspaceRevision"],"expectedKBRevision":current["kbRevision"]});
    assert!(call(root.path(),"kb-undo",old_undo).is_err());
    assert!(snapshot(root.path(),"a")["links"].as_array().unwrap().is_empty());
}
#[test]
fn blocked_pair_is_order_independent_and_undo_restores_absence() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let a=create(root.path(),"a","А"); let b=create(root.path(),"b","Б");
    let s=snapshot(root.path(),"a");
    let request=json!({"operationID":uuid(),"expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"],
        "expectedFromRevision":b.revision,"expectedToRevision":a.revision,"fromID":"b","toID":"a","blocked":true});
    let result=call(root.path(),"kb-feedback-change",request.clone()).unwrap();
    assert_eq!(result["feedback"]["firstID"],"a"); assert_eq!(result["feedback"]["secondID"],"b");
    assert_eq!(call(root.path(),"kb-feedback-change",request.clone()).unwrap(),result);
    let undo=json!({"operationID":uuid(),"targetOperationID":request["operationID"],
        "expectedWorkspaceRevision":result["workspaceRevision"],"expectedKBRevision":result["kbRevision"]});
    let undone=call(root.path(),"kb-undo",undo).unwrap();
    assert!(undone["link"].is_null());
    let connection=Connection::open(root.path().join(DATABASE)).unwrap();
    assert!(feedback_row(&connection,"a","b").unwrap().is_none());
}
#[test]
fn local_suggestions_explain_overlap_and_respect_block_link_trash_and_staleness() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let a=create(root.path(),"a","Пилотный бюджет: согласовать оплату договора с закупками.");
    let b=create(root.path(),"b","Условия оплаты договора, бюджет пилотного проекта и закупки.");
    create(root.path(),"c","Рецепт банановых оладий: молоко, корица и мука.");
    let s=snapshot(root.path(),"a");
    let query=json!({"noteID":"a","expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"]});
    let result=call(root.path(),"kb-suggestions",query.clone()).unwrap();
    let items=result["items"].as_array().unwrap();
    assert_eq!(items.len(),1,"{result}");
    assert_eq!(items[0]["noteID"],"b");
    assert!(items[0]["sharedTerms"].as_array().unwrap().len()>=2);
    assert!(result["partial"]==false);
    let block=json!({"operationID":uuid(),"expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"],
        "expectedFromRevision":a.revision,"expectedToRevision":b.revision,"fromID":"a","toID":"b","blocked":true});
    let blocked=call(root.path(),"kb-feedback-change",block.clone()).unwrap();
    assert!(call(root.path(),"kb-suggestions",query).is_err());
    let current=snapshot(root.path(),"a");
    let query=json!({"noteID":"a","expectedWorkspaceRevision":current["workspaceRevision"],"expectedKBRevision":current["kbRevision"]});
    assert!(call(root.path(),"kb-suggestions",query).unwrap()["items"].as_array().unwrap().is_empty());
    let undo=json!({"operationID":uuid(),"targetOperationID":block["operationID"],
        "expectedWorkspaceRevision":blocked["workspaceRevision"],"expectedKBRevision":blocked["kbRevision"]});
    call(root.path(),"kb-undo",undo).unwrap();
    let current=snapshot(root.path(),"a");
    let query=json!({"noteID":"a","expectedWorkspaceRevision":current["workspaceRevision"],"expectedKBRevision":current["kbRevision"]});
    assert_eq!(call(root.path(),"kb-suggestions",query).unwrap()["items"][0]["noteID"],"b");
    call(root.path(),"kb-link-change",link_request(&current,&a,&b)).unwrap();
    let current=snapshot(root.path(),"a");
    let query=json!({"noteID":"a","expectedWorkspaceRevision":current["workspaceRevision"],"expectedKBRevision":current["kbRevision"]});
    assert!(call(root.path(),"kb-suggestions",query).unwrap()["items"].as_array().unwrap().is_empty());
}
#[test]
fn local_topics_are_scoped_stable_and_never_include_a_blocked_pair() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let a=create(root.path(),"a","Пилотный бюджет и условия договора закупок");
    let b=create(root.path(),"b","Пилотный бюджет и условия договора платежей");
    create(root.path(),"c","Пилотный бюджет и условия договора подготовки");
    create(root.path(),"d","Пилотный бюджет и условия договора согласования");
    let initial=snapshot(root.path(),"a");
    let query=json!({"expectedWorkspaceRevision":initial["workspaceRevision"],"expectedKBRevision":initial["kbRevision"]});
    let first=call(root.path(),"kb-topics",query).unwrap();
    assert_eq!(first["noteLimitReached"],false);
    assert_eq!(first["topicLimitReached"],false);
    let first_topic=&first["topics"][0];
    assert!(first_topic["sources"].as_array().unwrap().len()>=4,"{first}");
    assert!(!first_topic["terms"].as_array().unwrap().is_empty());
    let id=first_topic["id"].as_str().unwrap().to_owned();
    create(root.path(),"e","Пилотный бюджет и условия договора поставки");
    let current=snapshot(root.path(),"a");
    let query=json!({"expectedWorkspaceRevision":current["workspaceRevision"],"expectedKBRevision":current["kbRevision"]});
    let next=call(root.path(),"kb-topics",query).unwrap();
    assert!(next["topics"].as_array().unwrap().iter().any(|topic|topic["id"]==id));
    crate::folders::save(root.path(),crate::folders::Folder {id:"private".into(),name:"Private".into(),
        revision:0,overrides:json!({"features":{"knowledgeBase":false}})}).unwrap();
    let private=serde_json::from_value(json!({"id":"secret-note","kind":"note","text":"Пилотный бюджет и условия договора",
        "folderID":"private","createdAt":0.0,"updatedAt":0.0,"revision":0})).unwrap();
    crate::notes::save_note(root.path(),private).unwrap();
    let current=snapshot(root.path(),"a");
    let query=json!({"expectedWorkspaceRevision":current["workspaceRevision"],"expectedKBRevision":current["kbRevision"]});
    let scoped=call(root.path(),"kb-topics",query).unwrap();
    assert!(!scoped.to_string().contains("secret-note"));
    assert!(scoped["topics"].as_array().unwrap().iter().any(|topic|topic["id"]==id));
    let disallowed=json!({"folderID":"private","expectedWorkspaceRevision":current["workspaceRevision"],"expectedKBRevision":current["kbRevision"]});
    assert!(call(root.path(),"kb-topics",disallowed).is_err());
    let block=json!({"operationID":uuid(),"expectedWorkspaceRevision":current["workspaceRevision"],"expectedKBRevision":current["kbRevision"],
        "expectedFromRevision":a.revision,"expectedToRevision":b.revision,"fromID":"a","toID":"b","blocked":true});
    call(root.path(),"kb-feedback-change",block).unwrap();
    let current=snapshot(root.path(),"a");
    let query=json!({"expectedWorkspaceRevision":current["workspaceRevision"],"expectedKBRevision":current["kbRevision"]});
    for topic in call(root.path(),"kb-topics",query).unwrap()["topics"].as_array().unwrap() {
        let ids=topic["sources"].as_array().unwrap().iter().filter_map(|source|source["noteID"].as_str()).collect::<BTreeSet<_>>();
        assert!(!(ids.contains("a") && ids.contains("b")));
    }
}
#[test]
fn note_search_finds_ungrouped_and_old_notes_before_pagination_without_private_leaks() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    crate::folders::save(root.path(),crate::folders::Folder {id:"private".into(),name:"Private".into(),
        revision:0,overrides:json!({"features":{"knowledgeBase":false}})}).unwrap();
    create(root.path(),"a","Уникальная заметка про маяк");
    let workspace=crate::workspace_repository::snapshot(root.path()).unwrap();
    let mut value=workspace.value.clone();
    let notes=value["notes"].as_array_mut().unwrap();
    notes.iter_mut().find(|n|n["id"]=="a").unwrap()["updatedAt"]=json!(1.0);
    for n in 0..70 {
        notes.push(json!({"id":format!("private-{n}"),"kind":"note","text":"маяк",
            "folderID":"private","createdAt":0.0,"updatedAt":5000.0,"revision":1}));
    }
    for n in 0..55 {
        notes.push(json!({"id":format!("visible-{n}"),"kind":"note","text":"маяк",
            "createdAt":0.0,"updatedAt":1000.0 + n as f64,"revision":1}));
    }
    crate::workspace_repository::compare_and_save(root.path(),workspace.revision,&value).unwrap();
    let current=snapshot(root.path(),"a");
    let query=json!({"query":"маяк","expectedWorkspaceRevision":current["workspaceRevision"]});
    let first=call(root.path(),"kb-note-search",query.clone()).unwrap();
    assert_eq!(first["total"],56); assert_eq!(first["items"].as_array().unwrap().len(),50);
    assert_eq!(first["nextOffset"],50); assert!(!first.to_string().contains("private"));
    let mut next=query.clone(); next["offset"]=json!(50);
    let second=call(root.path(),"kb-note-search",next).unwrap();
    assert_eq!(second["items"].as_array().unwrap().len(),6);
    assert!(second["items"].as_array().unwrap().iter().any(|n|n["noteID"]=="a"));
    assert!(call(root.path(),"kb-note-search",json!({"query":"маяк","folderID":"private",
        "expectedWorkspaceRevision":current["workspaceRevision"]})).is_err());
    create(root.path(),"later","маяк");
    assert!(call(root.path(),"kb-note-search",query).is_err());
}

#[test]
fn global_topics_connect_notes_across_the_old_page_boundary() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    create(root.path(),"seed","Арктический корабль полярная станция");
    let workspace=crate::workspace_repository::snapshot(root.path()).unwrap();
    let mut value=workspace.value.clone();
    let notes=value["notes"].as_array_mut().unwrap();
    notes.iter_mut().find(|n|n["id"]=="seed").unwrap()["updatedAt"]=json!(1.0);
    for n in 0..204 {
        let text=if n<3 {"Арктический корабль полярная станция".to_owned()} else {format!("уникальность{n}")};
        notes.push(json!({"id":format!("note-{n:03}"),"kind":"note","text":text,
            "createdAt":0.0,"updatedAt":1000.0+n as f64,"revision":1}));
    }
    crate::workspace_repository::compare_and_save(root.path(),workspace.revision,&value).unwrap();
    let s=snapshot(root.path(),"seed");
    let mut request=json!({"expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"]});
    let first=call(root.path(),"kb-topics",request.clone()).unwrap();
    assert_eq!(first["total"],205); assert_eq!(first["examined"],205);
    assert_eq!(first["approximate"],true);
    assert!(first["topics"].as_array().unwrap().iter().any(|topic| {
        let ids=topic["sources"].as_array().unwrap().iter().filter_map(|item|item["noteID"].as_str()).collect::<BTreeSet<_>>();
        ids.contains("seed") && ids.contains("note-000") && ids.contains("note-001") && ids.contains("note-002")
    }));
    request["offset"]=json!(1);
    assert!(call(root.path(),"kb-topics",request).is_err());
}
#[test]
fn global_topic_pagination_keeps_stable_ids_and_sources() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    create(root.path(),"seed","topic000 realm000");
    let workspace=crate::workspace_repository::snapshot(root.path()).unwrap();
    let mut value=workspace.value.clone();
    let notes=value["notes"].as_array_mut().unwrap();
    for group in 0..60 { for member in 0..4 {
        notes.push(json!({"id":format!("g{group:03}-{member}"),"kind":"note",
            "text":format!("topic{group:03} realm{group:03}"),
            "createdAt":0.0,"updatedAt":1000.0+group as f64,"revision":1}));
    }}
    crate::workspace_repository::compare_and_save(root.path(),workspace.revision,&value).unwrap();
    let s=snapshot(root.path(),"seed");
    let mut request=json!({"expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"]});
    let first=call(root.path(),"kb-topics",request.clone()).unwrap();
    assert_eq!(first["topics"].as_array().unwrap().len(),50);
    assert_eq!(first["nextOffset"],50);
    request["offset"]=json!(50);
    let second=call(root.path(),"kb-topics",request.clone()).unwrap();
    assert!(!second["topics"].as_array().unwrap().is_empty());
    let ids=first["topics"].as_array().unwrap().iter().map(|row|row["id"].as_str().unwrap()).collect::<BTreeSet<_>>();
    assert!(second["topics"].as_array().unwrap().iter().all(|row|!ids.contains(row["id"].as_str().unwrap())));
    let again=call(root.path(),"kb-topics",request).unwrap();
    assert_eq!(second["topics"],again["topics"]);
}
#[test]
fn cancelling_topic_build_is_scoped_to_the_library() {
    let first=tempfile::tempdir().unwrap();
    let second=tempfile::tempdir().unwrap();
    let (first_key,first_generation)=advance_topic_generation(first.path()).unwrap();
    let (second_key,second_generation)=advance_topic_generation(second.path()).unwrap();
    call(first.path(),"kb-topics-cancel",json!({})).unwrap();
    assert!(check_topic_generation(&first_key,first_generation).is_err());
    assert!(check_topic_generation(&second_key,second_generation).is_ok());
    assert!(topic_candidate_pairs(&[],&[],None,&BTreeSet::new(),(&first_key,first_generation)).is_err());
    let old=uuid(); let new=uuid();
    let (_,old_generation)=begin_topic_generation(first.path(),Some(&old)).unwrap();
    cancel_topic_generation(first.path(),Some(&old)).unwrap();
    assert!(check_topic_generation(&first_key,old_generation).is_err());
    let (_,new_generation)=begin_topic_generation(first.path(),Some(&new)).unwrap();
    cancel_topic_generation(first.path(),Some(&old)).unwrap();
    assert!(check_topic_generation(&first_key,new_generation).is_ok(),"late cancel must not stop a newer request");
    let not_started=uuid(); cancel_topic_generation(first.path(),Some(&not_started)).unwrap();
    assert!(begin_topic_generation(first.path(),Some(&not_started)).is_err(),"cancel before start must be honored");
}
#[test]
fn cancelling_an_inflight_topic_build_prevents_publication() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    for id in ["a","b","c","d"] {create(root.path(),id,"Пилот бюджет договор");}
    let snapshot=snapshot(root.path(),"a");
    let (reached_tx,reached_rx)=std::sync::mpsc::channel();
    let (resume_tx,resume_rx)=std::sync::mpsc::channel();
    *TOPIC_PAUSE.get_or_init(||Mutex::new(None)).lock().unwrap()=Some((root.path().to_path_buf(),reached_tx,resume_rx));
    let owned=root.path().to_path_buf();
    let task=std::thread::spawn(move ||call(&owned,"kb-topics",json!({
        "expectedWorkspaceRevision":snapshot["workspaceRevision"],"expectedKBRevision":snapshot["kbRevision"]})));
    reached_rx.recv_timeout(WaitDuration::from_secs(10)).unwrap();
    call(root.path(),"kb-topics-cancel",json!({})).unwrap();
    resume_tx.send(()).unwrap();
    assert!(task.join().unwrap().is_err());
    assert!(!root.path().join("cache/knowledge/topics-all-global.json").exists());
    assert_eq!(crate::notes::load_note_snapshot(root.path(),"a").unwrap().text,"Пилот бюджет договор");
}
#[test]
fn saved_meeting_links_are_versioned_private_and_survive_only_while_valid() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let current_note=create(root.path(),"meeting-note","Проверить бюджет договора");
    let directory=root.path().join("meetings/meeting-one");
    crate::storage::atomic_json(&directory.join("meta.json"),&json!({"id":"meeting-one","title":"Закрытый заголовок",
        "source":"audio.mp3","createdAt":1,"status":"ready"})).unwrap();
    crate::storage::atomic_json(&directory.join("transcript.json"),&json!({"segments":[
        {"id":1,"start":1,"end":2,"text":"Секретная фраза бюджета договора"}]})).unwrap();
    let source=crate::knowledge_meetings::snapshot(root.path(),"meeting-one",None).unwrap().0.remove(0);
    let s=snapshot(root.path(),"meeting-note");
    let request=json!({"action":"add","operationID":uuid(),"noteID":"meeting-note","noteRevision":current_note.revision,
        "expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"],"source":source});
    let added=call(root.path(),"kb-meeting-link-change",request.clone()).unwrap();
    assert_eq!(call(root.path(),"kb-meeting-link-change",request.clone()).unwrap(),added);
    let id=added["link"]["id"].as_str().unwrap().to_owned();
    let read=json!({"noteID":"meeting-note","noteRevision":current_note.revision});
    let first=call(root.path(),"kb-meeting-links",read.clone()).unwrap();
    assert_eq!(first["items"][0]["available"],true);
    assert_eq!(first["items"][0]["source"]["text"],"Секретная фраза бюджета договора");
    let database=Connection::open(root.path().join(DATABASE)).unwrap();
    let saved:String=database.query_row("SELECT source_ref FROM kb_meeting_links WHERE id=?1",[&id],|row|row.get(0)).unwrap();
    assert!(!saved.contains("Секретная") && !saved.contains("Закрытый заголовок"));
    drop(database);
    crate::storage::atomic_json(&directory.join("transcript.json"),&json!({"segments":[
        {"id":1,"start":1,"end":2,"text":"Иное содержание"}]})).unwrap();
    let stale=call(root.path(),"kb-meeting-links",read.clone()).unwrap();
    assert_eq!(stale["items"][0]["available"],false);
    assert!(!stale.to_string().contains("meeting-one") && !stale.to_string().contains("Секретная"));
    assert!(call(root.path(),"kb-meeting-link-change",json!({"action":"add","operationID":uuid(),"noteID":"meeting-note",
        "noteRevision":current_note.revision,"expectedWorkspaceRevision":stale["workspaceRevision"],"expectedKBRevision":stale["kbRevision"],"source":source})).is_err());
    let removed=call(root.path(),"kb-meeting-link-change",json!({"action":"remove","operationID":uuid(),"noteID":"meeting-note",
        "noteRevision":current_note.revision,"expectedWorkspaceRevision":stale["workspaceRevision"],"expectedKBRevision":stale["kbRevision"],"linkID":id})).unwrap();
    assert_eq!(removed["link"]["deleted"],true);
    assert!(call(root.path(),"kb-meeting-links",read).unwrap()["items"].as_array().unwrap().is_empty());
    crate::notes::delete_note(root.path(),"meeting-note",current_note.revision).unwrap();
    create(root.path(),"meeting-note","Новая заметка");
    let replay=call(root.path(),"kb-meeting-link-change",request);
    assert!(replay.is_err(),"stale source must not resurrect a deleted link");
    assert!(snapshot(root.path(),"meeting-note")["links"].as_array().unwrap().is_empty());
}
#[test]
fn saved_meeting_links_redact_source_after_folder_revocation() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let current_note=create(root.path(),"n","Бюджет договора");
    let directory=root.path().join("meetings/meeting-private");
    crate::storage::atomic_json(&directory.join("meta.json"),&json!({"id":"meeting-private","title":"Частная встреча",
        "source":"audio.mp3","createdAt":1,"status":"ready"})).unwrap();
    crate::storage::atomic_json(&directory.join("transcript.json"),&json!({"segments":[
        {"id":3,"start":1,"end":2,"text":"Частное содержание бюджета"}]})).unwrap();
    let source=crate::knowledge_meetings::snapshot(root.path(),"meeting-private",None).unwrap().0.remove(0);
    historical_meeting_link(root.path(),&current_note,&source);
    crate::folders::save(root.path(),crate::folders::Folder {id:"private".into(),name:"Приватно".into(),
        revision:0,overrides:json!({"features":{"knowledgeBase":false}})}).unwrap();
    crate::notes::save_context(root.path(),serde_json::from_value(json!({"meetingID":"meeting-private","folderID":"private"})).unwrap()).unwrap();
    let result=call(root.path(),"kb-meeting-links",json!({"noteID":"n","noteRevision":current_note.revision})).unwrap();
    assert_eq!(result["items"][0]["available"],false);
    assert!(!result.to_string().contains("meeting-private") && !result.to_string().contains("Частная") && !result.to_string().contains("Частное"));
}
#[test]
#[ignore = "synthetic performance probe; run separately without capture or inference"]
fn global_topics_scale_probe() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    create(root.path(),"seed","topic0000 realm0000");
    let workspace=crate::workspace_repository::snapshot(root.path()).unwrap();
    let mut value=workspace.value.clone();
    let notes=value["notes"].as_array_mut().unwrap();
    for group in 0..400 {for member in 0..5 {
        notes.push(json!({"id":format!("probe-{group:04}-{member}"),"kind":"note",
            "text":format!("topic{group:04} realm{group:04}"),"createdAt":0.0,
            "updatedAt":1000.0+group as f64,"revision":1}));
    }}
    crate::workspace_repository::compare_and_save(root.path(),workspace.revision,&value).unwrap();
    let snapshot=snapshot(root.path(),"seed");
    let start=std::time::Instant::now();
    let result=call(root.path(),"kb-topics",json!({"expectedWorkspaceRevision":snapshot["workspaceRevision"],
        "expectedKBRevision":snapshot["kbRevision"]})).unwrap();
    let elapsed=start.elapsed();
    assert_eq!(result["examined"],2001);
    assert!(result["topicTotal"].as_u64().unwrap()>=300);
    println!("SYNTHETIC_TOPIC_PROBE notes=2001 groups={} elapsed_ms={} approximate={}",
        result["topicTotal"],elapsed.as_millis(),result["approximate"]);
}
#[test]
fn saved_collection_survives_cache_cleanup_and_guards_concurrent_edits() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    for id in ["a","b","c","d"] {create(root.path(),id,"Бюджет договора пилотного проекта");}
    let s=snapshot(root.path(),"a");
    let query=json!({"expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"]});
    let topics=call(root.path(),"kb-topics",query).unwrap();
    let sources=topics["topics"][0]["sources"].clone();
    let create_request=json!({"action":"create","operationID":uuid(),"name":"Мой проект","sources":sources,
        "expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"]});
    let created=call(root.path(),"kb-collection-change",create_request.clone()).unwrap();
    assert_eq!(call(root.path(),"kb-collection-change",create_request).unwrap(),created);
    let id=created["collectionID"].as_str().unwrap().to_owned();
    let mut rename=json!({"action":"rename","operationID":uuid(),"collectionID":id,"name":"Новый проект",
        "expectedRevision":created["revision"],"expectedWorkspaceRevision":created["workspaceRevision"],"expectedKBRevision":created["kbRevision"]});
    let renamed=call(root.path(),"kb-collection-change",rename.clone()).unwrap();
    rename["operationID"]=json!(uuid());
    assert!(call(root.path(),"kb-collection-change",rename).is_err());
    fs::remove_dir_all(root.path().join("cache").join("knowledge")).unwrap();
    let query=json!({"expectedWorkspaceRevision":renamed["workspaceRevision"],"expectedKBRevision":renamed["kbRevision"]});
    let list=call(root.path(),"kb-topics",query).unwrap();
    assert_eq!(list["collections"][0]["name"],"Новый проект");
    assert_eq!(list["collections"][0]["sources"].as_array().unwrap().len(),4);
    let hide=json!({"action":"hide","operationID":uuid(),"collectionID":id,
        "expectedRevision":renamed["revision"],"expectedWorkspaceRevision":renamed["workspaceRevision"],"expectedKBRevision":renamed["kbRevision"]});
    let hidden=call(root.path(),"kb-collection-change",hide).unwrap();
    let list=call(root.path(),"kb-topics",json!({"expectedWorkspaceRevision":hidden["workspaceRevision"],"expectedKBRevision":hidden["kbRevision"]})).unwrap();
    assert_eq!(list["collections"][0]["hidden"],true);
    let a=crate::notes::load_note_snapshot(root.path(),"a").unwrap();
    crate::notes::trash_note(root.path(),"a",a.revision,false).unwrap();
    let latest=snapshot(root.path(),"b");
    let list=call(root.path(),"kb-topics",json!({"expectedWorkspaceRevision":latest["workspaceRevision"],"expectedKBRevision":latest["kbRevision"]})).unwrap();
    assert_eq!(list["collections"][0]["sources"].as_array().unwrap().len(),3);
    assert_eq!(list["collections"][0]["nameRedacted"],true);
    assert_eq!(list["collections"][0]["name"],"");
    assert!(!list["collections"].to_string().contains("\"noteID\":\"a\""));
}
#[test]
fn hard_delete_atomically_purges_links_collections_and_old_replay() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let a=create(root.path(),"erase-me","Удаляемый материал");
    let b=create(root.path(),"b","Другой материал");
    let s=snapshot(root.path(),"erase-me");
    let link=link_request(&s,&a,&b);
    let saved=call(root.path(),"kb-link-change",link.clone()).unwrap();
    let collection=json!({"action":"create","operationID":uuid(),"name":"Подборка","sources":[
        {"noteID":"erase-me","revision":a.revision},{"noteID":"b","revision":b.revision}],
        "expectedWorkspaceRevision":saved["workspaceRevision"],"expectedKBRevision":saved["kbRevision"]});
    call(root.path(),"kb-collection-change",collection).unwrap();
    crate::notes::delete_note(root.path(),"erase-me",a.revision).unwrap();
    create(root.path(),"erase-me","Совершенно новая заметка");
    let latest=snapshot(root.path(),"erase-me");
    assert!(latest["links"].as_array().unwrap().is_empty());
    let all=call(root.path(),"kb-topics",json!({"expectedWorkspaceRevision":latest["workspaceRevision"],"expectedKBRevision":latest["kbRevision"]})).unwrap();
    assert_eq!(all["collections"][0]["sources"].as_array().unwrap().len(),1);
    assert_eq!(all["collections"][0]["sources"][0]["noteID"],"b");
    let replayed=call(root.path(),"kb-link-change",link).unwrap();
    assert_eq!(replayed["redacted"],true);
    assert!(snapshot(root.path(),"erase-me")["links"].as_array().unwrap().is_empty());
}
#[test]
fn collection_titles_do_not_leak_after_a_member_folder_is_revoked() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let folder=crate::folders::save(root.path(),crate::folders::Folder {id:"secret".into(),name:"Secret".into(),revision:0,overrides:json!({})}).unwrap();
    let public=create(root.path(),"public","Общая заметка");
    let private=serde_json::from_value(json!({"id":"private-item","kind":"note","title":"Закрытый замысел","text":"Секретный продукт",
        "folderID":"secret","createdAt":0.0,"updatedAt":0.0,"revision":0})).unwrap();
    let private=crate::notes::save_note(root.path(),private).unwrap();
    let s=snapshot(root.path(),"public");
    let request=json!({"action":"create","operationID":uuid(),"name":"Секретный продукт","sources":[
        {"noteID":public.id,"revision":public.revision},{"noteID":private.id,"revision":private.revision}],
        "expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"]});
    call(root.path(),"kb-collection-change",request).unwrap();
    let mut folder=folder; folder.overrides=json!({"features":{"knowledgeBase":false}});
    crate::folders::save(root.path(),folder).unwrap();
    let s=snapshot(root.path(),"public");
    let result=call(root.path(),"kb-topics",json!({"expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"]})).unwrap();
    assert_eq!(result["collections"][0]["nameRedacted"],true);
    assert!(!result.to_string().contains("Секретный"));
    assert!(!result.to_string().contains("private-item"));
    assert_eq!(result["collections"][0]["sources"].as_array().unwrap().len(),1);
}
#[test]
fn collection_membership_changes_are_atomic_versioned_and_preserve_originals() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let a=create(root.path(),"a","Первый текст"); let b=create(root.path(),"b","Второй текст");
    let c=create(root.path(),"c","Третий текст");
    let s=snapshot(root.path(),"a");
    let created=call(root.path(),"kb-collection-change",json!({"action":"create","operationID":uuid(),"name":"Подборка",
        "sources":[{"noteID":"a","revision":a.revision}],"expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"]})).unwrap();
    let request=json!({"action":"add-sources","operationID":uuid(),"collectionID":created["collectionID"],"expectedRevision":created["revision"],
        "sources":[{"noteID":"b","revision":b.revision},{"noteID":"c","revision":c.revision}],
        "expectedWorkspaceRevision":created["workspaceRevision"],"expectedKBRevision":created["kbRevision"]});
    let mut stale=request.clone(); stale["sources"][1]["revision"]=json!(c.revision+1);
    assert!(call(root.path(),"kb-collection-change",stale).is_err());
    let added=call(root.path(),"kb-collection-change",request.clone()).unwrap();
    assert_eq!(call(root.path(),"kb-collection-change",request).unwrap(),added);
    let remove=json!({"action":"remove-source","operationID":uuid(),"collectionID":created["collectionID"],
        "expectedRevision":added["revision"],"noteID":"b","noteRevision":b.revision,
        "expectedWorkspaceRevision":added["workspaceRevision"],"expectedKBRevision":added["kbRevision"]});
    let removed=call(root.path(),"kb-collection-change",remove).unwrap();
    let topics=call(root.path(),"kb-topics",json!({"expectedWorkspaceRevision":removed["workspaceRevision"],"expectedKBRevision":removed["kbRevision"]})).unwrap();
    let ids=topics["collections"][0]["sources"].as_array().unwrap().iter().map(|item|item["noteID"].as_str().unwrap()).collect::<BTreeSet<_>>();
    assert_eq!(ids,BTreeSet::from(["a","c"]));
    assert_eq!(crate::notes::load_note_snapshot(root.path(),"b").unwrap().text,"Второй текст");
    assert_eq!(crate::notes::load_note_snapshot(root.path(),"c").unwrap().revision,c.revision);
}
#[test]
fn derived_cache_never_follows_symlink_outside_library() {
    use std::os::unix::fs::symlink;
    let root=tempfile::tempdir().unwrap(); let outside=tempfile::tempdir().unwrap();
    setup(root.path()); create(root.path(),"a","Содержимое"); let current=snapshot(root.path(),"a");
    symlink(outside.path(),root.path().join("cache")).unwrap();
    let query=json!({"expectedWorkspaceRevision":current["workspaceRevision"],"expectedKBRevision":current["kbRevision"]});
    assert!(call(root.path(),"kb-topics",query).is_err());
    assert!(fs::read_dir(outside.path()).unwrap().next().is_none());
    assert_eq!(crate::notes::load_note_snapshot(root.path(),"a").unwrap().text,"Содержимое");
}

#[test]
fn folder_can_enable_knowledge_when_global_default_is_off() {
    let root=tempfile::tempdir().unwrap();
    crate::storage::atomic_json(&root.path().join("settings.json"),
        &json!({"features":{"knowledgeBase":false}})).unwrap();
    crate::folders::save(root.path(),crate::folders::Folder {id:"enabled".into(),name:"Enabled".into(),
        revision:0,overrides:json!({"features":{"knowledgeBase":true}})}).unwrap();
    let make=|id:&str| {
        let note=serde_json::from_value(json!({"id":id,"kind":"note","text":"Бюджет договора закупки пилотного проекта",
            "folderID":"enabled","createdAt":0.0,"updatedAt":0.0,"revision":0})).unwrap();
        crate::notes::save_note(root.path(),note).unwrap()
    };
    let a=make("a"); let b=make("b"); make("c"); make("d");
    let outside=create(root.path(),"outside","Бюджет договора закупки пилотного проекта");
    let s=snapshot(root.path(),"a");
    assert!(call(root.path(),"kb-snapshot",json!({"noteID":"outside"})).is_err());
    assert!(call(root.path(),"kb-snapshot",json!({})).is_ok());
    let input=json!({"noteID":"a","expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"]});
    let suggestions=call(root.path(),"kb-suggestions",input).unwrap();
    assert!(suggestions["items"].as_array().unwrap().iter().any(|item|item["noteID"]=="b"));
    assert!(!suggestions.to_string().contains("outside"));
    let topics=call(root.path(),"kb-topics",json!({"expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"]})).unwrap();
    assert!(!topics["topics"].as_array().unwrap().is_empty());
    assert!(!topics.to_string().contains("outside"));
    assert!(call(root.path(),"kb-link-change",link_request(&s,&a,&outside)).is_err());
    assert!(call(root.path(),"kb-link-change",link_request(&s,&a,&b)).is_ok());
}

#[test]
fn revoked_candidate_folder_never_publishes_inflight_suggestions() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let folder=crate::folders::save(root.path(),crate::folders::Folder {id:"scoped".into(),name:"Scoped".into(),
        revision:0,overrides:json!({"features":{"knowledgeBase":true,"semanticSearch":true}})}).unwrap();
    create(root.path(),"a","Обсудить бюджет договора проекта");
    let target=serde_json::from_value(json!({"id":"b","kind":"note","text":"Обсудить бюджет договора проекта",
        "folderID":"scoped","createdAt":0.0,"updatedAt":0.0,"revision":0})).unwrap();
    crate::notes::save_note(root.path(),target).unwrap();
    let s=snapshot(root.path(),"a");
    let input=json!({"noteID":"a","expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"]});
    assert_eq!(call(root.path(),"kb-suggestions",input.clone()).unwrap()["items"][0]["noteID"],"b");
    let (reached_tx,reached_rx)=mpsc::channel(); let (resume_tx,resume_rx)=mpsc::channel();
    *SUGGESTION_PAUSE.get_or_init(||Mutex::new(None)).lock().unwrap()=Some((root.path().to_path_buf(),reached_tx,resume_rx));
    let path=root.path().to_path_buf();
    let running=std::thread::spawn(move ||call(&path,"kb-suggestions",input));
    reached_rx.recv_timeout(WaitDuration::from_secs(10)).expect("suggestions reached fence");
    let mut folder=folder; folder.overrides=json!({"features":{"knowledgeBase":false,"semanticSearch":false}});
    crate::folders::save(root.path(),folder).unwrap();
    resume_tx.send(()).unwrap();
    assert!(running.join().unwrap().is_err(),"revoked candidate must not appear in an in-flight result");
}

#[test]
fn private_notes_do_not_exhaust_suggestion_limit_or_leak_into_partial_flag() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    crate::folders::save(root.path(),crate::folders::Folder {id:"private".into(),name:"Private".into(),
        revision:0,overrides:json!({"features":{"knowledgeBase":false}})}).unwrap();
    create(root.path(),"a","Бюджет договора закупки пилотного проекта");
    create(root.path(),"b","Бюджет договора закупки пилотного проекта");
    let workspace=crate::workspace_repository::snapshot(root.path()).unwrap();
    let mut value=workspace.value.clone();
    let notes=value["notes"].as_array_mut().unwrap();
    for index in 0..1501 {
        notes.push(json!({"id":format!("private-{index:04}"),"kind":"note",
            "text":"Бюджет договора закупки пилотного проекта","folderID":"private",
            "createdAt":10.0,"updatedAt":10.0,"revision":0}));
    }
    crate::workspace_repository::compare_and_save(root.path(),workspace.revision,&value).unwrap();
    let s=snapshot(root.path(),"a");
    let result=call(root.path(),"kb-suggestions",json!({"noteID":"a","expectedWorkspaceRevision":s["workspaceRevision"],
        "expectedKBRevision":s["kbRevision"]})).unwrap();
    assert_eq!(result["items"][0]["noteID"],"b");
    assert_eq!(result["partial"],false);
    assert!(!result.to_string().contains("private-"));
}

#[test]
fn meeting_backlinks_and_undo_revalidate_both_ends() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let note=create(root.path(),"note-a","Связанный текст");
    let directory=root.path().join("meetings/meeting-a");
    crate::storage::atomic_json(&directory.join("meta.json"),&json!({"id":"meeting-a","title":"Встреча","source":"audio.mp3","createdAt":1,"status":"ready"})).unwrap();
    crate::storage::atomic_json(&directory.join("transcript.json"),&json!({"segments":[{"id":1,"start":1,"end":2,"text":"Фраза"}]})).unwrap();
    let source=crate::knowledge_meetings::snapshot(root.path(),"meeting-a",None).unwrap().0.remove(0);
    let s=snapshot(root.path(),"note-a");
    let added=call(root.path(),"kb-meeting-link-change",json!({"action":"add","operationID":uuid(),"noteID":"note-a","noteRevision":note.revision,
        "expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"],"source":source})).unwrap();
    let back=call(root.path(),"kb-meeting-backlinks",json!({"meetingID":"meeting-a"})).unwrap();
    assert_eq!(back["items"].as_array().unwrap().len(),1);
    assert_eq!(back["items"][0]["noteID"],"note-a");
    let undo=json!({"operationID":uuid(),"targetOperationID":added["operationID"],
        "expectedWorkspaceRevision":back["workspaceRevision"],"expectedKBRevision":back["kbRevision"]});
    let undone=call(root.path(),"kb-undo",undo.clone()).unwrap();
    assert_eq!(undone["link"]["deleted"],true);
    assert_eq!(call(root.path(),"kb-undo",undo).unwrap(),undone);
    assert!(call(root.path(),"kb-meeting-backlinks",json!({"meetingID":"meeting-a"})).unwrap()["items"].as_array().unwrap().is_empty());
    let s=snapshot(root.path(),"note-a");
    let added=call(root.path(),"kb-meeting-link-change",json!({"action":"add","operationID":uuid(),"noteID":"note-a","noteRevision":note.revision,
        "expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"],"source":source})).unwrap();
    let removed=call(root.path(),"kb-meeting-link-change",json!({"action":"remove","operationID":uuid(),"noteID":"note-a","noteRevision":note.revision,
        "expectedWorkspaceRevision":added["workspaceRevision"],"expectedKBRevision":added["kbRevision"],"linkID":added["link"]["id"]})).unwrap();
    let restore=json!({"operationID":uuid(),"targetOperationID":removed["operationID"],"expectedWorkspaceRevision":removed["workspaceRevision"],"expectedKBRevision":removed["kbRevision"]});
    let restored=call(root.path(),"kb-undo",restore).unwrap();
    assert_eq!(restored["link"]["deleted"],false);
    let removed=call(root.path(),"kb-meeting-link-change",json!({"action":"remove","operationID":uuid(),"noteID":"note-a","noteRevision":note.revision,
        "expectedWorkspaceRevision":restored["workspaceRevision"],"expectedKBRevision":restored["kbRevision"],"linkID":restored["link"]["id"]})).unwrap();
    crate::storage::atomic_json(&directory.join("transcript.json"),&json!({"segments":[{"id":1,"start":1,"end":2,"text":"Изменено"}]})).unwrap();
    assert!(call(root.path(),"kb-undo",json!({"operationID":uuid(),"targetOperationID":removed["operationID"],
        "expectedWorkspaceRevision":removed["workspaceRevision"],"expectedKBRevision":removed["kbRevision"]})).is_err());
    assert!(call(root.path(),"kb-meeting-backlinks",json!({"meetingID":"meeting-a"})).unwrap()["items"].as_array().unwrap().is_empty());
}

#[test]
fn meeting_backlinks_hide_trashed_or_inaccessible_notes_and_cannot_undo_a_newer_change() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let note=create(root.path(),"note-b","Содержимое заметки");
    let directory=root.path().join("meetings/meeting-b");
    crate::storage::atomic_json(&directory.join("meta.json"),&json!({"id":"meeting-b","title":"Встреча","source":"audio.mp3","createdAt":1,"status":"ready"})).unwrap();
    crate::storage::atomic_json(&directory.join("transcript.json"),&json!({"segments":[{"id":1,"start":1,"end":2,"text":"Фраза"}]})).unwrap();
    let source=crate::knowledge_meetings::snapshot(root.path(),"meeting-b",None).unwrap().0.remove(0);
    let added=historical_meeting_link(root.path(),&note,&source);
    let removed=call(root.path(),"kb-meeting-link-change",json!({"action":"remove","operationID":uuid(),"noteID":"note-b","noteRevision":note.revision,
        "expectedWorkspaceRevision":added["workspaceRevision"],"expectedKBRevision":added["kbRevision"],"linkID":added["link"]["id"]})).unwrap();
    let readded=historical_meeting_link(root.path(),&note,&source);
    assert!(call(root.path(),"kb-undo",json!({"operationID":uuid(),"targetOperationID":removed["operationID"],"expectedWorkspaceRevision":readded["workspaceRevision"],"expectedKBRevision":readded["kbRevision"]})).is_err());
    let trashed=crate::notes::trash_note(root.path(),"note-b",note.revision,false).unwrap();
    assert!(call(root.path(),"kb-meeting-backlinks",json!({"meetingID":"meeting-b"})).unwrap()["items"].as_array().unwrap().is_empty());
    crate::notes::delete_note(root.path(),"note-b",trashed.revision).unwrap();
    create(root.path(),"note-b","Другой текст");
    assert!(call(root.path(),"kb-meeting-backlinks",json!({"meetingID":"meeting-b"})).unwrap()["items"].as_array().unwrap().is_empty());
    assert!(call(root.path(),"kb-undo",json!({"operationID":uuid(),"targetOperationID":readded["operationID"],"expectedWorkspaceRevision":readded["workspaceRevision"],"expectedKBRevision":readded["kbRevision"]})).is_err());
}

#[test]
fn meeting_unlink_tombstone_survives_identical_source_restore_and_receipt_replay() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let note=create(root.path(),"n","Бюджет договора");
    let directory=root.path().join("meetings/m");
    crate::storage::atomic_json(&directory.join("meta.json"),&json!({"id":"m","title":"Встреча","source":"audio.mp3","createdAt":1,"status":"ready"})).unwrap();
    crate::storage::atomic_json(&directory.join("transcript.json"),&json!({"segments":[{"id":1,"start":0,"end":1,"text":"Бюджет договора"}]})).unwrap();
    let meta=fs::read(directory.join("meta.json")).unwrap();let transcript=fs::read(directory.join("transcript.json")).unwrap();
    let source=crate::knowledge_meetings::snapshot(root.path(),"m",None).unwrap().0.remove(0);
    let s=snapshot(root.path(),"n");
    let request=json!({"action":"add","operationID":uuid(),"noteID":"n","noteRevision":note.revision,
        "expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"],"source":source});
    let added=call(root.path(),"kb-meeting-link-change",request.clone()).unwrap();
    // An old profile fingerprint is not content identity. Current rights still apply.
    let database=Connection::open(root.path().join(DATABASE)).unwrap();
    database.execute("UPDATE kb_meeting_links SET source_ref=json_set(source_ref,'$.policyFingerprint','former-model-profile')",[]).unwrap();drop(database);
    assert_eq!(call(root.path(),"kb-meeting-links",json!({"noteID":"n","noteRevision":note.revision})).unwrap()["items"][0]["available"],true);
    let current=snapshot(root.path(),"n");
    call(root.path(),"kb-meeting-link-change",json!({"action":"remove","operationID":uuid(),"noteID":"n","noteRevision":note.revision,
        "expectedWorkspaceRevision":current["workspaceRevision"],"expectedKBRevision":current["kbRevision"],"linkID":added["link"]["id"]})).unwrap();
    fs::remove_dir_all(&directory).unwrap();fs::create_dir_all(&directory).unwrap();fs::write(directory.join("meta.json"),meta).unwrap();fs::write(directory.join("transcript.json"),transcript).unwrap();
    call(root.path(),"kb-meeting-link-change",request).unwrap();
    assert!(call(root.path(),"kb-meeting-links",json!({"noteID":"n","noteRevision":note.revision})).unwrap()["items"].as_array().unwrap().is_empty());
    assert!(call(root.path(),"kb-meeting-backlinks",json!({"meetingID":"m"})).unwrap()["items"].as_array().unwrap().is_empty());
}
