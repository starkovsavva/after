use super::*;
fn proposed(action: &str, text: &str) -> Proposal {
    Proposal {
        action: action.into(),
        query: String::new(),
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
fn fixture(root: &Path) -> String {
    let directory = crate::storage::meeting_directory(root, "meeting").unwrap();
    crate::storage::atomic_json(&directory.join("meta.json"),&json!({"id":"meeting","title":"Закупки","createdAt":1,"source":"audio.wav","completedTasks":[]})).unwrap();
    crate::storage::atomic_json(&directory.join("summary.json"),&json!({"items":[{"kind":"action","text":"Проверить договор","owner":"Анна","due":"","segmentIDs":[5]}],"cards":[],"overview":"Условия пилота","generatedAt":1})).unwrap();
    notes::tasks(root).unwrap()["tasks"][0]["id"]
        .as_str()
        .unwrap()
        .to_owned()
}
fn planned(root: &Path, input: Value, proposal: Proposal) -> Value {
    let w = notes::list(root).unwrap();
    let targets = snapshot_targets(root, &w).unwrap();
    store_plan(root, &input, proposal, targets).unwrap()
}
fn applied(root: &Path, p: &Value) -> Value {
    apply(
        root,
        &json!({"planID":p["planID"],"operationID":p["operationID"]}),
    )
    .unwrap()
}
fn note(root: &Path, title: &str, text: &str, kind: &str) -> CapturedNote {
    let mut n = empty_note(kind, text, title, None).unwrap();
    n.revision = 0;
    notes::save_note(root, n).unwrap()
}
#[test]
fn create_apply_retry_and_undo_are_idempotent() {
    let root = tempfile::tempdir().unwrap();
    let p = planned(
        root.path(),
        json!({}),
        proposed("createNote", "Проверить цену"),
    );
    assert_eq!(p["status"], "ready");
    let r = applied(root.path(), &p);
    assert_eq!(applied(root.path(), &p), r);
    assert_eq!(notes::list(root.path()).unwrap().notes.len(), 1);
    let input = json!({"operationID":r["operationID"]});
    assert_eq!(undo(root.path(), &input).unwrap()["undone"], true);
    assert_eq!(undo(root.path(), &input).unwrap()["undone"], true);
    assert!(notes::list(root.path()).unwrap().notes.is_empty());
    assert_eq!(applied(root.path(), &p)["undone"], true);
    assert!(notes::list(root.path()).unwrap().notes.is_empty());
}
#[test]
fn append_preserves_previous_text_and_history_and_rejects_stale_apply_and_undo() {
    let root = tempfile::tempdir().unwrap();
    let n = note(root.path(), "Договор", "Старый текст", "task");
    let input = json!({"taskID":format!("manual:{}",n.id)});
    let p = planned(
        root.path(),
        input.clone(),
        proposed("appendTask", "Проверить условия оплаты"),
    );
    let stale = planned(root.path(), input, proposed("appendTask", "Позвонить"));
    let r = applied(root.path(), &p);
    let saved = notes::load_note_snapshot(root.path(), &n.id).unwrap();
    assert_eq!(saved.text, "Старый текст\n\nПроверить условия оплаты");
    assert_eq!(saved.history.len(), 1);
    assert_eq!(saved.history[0]["operationID"], r["operationID"]);
    assert!(apply(
        root.path(),
        &json!({"planID":stale["planID"],"operationID":stale["operationID"]})
    )
    .is_err());
    let mut edited = saved.clone();
    edited.owner = "Алексей".into();
    notes::save_note(root.path(), edited).unwrap();
    assert!(undo(root.path(), &json!({"operationID":r["operationID"]})).is_err());
    let updated = notes::load_note_snapshot(root.path(), &n.id).unwrap();
    assert_eq!(updated.owner, "Алексей");
    assert_eq!(updated.history, saved.history);
}
#[test]
fn repeated_semantic_addition_does_not_duplicate_content() {
    let root = tempfile::tempdir().unwrap();
    let n = note(root.path(), "Договор", "Основной текст", "task");
    let input = json!({"taskID":n.id});
    let p = planned(
        root.path(),
        input.clone(),
        proposed("appendTask", "Проверить оплату"),
    );
    applied(root.path(), &p);
    let p = planned(
        root.path(),
        input,
        proposed("appendTask", "Проверить оплату"),
    );
    applied(root.path(), &p);
    let saved = notes::load_note_snapshot(root.path(), &n.id).unwrap();
    assert_eq!(saved.history.len(), 1);
    assert_eq!(saved.text.matches("Проверить оплату").count(), 1);
}
#[test]
fn ambiguous_targets_require_valid_explicit_choice() {
    let root = tempfile::tempdir().unwrap();
    let a = note(root.path(), "Договор поставки", "Договор поставки", "task");
    let b = note(root.path(), "Договор аренды", "Договор аренды", "task");
    let mut proposal = proposed("appendTask", "Проверить оплату");
    proposal.query = "договор".into();
    let p = planned(root.path(), json!({}), proposal);
    assert_eq!(p["status"], "choose");
    assert_eq!(p["candidates"].as_array().unwrap().len(), 2);
    assert!(apply(
        root.path(),
        &json!({"planID":p["planID"],"operationID":p["operationID"]})
    )
    .is_err());
    assert!(choose(
        root.path(),
        &json!({"planID":p["planID"],"targetID":"../../outside"})
    )
    .is_err());
    let p = choose(
        root.path(),
        &json!({"planID":p["planID"],"targetID":format!("manual:{}",b.id)}),
    )
    .unwrap();
    let r = applied(root.path(), &p);
    assert_eq!(r["target"]["id"], b.id);
    assert_eq!(
        notes::load_note_snapshot(root.path(), &a.id).unwrap().text,
        a.text
    );
}
#[test]
fn exact_existing_task_is_extended_without_duplicate_but_partial_title_is_not_merged() {
    let root = tempfile::tempdir().unwrap();
    let n = note(
        root.path(),
        "Проверить договор",
        "Проверить договор",
        "task",
    );
    let mut proposal = proposed("createTask", "Проверить договор и условия оплаты");
    proposal.title = "Проверить договор".into();
    let p = planned(root.path(), json!({}), proposal);
    assert_eq!(p["action"], "appendTask");
    applied(root.path(), &p);
    assert_eq!(notes::list(root.path()).unwrap().notes.len(), 1);
    assert!(notes::load_note_snapshot(root.path(), &n.id)
        .unwrap()
        .text
        .contains("условия оплаты"));
    let mut proposal = proposed("createTask", "Проверить договор аренды");
    proposal.title = "Проверить договор аренды".into();
    let p = planned(root.path(), json!({}), proposal);
    assert_eq!(p["action"], "createTask");
    applied(root.path(), &p);
    assert_eq!(notes::list(root.path()).unwrap().notes.len(), 2);
}
#[test]
fn summary_task_materialization_is_stable_and_deduplicates_after_reordering() {
    let root = tempfile::tempdir().unwrap();
    let id = fixture(root.path());
    let request = json!({"taskID":id});
    let n = task_update(root.path(), &request, true).unwrap();
    assert_eq!(
        task_update(root.path(), &request, true).unwrap()["id"],
        n["id"]
    );
    assert_eq!(
        notes::tasks(root.path()).unwrap()["tasks"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let patch = json!({"taskID":n["id"],"expectedRevision":n["revision"],"patch":{"due":"2026-10-30","subtasks":[{"id":"sub-1","text":"Проверить оплату","completed":false}]}});
    let updated = task_update(root.path(), &patch, false).unwrap();
    assert_eq!(updated["subtasks"][0]["text"], "Проверить оплату");
    assert!(task_update(root.path(), &patch, false).is_err());
    let path = root.path().join("meetings/meeting/summary.json");
    let mut summary = read_json(&path, 8 * 1_048_576).unwrap();
    summary["items"]
        .as_array_mut()
        .unwrap()
        .insert(0, json!({"kind":"detail","text":"Цена","segmentIDs":[2]}));
    crate::storage::atomic_json(&path, &summary).unwrap();
    let tasks = notes::tasks(root.path()).unwrap();
    assert_eq!(tasks["tasks"].as_array().unwrap().len(), 1);
    assert_eq!(tasks["tasks"][0]["noteID"], n["id"]);
}
#[test]
fn source_regeneration_between_plan_and_apply_is_rejected() {
    let root = tempfile::tempdir().unwrap();
    let id = fixture(root.path());
    let p = planned(
        root.path(),
        json!({"taskID":id}),
        proposed("appendTask", "Сверить реквизиты"),
    );
    let path = root.path().join("meetings/meeting/summary.json");
    let mut summary = read_json(&path, 8 * 1_048_576).unwrap();
    summary["items"][0]["text"] = json!("Другая задача");
    crate::storage::atomic_json(&path, &summary).unwrap();
    assert!(apply(
        root.path(),
        &json!({"planID":p["planID"],"operationID":p["operationID"]})
    )
    .is_err());
    assert!(notes::list(root.path()).unwrap().notes.is_empty());
}
#[test]
fn card_deck_uses_review_storage_and_safe_undo_rejects_reviewed_cards() {
    let root = tempfile::tempdir().unwrap();
    let mut proposal = proposed("createCards", "");
    proposal.title = "Фразы о сроках".into();
    proposal.cards = vec![ProposedCard {
        kind: "phrase".into(),
        front: "meet a deadline".into(),
        back: "уложиться в срок".into(),
        context: "Пример: We met the deadline.".into(),
    }];
    let p = planned(root.path(), json!({}), proposal.clone());
    let r = applied(root.path(), &p);
    let id = r["target"]["id"].as_str().unwrap();
    assert_eq!(applied(root.path(), &p), r);
    let dir = root.path().join("meetings").join(id);
    let summary = read_json(&dir.join("summary.json"), 8 * 1_048_576).unwrap();
    let card = summary["cards"][0]["id"].as_str().unwrap();
    crate::storage::review(root.path(), id, card, 3).unwrap();
    assert!(undo(root.path(), &json!({"operationID":r["operationID"]})).is_err());
    assert!(dir.exists());
    let p = planned(root.path(), json!({}), proposal);
    let r = applied(root.path(), &p);
    let id = r["target"]["id"].as_str().unwrap();
    undo(root.path(), &json!({"operationID":r["operationID"]})).unwrap();
    assert!(!root.path().join("meetings").join(id).exists());
    assert!(root.path().join("notes/voice-trash").join(id).exists());
}
#[test]
fn unsupported_forged_and_invalid_plans_never_mutate_notes() {
    let root = tempfile::tempdir().unwrap();
    let mut proposal = proposed("unsupported", "Уточните название");
    let p = planned(root.path(), json!({}), proposal.clone());
    assert_eq!(p["status"], "unsupported");
    assert!(apply(
        root.path(),
        &json!({"planID":p["planID"],"operationID":p["operationID"]})
    )
    .is_err());
    proposal.action = "deleteFiles".into();
    assert!(store_plan(root.path(), &json!({}), proposal, vec![]).is_err());
    let p = planned(
        root.path(),
        json!({}),
        proposed("createNote", "Новая заметка"),
    );
    assert!(apply(
        root.path(),
        &json!({"planID":p["planID"],"operationID":uuid()})
    )
    .is_err());
    assert!(task_update(
        root.path(),
        &json!({"taskID":"../../outside","patch":{"revision":99}}),
        false
    )
    .is_err());
    assert!(notes::list(root.path()).unwrap().notes.is_empty());
}
#[test]
fn dates_resolve_in_user_timezone_and_preserve_unrecognized_literal() {
    let at = Utc
        .with_ymd_and_hms(2026, 10, 25, 23, 30, 0)
        .unwrap()
        .timestamp() as f64;
    assert_eq!(due_date("сегодня", at, 180).unwrap(), "2026-10-26");
    assert_eq!(due_date("завтра", at, 180).unwrap(), "2026-10-27");
    assert_eq!(due_date("на пятницу", at, 180).unwrap(), "2026-10-30");
    assert_eq!(
        due_date("end of this quarter", at, 180).unwrap(),
        "end of this quarter"
    );
    assert!(due_date("today", at, 1000).is_err());
    assert!(due_date("today", f64::NAN, 0).is_err());
}
#[test]
fn concurrent_same_operation_has_one_effect() {
    let root = tempfile::tempdir().unwrap();
    let p = planned(
        root.path(),
        json!({}),
        proposed("createTask", "Проверить срок"),
    );
    let mut handles = vec![];
    for _ in 0..5 {
        let root = root.path().to_owned();
        let p = p.clone();
        handles.push(std::thread::spawn(move || {
            apply(
                &root,
                &json!({"planID":p["planID"],"operationID":p["operationID"]}),
            )
            .unwrap()
        }));
    }
    let results: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    assert!(results.iter().all(|r| r == &results[0]));
    assert_eq!(notes::list(root.path()).unwrap().notes.len(), 1);
}
#[test]
fn typed_task_append_is_exact_and_patch_validation_preserves_existing_data() {
    let root = tempfile::tempdir().unwrap();
    let n = note(root.path(), "Договор", "Проверить договор", "task");
    let input = json!({"command":"task-append","taskID":n.id,"expectedRevision":n.revision,"text":"Проверить оплату"});
    let saved = dispatch(root.path(), &input).unwrap();
    assert_eq!(saved["text"], "Проверить договор\n\nПроверить оплату");
    assert_eq!(saved["history"][0]["text"], "Проверить оплату");
    assert!(dispatch(root.path(), &input).is_err());
    for patch in [
        json!({"revision":999}),
        json!({"completed":"yes"}),
        json!({"subtasks":[{"id":"same","text":"A","completed":false},{"id":"same","text":"B","completed":true}]}),
        json!({"subtasks":[{"id":"../../outside","text":"A","completed":false}]}),
    ] {
        assert!(dispatch(root.path(),&json!({"command":"task-update","taskID":n.id,"expectedRevision":saved["revision"],"patch":patch})).is_err());
    }
    assert_eq!(
        serde_json::to_value(notes::load_note_snapshot(root.path(), &n.id).unwrap()).unwrap(),
        saved
    );
}
#[test]
fn operation_id_cannot_be_reused_with_another_plan() {
    let root = tempfile::tempdir().unwrap();
    let a = planned(root.path(), json!({}), proposed("createNote", "A"));
    let b = planned(root.path(), json!({}), proposed("createNote", "B"));
    applied(root.path(), &a);
    assert!(apply(
        root.path(),
        &json!({"planID":b["planID"],"operationID":a["operationID"]})
    )
    .is_err());
    assert_eq!(notes::list(root.path()).unwrap().notes.len(), 1);
}
#[test]
fn interrupted_card_publication_recovers_exact_authorized_deck_without_network() {
    let root = tempfile::tempdir().unwrap();
    let mut proposal = proposed("createCards", "");
    proposal.cards = vec![ProposedCard {
        kind: "concept".into(),
        front: "RTO".into(),
        back: "Целевое время восстановления".into(),
        context: "Пример: RTO — 30 минут.".into(),
    }];
    let p = planned(root.path(), json!({}), proposal);
    let directory = notes::directory(root.path()).unwrap();
    let mut w = notes::list(root.path()).unwrap();
    let plan = w
        .voice_plans
        .iter()
        .find(|item| item["planID"] == p["planID"])
        .unwrap()
        .clone();
    // Simulate the durable intent left by a process which stopped before its
    // first deck write. No model or API is contacted during recovery.
    w.voice_operations.push(json!({"operationID":p["operationID"],"planID":p["planID"],"plan":plan,"pending":true,"undone":false}));
    notes::persist(&directory, &w).unwrap();
    let result = recover(root.path()).unwrap();
    assert_eq!(result["recovered"].as_array().unwrap().len(), 1);
    let r = &result["recovered"][0];
    assert!(root
        .path()
        .join("meetings")
        .join(r["target"]["id"].as_str().unwrap())
        .join("meta.json")
        .exists());
    assert!(recover(root.path()).unwrap()["recovered"]
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(applied(root.path(), &p), *r);
}
#[test]
fn canonical_summary_completion_checks_current_source_before_mutation() {
    let root = tempfile::tempdir().unwrap();
    let id = fixture(root.path());
    let saved = task_update(root.path(), &json!({"taskID":id}), true).unwrap();
    notes::complete_task(root.path(), "meeting", 0, "Проверить договор", true).unwrap();
    assert!(
        notes::load_note_snapshot(root.path(), saved["id"].as_str().unwrap())
            .unwrap()
            .completed
    );
    assert!(notes::complete_task(root.path(), "meeting", 0, "Другая задача", false).is_err());
    assert!(
        notes::load_note_snapshot(root.path(), saved["id"].as_str().unwrap())
            .unwrap()
            .completed
    );
}

#[test]
fn real_planner_provider_route_sends_only_selected_context_and_validates_schema() {
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    let root = tempfile::tempdir().unwrap();
    fixture(root.path());
    let selected = note(
        root.path(),
        "Условия пилота",
        "SELECTED_NOTE: скидка 15 процентов",
        "note",
    );
    note(
        root.path(),
        "Личная заметка",
        "UNRELATED_PRIVATE_CONTENT_MUST_STAY_LOCAL",
        "note",
    );
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let proposal = proposed("createNote", "Запросить договор");
    let answer = serde_json::to_string(&proposal).unwrap();
    let server = std::thread::spawn(move || {
        let mut requests = Vec::new();
        for i in 0..2 {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut first = String::new();
            reader.read_line(&mut first).unwrap();
            let mut length = 0;
            let mut headers = String::new();
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" {
                    break;
                }
                if let Some((name, value)) = line.split_once(':') {
                    if name.eq_ignore_ascii_case("content-length") {
                        length = value.trim().parse::<usize>().unwrap();
                    }
                }
                headers.push_str(&line);
            }
            let mut bytes = vec![0; length];
            reader.read_exact(&mut bytes).unwrap();
            let request: Value = if bytes.is_empty() {
                Value::Null
            } else {
                serde_json::from_slice(&bytes).unwrap()
            };
            requests.push((first, headers, request));
            let body = if i == 0 {
                json!({"data":[{"id":"qwen-test","object":"model","owned_by":"local"}]})
            } else {
                json!({"choices":[{"finish_reason":"stop","message":{"content":answer}}]})
            }
            .to_string();
            write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body).unwrap();
        }
        requests
    });
    crate::storage::atomic_json(&root.path().join("settings.json"),&json!({"mode":"local","localProvider":"lmstudio","localModel":"qwen-test","localEndpoint":format!("http://{address}")})).unwrap();
    let p=crate::request(&json!({"root":root.path(),"command":"voice-plan","text":"Создай заметку запросить договор","meetingID":"meeting","noteID":selected.id})).unwrap();
    assert_eq!(p["status"], "ready");
    let requests = server.join().unwrap();
    assert!(requests[0].0.starts_with("GET /v1/models "));
    assert!(requests[1].0.starts_with("POST /v1/chat/completions "));
    let body = &requests[1].2;
    assert_eq!(body["model"], "qwen-test");
    assert_eq!(body["response_format"]["json_schema"]["strict"], true);
    let prompt = body["messages"][1]["content"].as_str().unwrap();
    assert!(prompt.contains("SELECTED_NOTE"));
    assert!(prompt.contains("Проверить договор"));
    assert!(!prompt.contains("UNRELATED_PRIVATE_CONTENT"));
    assert!(!requests
        .iter()
        .any(|request| request.1.to_ascii_lowercase().contains("authorization:")));
    let result = applied(root.path(), &p);
    assert_eq!(result["target"]["kind"], "note");
}

#[test]
fn inspect_restores_prepared_or_committed_operation_without_reexecution() {
    let root = tempfile::tempdir().unwrap();
    let p = planned(
        root.path(),
        json!({}),
        proposed("createNote", "Сохранить точные условия"),
    );
    let input =
        json!({"command":"voice-inspect","planID":p["planID"],"operationID":p["operationID"]});
    let ready = dispatch(root.path(), &input).unwrap();
    assert_eq!(ready["plan"], p);
    assert!(ready["result"].is_null());
    let result = applied(root.path(), &p);
    let restored = dispatch(root.path(), &input).unwrap();
    assert!(restored["plan"].is_null());
    assert_eq!(restored["result"], result);
    assert_eq!(notes::list(root.path()).unwrap().notes.len(), 1);
    assert!(dispatch(
        root.path(),
        &json!({"command":"voice-inspect","planID":uuid(),"operationID":p["operationID"]})
    )
    .is_err());
    undo(root.path(), &json!({"operationID":p["operationID"]})).unwrap();
    assert_eq!(
        dispatch(root.path(), &input).unwrap()["result"]["canUndo"],
        false
    );
}

#[test]
fn renamed_card_deck_cannot_be_undone_over_a_later_user_edit() {
    let root = tempfile::tempdir().unwrap();
    let mut proposal = proposed("createCards", "");
    proposal.cards = vec![ProposedCard {
        kind: "concept".into(),
        front: "RPO".into(),
        back: "Допустимая потеря данных по времени".into(),
        context: "".into(),
    }];
    let p = planned(root.path(), json!({}), proposal);
    let result = applied(root.path(), &p);
    let id = result["target"]["id"].as_str().unwrap();
    crate::storage::update_meta(root.path(), id, &json!({"title":"Моя новая колода"})).unwrap();
    assert!(undo(root.path(), &json!({"operationID":p["operationID"]})).is_err());
    assert_eq!(
        read_json(
            &root.path().join("meetings").join(id).join("meta.json"),
            1_048_576
        )
        .unwrap()["title"],
        "Моя новая колода"
    );
}

#[test]
fn summary_ids_follow_source_signature_and_deduplicate_identical_actions() {
    let root = tempfile::tempdir().unwrap();
    let original = fixture(root.path());
    let path = root.path().join("meetings/meeting/summary.json");
    let mut summary = read_json(&path, 8 * 1_048_576).unwrap();
    let duplicate = summary["items"][0].clone();
    summary["items"].as_array_mut().unwrap().push(duplicate);
    summary["items"].as_array_mut().unwrap().insert(
        0,
        json!({"kind":"action","text":"Проверить реквизиты","owner":"","due":"","segmentIDs":[6]}),
    );
    crate::storage::atomic_json(&path, &summary).unwrap();
    let tasks = notes::tasks(root.path()).unwrap();
    assert_eq!(tasks["tasks"].as_array().unwrap().len(), 2);
    assert!(tasks["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .any(|task| task["id"] == original));
    summary["items"].as_array_mut().unwrap().reverse();
    crate::storage::atomic_json(&path, &summary).unwrap();
    let reversed = notes::tasks(root.path()).unwrap();
    let ids = |value: &Value| {
        value["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|task| task["id"].as_str().unwrap().to_owned())
            .collect::<std::collections::BTreeSet<_>>()
    };
    assert_eq!(ids(&tasks), ids(&reversed));
}

#[test]
fn explicit_source_and_summary_checkbox_refs_reject_stale_identity_without_mutation() {
    let root = tempfile::tempdir().unwrap();
    let id = fixture(root.path());
    for command in ["task-materialize", "task-update", "task-append"] {
        let input = json!({"command":command,"taskID":id,"text":"Дополнение","patch":{"completed":true},"expectedSource":{"meetingID":"meeting","text":"Проверить договор","segmentIDs":[999]}});
        assert!(dispatch(root.path(), &input).is_err());
        assert!(notes::list(root.path()).unwrap().notes.is_empty());
    }
    let note=dispatch(root.path(),&json!({"command":"task-materialize","taskID":id,"expectedSource":{"meetingID":"meeting","text":"Проверить договор","segmentIDs":[5]}})).unwrap();
    assert!(crate::request(&json!({"root":root.path(),"command":"notes-task-complete","meetingID":"meeting","itemIndex":0,"text":"Проверить договор","expectedSegmentIDs":[999],"completed":true})).is_err());
    assert!(
        !notes::load_note_snapshot(root.path(), note["id"].as_str().unwrap())
            .unwrap()
            .completed
    );
}

#[test]
fn notes_public_response_omits_journal_and_stored_targets_omit_task_history() {
    let root = tempfile::tempdir().unwrap();
    let note = note(root.path(), "Договор", "Текст договора", "task");
    let p = planned(
        root.path(),
        json!({"taskID":note.id}),
        proposed("appendTask", "Проверить оплату"),
    );
    applied(root.path(), &p);
    let p = planned(
        root.path(),
        json!({"taskID":note.id}),
        proposed("appendTask", "Проверить реквизиты"),
    );
    let workspace = notes::list(root.path()).unwrap();
    assert!(!workspace.voice_plans.is_empty() && !workspace.voice_operations.is_empty());
    let internal = workspace
        .voice_plans
        .iter()
        .find(|plan| plan["planID"] == p["planID"])
        .unwrap();
    let target = &internal["target"];
    assert!(
        target.get("history").is_none()
            && target.get("subtasks").is_none()
            && target.get("taskOrigin").is_none()
    );
    let public = crate::request(&json!({"root":root.path(),"command":"notes-list"})).unwrap();
    assert!(public.get("voicePlans").is_none() && public.get("voiceOperations").is_none());
    assert_eq!(public["notes"][0]["history"].as_array().unwrap().len(), 1);
}

#[test]
fn prepared_voice_plan_follows_exact_source_after_summary_reordering() {
    let root = tempfile::tempdir().unwrap();
    let id = fixture(root.path());
    let p = planned(
        root.path(),
        json!({"taskID":id}),
        proposed("appendTask", "Сверить реквизиты"),
    );
    let path = root.path().join("meetings/meeting/summary.json");
    let mut summary = read_json(&path, 8 * 1_048_576).unwrap();
    summary["items"].as_array_mut().unwrap().insert(
        0,
        json!({"kind":"action","text":"Другая задача","owner":"","due":"","segmentIDs":[88]}),
    );
    crate::storage::atomic_json(&path, &summary).unwrap();
    let result = applied(root.path(), &p);
    let note =
        notes::load_note_snapshot(root.path(), result["target"]["id"].as_str().unwrap()).unwrap();
    assert!(note.text.starts_with("Проверить договор\n\n"));
    assert_eq!(note.task_origin.unwrap()["segmentIDs"], json!([5]));
    assert!(notes::tasks(root.path()).unwrap()["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .any(|task| task["text"] == "Другая задача" && task["noteID"].is_null()));
}

#[test]
fn new_voice_deadlines_use_command_local_date_and_preserve_unrecognized_wording() {
    let at=Utc.with_ymd_and_hms(2026,10,25,23,30,0).unwrap().timestamp() as f64;
    assert_eq!(due_date("завтра",at,180).unwrap(),"2026-10-27");
    assert_eq!(due_date("tomorrow",at,-420).unwrap(),"2026-10-26");
    assert_eq!(due_date("послезавтра",at,180).unwrap(),"2026-10-28");
    assert_eq!(due_date("к пятнице",at,180).unwrap(),"2026-10-30");
    assert_eq!(due_date("Friday",at,180).unwrap(),"2026-10-30");
    assert_eq!(due_date("после согласования",at,180).unwrap(),"после согласования");
    assert_eq!(due_date("2026-12-15",at,180).unwrap(),"2026-12-15");
    assert_eq!(due_date("",at,180).unwrap(),"");
    assert!(due_date("завтра",at,1440).is_err());
}

#[test]
fn voice_deadline_update_on_old_task_is_frozen_at_command_time_not_source_time() {
    let root=tempfile::tempdir().unwrap();let task_id=fixture(root.path());
    let at=Utc.with_ymd_and_hms(2026,10,25,23,30,0).unwrap().timestamp() as f64;
    let mut proposal=proposed("updateTask","");proposal.set_due=true;proposal.due="завтра".into();
    let plan=planned(root.path(),json!({"taskID":task_id,"now":at,"timeZoneOffsetMinutes":180}),proposal);
    assert_eq!(plan["status"],"ready");let result=applied(root.path(),&plan);
    let note=notes::load_note_snapshot(root.path(),result["target"]["id"].as_str().unwrap()).unwrap();
    assert_eq!(note.due,"2026-10-27");
    // Retrying an already-applied plan cannot reinterpret tomorrow later.
    assert_eq!(applied(root.path(),&plan),result);
    let original=read_json(&root.path().join("meetings/meeting/summary.json"),1_048_576).unwrap();
    assert_eq!(original["items"][0]["due"],"");
}

#[test]
fn changing_only_owner_does_not_reinterpret_legacy_source_deadline() {
    let root=tempfile::tempdir().unwrap();fixture(root.path());
    let path=root.path().join("meetings/meeting/summary.json");let mut source=read_json(&path,1_048_576).unwrap();source["items"][0]["due"]=json!("к пятнице");crate::storage::atomic_json(&path,&source).unwrap();
    let task_id=notes::tasks(root.path()).unwrap()["tasks"][0]["id"].clone();
    let mut proposal=proposed("updateTask","");proposal.set_owner=true;proposal.owner="Майкл".into();
    let plan=planned(root.path(),json!({"taskID":task_id,"now":2_000_000_000,"timeZoneOffsetMinutes":180}),proposal);let result=applied(root.path(),&plan);
    let note=notes::load_note_snapshot(root.path(),result["target"]["id"].as_str().unwrap()).unwrap();
    assert_eq!(note.due,"к пятнице");assert_eq!(note.owner,"Майкл");assert_eq!(read_json(&path,1_048_576).unwrap(),source);
}
