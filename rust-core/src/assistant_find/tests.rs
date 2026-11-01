use super::*;
use uuid::Uuid;

fn enable(root: &Path) {
    crate::storage::atomic_json(&root.join("settings.json"), &json!({
        "features":{"assistant":true,"tasks":true}
    })).unwrap();
}
fn task(root: &Path, title: &str, project: &str, folder: Option<&str>, due: &str) -> Value {
    task_call(root, "task-create", json!({"title":title,"project":project,"folderID":folder,
        "due":due,"text":"данные для проверки","operationID":Uuid::new_v4().to_string()})).unwrap()
}
fn plan(selector: Value, scope: Value) -> Value {
    json!({"intent":"find","entityKind":"task","selector":selector,"scope":scope,
        "clock":{"queryNow":chrono::Utc::now().timestamp_millis() as f64 / 1000.0 + 3600.0,"timeZoneID":"Europe/Moscow"}})
}
fn run(root: &Path, p: Value, limit: usize) -> Value {
    dispatch(root, &json!({"command":"assistant-find","plan":p,"limit":limit})).unwrap()
}
#[test]
fn latest_uses_creation_not_recent_progress_and_is_filtered_before_limit() {
    let root=tempfile::tempdir().unwrap(); enable(root.path());
    let first=task(root.path(),"Старая", "work",None,"");
    // The production policy deliberately refuses to guess when creation
    // timestamps tie. Ensure this fixture actually models two distinct times.
    std::thread::sleep(std::time::Duration::from_millis(3));
    let latest=task(root.path(),"Новая", "work",None,"");
    for i in 0..24 { task(root.path(),&format!("Другой проект {i}"),"other",None,""); }
    let mut old=crate::notes::load_note_snapshot(root.path(),first["id"].as_str().unwrap().trim_start_matches("manual:")).unwrap();
    old.text="Обновление старой задачи".into();
    crate::notes::save_note(root.path(),old).unwrap();
    let p=plan(json!({"type":"latestCreated"}),json!({"mode":"project","projectID":"work"}));
    let result=run(root.path(),p,1);
    assert_eq!(result["state"],"results");
    assert_eq!(result["targets"][0]["taskID"],latest["id"]);
}
#[test]
fn search_scope_and_revalidation_reject_changed_or_revoked_task() {
    let root=tempfile::tempdir().unwrap(); enable(root.path());
    let folder=crate::folders::save(root.path(),crate::folders::Folder {
        id:"work".into(),name:"Работа".into(),revision:0,overrides:json!({}),
    }).unwrap();
    let selected=task(root.path(),"Пилот проекта","alpha",Some(&folder.id),"2026-10-31");
    task(root.path(),"Пилот личный","alpha",None,"2026-10-31");
    let p=plan(json!({"type":"search","query":"пилот"}),json!({"mode":"folder","folderID":"work"}));
    let result=run(root.path(),p.clone(),20);
    assert_eq!(result["coverage"]["matching"],1);
    let target=result["targets"][0].clone();
    assert_eq!(dispatch(root.path(),&json!({"command":"assistant-find-validate","plan":p,"target":target})).unwrap()["valid"],true);
    task_call(root.path(),"task-details-update",json!({"taskID":selected["id"],"expectedRevision":selected["revision"],
        "expectedSourceFingerprint":selected["sourceFingerprint"],"operationID":Uuid::new_v4().to_string(),
        "patch":{"title":"Новый заголовок"}})).unwrap();
    let p=plan(json!({"type":"search","query":"пилот"}),json!({"mode":"folder","folderID":"work"}));
    assert_eq!(dispatch(root.path(),&json!({"command":"assistant-find-validate","plan":p,"target":target})).unwrap()["valid"],false);
    crate::storage::atomic_json(&root.path().join("settings.json"), &json!({"features":{"assistant":false,"tasks":true}})).unwrap();
    let p=plan(json!({"type":"search","query":"пилот"}),json!({"mode":"library"}));
    assert!(dispatch(root.path(),&json!({"command":"assistant-find","plan":p})).is_err());
}
#[test]
fn due_range_and_unknown_free_text_are_reported() {
    let root=tempfile::tempdir().unwrap(); enable(root.path());
    let expected=task(root.path(),"Сегодня","",None,"2026-10-31");
    task(root.path(),"Завтра","",None,"2026-11-01");
    task(root.path(),"Неизвестно","",None,"на выходных");
    let p=plan(json!({"type":"dueRange","startDate":"2026-10-31","endDateExclusive":"2026-11-01"}),json!({"mode":"library"}));
    let result=run(root.path(),p,20);
    assert_eq!(result["targets"][0]["taskID"],expected["id"]);
    assert_eq!(result["coverage"]["unknownDue"],1);
    assert!(!result["warnings"].as_array().unwrap().is_empty());
}
#[test]
fn imported_creation_time_never_silently_decides_the_latest_task() {
    let root=tempfile::tempdir().unwrap(); enable(root.path());
    let local=task(root.path(),"Локальная","",None,"");
    let imported=task_call(root.path(),"task-create",json!({"title":"Импортированная",
        "source":"yandex","operationID":Uuid::new_v4().to_string()})).unwrap();
    let p=plan(json!({"type":"latestCreated"}),json!({"mode":"library"}));
    let result=run(root.path(),p,20);
    assert_eq!(result["state"],"clarify");
    assert_eq!(result["coverage"]["unknownCreation"],1);
    let ids=result["targets"].as_array().unwrap().iter().map(|v|v["taskID"].as_str().unwrap()).collect::<Vec<_>>();
    assert!(ids.contains(&local["id"].as_str().unwrap()));
    assert!(ids.contains(&imported["id"].as_str().unwrap()));
}
#[test]
fn creation_after_request_clock_is_not_claimed_as_latest() {
    let root=tempfile::tempdir().unwrap(); enable(root.path());
    task(root.path(),"Позже времени запроса","",None,"");
    let mut p=plan(json!({"type":"latestCreated"}),json!({"mode":"library"}));
    p["clock"]["queryNow"]=json!(100.0);
    let result=run(root.path(),p,20);
    assert_eq!(result["state"],"clarify");
    assert_eq!(result["coverage"]["unknownCreation"],1);
}
#[test]
fn latest_task_inspection_returns_bounded_history_with_its_own_fingerprint() {
    let root=tempfile::tempdir().unwrap(); enable(root.path());
    let expected=task(root.path(),"Последняя","",None,"");
    let mut p=plan(json!({"type":"latestCreated"}),json!({"mode":"library"}));
    p["intent"]=json!("inspect");
    let result=run(root.path(),p.clone(),20);
    let mut target=result["targets"][0].clone();
    assert_eq!(target["taskID"],expected["id"]);
    assert!(!target["recentHistory"].as_array().unwrap().is_empty());
    assert_eq!(target["historyFingerprint"].as_str().unwrap().len(),64);
    assert_eq!(dispatch(root.path(),&json!({"command":"assistant-find-validate","plan":p,"target":target})).unwrap()["valid"],true);
    target["historyFingerprint"]=json!("0".repeat(64));
    let mut p=plan(json!({"type":"latestCreated"}),json!({"mode":"library"}));
    p["intent"]=json!("inspect");
    assert_eq!(dispatch(root.path(),&json!({"command":"assistant-find-validate","plan":p,"target":target})).unwrap()["valid"],false);
}
#[test]
fn follow_up_rejects_changed_or_reordered_visible_list() {
    let root=tempfile::tempdir().unwrap(); enable(root.path());
    task(root.path(),"Пилот один","",None,"");
    task(root.path(),"Пилот два","",None,"");
    let p=plan(json!({"type":"search","query":"пилот"}),json!({"mode":"library"}));
    let response=run(root.path(),p.clone(),20);
    assert_eq!(response["targets"].as_array().unwrap().len(),2);
    let request=json!({"command":"assistant-find-validate-list","plan":p,"response":response,"limit":20});
    assert_eq!(dispatch(root.path(),&request).unwrap()["valid"],true);
    task(root.path(),"Пилот три","",None,"");
    assert_eq!(dispatch(root.path(),&request).unwrap()["valid"],false);
}
#[test]
fn latest_report_is_chosen_by_time_before_limits_and_keeps_attribution() {
    let task = json!({"id":"task", "title":"T", "text":"", "revision":1,
        "sourceFingerprint":"", "createdAt":1.0, "source":"local", "virtual":false,
        "history":[
            {"id":"new", "kind":"report", "actor":"Agent A", "createdAt":50.0,
             "text":"Отчёт".repeat(300), "artifacts":[{"id":"one","title":"Результат"},
                {"id":"two","title":"Код"}, {"id":"three","title":"Тесты"}, {"id":"four","title":"Ещё"}]},
            {"id":"old", "kind":"report", "actor":"Agent B", "createdAt":5.0, "text":"Старый", "artifacts":[]},
            {"id":"progress", "kind":"progress", "actor":"Agent A", "createdAt":100.0, "text":"Идёт работа"}
        ]});
    let result = describe(&task, &json!({"contextVersion":"v"}), Some(&task), 200.0);
    let report = &result["latestReport"];
    assert_eq!(report["eventID"], "new");
    assert_eq!(report["actor"], "Agent A");
    assert_eq!(report["artifacts"].as_array().unwrap().len(), 3);
    assert_eq!(report["artifactsTruncated"], true);
    assert_eq!(report["textTruncated"], true);
    assert_eq!(report["text"].as_str().unwrap().chars().count(), 1000);
    assert_eq!(result["recentHistory"][0], "Идёт работа");
}
#[test]
fn malformed_plans_fail_closed() {
    let root=tempfile::tempdir().unwrap(); enable(root.path());
    let mut p=plan(json!({"type":"latestCreated"}),json!({"mode":"library"}));
    p["clock"]["timeZoneID"]=json!("../etc/passwd");
    assert!(dispatch(root.path(),&json!({"command":"assistant-find","plan":p})).is_err());
    let mut p=plan(json!({"type":"latestCreated"}),json!({"mode":"library"}));
    p["clock"]["timeZoneID"]=json!("GMT+03:00");
    assert!(dispatch(root.path(),&json!({"command":"assistant-find","plan":p})).is_ok());
    let p=plan(json!({"type":"dueRange","startDate":"2026-02-30","endDateExclusive":"2026-03-01"}),json!({"mode":"library"}));
    assert!(dispatch(root.path(),&json!({"command":"assistant-find","plan":p})).is_err());
}
