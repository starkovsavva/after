use super::*;
fn call(root: &Path, command: &str, mut args: Value) -> Result<Value> {
    args["command"] = json!(command);
    crate::cards::dispatch(root, &args)
}
fn deck(root: &Path, front: &str, back: &str) -> Value {
    call(
        root,
        "card-save",
        json!({"front":front,"back":back,"newDeckTitle":"Английский"}),
    )
    .unwrap()
}
fn entries(root: &Path) -> Vec<Value> {
    call(root, "cards-library", json!({})).unwrap()["entries"]
        .as_array()
        .unwrap()
        .clone()
}
fn change(e: &Value) -> Value {
    json!({"meetingID":e["meeting"]["id"],"cardID":e["card"]["id"],"expectedFingerprint":e["fingerprint"],"front":"согласовать сроки","back":"agree on deadlines"})
}
#[test]
fn delete_restore_preserves_identity_sources_and_review_history() {
    let temp = tempfile::tempdir().unwrap();
    deck(temp.path(), "follow up", "вернуться к вопросу");
    let e = entries(temp.path()).remove(0);
    let dir = meeting_directory(temp.path(), e["meeting"]["id"].as_str().unwrap()).unwrap();
    let reviews = json!({e["card"]["id"].as_str().unwrap():{"due":"2030-01-01T00:00:00Z","count":7,"lastRating":3}});
    atomic_json(&dir.join("review-state.json"), &reviews).unwrap();
    call(temp.path(), "card-delete", change(&e)).unwrap();
    assert!(entries(temp.path()).is_empty());
    let trash = call(temp.path(), "card-trash-list", json!({})).unwrap()["entries"][0].clone();
    assert_eq!(trash["cardID"], e["card"]["id"]);
    assert!(call(temp.path(),"card-restore",json!({"meetingID":trash["meetingID"],"trashID":trash["trashID"],"expectedFingerprint":"stale"})).is_err());
    call(temp.path(),"card-restore",json!({"meetingID":trash["meetingID"],"trashID":trash["trashID"],"expectedFingerprint":trash["fingerprint"]})).unwrap();
    let restored = entries(temp.path()).remove(0);
    assert_eq!(restored["card"], e["card"]);
    assert_eq!(restored["review"]["count"], 7);
    assert_eq!(
        regular_json(&dir.join("review-state.json")).unwrap(),
        reviews
    );
}
#[test]
fn expired_trash_refuses_restore_and_purge_keeps_unexpired() {
    let temp = tempfile::tempdir().unwrap();
    deck(temp.path(), "one", "один");
    let e = entries(temp.path()).remove(0);
    call(temp.path(), "card-delete", change(&e)).unwrap();
    let dir = meeting_directory(temp.path(), e["meeting"]["id"].as_str().unwrap()).unwrap();
    let mut summary = regular_json(&dir.join("summary.json")).unwrap();
    summary["archivedCards"][0]["deletedAt"] = json!(now() - RETENTION_MS - 1);
    atomic_json(&dir.join("summary.json"), &summary).unwrap();
    let archived = &summary["archivedCards"][0];
    assert!(call(temp.path(),"card-restore",json!({"meetingID":e["meeting"]["id"],"trashID":trash_key(archived),"expectedFingerprint":fingerprint(archived)})).is_err());
    assert_eq!(
        call(temp.path(), "card-trash-purge", json!({})).unwrap()["purged"],
        1
    );
}
#[test]
fn batch_rewrite_is_idempotent_preserves_ids_review_and_undo() {
    let temp = tempfile::tempdir().unwrap();
    deck(temp.path(), "follow up", "вернуться к вопросу");
    let e = entries(temp.path()).remove(0);
    let args = json!({"operationID":"rewrite-1","action":"rewriteCards","changes":[change(&e)]});
    assert_eq!(
        call(temp.path(), "cards-batch-apply", args.clone()).unwrap(),
        call(temp.path(), "cards-batch-apply", args.clone()).unwrap()
    );
    let updated = entries(temp.path()).remove(0);
    assert_eq!(updated["card"]["id"], e["card"]["id"]);
    assert_eq!(updated["card"]["front"], "согласовать сроки");
    let dir = meeting_directory(temp.path(), e["meeting"]["id"].as_str().unwrap()).unwrap();
    let reviews = json!({e["card"]["id"].as_str().unwrap():{"due":"2030-01-01T00:00:00Z","count":3,"lastRating":3}});
    atomic_json(&dir.join("review-state.json"), &reviews).unwrap();
    call(
        temp.path(),
        "cards-batch-undo",
        json!({"operationID":"rewrite-1"}),
    )
    .unwrap();
    assert_eq!(entries(temp.path())[0]["card"], e["card"]);
    assert_eq!(
        regular_json(&dir.join("review-state.json")).unwrap(),
        reviews
    );
    assert!(call(temp.path(), "cards-batch-apply", args).is_err());
}
#[test]
fn stale_card_in_second_deck_prevents_any_partial_write() {
    let temp = tempfile::tempdir().unwrap();
    deck(temp.path(), "one", "один");
    deck(temp.path(), "two", "два");
    let es = entries(temp.path());
    let before = es[0]["card"].clone();
    let mut edit = change(&es[1]);
    edit["front"] = json!("edited");
    call(temp.path(), "card-save", edit).unwrap();
    assert!(call(temp.path(),"cards-batch-apply",json!({"operationID":"stale","action":"trashCards","changes":es.iter().map(change).collect::<Vec<_>>()})).is_err());
    assert_eq!(entries(temp.path())[0]["card"], before);
    assert_eq!(entries(temp.path()).len(), 2);
}
#[test]
fn durable_redo_recovers_exact_snapshots_and_rejects_changed_selection() {
    let temp = tempfile::tempdir().unwrap();
    deck(temp.path(), "one", "один");
    deck(temp.path(), "two", "два");
    let es = entries(temp.path());
    let args = json!({"operationID":"crash","action":"trashCards","changes":es.iter().map(change).collect::<Vec<_>>()});
    call(temp.path(), "cards-batch-apply", args.clone()).unwrap();
    let path = journal_path(temp.path(), "crash").unwrap();
    let mut journal = read_journal(&path).unwrap();
    journal["committed"] = json!(false);
    let first = &journal["decks"][0];
    atomic_json(
        &meeting_directory(temp.path(), first["meetingID"].as_str().unwrap())
            .unwrap()
            .join("summary.json"),
        &first["before"],
    )
    .unwrap();
    atomic_json(&path, &journal).unwrap();
    let recovered = call(temp.path(), "cards-batch-recover", json!({})).unwrap();
    assert_eq!(recovered["recovered"], 1);
    assert_eq!(recovered["errors"], json!([]));
    call(temp.path(), "cards-batch-apply", args.clone()).unwrap();
    assert!(entries(temp.path()).is_empty());
    assert_eq!(
        call(temp.path(), "card-trash-list", json!({})).unwrap()["entries"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    let mut altered = args;
    altered["changes"].as_array_mut().unwrap().pop();
    assert!(call(temp.path(), "cards-batch-apply", altered).is_err());
}
#[test]
fn unsafe_operation_paths_and_unknown_card_ids_cannot_write() {
    let temp = tempfile::tempdir().unwrap();
    deck(temp.path(), "one", "один");
    let e = entries(temp.path()).remove(0);
    assert!(call(
        temp.path(),
        "cards-batch-apply",
        json!({"operationID":"../evil","action":"trashCards","changes":[change(&e)]})
    )
    .is_err());
    let mut c = change(&e);
    c["cardID"] = json!("invented");
    assert!(call(
        temp.path(),
        "cards-batch-apply",
        json!({"operationID":"forged","action":"rewriteCards","changes":[c]})
    )
    .is_err());
    assert_eq!(entries(temp.path())[0]["card"], e["card"]);
}
