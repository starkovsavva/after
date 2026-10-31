use super::*;
fn call(root: &Path, command: &str, mut input: Value) -> Result<Value> {
    input["command"] = json!(command);
    dispatch(root, &input)
}
fn create_task(root: &Path, name: &str) -> Value {
    call(
        root,
        "task-create",
        json!({"title":name,"text":"Canonical task body","operationID":uuid()}),
    )
    .unwrap()
}
fn patch(root: &Path, t: &Value, p: Value) -> Value {
    call(root,"task-details-update",json!({"taskID":t["id"],"expectedRevision":t["revision"],"expectedSourceFingerprint":t["sourceFingerprint"],"operationID":uuid(),"patch":p})).unwrap()
}
fn get(root: &Path, id: &Value) -> Value {
    call(root, "task-get", json!({"taskID":id})).unwrap()
}
fn add_note(root: &Path, t: &Value, text: &str, shared: bool) -> Value {
    call(root,"task-material-link",json!({"taskID":t["id"],"expectedRevision":t["revision"],"operationID":uuid(),"material":{"kind":"note","title":"Thought","text":text,"shared":shared}})).unwrap()
}
fn enable(root: &Path) {
    call(
        root,
        "task-agent-settings",
        json!({"enabled":true,"expectedRevision":0,"operationID":uuid()}),
    )
    .unwrap();
}
fn c(root: &Path, t: &Value, agent: bool) -> Value {
    call(
        root,
        "task-context",
        json!({"taskID":t["id"],"agentOnly":agent}),
    )
    .unwrap()
}

#[test]
fn knowledge_selection_never_expands_legacy_task_material_permissions() {
    let dir = tempfile::tempdir().unwrap(); let root = dir.path();
    let task = create_task(root, "Task");
    let task = add_note(root, &task, "explicit legacy material", true);
    let before = get(root, &task["id"]);
    let result = call(root, "task-material-share-notes", json!({"taskID":task["id"],
        "expectedRevision":task["revision"], "operationID":uuid(),
        "notes":[{"id":"ungranted","revision":1}]}));
    assert!(result.is_err());
    assert_eq!(get(root, &task["id"]), before);
}

#[test]
fn legacy_workspace_status_and_note_editor_remain_compatible() {
    let root = tempfile::tempdir().unwrap();
    let task = create_task(root.path(), "First");
    let doing = patch(root.path(), &task, json!({"status":"doing"}));
    assert_eq!(doing["status"], "doing");
    assert_eq!(doing["completed"], false);
    let mut old = notes::list(root.path())
        .unwrap()
        .notes
        .into_iter()
        .find(|n| n.kind == "task")
        .unwrap();
    old.completed = true;
    old = notes::save_note(root.path(), old).unwrap();
    assert_eq!(get(root.path(), &doing["id"])["status"], "done");
    old.completed = false;
    notes::save_note(root.path(), old).unwrap();
    assert_eq!(get(root.path(), &doing["id"])["status"], "doing");
    let done = patch(
        root.path(),
        &get(root.path(), &doing["id"]),
        json!({"status":"done"}),
    );
    let mut old = notes::list(root.path())
        .unwrap()
        .notes
        .into_iter()
        .find(|n| n.kind == "task")
        .unwrap();
    old.completed = false;
    notes::save_note(root.path(), old).unwrap();
    assert_eq!(get(root.path(), &done["id"])["status"], "todo");
    let dir = notes::directory(root.path()).unwrap();
    let mut saved: Value =
        serde_json::from_slice(&std::fs::read(dir.join("workspace.json")).unwrap()).unwrap();
    for key in [
        "taskWorkspaces",
        "taskPlans",
        "taskOperations",
        "taskIntegration",
    ] {
        saved.as_object_mut().unwrap().remove(key);
    }
    let legacy_root = tempfile::tempdir().unwrap();
    let legacy_directory = notes::directory(legacy_root.path()).unwrap();
    storage::atomic_json(&legacy_directory.join("workspace.json"), &saved).unwrap();
    assert!(!notes::list(legacy_root.path()).unwrap().task_integration.enabled);
}
#[test]
fn references_are_live_excluded_materials_are_private_and_folders_are_not_read() {
    let root = tempfile::tempdir().unwrap();
    enable(root.path());
    let task = create_task(root.path(), "References");
    let task = patch(root.path(), &task, json!({"agentAccess":{"enabled":true}}));
    let task = add_note(root.path(), &task, "PRIVATE-SENTINEL", false);
    let task=call(root.path(),"task-material-link",json!({"taskID":task["id"],"expectedRevision":task["revision"],"operationID":uuid(),"material":{"kind":"folder","title":"Source folder","path":"/missing/never/opened/project","shared":true}})).unwrap();
    let before = c(root.path(), &task, false);
    let public = c(root.path(), &task, true);
    assert!(!public.to_string().contains("PRIVATE-SENTINEL"));
    assert!(public["task"]["materials"].as_array().unwrap().is_empty());
    assert_eq!(
        public["materials"][0]["path"],
        "/missing/never/opened/project"
    );
    let workspace = notes::list(root.path()).unwrap();
    assert!(
        serde_json::to_value(&workspace.task_workspaces[0].materials[0])
            .unwrap()
            .get("text")
            .is_none()
    );
    let mut note = workspace
        .notes
        .into_iter()
        .find(|n| n.kind == "note")
        .unwrap();
    note.text = "Edited private thought".into();
    notes::save_note(root.path(), note).unwrap();
    assert_ne!(
        before["contextVersion"],
        c(root.path(), &task, false)["contextVersion"]
    );
    assert_eq!(
        public["contextVersion"],
        c(root.path(), &task, true)["contextVersion"]
    );
    let m = task["materials"][0]["id"].clone();
    let task=call(root.path(),"task-material-link",json!({"taskID":task["id"],"expectedRevision":task["revision"],"operationID":uuid(),"material":{"id":m,"shared":true}})).unwrap();
    assert!(c(root.path(), &task, true)
        .to_string()
        .contains("Edited private thought"));
}
#[test]
fn claims_are_idempotent_concurrent_safe_and_revocation_blocks_replay() {
    let root = tempfile::tempdir().unwrap();
    enable(root.path());
    let t = create_task(root.path(), "Claim");
    let t = patch(root.path(), &t, json!({"agentAccess":{"enabled":true}}));
    let t = add_note(root.path(), &t, "PRIVATE-SENTINEL", false);
    let ctx = c(root.path(), &t, true);
    let args = json!({"taskID":t["id"],"expectedRevision":t["revision"],"expectedContextVersion":ctx["contextVersion"],"operationID":uuid(),"agentID":"Codex","agentOnly":true});
    let first = call(root.path(), "task-agent-claim", args.clone()).unwrap();
    assert_eq!(
        first,
        call(root.path(), "task-agent-claim", args.clone()).unwrap()
    );
    assert!(!first.to_string().contains("PRIVATE-SENTINEL"));
    let fresh = c(root.path(), &t, true);
    assert!(call(root.path(),"task-agent-claim",json!({"taskID":t["id"],"expectedRevision":first["revision"],"expectedContextVersion":fresh["contextVersion"],"operationID":uuid(),"agentID":"Other"})).is_err());
    let mut changed = args.clone();
    changed["agentID"] = json!("Different");
    assert!(call(root.path(), "task-agent-claim", changed).is_err());
    call(
        root.path(),
        "task-agent-settings",
        json!({"enabled":false,"expectedRevision":1,"operationID":uuid()}),
    )
    .unwrap();
    assert!(call(root.path(), "task-agent-claim", args).is_err());
    assert!(call(root.path(), "task-list", json!({"agentOnly":true})).is_err());
}
#[test]
fn report_snapshot_is_immutable_and_linked_note_edits_block_stale_completion() {
    let root = tempfile::tempdir().unwrap();
    enable(root.path());
    let t = create_task(root.path(), "Complete");
    let t = patch(root.path(), &t, json!({"agentAccess":{"enabled":true}}));
    let t = add_note(root.path(), &t, "Original requirement", true);
    let ctx = c(root.path(), &t, true);
    let claim=call(root.path(),"task-agent-claim",json!({"taskID":t["id"],"expectedRevision":t["revision"],"expectedContextVersion":ctx["contextVersion"],"operationID":uuid(),"agentID":"Codex"})).unwrap();
    let snapshot = claim["history"][0]["snapshot"].clone();
    assert!(snapshot.to_string().contains("Original requirement"));
    let no_report = json!({"taskID":t["id"],"expectedRevision":claim["revision"],"expectedContextVersion":c(root.path(),&t,true)["contextVersion"],"operationID":uuid(),"agentID":"Codex","claimID":claim["claim"]["id"]});
    assert!(call(root.path(), "task-agent-complete", no_report).is_err());
    let report=call(root.path(),"task-agent-report",json!({"taskID":t["id"],"expectedRevision":claim["revision"],"claimID":claim["claim"]["id"],"operationID":uuid(),"agentID":"Codex","text":"Verified","artifacts":[{"title":"Checks","kind":"checks","text":"12 checks"}]})).unwrap();
    let old_ctx = c(root.path(), &t, true);
    let mut note = notes::list(root.path())
        .unwrap()
        .notes
        .into_iter()
        .find(|n| n.kind == "note")
        .unwrap();
    note.text = "Changed requirement".into();
    notes::save_note(root.path(), note).unwrap();
    let mut complete = json!({"taskID":t["id"],"expectedRevision":report["revision"],"expectedContextVersion":old_ctx["contextVersion"],"operationID":uuid(),"agentID":"Codex","claimID":claim["claim"]["id"]});
    assert!(call(root.path(), "task-agent-complete", complete.clone()).is_err());
    let fresh = c(root.path(), &t, true);
    complete["expectedContextVersion"] = fresh["contextVersion"].clone();
    assert!(call(root.path(), "task-agent-complete", complete.clone()).is_err());
    let report2=call(root.path(),"task-agent-report",json!({"taskID":t["id"],"expectedRevision":report["revision"],"claimID":claim["claim"]["id"],"operationID":uuid(),"agentID":"Codex","text":"Rechecked changed requirement"})).unwrap();
    complete["expectedRevision"] = report2["revision"].clone();
    complete["expectedContextVersion"] = c(root.path(), &t, true)["contextVersion"].clone();
    let done = call(root.path(), "task-agent-complete", complete).unwrap();
    assert_eq!(done["status"], "done");
    assert_eq!(done["completed"], true);
    let stored = notes::list(root.path()).unwrap();
    let event = stored.task_workspaces[0]
        .history
        .iter()
        .find(|e| e.kind == "claimed")
        .unwrap();
    assert_eq!(event.snapshot.as_ref().unwrap(), &snapshot);
}
fn batch(root: &Path, items: &[Value], action: &str) -> Value {
    call(root,"task-batch-preview",json!({"action":action,"text":"Shared thought","items":items.iter().map(|t|json!({"taskID":t["id"],"expectedRevision":t["revision"],"expectedSourceFingerprint":t["sourceFingerprint"],"reason":"Explicit selection"})).collect::<Vec<_>>()})).unwrap()
}
#[test]
fn batch_subset_one_canonical_note_atomic_undo_and_duplicate_apply() {
    let root = tempfile::tempdir().unwrap();
    let a = create_task(root.path(), "A");
    let b = create_task(root.path(), "B");
    let a = patch(root.path(), &a, json!({"agentAccess":{"enabled":true}}));
    let p = batch(root.path(), &[a.clone(), b.clone()], "appendContext");
    let args = json!({"planID":p["planID"],"taskIDs":[a["id"],b["id"]],"text":"Edited shared thought","operationID":uuid()});
    let result = call(root.path(), "task-batch-apply", args.clone()).unwrap();
    assert_eq!(
        result,
        call(root.path(), "task-batch-apply", args.clone()).unwrap()
    );
    let ws = notes::list(root.path()).unwrap();
    assert_eq!(ws.notes.iter().filter(|n| n.kind == "note").count(), 1);
    assert_eq!(
        ws.task_workspaces[0].materials[0].note_id,
        ws.task_workspaces[1].materials[0].note_id
    );
    assert!(ws.task_workspaces[0].materials[0].shared);
    assert!(!ws.task_workspaces[1].materials[0].shared);
    let mut changed = args.clone();
    changed["text"] = json!("Changed retry");
    assert!(call(root.path(), "task-batch-apply", changed).is_err());
    call(
        root.path(),
        "task-operation-undo",
        json!({"operationID":args["operationID"]}),
    )
    .unwrap();
    assert_eq!(
        notes::list(root.path())
            .unwrap()
            .notes
            .iter()
            .filter(|n| n.kind == "note")
            .count(),
        0
    );
    assert!(get(root.path(), &a["id"])["materials"]
        .as_array()
        .unwrap()
        .is_empty());
    assert!(call(root.path(), "task-batch-apply", args).is_err());
    let a = get(root.path(), &a["id"]);
    let b = get(root.path(), &b["id"]);
    let p = batch(root.path(), &[a.clone(), b.clone()], "complete");
    let result = call(
        root.path(),
        "task-batch-apply",
        json!({"planID":p["planID"],"taskIDs":[a["id"]],"operationID":uuid()}),
    )
    .unwrap();
    assert_eq!(result["tasks"].as_array().unwrap().len(), 1);
    assert_eq!(get(root.path(), &b["id"])["completed"], false);
}
#[test]
fn stale_batch_context_and_late_undo_never_erase_new_edits() {
    let root = tempfile::tempdir().unwrap();
    let a = create_task(root.path(), "A");
    let a = add_note(root.path(), &a, "Before", false);
    let p = batch(root.path(), &[a.clone()], "complete");
    let mut note = notes::list(root.path())
        .unwrap()
        .notes
        .into_iter()
        .find(|n| n.kind == "note")
        .unwrap();
    note.text = "After".into();
    notes::save_note(root.path(), note).unwrap();
    assert!(call(
        root.path(),
        "task-batch-apply",
        json!({"planID":p["planID"],"taskIDs":[a["id"]],"operationID":uuid()})
    )
    .is_err());
    assert_eq!(get(root.path(), &a["id"])["completed"], false);
    let args = json!({"taskID":a["id"],"expectedRevision":a["revision"],"operationID":uuid(),"patch":{"status":"blocked"}});
    let b = call(root.path(), "task-details-update", args.clone()).unwrap();
    patch(root.path(), &b, json!({"title":"Later edit"}));
    assert!(call(
        root.path(),
        "task-operation-undo",
        json!({"operationID":args["operationID"]})
    )
    .is_err());
    assert_eq!(get(root.path(), &a["id"])["title"], "Later edit");
}
#[test]
fn operation_retention_never_reexecutes_old_create_or_blocks_new_actions() {
    let root = tempfile::tempdir().unwrap();
    let first = json!({"title":"Retained","operationID":uuid()});
    let mut t = call(root.path(), "task-create", first.clone()).unwrap();
    for i in 0..FULL_OPERATIONS + 5 {
        t = patch(root.path(), &t, json!({"title":format!("Edit {i}")}));
    }
    assert!(call(root.path(), "task-create", first)
        .unwrap_err()
        .to_string()
        .contains("Срок безопасного повтора"));
    assert_eq!(
        notes::list(root.path())
            .unwrap()
            .notes
            .iter()
            .filter(|n| n.kind == "task")
            .count(),
        1
    );
    let t = patch(root.path(), &t, json!({"status":"blocked"}));
    assert_eq!(t["status"], "blocked");
    let ws = notes::list(root.path()).unwrap();
    assert!(ws.task_operations[0]["expired"].as_bool().unwrap());
    assert!(ws.task_operations[0].get("before").is_none());
}
#[test]
fn virtual_summary_tasks_materialize_once_and_old_summary_alias_survives_regeneration() {
    let root = tempfile::tempdir().unwrap();
    let dir = storage::meeting_directory(root.path(), "meeting-one").unwrap();
    std::fs::create_dir_all(&dir).unwrap();
    storage::atomic_json(&dir.join("meta.json"),&json!({"id":"meeting-one","title":"Source","createdAt":1.0,"source":"source.mp3","completedTasks":[]})).unwrap();
    let item = json!({"kind":"action","text":"Original task","owner":"Anna","due":"tomorrow","segmentIDs":[7]});
    storage::atomic_json(&dir.join("summary.json"), &json!({"items":[item]})).unwrap();
    storage::atomic_json(
        &dir.join("transcript.json"),
        &json!({"segments":[{"id":7,"start":1.0,"end":2.0,"text":"Original task"}]}),
    )
    .unwrap();
    let id = format!("summary:meeting-one:{}", notes::task_signature(&item));
    let d = get(root.path(), &json!(id));
    assert_eq!(d["virtual"], true);
    let updated = patch(root.path(), &d, json!({"status":"doing"}));
    assert_eq!(updated["virtual"], false);
    assert_eq!(updated["materials"][0]["kind"], "meeting");
    storage::atomic_json(&dir.join("summary.json"), &json!({"items":[]})).unwrap();
    assert_eq!(get(root.path(), &json!(id))["id"], updated["id"]);
    assert_eq!(notes::list(root.path()).unwrap().notes.len(), 1);
}
#[test]
fn virtual_mutations_require_fingerprint_and_reject_changed_owner_or_replaced_item() {
    let root = tempfile::tempdir().unwrap();
    let dir = storage::meeting_directory(root.path(), "cas-source").unwrap();
    std::fs::create_dir_all(&dir).unwrap();
    storage::atomic_json(&dir.join("meta.json"),&json!({"id":"cas-source","title":"Source","createdAt":1.0,"source":"source.mp3","completedTasks":[]})).unwrap();
    let item = json!({"kind":"action","text":"Send agreement","owner":"Anna","due":"tomorrow","segmentIDs":[7]});
    storage::atomic_json(&dir.join("summary.json"), &json!({"items":[item]})).unwrap();
    let id = format!("summary:cas-source:{}", notes::task_signature(&item));
    let d = get(root.path(), &json!(id));
    let missing =
        json!({"taskID":id,"expectedRevision":0,"operationID":uuid(),"patch":{"status":"doing"}});
    assert!(call(root.path(), "task-details-update", missing).is_err());
    let changed = json!({"kind":"action","text":"Send agreement","owner":"Boris","due":"Friday","segmentIDs":[7]});
    storage::atomic_json(&dir.join("summary.json"), &json!({"items":[changed]})).unwrap();
    let stale = json!({"taskID":id,"expectedRevision":0,"expectedSourceFingerprint":d["sourceFingerprint"],"operationID":uuid(),"patch":{"status":"doing"}});
    assert!(call(root.path(), "task-details-update", stale.clone()).is_err());
    assert!(notes::list(root.path()).unwrap().notes.is_empty());
    storage::atomic_json(&dir.join("summary.json"),&json!({"items":[{"kind":"action","text":"Different task at index zero","owner":"Boris","due":"Friday","segmentIDs":[8]},changed]})).unwrap();
    let fresh = get(root.path(), &json!(id));
    let mut request = stale;
    request["expectedSourceFingerprint"] = fresh["sourceFingerprint"].clone();
    let accepted = call(root.path(), "task-details-update", request).unwrap();
    assert_eq!(accepted["owner"], "Boris");
    assert_eq!(accepted["text"], "Send agreement");
}
#[test]
fn task_list_is_a_bounded_summary_and_selected_get_loads_materials() {
    let root = tempfile::tempdir().unwrap();
    let task = create_task(root.path(), "Light list");
    let long = "source detail ".repeat(4000);
    let task = add_note(root.path(), &task, &long, false);
    let listing = call(root.path(), "task-list", json!({})).unwrap();
    assert_eq!(listing["tasks"][0]["materialCount"], 1);
    assert!(listing["tasks"][0]["materials"]
        .as_array()
        .unwrap()
        .is_empty());
    assert!(listing["tasks"][0]["history"]
        .as_array()
        .unwrap()
        .is_empty());
    assert!(listing.to_string().len() < 5000);
    let loaded = get(root.path(), &task["id"]);
    assert_eq!(loaded["materials"][0]["text"].as_str(), Some(long.trim()));
    let full = call(root.path(), "task-list", json!({"includeDetails":true})).unwrap();
    assert_eq!(
        full["tasks"][0]["materials"][0]["text"].as_str(),
        Some(long.trim())
    );
}
#[test]
fn operation_inspection_only_recovers_an_already_committed_matching_batch() {
    let root = tempfile::tempdir().unwrap();
    let t = create_task(root.path(), "Recovery");
    let p = batch(root.path(), &[t.clone()], "appendContext");
    let operation = uuid();
    assert_eq!(
        call(
            root.path(),
            "task-operation-inspect",
            json!({"operationID":operation,"planID":p["planID"]})
        )
        .unwrap()["committed"],
        false
    );
    assert!(get(root.path(), &t["id"])["materials"]
        .as_array()
        .unwrap()
        .is_empty());
    let input = json!({"planID":p["planID"],"taskIDs":[t["id"]],"text":"Edited before commit","operationID":operation});
    let result = call(root.path(), "task-batch-apply", input).unwrap();
    let inspected = call(
        root.path(),
        "task-operation-inspect",
        json!({"operationID":operation,"planID":p["planID"]}),
    )
    .unwrap();
    assert_eq!(inspected["result"], result);
    assert_eq!(inspected["request"]["text"], "Edited before commit");
    assert_eq!(inspected["undone"], false);
    assert!(call(
        root.path(),
        "task-operation-inspect",
        json!({"operationID":operation,"planID":"unrelated-plan"})
    )
    .is_err());
    let create_receipt =
        notes::list(root.path()).unwrap().task_operations[0]["operationID"].clone();
    assert!(call(
        root.path(),
        "task-operation-inspect",
        json!({"operationID":create_receipt,"planID":p["planID"]})
    )
    .is_err());
}
#[test]
fn two_simultaneous_agents_cannot_claim_the_same_task() {
    let root = tempfile::tempdir().unwrap();
    enable(root.path());
    let t = create_task(root.path(), "Concurrent claim");
    let t = patch(root.path(), &t, json!({"agentAccess":{"enabled":true}}));
    let ctx = c(root.path(), &t, true);
    let gate = std::sync::Arc::new(std::sync::Barrier::new(2));
    let mut joins = Vec::new();
    for name in ["Agent One", "Agent Two"] {
        let path = root.path().to_owned();
        let gate = gate.clone();
        let task = t.clone();
        let ctx = ctx.clone();
        joins.push(std::thread::spawn(move||{gate.wait();call(&path,"task-agent-claim",json!({"taskID":task["id"],"expectedRevision":task["revision"],"expectedContextVersion":ctx["contextVersion"],"operationID":uuid(),"agentID":name})).is_ok()}));
    }
    let successes = joins
        .into_iter()
        .map(|j| usize::from(j.join().unwrap()))
        .sum::<usize>();
    assert_eq!(successes, 1);
    let ws = notes::list(root.path()).unwrap();
    assert_eq!(
        ws.task_workspaces[0]
            .history
            .iter()
            .filter(|e| e.kind == "claimed")
            .count(),
        1
    );
}

#[test]
fn replay_uses_current_material_grants_after_note_and_folder_revocation() {
    let root = tempfile::tempdir().unwrap();
    enable(root.path());
    let t = create_task(root.path(), "Replay access");
    let mut t = patch(root.path(), &t, json!({"agentAccess":{"enabled":true}}));
    for material in [
        json!({"kind":"note","title":"REVOKED-NOTE-TITLE","text":"REVOKED-NOTE-BODY","shared":true}),
        json!({"kind":"folder","title":"REVOKED-FOLDER-TITLE","path":"/REVOKED-FOLDER-PATH","shared":true}),
        json!({"kind":"note","title":"Permitted thought","text":"PERMITTED-CONTEXT","shared":true}),
    ] {
        t=call(root.path(),"task-material-link",json!({"taskID":t["id"],"expectedRevision":t["revision"],"operationID":uuid(),"material":material})).unwrap();
    }
    let context = c(root.path(), &t, true);
    let claim_args = json!({"taskID":t["id"],"expectedRevision":t["revision"],"expectedContextVersion":context["contextVersion"],"operationID":uuid(),"agentID":"Codex","agentOnly":true});
    let claim = call(root.path(), "task-agent-claim", claim_args.clone()).unwrap();
    let report_args = json!({"taskID":t["id"],"expectedRevision":claim["revision"],"claimID":claim["claim"]["id"],"operationID":uuid(),"agentID":"Codex","agentOnly":true,"text":"Checks completed","artifacts":[{"title":"Checks","kind":"checks","text":"Passed"}]});
    let report = call(root.path(), "task-agent-report", report_args.clone()).unwrap();
    assert!(report.to_string().contains("REVOKED-NOTE-BODY"));
    assert!(report.to_string().contains("/REVOKED-FOLDER-PATH"));
    t = get(root.path(), &t["id"]);
    for material_id in [
        t["materials"][0]["id"].clone(),
        t["materials"][1]["id"].clone(),
    ] {
        t=call(root.path(),"task-material-link",json!({"taskID":t["id"],"expectedRevision":t["revision"],"operationID":uuid(),"material":{"id":material_id,"shared":false}})).unwrap();
    }
    assert_eq!(t["agentAccess"]["enabled"], true);
    for args in [claim_args, report_args] {
        let replayed = call(
            root.path(),
            args["command"]
                .as_str()
                .unwrap_or(if args.get("claimID").is_some() {
                    "task-agent-report"
                } else {
                    "task-agent-claim"
                }),
            args.clone(),
        )
        .unwrap();
        let serial = replayed.to_string();
        for forbidden in [
            "REVOKED-NOTE-TITLE",
            "REVOKED-NOTE-BODY",
            "REVOKED-FOLDER-TITLE",
            "REVOKED-FOLDER-PATH",
            "\"snapshot\"",
        ] {
            assert!(
                !serial.contains(forbidden),
                "Revoked material leaked through frozen receipt"
            );
        }
        assert!(serial.contains("PERMITTED-CONTEXT"));
    }
    let read = call(
        root.path(),
        "task-get",
        json!({"taskID":t["id"],"agentOnly":true}),
    )
    .unwrap();
    assert!(!read.to_string().contains("REVOKED-NOTE-BODY"));
}
#[test]
fn legacy_manual_completion_blocks_all_fresh_agent_mutations() {
    let root = tempfile::tempdir().unwrap();
    enable(root.path());
    let t = create_task(root.path(), "Manual completion");
    let t = patch(root.path(), &t, json!({"agentAccess":{"enabled":true}}));
    let ctx = c(root.path(), &t, true);
    let claimed=call(root.path(),"task-agent-claim",json!({"taskID":t["id"],"expectedRevision":t["revision"],"expectedContextVersion":ctx["contextVersion"],"operationID":uuid(),"agentID":"Codex"})).unwrap();
    let mut note = notes::list(root.path())
        .unwrap()
        .notes
        .into_iter()
        .find(|n| n.kind == "task")
        .unwrap();
    note.completed = true;
    notes::save_note(root.path(), note).unwrap();
    let current = get(root.path(), &t["id"]);
    let fresh = c(root.path(), &t, true);
    let before = std::fs::read(
        notes::directory(root.path())
            .unwrap()
            .join("workspace.json"),
    )
    .unwrap();
    for command in [
        "task-agent-progress",
        "task-agent-report",
        "task-agent-release",
        "task-agent-complete",
    ] {
        let error=call(root.path(),command,json!({"taskID":t["id"],"expectedRevision":current["revision"],"expectedContextVersion":fresh["contextVersion"],"operationID":uuid(),"agentID":"Codex","claimID":claimed["claim"]["id"],"text":"Must not revive the task"})).unwrap_err();
        assert!(error.to_string().contains("не находится в работе"));
    }
    let after = std::fs::read(
        notes::directory(root.path())
            .unwrap()
            .join("workspace.json"),
    )
    .unwrap();
    assert_eq!(before, after);
    assert_eq!(get(root.path(), &t["id"])["status"], "done");
}
#[test]
fn native_metadata_has_no_implicit_cap_and_mcp_pagination_has_no_duplicates() {
    let root = tempfile::tempdir().unwrap();
    let mut workspace = notes::list(root.path()).unwrap();
    workspace.task_integration = TaskIntegration {
        enabled: true,
        revision: 1,
    };
    for i in 0..250 {
        let id = format!("metadata-{i}");
        let note:CapturedNote=serde_json::from_value(json!({"id":id,"kind":"task","title":format!("Task {i}"),"text":"Metadata fixture","owner":"User","due":"","revision":1,"createdAt":i as f64,"updatedAt":i as f64})).unwrap();
        workspace.notes.push(note);
        workspace.task_workspaces.push(TaskRecord {
            note_id: id,
            status: if i % 2 == 0 { "doing" } else { "blocked" }.into(),
            source: if i % 2 == 0 { "manual" } else { "google" }.into(),
            project: format!("Project {}", i % 3),
            agent_access: AgentAccess { enabled: true },
            materials: vec![TaskMaterial {
                id: format!("material-{i}"),
                kind: "folder".into(),
                title: "Reference only".into(),
                path: Some(format!("/MUST-NOT-BE-READ/{i}")),
                shared: true,
                created_at: 0.0,
                ..Default::default()
            }],
            ..Default::default()
        });
    }
    persist(root.path(), &workspace).unwrap();
    let native = call(root.path(), "task-list", json!({})).unwrap();
    let rows = native["tasks"].as_array().unwrap();
    assert_eq!(rows.len(), 250);
    assert_eq!(native["truncated"], false);
    assert!(rows
        .iter()
        .all(|t| t["materials"].as_array().unwrap().is_empty()
            && t["history"].as_array().unwrap().is_empty()
            && t["materialCount"] == 1
            && t["status"] != "todo"
            && t["source"] != "local"
            && t["project"].as_str().is_some_and(|p| !p.is_empty())));
    let limited = call(root.path(), "task-list", json!({"limit":25})).unwrap();
    assert_eq!(limited["tasks"].as_array().unwrap().len(), 25);
    assert_eq!(limited["nextOffset"], 25);
    let first = call(root.path(), "task-list", json!({"agentOnly":true})).unwrap();
    assert_eq!(first["tasks"].as_array().unwrap().len(), 200);
    assert_eq!(first["nextOffset"], 200);
    let second = call(
        root.path(),
        "task-list",
        json!({"agentOnly":true,"offset":first["nextOffset"],"limit":200}),
    )
    .unwrap();
    assert_eq!(second["tasks"].as_array().unwrap().len(), 50);
    assert!(second["nextOffset"].is_null());
    assert_eq!(second["truncated"], false);
    assert_eq!(second["total"], 250);
    let ids = first["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .chain(second["tasks"].as_array().unwrap())
        .map(|t| t["id"].as_str().unwrap())
        .collect::<HashSet<_>>();
    assert_eq!(ids.len(), 250);
    assert!(call(
        root.path(),
        "task-list",
        json!({"agentOnly":true,"offset":-1})
    )
    .is_err());
    assert!(call(
        root.path(),
        "task-list",
        json!({"agentOnly":true,"limit":501})
    )
    .is_err());
}

#[test]
fn trashed_and_purged_source_alias_cannot_recreate_a_task() {
    let root=tempfile::tempdir().unwrap();
    let dir=storage::meeting_directory(root.path(),"deleted-source").unwrap();std::fs::create_dir_all(&dir).unwrap();
    storage::atomic_json(&dir.join("meta.json"),&json!({"id":"deleted-source","title":"Sync","createdAt":1.0,"source":"source.mp3"})).unwrap();
    let item=json!({"kind":"action","text":"Follow up on launch","owner":"","due":"","segmentIDs":[7]});
    storage::atomic_json(&dir.join("summary.json"),&json!({"items":[item]})).unwrap();
    let alias=format!("summary:deleted-source:{}",notes::task_signature(&item));
    let original=get(root.path(),&json!(alias));
    let materialized=patch(root.path(),&original,json!({"status":"doing"}));
    let note=notes::list(root.path()).unwrap().notes.into_iter().find(|n|format!("manual:{}",n.id)==materialized["id"].as_str().unwrap()).unwrap();
    let deleted=notes::trash_note(root.path(),&note.id,note.revision,false).unwrap();
    assert!(call(root.path(),"task-get",json!({"taskID":alias})).is_err());
    assert!(call(root.path(),"task-context",json!({"taskID":alias})).is_err());
    assert!(call(root.path(),"task-details-update",json!({"taskID":alias,"expectedRevision":0,"expectedSourceFingerprint":original["sourceFingerprint"],"operationID":uuid(),"patch":{"status":"doing"}})).is_err());
    assert_eq!(notes::list(root.path()).unwrap().notes.len(),1);
    let restored=notes::trash_note(root.path(),&note.id,deleted.revision,true).unwrap();
    assert_eq!(get(root.path(),&json!(alias))["id"],materialized["id"]);
    notes::delete_note(root.path(),&note.id,restored.revision).unwrap();
    assert!(call(root.path(),"task-get",json!({"taskID":alias})).is_err());
    assert!(call(root.path(),"task-context",json!({"taskID":alias})).is_err());
    assert!(call(root.path(),"task-details-update",json!({"taskID":alias,"expectedRevision":0,"expectedSourceFingerprint":original["sourceFingerprint"],"operationID":uuid(),"patch":{"status":"doing"}})).is_err());
    assert_eq!(notes::list(root.path()).unwrap().notes.len(),1);
    assert!(call(root.path(),"task-list",json!({})).unwrap()["tasks"].as_array().unwrap().is_empty());
}


#[test]
fn opted_in_mutations_enforce_current_folder_policy_without_blocking_manual_edits() {
    let root=tempfile::tempdir().unwrap();
    let task=create_task(root.path(),"Preserved task");
    crate::storage::atomic_json(&root.path().join("settings.json"),&json!({"features":{"tasks":true}})).unwrap();
    let folder=crate::folders::save(root.path(),crate::folders::Folder{id:"work".into(),name:"Work".into(),revision:0,overrides:json!({"features":{"tasks":false}})}).unwrap();
    let mut note=notes::list(root.path()).unwrap().notes.into_iter().find(|n|Some(n.id.as_str())==task["id"].as_str().map(canonical_id)).unwrap();
    note.folder_id=Some(folder.id.clone());let note=notes::save_note(root.path(),note).unwrap();
    let current=get(root.path(),&task["id"]);
    let request=json!({"taskID":task["id"],"expectedRevision":current["revision"],"expectedSourceFingerprint":current["sourceFingerprint"],"operationID":uuid(),"patch":{"status":"doing"},"requireTaskFeature":true});
    let before=crate::workspace_repository::snapshot(root.path()).unwrap();
    assert!(call(root.path(),"task-details-update",request.clone()).is_err());
    assert_eq!(crate::workspace_repository::snapshot(root.path()).unwrap().fingerprint,before.fingerprint);
    assert_eq!(notes::load_note_snapshot(root.path(),&note.id).unwrap().text,note.text);
    // A manual UI edit remains allowed when the optional module is hidden.
    let mut manual=request.clone();manual["requireTaskFeature"]=json!(false);
    let changed=call(root.path(),"task-details-update",manual).unwrap();assert_eq!(changed["status"],"doing");
    let mut enabled=folder;enabled.overrides=json!({"features":{"tasks":true}});crate::folders::save(root.path(),enabled).unwrap();
    crate::storage::atomic_json(&root.path().join("settings.json"),&json!({"features":{"tasks":false}})).unwrap();
    let current=get(root.path(),&task["id"]);
    let request=json!({"taskID":task["id"],"expectedRevision":current["revision"],"expectedSourceFingerprint":current["sourceFingerprint"],"operationID":uuid(),"patch":{"status":"blocked"},"requireTaskFeature":true});
    assert_eq!(call(root.path(),"task-details-update",request).unwrap()["status"],"blocked");
}

#[test]
fn creating_a_task_in_a_folder_preserves_its_processing_scope() {
    let root=tempfile::tempdir().unwrap();
    let folder=crate::folders::save(root.path(),crate::folders::Folder{id:"english".into(),name:"Английский".into(),revision:0,overrides:json!({"features":{"tasks":true}})}).unwrap();
    let task=call(root.path(),"task-create",json!({"title":"Повторить слова","text":"Контекст","folderID":folder.id,"operationID":uuid()})).unwrap();
    let note=notes::load_note_snapshot(root.path(),canonical_id(task["id"].as_str().unwrap())).unwrap();
    assert_eq!(note.folder_id.as_deref(),Some("english"));assert_eq!(note.folder,"Английский");
    assert!(crate::ai::live_features_for_input(root.path(),&json!({"taskID":task["id"]})).unwrap().tasks);
    let before=crate::workspace_repository::snapshot(root.path()).unwrap();
    assert!(call(root.path(),"task-create",json!({"title":"Draft","folderID":"missing","operationID":uuid()})).is_err());
    assert_eq!(crate::workspace_repository::snapshot(root.path()).unwrap().fingerprint,before.fingerprint);
}

#[test]
fn adding_transport_feature_guard_preserves_existing_receipt_replay() {
    let root=tempfile::tempdir().unwrap();
    crate::storage::atomic_json(&root.path().join("settings.json"),&json!({"features":{"tasks":true}})).unwrap();
    let request=json!({"title":"Existing task","operationID":uuid()});
    let created=call(root.path(),"task-create",request.clone()).unwrap();
    let mut guarded=request;guarded["requireTaskFeature"]=json!(true);
    assert_eq!(call(root.path(),"task-create",guarded.clone()).unwrap(),created);
    assert_eq!(notes::list(root.path()).unwrap().notes.len(),1);
    crate::storage::atomic_json(&root.path().join("settings.json"),&json!({"features":{"tasks":false}})).unwrap();
    assert!(call(root.path(),"task-create",guarded).is_err());
    assert_eq!(notes::list(root.path()).unwrap().notes.len(),1);
}

#[test]
fn board_drop_scope_guard_rejects_moved_virtual_tasks_and_keeps_legacy_requests() {
    let root = tempfile::tempdir().unwrap();
    storage::atomic_json(&root.path().join("settings.json"), &json!({"features":{"tasks":true}})).unwrap();
    let folder = crate::folders::save(root.path(), crate::folders::Folder {
        id: "board-work".into(), name: "Work".into(), revision: 0,
        overrides: json!({"features":{"tasks":true}}),
    }).unwrap();
    let unassigned = create_task(root.path(), "Unassigned task");
    let accepted_null = call(root.path(), "task-details-update", json!({
        "taskID":unassigned["id"], "expectedRevision":unassigned["revision"],
        "operationID":uuid(), "patch":{"status":"doing"}, "requireTaskFeature":true,
        "expectedTaskFolderID":null
    })).unwrap();
    assert_eq!(accepted_null["status"], "doing");

    let dir = storage::meeting_directory(root.path(), "board-source").unwrap();
    std::fs::create_dir_all(&dir).unwrap();
    storage::atomic_json(&dir.join("meta.json"), &json!({"id":"board-source","title":"Source","createdAt":1.0,"source":"synthetic.mp3","completedTasks":[]})).unwrap();
    let item = json!({"kind":"action","text":"Move source folder","owner":"Anna","due":"","segmentIDs":[1]});
    storage::atomic_json(&dir.join("summary.json"), &json!({"items":[item]})).unwrap();
    let id = format!("summary:board-source:{}", notes::task_signature(&item));
    let captured = get(root.path(), &json!(id));
    assert_eq!(captured["virtual"], true);
    let request = json!({"taskID":id,"expectedRevision":captured["revision"],
        "expectedSourceFingerprint":captured["sourceFingerprint"],"operationID":uuid(),
        "patch":{"status":"doing"},"requireTaskFeature":true,"expectedTaskFolderID":null});
    crate::folders::assign_meeting(root.path(), "board-source", Some(&folder.id), 0).unwrap();
    let moved = get(root.path(), &json!(id));
    assert_eq!(moved["revision"], captured["revision"]);
    assert_eq!(moved["sourceFingerprint"], captured["sourceFingerprint"]);
    let before = crate::workspace_repository::snapshot(root.path()).unwrap();
    assert!(call(root.path(), "task-details-update", request.clone()).unwrap_err().to_string().contains("Папка задачи изменилась"));
    assert_eq!(crate::workspace_repository::snapshot(root.path()).unwrap().fingerprint, before.fingerprint);
    assert_eq!(get(root.path(), &json!(id))["virtual"], true);
    // Older UI/MCP callers omit the optional captured-folder guard.
    let mut legacy = request.clone();
    legacy.as_object_mut().unwrap().remove("expectedTaskFolderID");
    legacy["operationID"] = json!(uuid());
    let accepted = call(root.path(), "task-details-update", legacy).unwrap();
    assert_eq!(accepted["status"], "doing");
    let matching = json!({"taskID":accepted["id"],"expectedRevision":accepted["revision"],
        "operationID":uuid(),"patch":{"status":"blocked"},"requireTaskFeature":true,
        "expectedTaskFolderID":folder.id});
    assert_eq!(call(root.path(), "task-details-update", matching).unwrap()["status"], "blocked");
}
