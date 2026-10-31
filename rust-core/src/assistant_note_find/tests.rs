use super::*;
use serde_json::json;
use std::path::PathBuf;
use std::sync::{mpsc,Mutex,OnceLock};
use std::time::Duration;

type Pause=(PathBuf,mpsc::Sender<()>,mpsc::Receiver<()>);
static PAUSE:OnceLock<Mutex<Option<Pause>>>=OnceLock::new();
pub(super) fn pause_before_publication(root:&Path) {
    let pause={let mut slot=PAUSE.get_or_init(||Mutex::new(None)).lock().unwrap();
        if slot.as_ref().is_some_and(|(path,_,_)|path==root) {slot.take()} else {None}};
    if let Some((_,reached,resume))=pause {
        reached.send(()).unwrap(); resume.recv_timeout(Duration::from_secs(10)).unwrap();
    }
}

fn setup(root:&Path) {
    crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"assistant":true,"knowledgeBase":false}})).unwrap();
}
fn note(root:&Path,id:&str,text:&str,folder:Option<&str>)->crate::notes::CapturedNote {
    crate::notes::save_note(root,serde_json::from_value(json!({"id":id,"kind":"note","title":"", "text":text,
        "folderID":folder,"createdAt":1.0,"updatedAt":1.0,"revision":0})).unwrap()).unwrap()
}
fn find(root:&Path,query:&str,scope:Value,limit:usize)->Result<Value> {
    dispatch(root,&json!({"command":"assistant-note-find","query":query,"scope":scope,"limit":limit}))
}
fn validate(root:&Path,scope:Value,target:Value)->Result<Value> {
    dispatch(root,&json!({"command":"assistant-note-validate","scope":scope,"target":target}))
}

#[test]
fn note_find_works_without_kb_and_filters_disabled_folders_before_limit() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    crate::folders::save(root.path(),crate::folders::Folder {id:"private".into(),name:"Private".into(),revision:0,
        overrides:json!({"features":{"assistant":false}})}).unwrap();
    note(root.path(),"public","План пилота и бюджет",None);
    let snapshot=crate::workspace_repository::snapshot(root.path()).unwrap();
    let mut value=snapshot.value.clone();
    for n in 0..60 {
        value["notes"].as_array_mut().unwrap().push(json!({"id":format!("private-{n}"),"kind":"note",
            "text":"Секретный план пилота","folderID":"private","createdAt":1.0,"updatedAt":9999.0,"revision":1}));
    }
    crate::workspace_repository::compare_and_save(root.path(),snapshot.revision,&value).unwrap();
    let result=find(root.path(),"пилот",json!({"mode":"library"}),1).unwrap();
    assert_eq!(result["matching"],1);
    assert_eq!(result["targets"][0]["noteID"],"public");
    assert_eq!(result["truncated"],false);
    assert!(!result.to_string().contains("Секретный"));
    assert!(!result.to_string().contains("private-"));
    assert!(!root.path().join("jobs.sqlite").exists(),"read-only lookup must not enqueue work");
    assert!(find(root.path(),"пилот",json!({"mode":"folder","folderID":"private"}),20).is_err());
}

#[test]
fn revoked_folder_during_lookup_never_publishes_the_result() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let mut folder=crate::folders::save(root.path(),crate::folders::Folder {id:"work".into(),name:"Work".into(),revision:0,
        overrides:json!({"features":{"assistant":true}})}).unwrap();
    note(root.path(),"selected","Маяк проекта",Some("work"));
    let (reached_tx,reached_rx)=mpsc::channel(); let (resume_tx,resume_rx)=mpsc::channel();
    *PAUSE.get_or_init(||Mutex::new(None)).lock().unwrap()=Some((root.path().to_path_buf(),reached_tx,resume_rx));
    let path=root.path().to_path_buf();
    let running=std::thread::spawn(move ||find(&path,"маяк",json!({"mode":"library"}),20));
    reached_rx.recv_timeout(Duration::from_secs(10)).expect("lookup reached publication fence");
    folder.overrides=json!({"features":{"assistant":false}});
    crate::folders::save(root.path(),folder).unwrap();
    resume_tx.send(()).unwrap();
    assert!(running.join().unwrap().is_err(),"revoked result must not be published");
}

#[test]
fn folder_only_assistant_respects_scope_and_never_reopens_stale_results() {
    let root=tempfile::tempdir().unwrap();
    crate::storage::atomic_json(&root.path().join("settings.json"),&json!({"features":{"assistant":false,"knowledgeBase":false}})).unwrap();
    let folder=crate::folders::save(root.path(),crate::folders::Folder {id:"work".into(),name:"Work".into(),revision:0,
        overrides:json!({"features":{"assistant":true}})}).unwrap();
    let old=note(root.path(),"selected","Пилотная встреча",Some("work"));
    note(root.path(),"outside","Пилотная встреча",None);
    let scope=json!({"mode":"folder","folderID":"work"});
    let result=find(root.path(),"пилот",scope.clone(),20).unwrap();
    assert_eq!(result["matching"],1);
    let selected=result["targets"][0].clone();
    assert_eq!(validate(root.path(),scope.clone(),selected.clone()).unwrap()["valid"],true);
    let library=find(root.path(),"пилот",json!({"mode":"library"}),20).unwrap();
    assert_eq!(library["matching"],1);
    assert!(!library.to_string().contains("outside"));
    let mut edited=old.clone(); edited.text="Пилот изменился".into();
    let edited=crate::notes::save_note(root.path(),edited).unwrap();
    assert_eq!(validate(root.path(),scope.clone(),selected.clone()).unwrap()["valid"],false);
    let current=find(root.path(),"пилот",scope.clone(),20).unwrap()["targets"][0].clone();
    assert_eq!(validate(root.path(),scope.clone(),current.clone()).unwrap()["valid"],true);
    let mut folder=folder; folder.overrides=json!({"features":{"assistant":false}});
    crate::folders::save(root.path(),folder).unwrap();
    assert_eq!(validate(root.path(),scope.clone(),current).unwrap()["valid"],false);
    assert!(find(root.path(),"пилот",scope,20).is_err());
    assert_eq!(crate::notes::load_note_snapshot(root.path(),"selected").unwrap().revision,edited.revision);
}

#[test]
fn malformed_scopes_and_unsafe_results_fail_closed() {
    let root=tempfile::tempdir().unwrap(); setup(root.path());
    let a=note(root.path(),"a","Обсудить бюджет",None);
    assert!(find(root.path(),"бюджет",json!({"mode":"project","projectID":"p"}),20).is_err());
    assert!(find(root.path(),"бюджет",json!({"mode":"library","folderID":"work"}),20).is_err());
    assert!(find(root.path(),"бюджет",json!({"mode":"folder","folderID":"../escape"}),20).is_err());
    assert!(find(root.path(),"бюджет",json!({"mode":"library"}),51).is_err());
    assert!(find(root.path(),"?!",json!({"mode":"library"}),20).is_err());
    let selected=find(root.path(),"бюджет",json!({"mode":"library"}),20).unwrap()["targets"][0].clone();
    let mut forged=selected.clone(); forged["sourceFingerprint"]=json!("0".repeat(64));
    assert_eq!(validate(root.path(),json!({"mode":"library"}),forged).unwrap()["valid"],false);
    let deleted=crate::notes::trash_note(root.path(),"a",a.revision,false).unwrap();
    assert_eq!(validate(root.path(),json!({"mode":"library"}),selected.clone()).unwrap()["valid"],false);
    crate::notes::trash_note(root.path(),"a",deleted.revision,true).unwrap();
    assert_eq!(validate(root.path(),json!({"mode":"library"}),selected).unwrap()["valid"],false);
}
