use super::*;
fn setup() -> (tempfile::TempDir, String) {
    let root = tempfile::tempdir().unwrap();
    crate::storage::atomic_json(
        &root.path().join("settings.json"),
        &json!({"features":{"tasks":true,"knowledgeBase":true}}),
    )
    .unwrap();
    let task=crate::task_workspace::dispatch(root.path(),&json!({"command":"task-create","title":"Synthetic project","text":"Plan a launch","operationID":uuid()})).unwrap();
    crate::notes::save_note(root.path(),serde_json::from_value(json!({"id":"shared","kind":"note","title":"Launch plan","text":"NEPTUNE release Friday","createdAt":1,"updatedAt":1,"revision":0})).unwrap()).unwrap();
    crate::notes::save_note(root.path(),serde_json::from_value(json!({"id":"private","kind":"note","title":"Private","text":"FORBIDDEN private credentials","createdAt":1,"updatedAt":1,"revision":0})).unwrap()).unwrap();
    dispatch(
        root.path(),
        &json!({"command":"agent-share-settings","enabled":true,"expectedRevision":0}),
    )
    .unwrap();
    (root, task["id"].as_str().unwrap().into())
}
fn grant(root: &Path, task: &str, s: &Session) -> String {
    let note = crate::notes::load_note_snapshot(root, "shared").unwrap();
    let preview=dispatch(root,&json!({"command":"agent-share-preview","taskID":task,"sources":[{"noteID":"shared","revision":note.revision}]})).unwrap();
    let result=dispatch(root,&json!({"command":"agent-share-approve","draftID":preview["id"],"digest":preview["digest"],"sessionID":s.id})).unwrap();
    result["id"].as_str().unwrap().into()
}
#[test]
fn immutable_package_ignores_legacy_writes_and_never_expands_scope() {
    let (root, task) = setup();
    let s = connect(root.path(), "Test client").unwrap();
    assert!(authorized(&open(root.path()).unwrap(), &s).is_err());
    let share = grant(root.path(), &task, &s);
    let mut note = crate::notes::load_note_snapshot(root.path(), "shared").unwrap();
    note.text = "NEW private edit".into();
    crate::notes::save_note(root.path(), note).unwrap();
    crate::storage::atomic_json(
        &root.path().join("settings.json"),
        &json!({"features":{"tasks":false,"knowledgeBase":false},"agentAccess":{"enabled":false}}),
    )
    .unwrap();
    let mut db = open(root.path()).unwrap();
    let found = tool(
        &mut db,
        &s,
        "after_share_search",
        &json!({"query":"NEPTUNE"}),
    )
    .unwrap();
    assert_eq!(found["sources"].as_array().unwrap().len(), 1);
    assert!(!found.to_string().contains("NEW"));
    let private = tool(
        &mut db,
        &s,
        "after_share_search",
        &json!({"query":"FORBIDDEN"}),
    )
    .unwrap();
    assert!(private["sources"].as_array().unwrap().is_empty());
    let source = &found["sources"][0];
    let read = tool(
        &mut db,
        &s,
        "after_share_read",
        &json!({"sourceID":source["id"],"fingerprint":source["fingerprint"]}),
    )
    .unwrap();
    assert_eq!(read["text"], "NEPTUNE release Friday");
    dispatch(
        root.path(),
        &json!({"command":"agent-share-revoke","shareID":share}),
    )
    .unwrap();
    assert!(tool(
        &mut db,
        &s,
        "after_share_search",
        &json!({"query":"NEPTUNE"})
    )
    .is_err());
}
#[test]
fn connection_capability_cannot_be_selected_by_model_or_another_session() {
    let (root, task) = setup();
    let a = connect(root.path(), "A").unwrap();
    let b = connect(root.path(), "B").unwrap();
    grant(root.path(), &task, &a);
    let mut db = open(root.path()).unwrap();
    assert!(tool(
        &mut db,
        &b,
        "after_share_search",
        &json!({"query":"NEPTUNE"})
    )
    .is_err());
    assert!(tool(
        &mut db,
        &a,
        "after_share_search",
        &json!({"query":"NEPTUNE","sessionID":b.id})
    )
    .is_err());
    let forged = Session {
        id: a.id.clone(),
        secret: b.secret.clone(),
    };
    assert!(authorized(&db, &forged).is_err());
    let status = status(root.path(), &a).unwrap().to_string();
    assert!(!status.contains(&a.secret));
    assert!(!status.contains(&a.id));
}
#[test]
fn preview_digest_expiry_master_off_and_report_receipts() {
    let (root, task) = setup();
    let a = connect(root.path(), "A").unwrap();
    let note = crate::notes::load_note_snapshot(root.path(), "shared").unwrap();
    let preview = prepare(
        root.path(),
        &json!({"taskID":task,"sources":[{"noteID":"shared","revision":note.revision}]}),
    )
    .unwrap();
    assert!(approve(
        root.path(),
        &json!({"draftID":preview["id"],"digest":"wrong","sessionID":a.id})
    )
    .is_err());
    let share = grant(root.path(), &task, &a);
    let mut db = open(root.path()).unwrap();
    let hit = tool(
        &mut db,
        &a,
        "after_share_search",
        &json!({"query":"NEPTUNE"}),
    )
    .unwrap()["sources"][0]
        .clone();
    let mut report = json!({"snapshotID":share,"operationID":uuid(),"text":"The release is Friday.","evidence":[{"sourceID":hit["id"],"fingerprint":hit["fingerprint"]}],"artifacts":[{"title":"Checklist","text":"Verify the release"}],"completed":true});
    assert!(tool(&mut db, &a, "after_share_report", &report).is_err());
    tool(&mut db, &a, "after_share_read", &report["evidence"][0]).unwrap();
    let saved = tool(&mut db, &a, "after_share_report", &report).unwrap();
    assert_eq!(
        saved,
        tool(&mut db, &a, "after_share_report", &report).unwrap()
    );
    report["text"] = json!("changed retry");
    assert!(tool(&mut db, &a, "after_share_report", &report).is_err());
    let history = dispatch(
        root.path(),
        &json!({"command":"agent-share-history","taskID":task}),
    )
    .unwrap();
    assert_eq!(history["reports"].as_array().unwrap().len(), 1);
    assert_eq!(history["shares"][0]["id"], share);
    let original =
        crate::task_workspace::dispatch(root.path(), &json!({"command":"task-get","taskID":task}))
            .unwrap();
    assert_ne!(original["status"], "done");
    assert!(!original.to_string().contains("Checklist"));
    dispatch(
        root.path(),
        &json!({"command":"agent-share-settings","enabled":false,"expectedRevision":1}),
    )
    .unwrap();
    assert!(authorized(&db, &a).is_err());
    dispatch(
        root.path(),
        &json!({"command":"agent-share-settings","enabled":true,"expectedRevision":2}),
    )
    .unwrap();
    assert!(
        authorized(&db, &a).is_err(),
        "re-enabling must not resurrect revoked shares"
    );
}
#[test]
fn revocation_waits_for_publication_and_old_writer_does_not_own_authority() {
    let (root, task) = setup();
    let a = connect(root.path(), "A").unwrap();
    let share = grant(root.path(), &task, &a);
    let publication = gate(root.path(), false).unwrap();
    let (sent, received) = std::sync::mpsc::channel();
    let path = root.path().to_owned();
    let thread = std::thread::spawn(move || {
        dispatch(
            &path,
            &json!({"command":"agent-share-revoke","shareID":share}),
        )
        .unwrap();
        sent.send(()).unwrap();
    });
    assert!(received.recv_timeout(Duration::from_millis(50)).is_err());
    drop(publication);
    received.recv_timeout(Duration::from_secs(3)).unwrap();
    thread.join().unwrap();
    assert!(authorized(&open(root.path()).unwrap(), &a).is_err());
}
#[test]
fn expired_draft_and_symlink_store_are_rejected() {
    let (root, task) = setup();
    let s = connect(root.path(), "Test").unwrap();
    let note = crate::notes::load_note_snapshot(root.path(), "shared").unwrap();
    let p = prepare(
        root.path(),
        &json!({"taskID":task,"sources":[{"noteID":"shared","revision":note.revision}]}),
    )
    .unwrap();
    open(root.path())
        .unwrap()
        .execute("UPDATE share_drafts SET expires=0", [])
        .unwrap();
    assert!(approve(
        root.path(),
        &json!({"draftID":p["id"],"digest":p["digest"],"sessionID":s.id})
    )
    .is_err());
    let other = tempfile::tempdir().unwrap();
    let path = root.path().join("agent-shares");
    fs::remove_dir_all(&path).unwrap();
    std::os::unix::fs::symlink(other.path(), path).unwrap();
    assert!(open(root.path()).is_err());
    assert!(fs::read_dir(other.path()).unwrap().next().is_none());
}

#[test]
fn pending_cleanup_preserves_active_approved_session_and_optional_types_are_strict() {
    let (root, task) = setup();
    let a = connect(root.path(), "A").unwrap();
    let share = grant(root.path(), &task, &a);
    let db = open(root.path()).unwrap();
    db.execute("UPDATE share_sessions SET last_seen=0 WHERE id=?1", [&a.id])
        .unwrap();
    let _b = connect(root.path(), "B").unwrap();
    assert!(authorized(&db, &a).is_ok());
    let mut db = db;
    assert!(tool(
        &mut db,
        &a,
        "after_share_search",
        &json!({"query":"NEPTUNE","limit":"8"})
    )
    .is_err());
    for extra in [
        json!({"artifacts":"wrong"}),
        json!({"evidence":false}),
        json!({"completed":"yes"}),
        json!({"artifacts":[{"title":"x","text":1}]}),
        json!({"artifacts":[{"title":"x","url":false}]}),
    ] {
        let mut args = json!({"snapshotID":share,"operationID":uuid(),"text":"Report"});
        for (k, v) in extra.as_object().unwrap() {
            args[k] = v.clone();
        }
        assert!(tool(&mut db, &a, "after_share_report", &args).is_err());
    }
}

#[test]
fn enumeration_and_renewal_fence_stale_work_without_losing_history() {
    for ended in ["active", "revoked", "expired", "masterOff"] {
        let (root, task) = setup();
        let old = connect(root.path(), "Renewing client").unwrap();
        let first_share = grant(root.path(), &task, &old);
        let mut db = open(root.path()).unwrap();
        let inventory = tool(&mut db, &old, "after_share_sources", &json!({})).unwrap();
        assert_eq!(inventory["snapshotID"], first_share);
        let sources = inventory["sources"].as_array().unwrap();
        assert_eq!(sources.len(), 2);
        assert!(sources
            .iter()
            .all(|s| s.get("text").is_none() && s.get("originID").is_none()));
        let source = sources.iter().find(|s| s["kind"] == "note").unwrap();
        let old_read = json!({"sourceID":source["id"],"fingerprint":source["fingerprint"]});
        let read = tool(&mut db, &old, "after_share_read", &old_read).unwrap();
        assert_eq!(read["snapshotID"], first_share);
        let old_report = json!({"snapshotID":first_share,"operationID":"same-operation","text":"Report on the first copy"});
        tool(&mut db, &old, "after_share_report", &old_report).unwrap();
        match ended {
            "revoked" => {
                dispatch(
                    root.path(),
                    &json!({"command":"agent-share-revoke","shareID":first_share}),
                )
                .unwrap();
            }
            "expired" => {
                db.execute("UPDATE shares SET expires=0 WHERE id=?1", [&first_share])
                    .unwrap();
            }
            "masterOff" => {
                dispatch(
                    root.path(),
                    &json!({"command":"agent-share-settings","enabled":false,"expectedRevision":1}),
                )
                .unwrap();
            }
            _ => (),
        }
        let old_code = status(root.path(), &old).unwrap()["connectionCode"].clone();
        let next = renew(root.path(), &old).unwrap();
        assert_ne!(old.id, next.id);
        assert_ne!(old.secret, next.secret);
        let pending = status(root.path(), &next).unwrap();
        assert_eq!(pending["approved"], false);
        assert_ne!(pending["connectionCode"], old_code);
        assert!(pending["snapshotID"].is_null());
        assert!(authorized(&db, &old).is_err());
        assert!(tool(&mut db, &next, "after_share_sources", &json!({})).is_err());
        assert!(tool(&mut db, &next, "after_share_report", &old_report).is_err());
        if ended == "masterOff" {
            dispatch(
                root.path(),
                &json!({"command":"agent-share-settings","enabled":true,"expectedRevision":2}),
            )
            .unwrap();
        }
        let next_share = grant(root.path(), &task, &next);
        assert_ne!(next_share, first_share);
        assert!(tool(&mut db, &next, "after_share_read", &old_read).is_err());
        assert!(tool(&mut db, &next, "after_share_report", &old_report).is_err());
        assert!(tool(
            &mut db,
            &next,
            "after_share_report",
            &json!({"operationID":"missing","text":"No fence"})
        )
        .is_err());
        let new_report = json!({"snapshotID":next_share,"operationID":"same-operation","text":"Report on the second copy"});
        tool(&mut db, &next, "after_share_report", &new_report).unwrap();
        let history = dispatch(
            root.path(),
            &json!({"command":"agent-share-history","taskID":task}),
        )
        .unwrap();
        assert_eq!(history["reports"].as_array().unwrap().len(), 2);
        assert_eq!(history["shares"].as_array().unwrap().len(), 2);
        assert_eq!(
            history["shares"]
                .as_array()
                .unwrap()
                .iter()
                .find(|s| s["id"] == first_share)
                .unwrap()["revoked"],
            true
        );
    }
}

#[test]
fn expired_pending_transport_can_request_fresh_approval_without_an_existing_grant() {
    let (root, _) = setup();
    let old = connect(root.path(), "Idle client").unwrap();
    let db = open(root.path()).unwrap();
    db.execute(
        "UPDATE share_sessions SET last_seen=0 WHERE id=?1",
        [&old.id],
    )
    .unwrap();
    connect(root.path(), "Another client").unwrap();
    assert!(authenticated(&db, &old).is_err());
    let next = renew(root.path(), &old).unwrap();
    assert_eq!(status(root.path(), &next).unwrap()["approved"], false);
    assert!(authorized(&db, &next).is_err());
}
