//! Explicit desktop task/card operations. Never forward a client command or
//! external path to the domain dispatchers.
use super::{bounded, domain, identifier, optional_id, parse, BridgeError, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::Path;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Empty {}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TaskId { task_id: String }
fn task_id(id: &str) -> Result<()> {
    if id.len() <= 256 && !id.is_empty()
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b':')) {
        Ok(())
    } else { Err(BridgeError::invalid()) }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreateTask { title: String, #[serde(default)] text: String, folder_id: Option<String>, operation_id: String }
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct UpdateTask {
    task_id: String, expected_revision: u64, expected_source_fingerprint: Option<String>,
    operation_id: String, patch: TaskPatch,
}
#[derive(Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
struct TaskPatch {
    #[serde(skip_serializing_if = "Option::is_none")] title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] due: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] owner: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] project: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SaveCard {
    front: String, back: String, kind: Option<String>, meeting_id: Option<String>,
    card_id: Option<String>, expected_fingerprint: Option<String>,
    new_deck_title: Option<String>, folder_id: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CardRef { meeting_id: String, card_id: String, expected_fingerprint: String }
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SuspendCard { meeting_id: String, card_id: String, expected_fingerprint: String, suspended: bool }
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReviewCard {
    meeting_id: String, card_id: String, expected_fingerprint: String,
    expected_review_fingerprint: String, rating: Option<u8>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct UndoReview { meeting_id: String, undo_id: String }

fn fingerprint(value: &str) -> Result<()> {
    if value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit()) {
        Ok(())
    } else { Err(BridgeError::invalid()) }
}
fn check_card(meeting: &str, card: &str, hash: &str) -> Result<()> {
    identifier(meeting)?; identifier(card)?; fingerprint(hash)
}
// Task material records can contain local paths and agent state. Only return
// fields needed for the ordinary local task UI.
fn task(value: &Value) -> Value {
    json!({"id":value["id"],"title":value["title"],"text":value["text"],
        "status":value["status"],"completed":value["completed"],"owner":value["owner"],
        "due":value["due"],"project":value["project"],"revision":value["revision"],
        "createdAt":value["createdAt"],"updatedAt":value["updatedAt"],
        "virtual":value["virtual"],"meetingId":value["meetingID"],
        "sourceFingerprint":value["sourceFingerprint"]})
}
fn card_entry(value: &Value) -> Value {
    let card = &value["card"];
    let review = &value["review"];
    json!({"meetingId":value["meeting"]["id"],"meetingTitle":value["meeting"]["title"],
        "card":{"id":card["id"],"kind":card["kind"],"front":card["front"],"back":card["back"],"context":card["context"]},
        "fingerprint":value["fingerprint"],
        "review":if review.is_null() { Value::Null } else { json!({"due":review["due"],"count":review["count"]}) },
        "reviewFingerprint":value["reviewFingerprint"],
        "suspended":value["suspended"],"sourceStale":value["sourceStale"]})
}
fn card_command(root: &Path, command: &str, args: Value) -> Result<Value> {
    let mut input = args;
    input["command"] = json!(command);
    domain(crate::cards::dispatch(root, &input))
}
fn task_command(root: &Path, command: &str, args: Value) -> Result<Value> {
    let mut input = args;
    input["command"] = json!(command);
    domain(crate::task_workspace::dispatch(root, &input))
}

pub(super) fn dispatch(root: &Path, command: &str, args: Value) -> Result<Value> {
    match command {
        "list_tasks" => {
            let _: Empty = parse(args)?;
            let value = task_command(root, "task-list", json!({"limit":500}))?;
            let tasks = value["tasks"].as_array().ok_or_else(BridgeError::library)?;
            Ok(json!({"tasks":tasks.iter().map(task).collect::<Vec<_>>(),
                "total":value["total"],"truncated":value["truncated"]}))
        }
        "get_task" => {
            let a: TaskId = parse(args)?; task_id(&a.task_id)?;
            let value = task_command(root, "task-get", json!({"taskID":a.task_id}))?;
            Ok(task(&value))
        }
        "create_task" => {
            let a: CreateTask = parse(args)?;
            bounded(&a.title, 1024)?; bounded(&a.text, 100_000)?; optional_id(a.folder_id.as_deref())?; identifier(&a.operation_id)?;
            if a.title.trim().is_empty() { return Err(BridgeError::invalid()); }
            let value = task_command(root, "task-create", json!({"title":a.title,"text":a.text,"folderID":a.folder_id,"operationID":a.operation_id}))?;
            Ok(task(&value))
        }
        "update_task" => {
            let a: UpdateTask = parse(args)?; task_id(&a.task_id)?; identifier(&a.operation_id)?;
            if let Some(hash) = &a.expected_source_fingerprint { bounded(hash, 256)?; }
            for (value, limit) in [(&a.patch.title,1024),(&a.patch.text,100_000),(&a.patch.due,1024),
                (&a.patch.owner,1024),(&a.patch.project,512),(&a.patch.status,32)] {
                if let Some(value) = value { bounded(value, limit)?; }
            }
            if a.patch.title.as_ref().is_some_and(|s|s.trim().is_empty())
                || a.patch.status.as_ref().is_some_and(|s|!["todo","doing","blocked","done"].contains(&s.as_str())) {
                return Err(BridgeError::invalid());
            }
            let value = task_command(root, "task-details-update", json!({"taskID":a.task_id,
                "expectedRevision":a.expected_revision,"expectedSourceFingerprint":a.expected_source_fingerprint,"operationID":a.operation_id,"patch":a.patch}))?;
            Ok(task(&value))
        }
        "list_cards" => {
            let _: Empty = parse(args)?;
            let value = card_command(root, "cards-library", json!({}))?;
            let entries = value["entries"].as_array().ok_or_else(BridgeError::library)?;
            Ok(json!({"cards":entries.iter().map(card_entry).collect::<Vec<_>>(),
                "errorCount":value["errors"].as_array().map_or(0, Vec::len)}))
        }
        "save_card" => {
            let a: SaveCard = parse(args)?;
            bounded(&a.front, 100_000)?; bounded(&a.back, 100_000)?;
            if a.front.trim().is_empty() || a.back.trim().is_empty() { return Err(BridgeError::invalid()); }
            optional_id(a.meeting_id.as_deref())?; optional_id(a.card_id.as_deref())?; optional_id(a.folder_id.as_deref())?;
            if let Some(hash)=&a.expected_fingerprint { fingerprint(hash)?; }
            if a.card_id.is_some() && (a.meeting_id.is_none() || a.expected_fingerprint.is_none()) { return Err(BridgeError::invalid()); }
            if let Some(title)=&a.new_deck_title { bounded(title, 512)?; }
            if a.kind.as_ref().is_some_and(|s|!["phrase","concept"].contains(&s.as_str())) { return Err(BridgeError::invalid()); }
            let value = card_command(root, "card-save", json!({"front":a.front,"back":a.back,
                "kind":a.kind.unwrap_or_else(||"phrase".into()),"meetingID":a.meeting_id,
                "cardID":a.card_id,"expectedFingerprint":a.expected_fingerprint,
                "newDeckTitle":a.new_deck_title.unwrap_or_else(||"My cards".into()),"folderID":a.folder_id}))?;
            Ok(json!({"meetingId":value["meeting"]["id"],"card":{"id":value["card"]["id"]}}))
        }
        "delete_card" => {
            let a: CardRef = parse(args)?; check_card(&a.meeting_id,&a.card_id,&a.expected_fingerprint)?;
            card_command(root,"card-delete",json!({"meetingID":a.meeting_id,"cardID":a.card_id,"expectedFingerprint":a.expected_fingerprint}))
        }
        "suspend_card" => {
            let a: SuspendCard = parse(args)?; check_card(&a.meeting_id,&a.card_id,&a.expected_fingerprint)?;
            card_command(root,"card-suspend",json!({"meetingID":a.meeting_id,"cardID":a.card_id,"expectedFingerprint":a.expected_fingerprint,"suspended":a.suspended}))
        }
        "preview_card_review" | "review_card" => {
            let a: ReviewCard = parse(args)?; check_card(&a.meeting_id,&a.card_id,&a.expected_fingerprint)?;
            fingerprint(&a.expected_review_fingerprint)?;
            if command == "review_card" && !a.rating.is_some_and(|r|(1..=4).contains(&r)) { return Err(BridgeError::invalid()); }
            if command == "preview_card_review" && a.rating.is_some() { return Err(BridgeError::invalid()); }
            card_command(root,if command=="review_card" {"cards-review"} else {"cards-review-preview"},
                json!({"meetingID":a.meeting_id,"cardID":a.card_id,"expectedFingerprint":a.expected_fingerprint,
                    "expectedReviewFingerprint":a.expected_review_fingerprint,"rating":a.rating}))
        }
        "undo_card_review" => {
            let a: UndoReview = parse(args)?; identifier(&a.meeting_id)?; identifier(&a.undo_id)?;
            card_command(root,"cards-review-undo",json!({"meetingID":a.meeting_id,"undoID":a.undo_id}))
        }
        _ => Err(BridgeError::invalid()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop::handle_bytes;
    fn request(root: &Path, command: &str, arguments: Value) -> Value {
        handle_bytes(root, &serde_json::to_vec(&json!({"command":command,"arguments":arguments})).unwrap())
    }
    fn success(root: &Path, command: &str, arguments: Value) -> Value {
        let result = request(root,command,arguments);
        assert_eq!(result["ok"],true,"{result}");
        result["result"].clone()
    }
    #[test]
    fn tasks_persist_and_reject_stale_updates() {
        let root = tempfile::tempdir().unwrap();
        let created = success(root.path(),"create_task",json!({"title":"Prepare","text":"Agenda","operationId":"create-1"}));
        assert_eq!(created["title"],"Prepare");
        assert!(!created.to_string().contains("agentAccess"));
        let list = success(root.path(),"list_tasks",json!({}));
        assert_eq!(list["tasks"].as_array().unwrap().len(),1);
        let args=json!({"taskId":created["id"],"expectedRevision":created["revision"],"operationId":"update-1","patch":{"status":"done"}});
        let updated=success(root.path(),"update_task",args.clone());
        assert_eq!(updated["completed"],true);
        // Identical retry replays once; a new operation with an old revision conflicts.
        assert_eq!(success(root.path(),"update_task",args.clone())["status"],"done");
        let mut stale=args; stale["operationId"]=json!("update-2");
        assert_eq!(request(root.path(),"update_task",stale)["error"]["code"],"conflict");
        assert_eq!(success(root.path(),"get_task",json!({"taskId":created["id"]}))["status"],"done");
    }
    #[test]
    fn cards_persist_review_and_reject_stale_edit() {
        let root = tempfile::tempdir().unwrap();
        let created = success(root.path(),"save_card",json!({"front":"Hello","back":"Привет","newDeckTitle":"Test"}));
        let list=success(root.path(),"list_cards",json!({}));
        let entry=&list["cards"][0];
        assert_eq!(entry["card"]["front"],"Hello");
        let reference=json!({"meetingId":created["meetingId"],"cardId":created["card"]["id"],
            "expectedFingerprint":entry["fingerprint"],"expectedReviewFingerprint":entry["reviewFingerprint"]});
        let preview=success(root.path(),"preview_card_review",reference.clone());
        assert_eq!(preview["options"].as_array().unwrap().len(),4);
        let mut rated=reference.clone(); rated["rating"]=json!(3);
        let reviewed=success(root.path(),"review_card",rated.clone());
        assert_eq!(reviewed["state"]["count"],1);
        assert_eq!(request(root.path(),"review_card",rated)["error"]["code"],"conflict");
        success(root.path(),"undo_card_review",json!({"meetingId":reviewed["meetingID"],"undoId":reviewed["undoID"]}));
        assert!(success(root.path(),"list_cards",json!({}))["cards"][0]["review"].is_null());
    }
    #[test]
    fn renderer_cannot_select_commands_paths_or_agent_access() {
        let root=tempfile::tempdir().unwrap();
        for (command,args) in [
            ("list_tasks",json!({"agentOnly":true})),
            ("create_task",json!({"title":"x","path":"C:\\secret"})),
            ("update_task",json!({"taskId":"x","expectedRevision":1,"patch":{"agentAccess":{"enabled":true}}})),
            ("list_cards",json!({"command":"cards-import","path":"C:\\secret"})),
            ("delete_card",json!({"meetingId":"../outside","cardId":"x","expectedFingerprint":"a".repeat(64)})),
        ] {
            assert_eq!(request(root.path(),command,args)["error"]["code"],"invalid_request");
        }
        assert_eq!(request(root.path(),"task-agent-claim",json!({}))["error"]["code"],"unsupported_command");
    }
}
