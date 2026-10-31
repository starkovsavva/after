use super::*;
use crate::storage::atomic_json;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::time::{Duration, Instant};

fn enabled_root() -> tempfile::TempDir {
    let root = tempfile::tempdir().unwrap();
    atomic_json(&root.path().join("settings.json"), &json!({"features":{"assistant":true,"cards":true,"tasks":true,"calendar":true,"semanticSearch":true}})).unwrap();
    root
}
fn input(query: &str) -> Value {
    json!({"text":"Что известно о пилоте и какие ближайшие дела?","query":query,"now":1_793_145_600.0,"timeZoneOffsetMinutes":180})
}
fn note(root: &Path, id: &str, text: &str) -> crate::notes::CapturedNote {
    let n = serde_json::from_value(json!({"id":id,"kind":"note","title":"Пилот","text":text,"createdAt":100.0,"updatedAt":100.0,"revision":0})).unwrap();
    crate::notes::save_note(root, n).unwrap()
}
fn task(root: &Path, title: &str) -> Value {
    domain(root,"task-create",json!({"title":title,"text":"Проверить пилот в пятницу","project":"Пилот","operationID":uuid::Uuid::new_v4().to_string()})).unwrap()
}
fn meeting(root: &Path) -> std::path::PathBuf {
    let dir = root.join("meetings/meeting-one");
    atomic_json(&dir.join("meta.json"),&json!({"id":"meeting-one","title":"Пилот продукта","createdAt":150.0,"source":"source.mp3"})).unwrap();
    atomic_json(&dir.join("transcript.json"),&json!({"segments":[{"id":7,"start":0.0,"end":4.0,"text":"Пилот начинается в пятницу. Мы проверим экспорт."}]})).unwrap();
    atomic_json(&dir.join("summary.json"),&json!({"overview":"Пилот начинается в пятницу.","items":[{"kind":"detail","text":"Пилот: проверить экспорт","owner":"","due":"","segmentIDs":[7]}],"cards":[{"id":"card-one","front":"Pilot launch","back":"Запуск пилота","context":"Пилот начинается в пятницу.","segmentIDs":[7]}]})).unwrap();
    dir
}
fn calendar() -> Value {
    json!({"connected":true,"coverageStart":1_793_000_000.0,"coverageEnd":1_794_000_000.0,"events":[{"id":"event-one:1793145600","title":"Обсудить пилот","start":1_793_145_600.0,"end":1_793_149_200.0,"allDay":false,"calendarTitle":"Личный"}]})
}
fn one_answer(prompt: &Value, kind: &str) -> Value {
    let s = prompt["sources"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["kind"] == kind)
        .unwrap();
    json!({"title":"О пилоте","paragraphs":[{"text":"Пилот начинается в пятницу.","sourceIDs":[s["id"]]}]})
}

#[test]
fn real_retrieval_covers_all_kinds_and_preserves_canonical_files() {
    let root = enabled_root();
    let n = note(root.path(), "note-one", "Пилот начинается в пятницу.");
    let t = task(root.path(), "Проверить пилот");
    let dir = meeting(root.path());
    let mut args = input("пилот");
    args["calendar"] = calendar();
    let before = fs::read(root.path().join("notes/workspace.json")).unwrap();
    let original = fs::read(dir.join("transcript.json")).unwrap();
    let found = retrieve(root.path(), &args).unwrap();
    let kinds: HashSet<_> = found
        .candidates
        .iter()
        .map(|c| c.source.kind.as_str())
        .collect();
    for kind in [
        "task",
        "note",
        "meeting",
        "transcript",
        "summary",
        "card",
        "calendar",
    ] {
        assert!(kinds.contains(kind), "missing {kind}");
    }
    let result = answer_with(root.path(), &args, |prompt| {
        let paragraphs: Vec<_> = prompt["sources"]
            .as_array()
            .unwrap()
            .iter()
            .take(8)
            .map(|s| json!({"text":s["excerpt"],"sourceIDs":[s["id"]]}))
            .collect();
        Ok(json!({"title":"Источники пилота","paragraphs":paragraphs}))
    })
    .unwrap();
    assert!(!result["paragraphs"].as_array().unwrap().is_empty());
    assert!(result["sources"]
        .as_array()
        .unwrap()
        .iter()
        .any(|s| s["noteID"] == n.id));
    assert!(result["sources"]
        .as_array()
        .unwrap()
        .iter()
        .any(|s| s["taskID"] == t["id"]));
    for paragraph in result["paragraphs"].as_array().unwrap() {
        assert!(!paragraph["sourceIDs"].as_array().unwrap().is_empty());
    }
    for s in result["sources"].as_array().unwrap() {
        assert_eq!(
            validate_source(root.path(), &json!({"source":s,"calendar":calendar()})).unwrap()
                ["valid"],
            true,
            "{s}"
        );
    }
    assert_eq!(
        fs::read(root.path().join("notes/workspace.json")).unwrap(),
        before
    );
    assert_eq!(fs::read(dir.join("transcript.json")).unwrap(), original);
}

#[test]
fn model_cannot_invent_citations_omit_evidence_or_expand_output() {
    let root = enabled_root();
    note(root.path(), "one", "Пилот начинается в пятницу.");
    for draft in [
        json!({"title":"Ответ","paragraphs":[{"text":"Факт","sourceIDs":["fabricated"]}]}),
        json!({"title":"Ответ","paragraphs":[{"text":"Факт","sourceIDs":[]}]}),
        json!({"title":"Ответ","paragraphs":[{"text":"Факт"}]}),
        json!({"title":"Ответ","paragraphs":[],"sources":["invented"]}),
        json!({"title":"x".repeat(301),"paragraphs":[]}),
    ] {
        assert!(answer_with(root.path(), &input("пилот"), |_| Ok(draft.clone())).is_err());
    }
    assert!(answer_with(root.path(), &input("пилот"), |p| {
        let s = &p["sources"][0]["id"];
        Ok(json!({"title":"Ответ","paragraphs":[{"text":"Факт","sourceIDs":[s,s]}]}))
    })
    .is_err());
}

#[test]
fn absent_sources_skip_model_and_do_not_claim_the_library_is_empty() {
    let root = enabled_root();
    let mut called = false;
    let result = answer_with(root.path(), &input("неизвестно"), |_| {
        called = true;
        unreachable!()
    })
    .unwrap();
    assert!(!called);
    assert_eq!(result["title"], "Недостаточно данных");
    assert_eq!(result["sources"], json!([]));
    assert!(!result.to_string().contains("нет задач"));
    assert!(result["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .any(|w| w.as_str().unwrap().contains("Календарь не подключён")));
}

#[test]
fn trash_external_folders_account_files_and_drafts_are_not_evidence() {
    use std::os::unix::fs::symlink;
    let root = enabled_root();
    let outside = tempfile::tempdir().unwrap();
    let trashed = note(root.path(), "trash-one", "Пилот СЕКРЕТ_ИЗ_КОРЗИНЫ");
    crate::notes::trash_note(root.path(), &trashed.id, trashed.revision, false).unwrap();
    note(root.path(), "visible", "Пилот начинается в пятницу.");
    fs::write(outside.path().join("secret.txt"), "СЕКРЕТ_ИЗ_РЕПОЗИТОРИЯ").unwrap();
    fs::write(root.path().join("voice-draft.json"), "СЕКРЕТ_ИЗ_ЧЕРНОВИКА").unwrap();
    fs::write(root.path().join("auth.json"), "СЕКРЕТ_УЧЁТНОЙ_ЗАПИСИ").unwrap();
    let t = task(root.path(), "Пилот");
    domain(root.path(),"task-material-link",json!({"taskID":t["id"],"expectedRevision":t["revision"],"operationID":uuid::Uuid::new_v4().to_string(),"material":{"kind":"repository","title":"Личный код","path":outside.path().to_str().unwrap(),"shared":true}})).unwrap();
    fs::create_dir_all(root.path().join("meetings")).unwrap();
    symlink(outside.path(), root.path().join("meetings/linked")).unwrap();
    answer_with(root.path(), &input("пилот"), |p| {
        let text = p.to_string();
        for forbidden in [
            "СЕКРЕТ_ИЗ_КОРЗИНЫ",
            "СЕКРЕТ_ИЗ_РЕПОЗИТОРИЯ",
            "СЕКРЕТ_ИЗ_ЧЕРНОВИКА",
            "СЕКРЕТ_УЧЁТНОЙ_ЗАПИСИ",
            outside.path().to_str().unwrap(),
        ] {
            assert!(!text.contains(forbidden), "leaked {forbidden}");
        }
        Ok(one_answer(p, "note"))
    })
    .unwrap();
}

#[test]
fn changed_or_trashed_note_cannot_survive_a_slow_model_response() {
    for trash in [false, true] {
        let root = enabled_root();
        let n = note(root.path(), "one", "Пилот начинается в пятницу.");
        let result = answer_with(root.path(), &input("пилот"), |p| {
            if trash {
                crate::notes::trash_note(root.path(), &n.id, n.revision, false).unwrap();
            } else {
                let mut edited = n.clone();
                edited.text = "Пилот отменён".into();
                crate::notes::save_note(root.path(), edited).unwrap();
            }
            Ok(one_answer(p, "note"))
        })
        .unwrap();
        assert_eq!(result["sources"], json!([]));
        assert_eq!(result["title"], "Недостаточно данных");
        assert!(result["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|w| w.as_str().unwrap().contains("изменились")));
    }
}

#[test]
fn changed_linked_thought_invalidates_task_citation_without_mutating_task() {
    let root = enabled_root();
    let n = note(root.path(), "thought", "Пилот: согласовать пятницу");
    let t = task(root.path(), "Пилот");
    let linked=domain(root.path(),"task-material-link",json!({"taskID":t["id"],"expectedRevision":t["revision"],"operationID":uuid::Uuid::new_v4().to_string(),"material":{"kind":"note","title":"Мысль","noteID":n.id,"shared":false}})).unwrap();
    let result = answer_with(root.path(), &input("пилот"), |p| {
        let mut edited = n.clone();
        edited.text = "Согласовать понедельник".into();
        crate::notes::save_note(root.path(), edited).unwrap();
        Ok(one_answer(p, "task"))
    })
    .unwrap();
    assert_eq!(result["sources"], json!([]));
    assert_eq!(
        domain(root.path(), "task-get", json!({"taskID":t["id"]})).unwrap()["revision"],
        linked["revision"]
    );
}

#[test]
fn meeting_changes_and_nonexistent_or_unbounded_routes_are_rejected() {
    let root = enabled_root();
    let dir = meeting(root.path());
    let found = retrieve(root.path(), &input("пилот")).unwrap();
    let transcript = found
        .candidates
        .iter()
        .find(|c| c.source.kind == "transcript")
        .unwrap()
        .source
        .clone();
    let mut invalid = transcript.clone();
    invalid.segment_id = Some(i64::MAX as u64 + 1);
    assert!(!current(root.path(), &invalid, &input("")).unwrap());
    invalid = transcript.clone();
    invalid.segment_id = Some(999);
    assert!(!current(root.path(), &invalid, &input("")).unwrap());
    invalid = transcript.clone();
    invalid.meeting_id = Some("../outside".into());
    assert!(!current(root.path(), &invalid, &input("")).unwrap());
    invalid = transcript.clone();
    invalid.source_fingerprint = "forged".into();
    assert!(!current(root.path(), &invalid, &input("")).unwrap());
    let mut card = found
        .candidates
        .iter()
        .find(|c| c.source.kind == "card")
        .unwrap()
        .source
        .clone();
    card.card_id = Some("absent-card".into());
    assert!(!current(root.path(), &card, &input("")).unwrap());
    let result = answer_with(root.path(), &input("пилот"), |p| {
        atomic_json(
            &dir.join("transcript.json"),
            &json!({"segments":[{"id":7,"start":0.0,"end":4.0,"text":"Новое решение"}]}),
        )
        .unwrap();
        Ok(one_answer(p, "transcript"))
    })
    .unwrap();
    assert_eq!(result["sources"], json!([]));
    assert_eq!(
        validate_source(root.path(), &json!({"source":transcript})).unwrap()["valid"],
        false
    );
}

#[test]
fn calendar_coverage_permissions_caps_and_fresh_occurrence_validation_are_explicit() {
    let root = enabled_root();
    let mut args = input("пилот");
    args["calendar"] = calendar();
    let result = answer_with(root.path(), &args, |p| Ok(one_answer(p, "calendar"))).unwrap();
    let s = &result["sources"][0];
    assert_eq!(s["eventID"], "event-one:1793145600");
    assert_eq!(
        validate_source(root.path(), &json!({"source":s,"calendar":calendar()})).unwrap()["valid"],
        true
    );
    assert_eq!(
        validate_source(
            root.path(),
            &json!({"source":s,"calendar":{"connected":false}})
        )
        .unwrap()["valid"],
        false
    );
    let mut changed = calendar();
    changed["events"][0]["title"] = json!("Пилот отменён");
    assert_eq!(
        validate_source(root.path(), &json!({"source":s,"calendar":changed})).unwrap()["valid"],
        false
    );
    let mut invalid = args.clone();
    invalid["calendar"]["coverageEnd"] = json!(1_793_000_000.0 + MAX_CALENDAR_SPAN + 1.0);
    assert!(retrieve(root.path(), &invalid).is_err());
    invalid = args.clone();
    invalid["calendar"]["events"] = json!(vec![calendar()["events"][0].clone(); 1001]);
    assert!(retrieve(root.path(), &invalid).is_err());
    invalid = args.clone();
    invalid["calendar"]["connected"] = json!(false);
    let hidden = retrieve(root.path(), &invalid).unwrap();
    assert!(hidden.candidates.is_empty());
    invalid = args.clone();
    invalid["calendar"]["events"][0]["start"] = json!(1.0);
    invalid["calendar"]["events"][0]["end"] = json!(2.0);
    let outside = retrieve(root.path(), &invalid).unwrap();
    assert!(outside.candidates.is_empty());
    assert!(!outside.warnings.is_empty());
}

#[test]
fn query_and_prompt_budgets_are_unicode_safe_and_drop_unsupplied_sources() {
    let root = enabled_root();
    for i in 0..45 {
        note(
            root.path(),
            &format!("note-{i}"),
            &format!("Пилот {}", "Большое описание. ".repeat(500)),
        );
    }
    let mut args = input("пилот");
    args["text"] = json!("Уточни ".repeat(500));
    let mut found = retrieve(root.path(), &args).unwrap();
    let p = pack(&args, &mut found).unwrap();
    assert!(SYSTEM.len() + schema().to_string().len() + p.to_string().len() <= MAX_PROMPT);
    assert!(found.truncated);
    assert!(found.candidates.len() < MAX_SOURCES);
    for c in &found.candidates {
        assert!(p["sources"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["id"] == c.source.id));
    }
    for query in [
        json!(vec!["one"; 4]),
        json!("я".repeat(161)),
        json!("word ".repeat(21)),
        json!("bad\0query"),
    ] {
        args["query"] = query;
        assert!(retrieve(root.path(), &args).is_err());
    }
    args = input("пилот");
    args["timeZoneOffsetMinutes"] = json!(841);
    assert!(retrieve(root.path(), &args).is_err());
}

#[test]
fn public_answer_uses_existing_settings_and_localhost_ai_stack() {
    let root = enabled_root();
    note(root.path(), "one", "Пилот начинается в пятницу.");
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let address = listener.local_addr().unwrap();
    atomic_json(&root.path().join("settings.json"),&json!({"features":{"assistant":true,"cards":true,"tasks":true,"calendar":true,"semanticSearch":true},"mode":"local","localProvider":"lmstudio","localEndpoint":format!("http://{address}"),"localModel":"fixture-model"})).unwrap();
    let server = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(15);
        let mut generated = false;
        for _ in 0..2 {
            let mut stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline, "AI stack did not reach fixture");
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    Err(e) => panic!("{e}"),
                }
            };
            // Darwin can inherit the listener's nonblocking flag. HTTP headers
            // may arrive after accept(), so use the bounded blocking read below.
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut first = String::new();
            reader.read_line(&mut first).unwrap();
            let mut length = 0;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" {
                    break;
                }
                if let Some(value) = line.to_lowercase().strip_prefix("content-length:") {
                    length = value.trim().parse::<usize>().unwrap();
                }
            }
            assert!(length < 30_000);
            let mut bytes = vec![0; length];
            reader.read_exact(&mut bytes).unwrap();
            let body = if first.starts_with("GET /v1/models ") {
                json!({"data":[{"id":"fixture-model"}]})
            } else {
                assert!(first.starts_with("POST /v1/chat/completions "));
                let request: Value = serde_json::from_slice(&bytes).unwrap();
                assert!(
                    request["response_format"]["json_schema"]["schema"]["properties"]["paragraphs"]
                        .is_object()
                );
                let prompt: Value =
                    serde_json::from_str(request["messages"][1]["content"].as_str().unwrap())
                        .unwrap();
                generated = true;
                json!({"choices":[{"finish_reason":"stop","message":{"content":one_answer(&prompt,"note").to_string()}}]})
            };
            let response = body.to_string();
            write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",response.len(),response).unwrap();
        }
        assert!(generated);
    });
    let result = answer(root.path(), &input("пилот")).unwrap();
    server.join().unwrap();
    assert_eq!(result["title"], "О пилоте");
    assert_eq!(result["sources"][0]["kind"], "note");
}

fn stamped_summary(root: &Path) -> std::path::PathBuf {
    let dir = meeting(root);
    let mut summary = safe_json(&dir.join("summary.json"), 8 * 1_048_576).unwrap();
    summary["sourceFingerprint"] = json!(format!(
        "{:x}",
        Sha256::digest(fs::read(dir.join("transcript.json")).unwrap())
    ));
    summary["items"][0]["kind"] = json!("action");
    atomic_json(&dir.join("summary.json"), &summary).unwrap();
    dir
}
#[test]
fn explicit_stale_dependencies_are_not_reborn_as_fresh_file_stamps() {
    for state in ["sourceStale", "overviewStale", "fingerprintMismatch"] {
        let root = enabled_root();
        let dir = stamped_summary(root.path());
        let before = retrieve(root.path(), &input("пилот")).unwrap();
        let virtual_task = before
            .candidates
            .iter()
            .find(|c| c.source.kind == "task")
            .unwrap();
        let context = domain(
            root.path(),
            "task-context",
            json!({"taskID":virtual_task.source.task_id}),
        )
        .unwrap();
        domain(root.path(),"task-details-update",json!({"taskID":context["task"]["id"],"expectedRevision":context["task"]["revision"],"expectedSourceFingerprint":context["task"]["sourceFingerprint"],"operationID":uuid::Uuid::new_v4().to_string(),"patch":{"owner":"Принятая задача"}})).unwrap();
        // A second action stays virtual, while the accepted canonical task is independent.
        let mut summary = safe_json(&dir.join("summary.json"), 8 * 1_048_576).unwrap();
        summary["items"].as_array_mut().unwrap().push(json!({"kind":"action","text":"Пилот: виртуальная задача","owner":"","due":"","segmentIDs":[7]}));
        if state == "fingerprintMismatch" {
            let mut transcript = safe_json(&dir.join("transcript.json"), 64 * 1_048_576).unwrap();
            transcript["segments"][0]["text"] = json!("Пилот перенесён на понедельник");
            atomic_json(&dir.join("transcript.json"), &transcript).unwrap();
        } else {
            summary[state] = json!(true);
        }
        atomic_json(&dir.join("summary.json"), &summary).unwrap();
        let found = retrieve(root.path(), &input("пилот")).unwrap();
        assert!(
            found
                .candidates
                .iter()
                .any(|c| c.source.kind == "task" && c.source.excerpt.contains("Принятая задача")),
            "accepted canonical task remains current"
        );
        if state == "overviewStale" {
            assert!(found
                .candidates
                .iter()
                .any(|c| c.source.kind == "summary" && c.source.item_index.is_some()));
            assert!(found.candidates.iter().any(|c| c.source.kind == "card"));
            assert!(!found
                .candidates
                .iter()
                .any(|c| c.source.kind == "summary" && c.source.item_index.is_none()));
        } else {
            assert!(!found
                .candidates
                .iter()
                .any(|c| ["summary", "card"].contains(&c.source.kind.as_str())));
            assert!(!found.candidates.iter().any(|c| c
                .source
                .task_id
                .as_deref()
                .is_some_and(|id| id.starts_with("summary:"))));
        }
        // Re-indexed stale data has a perfectly current file stamp. That stamp
        // must not override the explicit dependency state during navigation.
        let indexed = crate::search::search(root.path(), "пилот", "cards", 5).unwrap();
        let hit = &indexed["hits"][0];
        assert_eq!(
            crate::search::validate(
                root.path(),
                "meeting-one",
                hit["sourceFingerprint"].as_str().unwrap()
            )
            .unwrap()["valid"],
            true
        );
        let mut card = source(
            "card",
            "meeting-one:card-card-one",
            "Пилот",
            "stale",
            hit["sourceFingerprint"].as_str().unwrap().into(),
        );
        card.meeting_id = Some("meeting-one".into());
        card.card_id = Some("card-one".into());
        assert_eq!(
            current(root.path(), &card, &input("пилот")).unwrap(),
            state == "overviewStale"
        );
    }
}

#[test]
fn dependency_changes_during_generation_remove_the_whole_cited_paragraph() {
    let root = enabled_root();
    let dir = stamped_summary(root.path());
    let result = answer_with(root.path(), &input("пилот"), |p| {
        let mut summary = safe_json(&dir.join("summary.json"), 8 * 1_048_576).unwrap();
        summary["sourceStale"] = json!(true);
        atomic_json(&dir.join("summary.json"), &summary).unwrap();
        Ok(one_answer(p, "card"))
    })
    .unwrap();
    assert_eq!(result["title"], "Недостаточно данных");
    assert_eq!(result["sources"], json!([]));
}

#[test]
fn long_task_tail_keeps_matching_constraint_and_current_structured_fields() {
    let root = enabled_root();
    let marker = "НЕУДАЛЯЕМЫЙ_АРХИВ";
    let body = format!(
        "{} Нельзя удалять {marker} до отдельного согласования.",
        "Общие условия. ".repeat(200)
    );
    let t=domain(root.path(),"task-create",json!({"title":"Архивные требования","text":body,"owner":"Анна","due":"2026-11-03","operationID":uuid::Uuid::new_v4().to_string()})).unwrap();
    for i in 0..20 {
        task(root.path(), &format!("Обычная задача {i}"));
    }
    let found = retrieve(root.path(), &input(marker)).unwrap();
    let s = &found
        .candidates
        .iter()
        .find(|c| {
            c.source
                .task_id
                .as_ref()
                .is_some_and(|id| t["id"] == id.as_str())
        })
        .unwrap()
        .source;
    assert!(s.excerpt.contains(marker), "{}", s.excerpt);
    assert!(
        s.excerpt.contains("Нельзя удалять"),
        "negation and constraint must surround the match"
    );
    for field in ["Статус: todo", "Анна", "2026-11-03"] {
        assert!(s.excerpt.contains(field), "missing {field}: {}", s.excerpt);
    }
}

#[test]
fn legacy_summary_dependency_uncertainty_is_explicit_not_a_verified_quote() {
    let root = enabled_root();
    meeting(root.path());
    let found = retrieve(root.path(), &input("пилот")).unwrap();
    assert!(found
        .candidates
        .iter()
        .filter(|c| ["summary", "card"].contains(&c.source.kind.as_str()))
        .all(|c| c.source.dependency_unknown));
    assert!(found
        .warnings
        .iter()
        .any(|w| w.contains("нет версии исходного транскрипта")));
    assert!(SYSTEM.contains("never present its text as a verified or verbatim transcript quote"));
}

#[test]
fn calendar_query_and_explicit_day_are_selected_before_the_128_limit() {
    let root = enabled_root();
    let now = 1_793_145_600.0;
    let mut snapshot = calendar();
    snapshot["coverageStart"] = json!(now - 86_400.0);
    snapshot["coverageEnd"] = json!(now + 15.0 * 86_400.0);
    let mut events = Vec::new();
    for i in 0..150 {
        events.push(json!({"id":format!("near-{i}"),"title":"Ежедневная встреча","start":now+i as f64*30.0,"end":now+i as f64*30.0+60.0,"allDay":false,"calendarTitle":"Личный"}));
    }
    let far = now + 8.0 * 86_400.0;
    events.push(json!({"id":"far-topic","title":"УНИКАЛЬНЫЙ_ПРОЕКТ_ХВОСТ","start":far,"end":far+3600.0,"allDay":false,"calendarTitle":"Личный"}));
    snapshot["events"] = json!(events);
    let mut args = input("УНИКАЛЬНЫЙ_ПРОЕКТ_ХВОСТ");
    args["calendar"] = snapshot.clone();
    args["now"] = json!(now);
    args["text"] = json!("Найди событие по уникальному проекту");
    let result = answer_with(root.path(), &args, |p| {
        assert_eq!(p["sources"][0]["eventID"], "far-topic");
        Ok(one_answer(p, "calendar"))
    })
    .unwrap();
    assert_eq!(result["sources"][0]["eventID"], "far-topic");
    assert_eq!(result["truncated"], true);
    assert_eq!(
        validate_source(
            root.path(),
            &json!({"source":result["sources"][0],"calendar":snapshot})
        )
        .unwrap()["valid"],
        true,
        "navigation revalidation must not repeat nearest-128 retrieval"
    );
    let day = FixedOffset::east_opt(3 * 3600)
        .unwrap()
        .timestamp_opt(far as i64, 0)
        .unwrap()
        .format("%Y-%m-%d")
        .to_string();
    args["query"] = json!("");
    args["text"] = json!(format!("Какие встречи на {day}?"));
    let found = retrieve(root.path(), &args).unwrap();
    assert_eq!(found.candidates.len(), 1);
    assert_eq!(
        found.candidates[0].source.event_id.as_deref(),
        Some("far-topic")
    );
    assert!(found.calendar["requestedStart"].is_string());
}

#[test]
fn calendar_relative_period_and_partial_coverage_are_not_silently_broadened() {
    let root = enabled_root();
    let mut args = input("");
    args["calendar"] = calendar();
    args["text"] = json!("Что у меня послезавтра?");
    let (now, offset) = validate_clock(&args).unwrap();
    let period = requested_period(&args, now, offset).unwrap().unwrap();
    let day = FixedOffset::east_opt(3 * 3600)
        .unwrap()
        .timestamp_opt(now as i64, 0)
        .unwrap()
        .date_naive();
    let expected = FixedOffset::east_opt(3 * 3600)
        .unwrap()
        .from_local_datetime(
            &day.checked_add_signed(chrono::Duration::days(2))
                .unwrap()
                .and_hms_opt(0, 0, 0)
                .unwrap(),
        )
        .unwrap()
        .timestamp() as f64;
    assert_eq!(period, (expected, expected + 86_400.0));
    args["periodStart"] = json!(1_792_000_000.0);
    args["periodEnd"] = json!(1_792_086_400.0);
    let found = retrieve(root.path(), &args).unwrap();
    assert!(found.candidates.is_empty());
    assert!(found.truncated);
    assert!(found
        .warnings
        .iter()
        .any(|w| w.contains("выходит за доступный снимок")));
}

#[test]
fn fts_bm25_ranks_survive_batch_fusion_instead_of_becoming_recency_order() {
    let root = enabled_root();
    for i in 0..18 {
        let dir = root.path().join("meetings").join(format!("rank-{i}"));
        atomic_json(&dir.join("meta.json"),&json!({"id":format!("rank-{i}"),"title":format!("Разговор {i}"),"createdAt":i as f64,"source":"source.mp3"})).unwrap();
        let body = format!(
            "{} {}",
            "пилот ".repeat(18 - i),
            "разные слова ".repeat(i + 1)
        );
        atomic_json(
            &dir.join("transcript.json"),
            &json!({"segments":[{"id":7,"start":0.0,"end":4.0,"text":body}]}),
        )
        .unwrap();
    }
    let results =
        crate::search::search_batch(root.path(), &[("пилот".into(), "transcript".into(), 6)])
            .unwrap();
    let expected: Vec<_> = results[0]["hits"]
        .as_array()
        .unwrap()
        .iter()
        .map(|hit| hit["meetingID"].as_str().unwrap().to_owned())
        .collect();
    let found = retrieve(root.path(), &input("пилот")).unwrap();
    let actual: Vec<_> = found
        .candidates
        .iter()
        .filter(|c| c.source.kind == "transcript")
        .take(6)
        .map(|c| c.source.meeting_id.clone().unwrap())
        .collect();
    assert_eq!(actual, expected);
    assert_ne!(
        actual[0], "rank-17",
        "newest weak lexical match cannot replace the BM25 winner"
    );
}

#[test]
fn calendar_event_uses_endpoint_offsets_across_dst_with_canonical_epochs() {
    let root = enabled_root();
    let begin = chrono::DateTime::parse_from_rfc3339("2026-10-25T00:30:00Z")
        .unwrap()
        .timestamp() as f64;
    let finish = begin + 3600.0;
    let event = json!({"id":"dst-occurrence","title":"Release review","start":begin,"end":finish,"allDay":false,"calendarTitle":"Personal","startOffsetMinutes":120,"endOffsetMinutes":60});
    let snapshot = json!({"connected":true,"coverageStart":begin-86400.0,"coverageEnd":finish+86400.0,"events":[event]});
    let mut args = input("release");
    args["text"] = json!("When is Release review?");
    args["now"] = json!(begin - 3600.0);
    args["timeZoneOffsetMinutes"] = json!(60);
    args["calendar"] = snapshot.clone();
    let result = answer_with(root.path(), &args, |prompt| {
        let source = &prompt["sources"][0];
        let excerpt = source["excerpt"].as_str().unwrap();
        assert!(
            excerpt.contains("Начало: 2026-10-25T02:30:00+02:00"),
            "{excerpt}"
        );
        assert!(
            excerpt.contains("Конец: 2026-10-25T02:30:00+01:00"),
            "{excerpt}"
        );
        Ok(one_answer(prompt, "calendar"))
    })
    .unwrap();
    assert_eq!(finish - begin, 3600.0);
    let source = &result["sources"][0];
    assert_eq!(
        validate_source(root.path(), &json!({"source":source,"calendar":snapshot})).unwrap()
            ["valid"],
        true
    );
    let mut changed = snapshot.clone();
    changed["events"][0]["startOffsetMinutes"] = json!(60);
    assert_eq!(
        validate_source(root.path(), &json!({"source":source,"calendar":changed})).unwrap()
            ["valid"],
        false,
        "changed local-date interpretation is a stale citation"
    );
    args["calendar"]["events"][0]["endOffsetMinutes"] = json!(841);
    let invalid = retrieve(root.path(), &args).unwrap();
    assert!(invalid.candidates.is_empty());
    assert!(invalid
        .warnings
        .iter()
        .any(|warning| warning.contains("часовым поясом")));
}

#[test]
fn disabled_optional_kinds_are_absent_and_saved_routes_become_invalid() {
    let root = enabled_root();
    note(root.path(), "n-opt", "Пилот и следующий шаг");
    task(root.path(), "Пилот: проверить");
    meeting(root.path());
    let mut args = input("пилот"); args["calendar"] = calendar();
    let before = lookup(root.path(), &args).unwrap();
    let disabled: Vec<_> = before["sources"].as_array().unwrap().iter().filter(|s| ["card","task","calendar"].contains(&s["kind"].as_str().unwrap_or(""))).cloned().collect();
    for kind in ["card","task","calendar"] { assert!(disabled.iter().any(|s| s["kind"] == kind), "missing {kind}"); }
    atomic_json(&root.path().join("settings.json"), &json!({"features":{"assistant":true}})).unwrap();
    let after = lookup(root.path(), &args).unwrap();
    assert!(after["sources"].as_array().unwrap().iter().all(|s| !["card","task","calendar","code"].contains(&s["kind"].as_str().unwrap_or(""))));
    assert!(after["sources"].as_array().unwrap().iter().any(|s| s["kind"] == "note"));
    for source in disabled { assert_eq!(validate_source(root.path(), &json!({"source":source,"calendar":calendar(),"now":args["now"],"timeZoneOffsetMinutes":180})).unwrap()["valid"], false); }
    assert!(embedding_documents(root.path()).unwrap().0.is_empty());
    assert!(!root.path().join("cache/semantic.sqlite").exists());
    // Disabled calendar data is ignored rather than validated or persisted.
    args["calendar"] = json!({"connected":true,"events":"invalid-event-snapshot"});
    assert!(lookup(root.path(), &args).is_ok());
}
#[test]
fn assistant_off_never_calls_model_and_revoked_module_citations_are_removed() {
    let root = tempfile::tempdir().unwrap();
    note(root.path(), "n-kept", "Пилот начинается в пятницу.");
    let mut called = false;
    let result = answer_with(root.path(), &input("пилот"), |_| { called = true; unreachable!() });
    assert!(result.unwrap_err().to_string().contains("Включите «Помощник»"));
    assert!(!called);
    atomic_json(&root.path().join("settings.json"), &json!({"features":{"assistant":true,"tasks":true}})).unwrap();
    task(root.path(), "Проверить пилот");
    let answer = answer_with(root.path(), &input("пилот"), |prompt| {
        let paragraphs: Vec<_> = prompt["sources"].as_array().unwrap().iter().filter(|s| ["note","task"].contains(&s["kind"].as_str().unwrap_or(""))).map(|s| json!({"text":s["excerpt"],"sourceIDs":[s["id"]]})).collect();
        assert!(prompt["sources"].as_array().unwrap().iter().any(|s| s["kind"] == "task"));
        atomic_json(&root.path().join("settings.json"), &json!({"features":{"assistant":true}})).unwrap();
        Ok(json!({"title":"Пилот","paragraphs":paragraphs}))
    }).unwrap();
    assert!(!answer["paragraphs"].as_array().unwrap().is_empty());
    assert!(answer["sources"].as_array().unwrap().iter().all(|s| s["kind"] == "note"));
}

#[test]
fn folder_search_and_embeddings_respect_each_sources_effective_profile() {
    let root=tempfile::tempdir().unwrap();
    atomic_json(&root.path().join("settings.json"),&json!({"features":{}})).unwrap();
    let folder=crate::folders::save(root.path(),crate::folders::Folder{id:"english".into(),name:"Английский".into(),revision:0,overrides:json!({"features":{"assistant":true,"semanticSearch":true}})}).unwrap();
    let mut allowed=note(root.path(),"allowed","Пилот запускается в пятницу.");allowed.folder_id=Some(folder.id.clone());crate::notes::save_note(root.path(),allowed).unwrap();
    note(root.path(),"base","Пилот запускается в понедельник.");
    let mut request=input("пилот");request["folderID"]=json!(folder.id);
    let found=lookup(root.path(),&request).unwrap();assert!(!found["sources"].as_array().unwrap().is_empty());assert!(found["sources"].as_array().unwrap().iter().all(|source|source["noteID"]=="allowed"));
    let answer=answer_with(root.path(),&request,|prompt|Ok(one_answer(prompt,"note"))).unwrap();assert_eq!(answer["sources"][0]["noteID"],"allowed");
    let(docs,_)=embedding_documents(root.path()).unwrap();assert!(!docs.is_empty());assert!(docs.iter().all(|d|d.source["noteID"]=="allowed"));
    let global=answer_with(root.path(),&input("пилот"),|_|panic!("global assistant must remain disabled"));assert!(global.is_err());
}


#[test]
fn lookup_exposes_semantic_outcome_independently_of_lexical_results() {
    let root = enabled_root();
    note(root.path(), "semantic-status-note", "Пилот запускается в пятницу.");
    let matching = json!({"text":"пилот", "query":"пилот", "kinds":["note"]});
    let empty = json!({"text":"zxqvabsence", "query":"zxqvabsence", "kinds":["transcript"]});
    let found = lookup(root.path(), &matching).unwrap();
    assert_eq!(found["semanticStatus"], "disabled");
    assert!(!found["sources"].as_array().unwrap().is_empty());
    let absent = lookup(root.path(), &empty).unwrap();
    assert_eq!(absent["semanticStatus"], "disabled");
    assert!(absent["sources"].as_array().unwrap().is_empty());
    let mut config = crate::semantic::Config::default();
    config.enabled = true;
    crate::semantic::dispatch(root.path(), &json!({"command":"semantic-config", "config":config})).unwrap();
    let preparing = lookup(root.path(), &matching).unwrap();
    assert_eq!(preparing["semanticStatus"], "needsRefresh");
    assert!(!preparing["sources"].as_array().unwrap().is_empty());
    // A broken enabled configuration is a failure, never a successful semantic
    // query inferred from the fact that lexical hits remain available.
    fs::write(root.path().join("semantic-settings.json"), b"invalid JSON").unwrap();
    let unavailable = lookup(root.path(), &matching).unwrap();
    assert_eq!(unavailable["semanticStatus"], "unavailable");
    assert!(!unavailable["sources"].as_array().unwrap().is_empty());
}
