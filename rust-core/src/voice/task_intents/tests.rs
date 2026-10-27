use super::*;

fn proposal(action: &str, text: &str) -> Proposal {
    Proposal {
        action: action.into(),
        query: "пилот".into(),
        title: String::new(),
        text: text.into(),
        due: String::new(),
        owner: String::new(),
        set_due: false,
        set_owner: false,
        set_completed: false,
        completed: false,
        cards: vec![],
    }
}
fn task(root: &Path, title: &str, project: &str, completed: bool) -> Value {
    let mut note = empty_note("task", title, title, None).unwrap();
    note.revision = 0;
    note.completed = completed;
    let note = notes::save_note(root, note).unwrap();
    let mut workspace = notes::list(root).unwrap();
    workspace
        .task_workspaces
        .push(crate::task_workspace::TaskRecord {
            note_id: note.id.clone(),
            status: if completed { "done" } else { "todo" }.into(),
            source: "local".into(),
            project: project.into(),
            ..Default::default()
        });
    notes::persist(&notes::directory(root).unwrap(), &workspace).unwrap();
    task_snapshot(root, &format!("manual:{}", note.id)).unwrap()
}
fn ranked(root: &Path, action: &str, text: &str, candidates: &[Value]) -> Value {
    prepare_ranked(
        root,
        &json!({"text":"Дополни связанные задачи про пилот","projectID":"Пилот"}),
        &proposal(action, text),
        candidates,
        Reranking {
            matches: candidates
                .iter()
                .map(|task| RankedTask {
                    id: task_key(task).into(),
                    reason: "Обсуждение того же пилота".into(),
                })
                .collect(),
            clarification: String::new(),
        },
    )
    .unwrap()
}
fn request(plan: &Value, ids: &[&str], text: &str) -> Value {
    json!({"planID":plan["planID"],"operationID":plan["operationID"],"confirmed":true,"selectedTargetIDs":ids,"text":text})
}
fn context_string(root: &Path, task: &Value) -> String {
    domain(root, "task-context", json!({"taskID":task["id"]}))
        .unwrap()
        .to_string()
}

#[test]
fn navigation_is_typed_and_does_not_materialize_or_modify_tasks() {
    let root = tempfile::tempdir().unwrap();
    let task = task(root.path(), "Пилот: проверить договор", "Пилот", false);
    let before = notes::list(root.path()).unwrap();
    let plan = ranked(root.path(), "openTask", "", &[task.clone()]);
    assert_eq!(plan["reviewRequired"], false);
    let result = apply(
        root.path(),
        &json!({"planID":plan["planID"],"operationID":plan["operationID"]}),
    )
    .unwrap();
    assert_eq!(result["target"]["kind"], "task");
    assert_eq!(result["target"]["id"], task["id"]);
    assert_eq!(result["canUndo"], false);
    let after = notes::list(root.path()).unwrap();
    assert_eq!(
        serde_json::to_value(before.notes).unwrap(),
        serde_json::to_value(after.notes).unwrap()
    );
    assert_eq!(before.task_workspaces.len(), after.task_workspaces.len());
    assert!(after.task_operations.is_empty());
    assert!(undo(root.path(), &json!({"operationID":plan["operationID"]})).is_err());
}
#[test]
fn batch_preview_requires_confirmation_allows_only_subset_and_edited_text_with_idempotent_undo() {
    let root = tempfile::tempdir().unwrap();
    let a = task(root.path(), "Пилот: договор", "Пилот", false);
    let b = task(root.path(), "Пилот: оплата", "Пилот", false);
    let complete = task(root.path(), "Пилот: первый созвон", "Пилот", true);
    let outside = task(root.path(), "Другой проект", "Личное", false);
    let plan = ranked(
        root.path(),
        "appendTaskContexts",
        "Проверить цену",
        &[a.clone(), b.clone(), complete.clone()],
    );
    assert_eq!(plan["status"], "ready");
    assert_eq!(plan["reviewRequired"], true);
    assert_eq!(plan["candidates"][2]["selected"], false);
    assert!(apply(
        root.path(),
        &json!({"planID":plan["planID"],"operationID":plan["operationID"]})
    )
    .is_err());
    let mut forged = request(
        &plan,
        &[task_key(&a), task_key(&outside)],
        "Проверить оплату",
    );
    assert!(apply(root.path(), &forged).is_err());
    forged["selectedTargetIDs"] = json!([task_key(&a), task_key(&a)]);
    assert!(apply(root.path(), &forged).is_err());
    let input = request(&plan, &[task_key(&a)], "Уточнить стоимость без НДС");
    let result = apply(root.path(), &input).unwrap();
    assert!(context_string(root.path(), &a).contains("Уточнить стоимость без НДС"));
    assert!(!context_string(root.path(), &a).contains("Проверить цену"));
    assert!(!context_string(root.path(), &b).contains("Уточнить стоимость без НДС"));
    assert!(!context_string(root.path(), &complete).contains("Уточнить стоимость без НДС"));
    assert_eq!(apply(root.path(), &input).unwrap(), result);
    assert!(apply(
        root.path(),
        &request(&plan, &[task_key(&b)], "Уточнить стоимость без НДС")
    )
    .is_err());
    assert!(apply(
        root.path(),
        &request(&plan, &[task_key(&a)], "Другое дополнение")
    )
    .is_err());
    let input = json!({"operationID":plan["operationID"]});
    assert_eq!(undo(root.path(), &input).unwrap()["undone"], true);
    assert_eq!(undo(root.path(), &input).unwrap()["undone"], true);
    assert!(!context_string(root.path(), &a).contains("Уточнить стоимость без НДС"));
    assert_eq!(
        apply(
            root.path(),
            &request(&plan, &[task_key(&a)], "Уточнить стоимость без НДС")
        )
        .unwrap()["undone"],
        true
    );
}
#[test]
fn stale_batch_conflict_is_atomic_and_later_edit_prevents_unsafe_undo() {
    let root = tempfile::tempdir().unwrap();
    let a = task(root.path(), "Пилот: договор", "Пилот", false);
    let b = task(root.path(), "Пилот: оплата", "Пилот", false);
    let plan = ranked(
        root.path(),
        "appendTaskContexts",
        "Уточнить бюджет",
        &[a.clone(), b.clone()],
    );
    let id = task_key(&b).strip_prefix("manual:").unwrap();
    let mut changed = notes::load_note_snapshot(root.path(), id).unwrap();
    changed.text.push_str(" — уточнили сроки");
    notes::save_note(root.path(), changed).unwrap();
    assert!(apply(
        root.path(),
        &request(&plan, &[task_key(&a), task_key(&b)], "Уточнить бюджет")
    )
    .is_err());
    assert!(!context_string(root.path(), &a).contains("Уточнить бюджет"));
    let a = task_snapshot(root.path(), task_key(&a)).unwrap();
    let b = task_snapshot(root.path(), task_key(&b)).unwrap();
    let plan = ranked(
        root.path(),
        "appendTaskContexts",
        "Уточнить бюджет",
        &[a.clone(), b.clone()],
    );
    apply(
        root.path(),
        &request(&plan, &[task_key(&a), task_key(&b)], "Уточнить бюджет"),
    )
    .unwrap();
    let id = task_key(&a).strip_prefix("manual:").unwrap();
    let mut changed = notes::load_note_snapshot(root.path(), id).unwrap();
    changed.owner = "Савва".into();
    notes::save_note(root.path(), changed).unwrap();
    assert!(undo(root.path(), &json!({"operationID":plan["operationID"]})).is_err());
    assert!(context_string(root.path(), &b).contains("Уточнить бюджет"));
}
#[test]
fn ambiguous_completion_never_applies_without_single_choice_and_confirmation() {
    let root = tempfile::tempdir().unwrap();
    let a = task(root.path(), "Пилот: договор", "Пилот", false);
    let b = task(root.path(), "Пилот: оплата", "Пилот", false);
    let plan = ranked(root.path(), "completeTask", "", &[a.clone(), b.clone()]);
    assert_eq!(plan["status"], "choose");
    assert!(apply(root.path(), &request(&plan, &[task_key(&a)], "")).is_err());
    assert!(choose(
        root.path(),
        &json!({"planID":plan["planID"],"targetID":"manual:invented"})
    )
    .is_err());
    let plan = choose(
        root.path(),
        &json!({"planID":plan["planID"],"targetID":a["id"]}),
    )
    .unwrap();
    assert_eq!(plan["reviewRequired"], true);
    let mut input = request(&plan, &[task_key(&a)], "");
    input["confirmed"] = json!(false);
    assert!(apply(root.path(), &input).is_err());
    apply(root.path(), &request(&plan, &[task_key(&a)], "")).unwrap();
    assert_eq!(
        task_snapshot(root.path(), task_key(&a)).unwrap()["completed"],
        true
    );
    assert_eq!(
        task_snapshot(root.path(), task_key(&b)).unwrap()["completed"],
        false
    );
    let a = task_snapshot(root.path(), task_key(&a)).unwrap();
    let reopen = ranked(root.path(), "reopenTask", "", &[a.clone()]);
    assert_eq!(reopen["candidates"][0]["selected"], false);
    apply(root.path(), &request(&reopen, &[task_key(&a)], "")).unwrap();
    assert_eq!(
        task_snapshot(root.path(), task_key(&a)).unwrap()["completed"],
        false
    );
}
#[test]
fn model_cannot_invent_targets_cross_scope_or_duplicate_ids() {
    let root = tempfile::tempdir().unwrap();
    let a = task(root.path(), "Пилот: договор", "Пилот", false);
    let outside = task(root.path(), "Личное", "Личное", false);
    let proposal = proposal("appendTaskContexts", "Проверить цену");
    let input = json!({"projectID":"Пилот"});
    let ranked = |id: &str| RankedTask {
        id: id.into(),
        reason: "Есть связь с темой".into(),
    };
    assert!(prepare_ranked(
        root.path(),
        &input,
        &proposal,
        &[a.clone()],
        Reranking {
            matches: vec![ranked(task_key(&outside))],
            clarification: String::new()
        }
    )
    .is_err());
    assert!(prepare_ranked(
        root.path(),
        &input,
        &proposal,
        &[outside.clone()],
        Reranking {
            matches: vec![ranked(task_key(&outside))],
            clarification: String::new()
        }
    )
    .is_err());
    assert!(prepare_ranked(
        root.path(),
        &input,
        &proposal,
        &[a.clone()],
        Reranking {
            matches: vec![ranked(task_key(&a)), ranked(task_key(&a))],
            clarification: String::new()
        }
    )
    .is_err());
    let empty = prepare_ranked(
        root.path(),
        &input,
        &proposal,
        &[a],
        Reranking {
            matches: vec![],
            clarification: "Уточните, о каком пилоте идёт речь".into(),
        },
    )
    .unwrap();
    assert_eq!(empty["status"], "unsupported");
    assert!(notes::list(root.path()).unwrap().task_operations.is_empty());
}
#[test]
fn candidate_scope_is_bounded_and_selected_task_does_not_broaden_deictic_command() {
    let root = tempfile::tempdir().unwrap();
    let selected = task(root.path(), "Пилот: договор", "Пилот", false);
    task(
        root.path(),
        "PRIVATE_UNRELATED_PROJECT_MUST_STAY_LOCAL",
        "Личное",
        false,
    );
    for i in 0..30 {
        task(root.path(), &format!("Пилот: шаг {i}"), "Пилот", false);
    }
    let mut proposal = proposal("openTask", "");
    proposal.query = String::new();
    let list = shortlist(
        root.path(),
        &json!({"projectID":"Пилот","taskID":selected["id"]}),
        &proposal,
    )
    .unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0]["id"], selected["id"]);
    proposal.query = "пилот".into();
    let list = shortlist(root.path(), &json!({"projectID":"Пилот"}), &proposal).unwrap();
    assert_eq!(list.len(), MAX_CANDIDATES);
    assert!(list.iter().all(|task| task["project"] == "Пилот"));
    assert!(!serde_json::to_string(&list)
        .unwrap()
        .contains("PRIVATE_UNRELATED"));
}

#[test]
fn russian_and_english_morphology_keep_older_relevant_tasks_in_the_shortlist() {
    let root = tempfile::tempdir().unwrap();
    let russian = task(root.path(), "Согласование договора", "Пилот", false);
    let english = task(root.path(), "Payment processing", "Пилот", false);
    for i in 0..30 {
        task(
            root.path(),
            &format!("Пилот: другой шаг {i}"),
            "Пилот",
            false,
        );
    }
    let mut proposal = proposal("openTask", "");
    proposal.query = "договорами".into();
    let list = shortlist(root.path(), &json!({"projectID":"Пилот"}), &proposal).unwrap();
    assert_eq!(list[0]["id"], russian["id"]);
    proposal.query = "payments".into();
    let list = shortlist(root.path(), &json!({"projectID":"Пилот"}), &proposal).unwrap();
    assert_eq!(list[0]["id"], english["id"]);
}

#[test]
fn linked_note_edits_invalidate_reranking_and_prepared_batch_even_without_task_revision_change() {
    let root = tempfile::tempdir().unwrap();
    let task = task(root.path(), "Пилот: договор", "Пилот", false);
    let mut note = empty_note(
        "note",
        &"Условия договора. ".repeat(80),
        "Важные условия",
        None,
    )
    .unwrap();
    note.revision = 0;
    let note = notes::save_note(root.path(), note).unwrap();
    let mut workspace = notes::list(root.path()).unwrap();
    workspace
        .task_workspaces
        .iter_mut()
        .find(|record| format!("manual:{}", record.note_id) == task["id"])
        .unwrap()
        .materials
        .push(crate::task_workspace::TaskMaterial {
            id: uuid(),
            kind: "note".into(),
            title: "Важные условия".into(),
            note_id: Some(note.id.clone()),
            shared: false,
            created_at: now(),
            ..Default::default()
        });
    notes::persist(&notes::directory(root.path()).unwrap(), &workspace).unwrap();
    let snapshot = task_snapshot(root.path(), task_key(&task)).unwrap();
    let plan = ranked(
        root.path(),
        "appendTaskContexts",
        "Уточнить цену",
        &[snapshot.clone()],
    );
    let mut note = note;
    note.text.push_str(" Изменение в самом конце заметки.");
    notes::save_note(root.path(), note).unwrap();
    let fresh = task_snapshot(root.path(), task_key(&task)).unwrap();
    assert_eq!(fresh["revision"], snapshot["revision"]);
    assert_ne!(fresh["contextVersion"], snapshot["contextVersion"]);
    assert!(apply(
        root.path(),
        &request(&plan, &[task_key(&task)], "Уточнить цену")
    )
    .is_err());
    assert!(prepare_ranked(
        root.path(),
        &json!({"projectID":"Пилот"}),
        &proposal("appendTaskContexts", "Уточнить цену"),
        &[snapshot],
        Reranking {
            matches: vec![RankedTask {
                id: task_key(&task).into(),
                reason: "Условия того же договора".into()
            }],
            clarification: String::new()
        }
    )
    .is_err());
    assert!(!context_string(root.path(), &task).contains("Уточнить цену"));
}

#[test]
fn real_two_pass_provider_pipeline_reranks_only_bounded_project_candidates_without_mutating() {
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    let root = tempfile::tempdir().unwrap();
    let target = task(root.path(), "Согласовать договор пилота", "Пилот", false);
    task(
        root.path(),
        "PRIVATE_UNRELATED_PROJECT_SENTINEL",
        "Личное",
        false,
    );
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let intent = serde_json::to_string(&proposal("openTask", "")).unwrap();
    let rerank = serde_json::to_string(&Reranking {
        matches: vec![RankedTask {
            id: task_key(&target).into(),
            reason: "В задаче обсуждается договор пилота".into(),
        }],
        clarification: String::new(),
    })
    .unwrap();
    let fixture = std::thread::spawn(move || {
        let mut bodies = Vec::new();
        for index in 0..4 {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut first = String::new();
            reader.read_line(&mut first).unwrap();
            let mut size = 0;
            let mut headers = String::new();
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" {
                    break;
                }
                if let Some((key, value)) = line.split_once(':') {
                    if key.eq_ignore_ascii_case("content-length") {
                        size = value.trim().parse::<usize>().unwrap();
                    }
                }
                headers.push_str(&line);
            }
            let mut bytes = vec![0; size];
            reader.read_exact(&mut bytes).unwrap();
            let body = if bytes.is_empty() {
                Value::Null
            } else {
                serde_json::from_slice::<Value>(&bytes).unwrap()
            };
            bodies.push((first, headers, body));
            let response=if index%2==0{json!({"data":[{"id":"voice-local-test"}]})}else{json!({"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":if index==1{&intent}else{&rerank}}}]})}.to_string();
            write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",response.len(),response).unwrap();
        }
        bodies
    });
    crate::storage::atomic_json(&root.path().join("settings.json"),&json!({"mode":"local","localProvider":"lmstudio","localModel":"voice-local-test","localEndpoint":format!("http://{address}")})).unwrap();
    let planned = super::super::plan(
        root.path(),
        &json!({"text":"Открой задачу про договор пилота","projectID":"Пилот"}),
    )
    .unwrap();
    assert_eq!(planned["status"], "ready");
    assert_eq!(planned["action"], "openTask");
    let bodies = fixture.join().unwrap();
    assert_eq!(bodies.len(), 4);
    assert!(bodies[3].0.starts_with("POST /v1/chat/completions "));
    let prompt = bodies[3].2["messages"][1]["content"].as_str().unwrap();
    assert!(prompt.contains(task_key(&target)));
    assert!(!prompt.contains("PRIVATE_UNRELATED_PROJECT_SENTINEL"));
    let schema = &bodies[3].2["response_format"]["json_schema"]["schema"];
    assert_eq!(schema["properties"]["matches"]["maxItems"], MAX_CANDIDATES);
    assert!(bodies
        .iter()
        .all(|request| !request.1.to_ascii_lowercase().contains("authorization:")));
    assert!(notes::list(root.path()).unwrap().task_operations.is_empty());
    let result = apply(
        root.path(),
        &json!({"planID":planned["planID"],"operationID":planned["operationID"]}),
    )
    .unwrap();
    assert_eq!(result["target"]["id"], target["id"]);
}

#[test]
fn domain_commit_before_voice_receipt_recovers_by_exact_operation_without_duplicate_context() {
    let root = tempfile::tempdir().unwrap();
    let task = task(root.path(), "Пилот: договор", "Пилот", false);
    let plan = ranked(
        root.path(),
        "appendTaskContext",
        "Уточнить бюджет",
        &[task.clone()],
    );
    let input = request(&plan, &[task_key(&task)], "Уточнить бюджет");
    let expected = apply(root.path(), &input).unwrap();
    let directory = notes::directory(root.path()).unwrap();
    let mut workspace = notes::list(root.path()).unwrap();
    // Simulate the crash window after the canonical transaction committed but
    // before the optional voice presentation receipt was written.
    workspace
        .voice_operations
        .retain(|entry| entry["operationID"] != plan["operationID"]);
    notes::persist(&directory, &workspace).unwrap();
    let count = notes::list(root.path()).unwrap().notes.len();
    let operation_count = notes::list(root.path()).unwrap().task_operations.len();
    let inspected = super::super::inspect(
        root.path(),
        &json!({"planID":plan["planID"],"operationID":plan["operationID"]}),
    )
    .unwrap();
    assert!(inspected["plan"].is_null());
    assert_eq!(inspected["result"], expected);
    assert_eq!(
        notes::list(root.path()).unwrap().task_operations.len(),
        operation_count
    );
    assert_eq!(apply(root.path(), &input).unwrap(), expected);
    assert_eq!(notes::list(root.path()).unwrap().notes.len(), count);
    let context = domain(root.path(), "task-context", json!({"taskID":task["id"]})).unwrap();
    assert_eq!(
        context["materials"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|material| material["text"] == "Уточнить бюджет")
            .count(),
        1
    );
}

#[test]
fn inspecting_an_unconfirmed_preview_never_applies_or_creates_a_commit_receipt() {
    let root = tempfile::tempdir().unwrap();
    let task = task(root.path(), "Пилот: договор", "Пилот", false);
    let plan = ranked(root.path(), "completeTask", "", &[task.clone()]);
    let before = notes::list(root.path()).unwrap();
    let inspected = super::super::inspect(
        root.path(),
        &json!({"planID":plan["planID"],"operationID":plan["operationID"]}),
    )
    .unwrap();
    assert_eq!(inspected["plan"]["reviewRequired"], true);
    assert!(inspected["result"].is_null());
    let after = notes::list(root.path()).unwrap();
    assert_eq!(
        serde_json::to_value(before.notes).unwrap(),
        serde_json::to_value(after.notes).unwrap()
    );
    assert!(after.task_operations.is_empty());
    assert!(after.voice_operations.is_empty());
    assert_eq!(
        task_snapshot(root.path(), task_key(&task)).unwrap()["completed"],
        false
    );
}

#[test]
fn restore_observes_domain_undo_that_committed_after_the_initial_receipt_read() {
    let root = tempfile::tempdir().unwrap();
    let task = task(root.path(), "Пилот: договор", "Пилот", false);
    let plan = ranked(
        root.path(),
        "appendTaskContext",
        "Уточнить бюджет",
        &[task.clone()],
    );
    apply(
        root.path(),
        &request(&plan, &[task_key(&task)], "Уточнить бюджет"),
    )
    .unwrap();
    let directory = notes::directory(root.path()).unwrap();
    let mut workspace = notes::list(root.path()).unwrap();
    let stored = workspace
        .voice_plans
        .iter()
        .find(|stored| stored["planID"] == plan["planID"])
        .unwrap()
        .clone();
    workspace
        .voice_operations
        .retain(|entry| entry["operationID"] != plan["operationID"]);
    notes::persist(&directory, &workspace).unwrap();
    // Deterministically interleave a real undo at the exact boundary between
    // the independent domain inspect and voice presentation write.
    let stale_receipt = domain(
        root.path(),
        "task-operation-inspect",
        json!({"operationID":plan["operationID"],"planID":stored["domainBatchPlanID"]}),
    )
    .unwrap();
    assert_eq!(stale_receipt["undone"], false);
    domain(
        root.path(),
        "task-operation-undo",
        json!({"operationID":plan["operationID"]}),
    )
    .unwrap();
    let result = restore_receipt(
        root.path(),
        plan["planID"].as_str().unwrap(),
        plan["operationID"].as_str().unwrap(),
        &stored,
        &stale_receipt,
    )
    .unwrap()
    .unwrap();
    assert_eq!(result["undone"], true);
    assert_eq!(result["canUndo"], false);
    let workspace = notes::list(root.path()).unwrap();
    let receipt = workspace
        .voice_operations
        .iter()
        .find(|entry| entry["operationID"] == plan["operationID"])
        .unwrap();
    assert_eq!(receipt["undone"], true);
    assert_eq!(receipt["result"]["canUndo"], false);
    assert!(!context_string(root.path(), &task).contains("Уточнить бюджет"));
}
