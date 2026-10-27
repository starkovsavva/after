use super::*;
fn proposal(action: &str) -> Proposal {
    Proposal {
        action: action.into(),
        query: String::new(),
        title: String::new(),
        text: String::new(),
        due: String::new(),
        owner: String::new(),
        set_due: false,
        set_owner: false,
        set_completed: false,
        completed: false,
        cards: vec![],
    }
}
fn setup(root: &Path) -> Value {
    domain(root,"card-save",json!({"front":"follow up","back":"вернуться к вопросу","newDeckTitle":"Рабочий английский"})).unwrap()
}
#[test]
fn selected_meeting_scope_never_includes_another_deck() {
    let temp = crate::voice::enabled_test_root();
    let a = setup(temp.path());
    setup(temp.path());
    let candidates = selected_cards(
        temp.path(),
        &json!({"meetingID":a["meeting"]["id"],"text":"Переделай все карточки"}),
        &proposal("rewriteCards"),
    )
    .unwrap();
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0]["meetingID"], a["meeting"]["id"]);
}
#[test]
fn rewrite_rejects_missing_duplicates_and_invented_ids() {
    let c = json!({"id":"deck:card","front":"one","back":"один","expectedFingerprint":"snapshot"});
    assert!(rewritten(
        &[c.clone()],
        &json!({"cards":[{"id":"another","front":"один","back":"one"}]})
    )
    .is_err());
    assert!(rewritten(&[c.clone()], &json!({"cards":[]})).is_err());
    let result = rewritten(
        &[c],
        &json!({"cards":[{"id":"deck:card","front":"один","back":"one"}]}),
    )
    .unwrap();
    assert_eq!(result[0]["expectedFingerprint"], "snapshot");
}
#[test]
fn bulk_preview_requires_confirmation_exact_supplied_ids_and_truthful_result() {
    let temp = crate::voice::enabled_test_root();
    let deck = setup(temp.path());
    let input = json!({"meetingID":deck["meeting"]["id"],"text":"Поменяй карточки: вопрос на русском, ответ на английском"});
    let p = proposal("rewriteCards");
    let candidates = selected_cards(temp.path(), &input, &p).unwrap();
    let mut changes = candidates.clone();
    changes[0]["front"] = json!("вернуться к вопросу");
    changes[0]["back"] = json!("follow up");
    let plan = store_prepared(temp.path(), &input, &p, &candidates, changes).unwrap();
    assert_eq!(plan["reviewRequired"], true);
    assert!(plan["candidates"][0]["detail"]
        .as_str()
        .unwrap()
        .contains("Будет:"));
    let mut apply_input = json!({"planID":plan["planID"],"operationID":plan["operationID"],"selectedTargetIDs":[plan["candidates"][0]["id"]]});
    assert!(apply(temp.path(), &apply_input).is_err());
    apply_input["confirmed"] = json!(true);
    let result = apply(temp.path(), &apply_input).unwrap();
    assert_eq!(result["title"], "Карточки обновлены");
    assert_eq!(apply(temp.path(), &apply_input).unwrap(), result);
    let mut forged = apply_input.clone();
    forged["selectedTargetIDs"] = json!(["forged"]);
    assert!(apply(temp.path(), &forged).is_err());
    undo(temp.path(), &json!({"operationID":plan["operationID"]})).unwrap();
    assert_eq!(apply(temp.path(), &apply_input).unwrap()["undone"], true);
}
#[test]
fn trash_and_restore_are_actual_reviewed_domain_actions() {
    let temp = crate::voice::enabled_test_root();
    let deck = setup(temp.path());
    let input = json!({"meetingID":deck["meeting"]["id"],"text":"Удали существующие карточки"});
    let p = prepare(temp.path(), &input, &proposal("trashCards")).unwrap();
    let args = json!({"planID":p["planID"],"operationID":p["operationID"],"confirmed":true,"selectedTargetIDs":[p["candidates"][0]["id"]]});
    let saved = apply(temp.path(), &args).unwrap();
    assert_eq!(saved["title"], "Карточки в корзине");
    assert!(
        domain(temp.path(), "cards-library", json!({})).unwrap()["entries"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let restored = prepare(temp.path(), &input, &proposal("restoreCards")).unwrap();
    apply(temp.path(),&json!({"planID":restored["planID"],"operationID":restored["operationID"],"confirmed":true,"selectedTargetIDs":[restored["candidates"][0]["id"]]})).unwrap();
    assert_eq!(
        domain(temp.path(), "cards-library", json!({})).unwrap()["entries"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

mod provider_checks {
    use super::*;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    #[test]
    fn real_planner_then_rewrite_proposes_selected_ids_without_writing_before_review() {
        let temp = crate::voice::enabled_test_root();
        let deck=domain(temp.path(),"card-save",json!({"front":"follow up","back":"вернуться к вопросу","newDeckTitle":"Рабочий английский"})).unwrap();
        domain(
            temp.path(),
            "card-save",
            json!({"front":"PRIVATE_OTHER_DECK_SENTINEL","back":"private","newDeckTitle":"Личное"}),
        )
        .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let scope = deck["meeting"]["id"].clone();
        let id = format!(
            "{}:{}",
            scope.as_str().unwrap(),
            deck["card"]["id"].as_str().unwrap()
        );
        let proposal = json!({"action":"rewriteCards","query":"","title":"","text":"","due":"","owner":"","setDue":false,"setOwner":false,"setCompleted":false,"completed":false,"cards":[]});
        let rewriting = json!({"cards":[{"id":id,"front":"вернуться к вопросу","back":"follow up"}],"clarification":""});
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
                let mut length = 0;
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
                }
                let mut bytes = vec![0; length];
                reader.read_exact(&mut bytes).unwrap();
                let body = if bytes.is_empty() {
                    Value::Null
                } else {
                    serde_json::from_slice::<Value>(&bytes).unwrap()
                };
                bodies.push(body);
                let response=if index%2==0{json!({"data":[{"id":"card-local-test"}]})}else{json!({"choices":[{"finish_reason":"stop","message":{"content":if index==1{proposal.to_string()}else{rewriting.to_string()}}}]})}.to_string();
                write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",response.len(),response).unwrap();
            }
            bodies
        });
        crate::storage::atomic_json(&temp.path().join("settings.json"),&json!({"features":{"assistant":true,"cards":true,"tasks":true,"calendar":true,"semanticSearch":true},"mode":"local","localProvider":"lmstudio","localModel":"card-local-test","localEndpoint":format!("http://{address}")})).unwrap();
        let plan=crate::voice::plan(temp.path(),&json!({"text":"Переделай все карточки: вопрос на русском, ответ на английском","meetingID":scope})).unwrap();
        assert_eq!(plan["action"], "rewriteCards");
        assert_eq!(plan["reviewRequired"], true);
        assert_eq!(plan["candidates"].as_array().unwrap().len(), 1);
        let bodies = fixture.join().unwrap();
        let sent = bodies[3]["messages"][1]["content"].as_str().unwrap();
        assert!(!sent.contains("PRIVATE_OTHER_DECK_SENTINEL"));
        assert!(sent.contains("follow up"));
        let library = domain(temp.path(), "cards-library", json!({"meetingID":scope})).unwrap();
        assert_eq!(library["entries"][0]["card"]["front"], "follow up");
        crate::voice::apply(temp.path(),&json!({"planID":plan["planID"],"operationID":plan["operationID"],"confirmed":true,"selectedTargetIDs":[plan["candidates"][0]["id"]]})).unwrap();
        let library = domain(temp.path(), "cards-library", json!({"meetingID":scope})).unwrap();
        assert_eq!(
            library["entries"][0]["card"]["front"],
            "вернуться к вопросу"
        );
        assert_eq!(library["entries"][0]["card"]["back"], "follow up");
    }
}
