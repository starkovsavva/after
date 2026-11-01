//! Runs the same host subprocess transport as native IPC, against a real engine
//! and a new synthetic data directory. No account, provider or existing library.
#![cfg(debug_assertions)]
use after_desktop::{
    bridge::LibraryBridge,
    models::{SaveFolderInput, SaveNoteInput},
};
use serde_json::json;
use std::path::PathBuf;

#[test]
#[ignore = "Set AFTER_TEST_ENGINE_PATH to the built canonical engine and run --ignored"]
fn opening_a_queue_reconciles_all_pages_without_starting_missing_or_uncertain_work() {
    use after_desktop::{
        import_queue::{ImportInput, ImportJob, ImportQueue, JobState, QueueCommand},
        worker_host::ImportWork,
    };
    use std::sync::atomic::AtomicBool;
    let engine = PathBuf::from(std::env::var_os("AFTER_TEST_ENGINE_PATH").unwrap());
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path().join("startup-library");
    let bridge = LibraryBridge::for_development(engine, root.clone()).unwrap();
    let source = fixture.path().join("keep original.wav");
    std::fs::write(&source, b"original source").unwrap();
    let queue = bridge.open_import_queue().unwrap();
    let mut history: Vec<ImportJob> = Vec::new();
    for _ in 0..71 {
        let work = ImportWork {
            operation_id: uuid::Uuid::new_v4().to_string(),
            attempt_token: uuid::Uuid::new_v4().to_string(),
            source: source.clone(),
            title: None,
        };
        let job = queue
            .execute(QueueCommand::Enqueue {
                input: ImportInput::from(&work),
            })
            .unwrap()
            .job
            .unwrap();
        queue
            .execute(QueueCommand::Claim {
                job_id: Some(job.id.clone()),
            })
            .unwrap()
            .job
            .unwrap();
        queue
            .execute(QueueCommand::Update {
                job_id: job.id.clone(),
                expected_attempt: 1,
                state: JobState::Interrupted,
                progress: 0.0,
            })
            .unwrap();
        history.push(job);
    }
    // This candidate sorts beyond the first 64-row recovery page.
    history.sort_by(|a, b| a.id.cmp(&b.id));
    let published = history.last().unwrap();
    bridge
        .import_work(
            &published.config.work(),
            &AtomicBool::new(false),
            &mut |_| {},
        )
        .unwrap();
    let uncertain = &history[0];
    let corrupt = root
        .join("meetings")
        .join(&uncertain.object_id)
        .join("meta.json");
    std::fs::create_dir_all(&corrupt).unwrap();

    let cancelled_work = ImportWork {
        operation_id: uuid::Uuid::new_v4().to_string(),
        attempt_token: uuid::Uuid::new_v4().to_string(),
        source: source.clone(),
        title: None,
    };
    let cancelled = queue
        .execute(QueueCommand::Enqueue {
            input: ImportInput::from(&cancelled_work),
        })
        .unwrap()
        .job
        .unwrap();
    queue
        .execute(QueueCommand::Claim {
            job_id: Some(cancelled.id.clone()),
        })
        .unwrap()
        .job
        .unwrap();
    queue
        .execute(QueueCommand::Cancel {
            job_id: cancelled.id.clone(),
            expected_attempt: 1,
        })
        .unwrap();
    drop(queue);
    let successor = bridge.open_import_queue().unwrap();
    assert_eq!(
        successor
            .execute(QueueCommand::Get {
                job_id: published.id.clone()
            })
            .unwrap()
            .job
            .unwrap()
            .state,
        JobState::Succeeded
    );
    assert_eq!(
        successor
            .execute(QueueCommand::Get {
                job_id: cancelled.id
            })
            .unwrap()
            .job
            .unwrap()
            .state,
        JobState::Cancelled
    );
    assert_eq!(
        successor
            .execute(QueueCommand::Get {
                job_id: uncertain.id.clone()
            })
            .unwrap()
            .job
            .unwrap()
            .state,
        JobState::Interrupted
    );
    assert!(corrupt.is_dir());
    for job in &history {
        if job.id != published.id && job.id != uncertain.id {
            assert!(
                !root.join("meetings").join(&job.object_id).exists(),
                "recovery must not create source copies"
            );
        }
    }
    assert!(!root
        .join("meetings")
        .join(cancelled_work.operation_id)
        .exists());
    assert_eq!(std::fs::read(&source).unwrap(), b"original source");
    assert_eq!(
        successor.execute(QueueCommand::List).unwrap().total,
        Some(72)
    );
}

#[test]
#[ignore = "Set AFTER_TEST_ENGINE_PATH to the built canonical engine and run --ignored"]
fn leased_queue_executes_import_and_reconciles_a_published_attempt_without_its_source() {
    use after_desktop::{
        import_queue::{ImportInput, ImportJob, ImportQueue, JobState, QueueCommand},
        worker_host::ImportWork,
    };
    use std::{
        sync::atomic::AtomicBool,
        time::{Duration, Instant},
    };
    fn wait(queue: &dyn ImportQueue, id: &str, expected: JobState) -> ImportJob {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let job = queue
                .execute(QueueCommand::Get { job_id: id.into() })
                .unwrap()
                .job
                .unwrap();
            if job.state == expected {
                return job;
            }
            assert_eq!(job.state, JobState::Running, "unexpected terminal state");
            assert!(Instant::now() < deadline, "queued import did not finish");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    let engine = PathBuf::from(std::env::var_os("AFTER_TEST_ENGINE_PATH").unwrap());
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path().join("owned-import-library");
    let bridge = LibraryBridge::for_development(engine, root.clone()).unwrap();
    let queue = bridge.open_import_queue().unwrap();
    let source = fixture.path().join("source После ; literal.wav");
    let bytes = vec![42; 900_000];
    std::fs::write(&source, &bytes).unwrap();
    let work = ImportWork {
        operation_id: uuid::Uuid::new_v4().to_string(),
        attempt_token: uuid::Uuid::new_v4().to_string(),
        source: source.clone(),
        title: Some("Owned queue import".into()),
    };
    let job = queue
        .execute(QueueCommand::Enqueue {
            input: ImportInput::from(&work),
        })
        .unwrap()
        .job
        .unwrap();
    assert_eq!(
        queue
            .execute(QueueCommand::Run {
                job_id: job.id.clone()
            })
            .unwrap()
            .job
            .unwrap()
            .attempt,
        1
    );
    assert_eq!(wait(&queue, &job.id, JobState::Succeeded).progress, 1.0);
    assert_eq!(std::fs::read(&source).unwrap(), bytes);
    assert_eq!(
        std::fs::read(
            root.join("meetings")
                .join(&work.operation_id)
                .join("source.wav")
        )
        .unwrap(),
        bytes
    );

    // Seed the publication/completion gap using a real import worker: the old
    // attempt published its exact receipt but never saved queue completion.
    let pending_source = fixture.path().join("lost acknowledgement.wav");
    std::fs::write(&pending_source, &bytes).unwrap();
    let pending = ImportWork {
        operation_id: uuid::Uuid::new_v4().to_string(),
        attempt_token: uuid::Uuid::new_v4().to_string(),
        source: pending_source.clone(),
        title: None,
    };
    let pending_job = queue
        .execute(QueueCommand::Enqueue {
            input: ImportInput::from(&pending),
        })
        .unwrap()
        .job
        .unwrap();
    queue
        .execute(QueueCommand::Claim {
            job_id: Some(pending_job.id.clone()),
        })
        .unwrap()
        .job
        .unwrap();
    bridge
        .import_work(&pending, &AtomicBool::new(false), &mut |_| {})
        .unwrap();
    drop(queue);
    std::fs::remove_file(&pending_source).unwrap();
    let successor = bridge.open_import_queue().unwrap();
    assert_eq!(
        successor.execute(QueueCommand::Recover).unwrap().recovered,
        Some(0)
    );
    let recovered = wait(&successor, &pending_job.id, JobState::Succeeded);
    assert_eq!(recovered.attempt, 1);
    assert!(successor
        .execute(QueueCommand::Run {
            job_id: pending_job.id.clone()
        })
        .unwrap()
        .job
        .is_none());
    assert!(!pending_source.exists());
    assert_eq!(
        std::fs::read(
            root.join("meetings")
                .join(&pending.operation_id)
                .join("source.wav")
        )
        .unwrap(),
        bytes
    );

    // A different receipt token must not adopt that published meeting.
    let mut wrong = ImportInput::from(&pending);
    wrong.attempt_token = uuid::Uuid::new_v4().to_string();
    let foreign = successor
        .execute(QueueCommand::Enqueue { input: wrong })
        .unwrap()
        .job
        .unwrap();
    successor
        .execute(QueueCommand::Run {
            job_id: foreign.id.clone(),
        })
        .unwrap();
    wait(&successor, &foreign.id, JobState::Failed);
    assert_eq!(bridge.workspace().unwrap().meetings.len(), 2);
    assert_eq!(std::fs::read(&source).unwrap(), bytes);
}

#[test]
#[ignore = "Set AFTER_TEST_ENGINE_PATH to the built canonical engine and run --ignored"]
fn import_owner_kernel_lease_is_released_after_abnormal_process_exit() {
    use after_desktop::import_queue::{ImportQueue, QueueCommand};
    use after_process_runtime::ProcessTree;
    use std::{
        io::{BufRead, BufReader},
        process::{Command, Stdio},
        sync::mpsc,
        time::Duration,
    };
    let engine = PathBuf::from(std::env::var_os("AFTER_TEST_ENGINE_PATH").unwrap());
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path().join("crash-library");
    let bridge = LibraryBridge::for_development(engine.clone(), root.clone()).unwrap();
    let mut command = Command::new(&engine);
    command
        .args(["desktop-import-queue", "--root"])
        .arg(&root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut owner = ProcessTree::spawn(&mut command).unwrap();
    let stdout = owner.take_stdout().unwrap();
    let (send, receive) = mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        let result = BufReader::new(stdout).read_line(&mut line).map(|_| line);
        let _ = send.send(result);
    });
    let ready = receive
        .recv_timeout(Duration::from_secs(10))
        .unwrap()
        .unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&ready).unwrap()["event"],
        "ready"
    );
    assert_eq!(bridge.open_import_queue().err().unwrap().code, "busy");
    let other =
        LibraryBridge::for_development(engine, fixture.path().join("independent-library")).unwrap();
    let independent = other.open_import_queue().unwrap();
    assert_eq!(
        independent.execute(QueueCommand::List).unwrap().total,
        Some(0)
    );
    owner.kill().unwrap();
    owner.wait().unwrap();
    let successor = bridge.open_import_queue().unwrap();
    assert_eq!(
        successor.execute(QueueCommand::List).unwrap().total,
        Some(0)
    );
    drop(successor);
    assert!(bridge.open_import_queue().is_ok());
    assert!(root.join(".desktop-import-executor.lock").is_file());
}

#[test]
#[ignore = "Set AFTER_TEST_ENGINE_PATH to the built canonical engine and run --ignored"]
fn native_import_queue_survives_bridge_recreation_and_preserves_attempt_fencing() {
    use after_desktop::{
        import_queue::{ImportInput, ImportQueue, JobState, QueueCommand},
        worker_host::ImportWork,
    };
    let engine = PathBuf::from(std::env::var_os("AFTER_TEST_ENGINE_PATH").unwrap());
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path().join("queue-library");
    let bridge = LibraryBridge::for_development(engine.clone(), root.clone()).unwrap();
    let queue = bridge.open_import_queue().unwrap();
    assert_eq!(bridge.open_import_queue().err().unwrap().code, "busy");
    let work = ImportWork {
        operation_id: uuid::Uuid::new_v4().to_string(),
        attempt_token: uuid::Uuid::new_v4().to_string(),
        source: fixture.path().join("native source ü ;.wav"),
        title: None,
    };
    let enqueued = queue
        .execute(QueueCommand::Enqueue {
            input: ImportInput::from(&work),
        })
        .unwrap();
    assert_eq!(enqueued.deduplicated, Some(false));
    let job = enqueued.job.unwrap();
    assert_eq!(job.state, JobState::Queued);
    let claimed = queue
        .execute(QueueCommand::Claim {
            job_id: Some(job.id.clone()),
        })
        .unwrap()
        .job
        .unwrap();
    assert_eq!(claimed.attempt, 1);
    assert_eq!(claimed.config.work().source, work.source);
    drop(queue);
    drop(bridge);
    let bridge = LibraryBridge::for_development(engine, root).unwrap();
    let queue = bridge.open_import_queue().unwrap();
    let persisted = queue
        .execute(QueueCommand::Get {
            job_id: job.id.clone(),
        })
        .unwrap()
        .job
        .unwrap();
    assert_eq!(persisted.state, JobState::Interrupted);
    assert_eq!(persisted.config.attempt_token, work.attempt_token);
    // The persistent helper holds the exclusive lifetime lease across requests.
    let recovery = queue.execute(QueueCommand::Recover).unwrap();
    assert_eq!(recovery.recovered, Some(0));
    assert_eq!(recovery.jobs[0].state, JobState::Interrupted);
    assert!(queue
        .execute(QueueCommand::Claim {
            job_id: Some(job.id.clone())
        })
        .unwrap()
        .job
        .is_none());
    queue
        .execute(QueueCommand::Retry {
            job_id: job.id.clone(),
            expected_attempt: 1,
        })
        .unwrap();
    assert_eq!(
        queue
            .execute(QueueCommand::Claim {
                job_id: Some(job.id.clone())
            })
            .unwrap()
            .job
            .unwrap()
            .attempt,
        2
    );
    assert!(queue
        .execute(QueueCommand::Update {
            job_id: job.id.clone(),
            expected_attempt: 1,
            state: JobState::Succeeded,
            progress: 1.0
        })
        .is_err());
    assert_eq!(
        queue
            .execute(QueueCommand::Cancel {
                job_id: job.id.clone(),
                expected_attempt: 2
            })
            .unwrap()
            .job
            .unwrap()
            .cancel_requested,
        true
    );
    queue
        .execute(QueueCommand::Update {
            job_id: job.id,
            expected_attempt: 2,
            state: JobState::Cancelled,
            progress: 0.0,
        })
        .unwrap();
    let snapshot = queue.execute(QueueCommand::List).unwrap();
    assert_eq!(snapshot.total, Some(1));
    assert_eq!(snapshot.has_more, Some(false));
    assert_eq!(snapshot.jobs[0].state, JobState::Cancelled);
    assert!(bridge.workspace().unwrap().meetings.is_empty());
}

#[test]
#[ignore = "Set AFTER_TEST_ENGINE_PATH to the built canonical engine and run --ignored"]
fn streaming_import_preserves_sources_and_recovers_only_its_exact_commit_receipt() {
    use after_desktop::worker_host::{ImportPhase, ImportWork};
    use std::sync::atomic::AtomicBool;
    let engine = PathBuf::from(std::env::var_os("AFTER_TEST_ENGINE_PATH").unwrap());
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path().join("worker-library");
    let bridge = LibraryBridge::for_development(engine, root.clone()).unwrap();
    bridge.workspace().unwrap();
    let source = fixture.path().join("literal source ; unicode После.wav");
    let bytes = vec![42; 700_000];
    std::fs::write(&source, &bytes).unwrap();
    let work = ImportWork {
        operation_id: uuid::Uuid::new_v4().to_string(),
        attempt_token: uuid::Uuid::new_v4().to_string(),
        source: source.clone(),
        title: Some("Worker import".into()),
    };
    let mut progress = Vec::new();
    let meeting = bridge
        .import_work(&work, &AtomicBool::new(false), &mut |value| {
            progress.push(value)
        })
        .unwrap();
    assert_eq!(meeting.id, work.operation_id);
    assert!(progress
        .iter()
        .any(|value| value.phase == ImportPhase::Copying));
    assert_eq!(progress.last().unwrap().phase, ImportPhase::Committing);
    assert_eq!(std::fs::read(&source).unwrap(), bytes);
    assert_eq!(
        std::fs::read(root.join("meetings").join(&meeting.id).join("source.wav")).unwrap(),
        bytes
    );
    // Simulate cancellation after publication / a lost final reply. No duplicate
    // import is created and a different token cannot adopt someone else's result.
    let recovered = bridge
        .import_work(&work, &AtomicBool::new(true), &mut |_| {})
        .unwrap();
    assert_eq!(recovered.id, meeting.id);
    let mut wrong = work;
    wrong.attempt_token = uuid::Uuid::new_v4().to_string();
    assert_eq!(
        bridge
            .import_work(&wrong, &AtomicBool::new(true), &mut |_| {})
            .unwrap_err()
            .code,
        "cancelled"
    );
    assert_eq!(bridge.workspace().unwrap().meetings.len(), 1);
    let cancelled = ImportWork {
        operation_id: uuid::Uuid::new_v4().to_string(),
        attempt_token: uuid::Uuid::new_v4().to_string(),
        source,
        title: None,
    };
    assert_eq!(
        bridge
            .import_work(&cancelled, &AtomicBool::new(true), &mut |_| {})
            .unwrap_err()
            .code,
        "cancelled"
    );
    assert!(!root.join("meetings").join(cancelled.operation_id).exists());
}

#[test]
#[ignore = "Set AFTER_TEST_ENGINE_PATH to the built canonical engine and run --ignored"]
fn canonical_engine_persists_scoped_notes_and_rejects_stale_edits() {
    let engine = PathBuf::from(
        std::env::var_os("AFTER_TEST_ENGINE_PATH")
            .expect("AFTER_TEST_ENGINE_PATH must point to a real posle-engine"),
    );
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path().join("isolated-library");
    let bridge = LibraryBridge::for_development(engine.clone(), root.clone()).unwrap();
    let initial = bridge.workspace().unwrap();
    assert!(initial.notes.is_empty() && initial.folders.is_empty() && initial.meetings.is_empty());
    assert!(initial.capabilities.library);
    assert!(initial.capabilities.import);
    assert!(initial.capabilities.tasks && initial.capabilities.cards);
    assert_eq!(initial.capabilities.recording, cfg!(windows));
    assert!(!initial.capabilities.assistant);
    let folder = bridge
        .save_folder(SaveFolderInput {
            id: None,
            name: "Английский".into(),
            expected_revision: None,
        })
        .unwrap();
    let note = bridge
        .save_note(SaveNoteInput {
            id: None,
            title: "Friday practice".into(),
            text: "Use phrasal verbs about travel.".into(),
            folder_id: Some(Some(folder.id.clone())),
            meeting_id: None,
            expected_revision: None,
        })
        .unwrap();
    assert_eq!(note.revision, 1);
    assert_eq!(note.folder_id.as_deref(), Some(folder.id.as_str()));
    let edit = SaveNoteInput {
        id: Some(note.id.clone()),
        title: note.title.clone(),
        text: "Updated useful phrasal verbs.".into(),
        folder_id: note.folder_id.clone().map(Some),
        meeting_id: None,
        expected_revision: Some(note.revision),
    };
    let saved = bridge.save_note(edit.clone()).unwrap();
    assert_eq!(saved.revision, 2);
    assert_eq!(bridge.save_note(edit).unwrap_err().code, "conflict");
    assert_eq!(
        bridge
            .save_folder(SaveFolderInput {
                id: Some(folder.id.clone()),
                name: "English".into(),
                expected_revision: Some(99)
            })
            .unwrap_err()
            .code,
        "conflict"
    );
    let results = bridge
        .search("phrasal".into(), Some(folder.id.clone()))
        .unwrap();
    assert!(results
        .hits
        .iter()
        .any(|hit| hit.note_id.as_deref() == Some(note.id.as_str()) || hit.id == note.id));
    let partial = SaveNoteInput {
        id: Some(note.id.clone()),
        title: saved.title.clone(),
        text: saved.text.clone(),
        folder_id: None,
        meeting_id: None,
        expected_revision: Some(saved.revision),
    };
    let preserved = bridge.save_note(partial).unwrap();
    assert_eq!(preserved.folder_id, note.folder_id);
    // A new host instance proves this is durable canonical storage, not UI state.
    let reopened = LibraryBridge::for_development(engine, root.clone())
        .unwrap()
        .workspace()
        .unwrap();
    assert_eq!(reopened.notes.len(), 1);
    assert_eq!(reopened.notes[0].text, saved.text);
    assert_eq!(reopened.notes[0].revision, 3);
    assert_eq!(reopened.folders[0].id, folder.id);
    assert!(root.join("core.sqlite").exists());
}

#[test]
#[ignore = "Set AFTER_TEST_ENGINE_PATH to the built canonical engine and run --ignored"]
fn tasks_and_cards_cross_real_host_transport_and_remain_isolated() {
    let engine = PathBuf::from(
        std::env::var_os("AFTER_TEST_ENGINE_PATH")
            .expect("AFTER_TEST_ENGINE_PATH must point to a real posle-engine"),
    );
    let fixture = tempfile::tempdir().unwrap();
    let first_root = fixture.path().join("first-private-library");
    let second_root = fixture.path().join("second-private-library");
    let first = LibraryBridge::for_development(engine.clone(), first_root.clone()).unwrap();
    let second = LibraryBridge::for_development(engine.clone(), second_root).unwrap();
    let op = |name: &str, args| first.feature_operation(name, args).unwrap();

    let created = op(
        "create_task",
        json!({"title":"Transport task","text":"Private agenda",
        "operationId":"create-task-1"}),
    );
    assert_eq!(created["title"], "Transport task");
    let task_id = created["id"].as_str().unwrap();
    let edit = json!({"taskId":task_id,"expectedRevision":created["revision"],
        "expectedSourceFingerprint":created["sourceFingerprint"],"operationId":"edit-task-1",
        "patch":{"status":"done","title":"Updated task"}});
    let updated = op("update_task", edit.clone());
    assert_eq!(updated["status"], "done");
    // Retrying the same operation cannot create a duplicate.
    assert_eq!(
        op("update_task", edit.clone())["revision"],
        updated["revision"]
    );
    let mut stale = edit;
    stale["operationId"] = json!("edit-task-2");
    assert_eq!(
        first
            .feature_operation("update_task", stale)
            .unwrap_err()
            .code,
        "conflict"
    );
    assert_eq!(
        second.feature_operation("list_tasks", json!({})).unwrap()["tasks"],
        json!([])
    );
    assert!(second
        .feature_operation("get_task", json!({"taskId":task_id}))
        .is_err());

    let saved = op(
        "save_card",
        json!({"front":"Hello","back":"Привет","newDeckTitle":"Transport deck"}),
    );
    let first_cards = op("list_cards", json!({}));
    let card = &first_cards["cards"][0];
    assert_eq!(card["card"]["front"], "Hello");
    let reference = json!({"meetingId":saved["meetingId"],"cardId":saved["card"]["id"],
        "expectedFingerprint":card["fingerprint"],"expectedReviewFingerprint":card["reviewFingerprint"]});
    assert_eq!(
        op("preview_card_review", reference.clone())["options"]
            .as_array()
            .unwrap()
            .len(),
        4
    );
    let mut review = reference;
    review["rating"] = json!(3);
    let receipt = op("review_card", review.clone());
    assert_eq!(receipt["state"]["count"], 1);
    assert_eq!(
        first
            .feature_operation("review_card", review)
            .unwrap_err()
            .code,
        "conflict"
    );
    op(
        "undo_card_review",
        json!({"meetingId":receipt["meetingID"],"undoId":receipt["undoID"]}),
    );
    assert!(op("list_cards", json!({}))["cards"][0]["review"].is_null());
    assert_eq!(
        second.feature_operation("list_cards", json!({})).unwrap()["cards"],
        json!([])
    );

    // A caller may choose only allowlisted operations and may never supply
    // agent commands, arbitrary file paths, roots or unrecognised fields.
    for (operation, args) in [
        ("task-agent-claim", json!({})),
        ("import_meeting", json!({"sourcePath":"C:\\private.wav"})),
        ("list_tasks", json!({"root":"C:\\outside"})),
        (
            "list_cards",
            json!({"command":"cards-import","path":"C:\\outside"}),
        ),
        (
            "update_task",
            json!({"taskId":task_id,"expectedRevision":updated["revision"],
            "operationId":"agent-1","patch":{"agentAccess":{"enabled":true}}}),
        ),
    ] {
        assert_eq!(
            first.feature_operation(operation, args).unwrap_err().code,
            "invalid_request"
        );
    }
    assert_eq!(
        first
            .feature_operation("list_cards", json!([]))
            .unwrap_err()
            .code,
        "invalid_request"
    );

    // Reopening the bridge verifies committed storage, not only process state.
    let reopened = LibraryBridge::for_development(engine, first_root).unwrap();
    assert_eq!(
        reopened.feature_operation("list_tasks", json!({})).unwrap()["tasks"][0]["title"],
        "Updated task"
    );
    assert_eq!(
        reopened.feature_operation("list_cards", json!({})).unwrap()["cards"][0]["card"]["back"],
        "Привет"
    );
}

#[test]
#[ignore = "Set AFTER_TEST_ENGINE_PATH to the built canonical engine and run --ignored"]
fn queued_file_import_persists_success_and_reuses_exact_receipt_without_source() {
    use after_desktop::{
        import_queue::{ImportQueue, JobState, QueueCommand},
        worker_host::ImportWork,
    };
    use std::sync::atomic::AtomicBool;
    let engine = PathBuf::from(std::env::var_os("AFTER_TEST_ENGINE_PATH").unwrap());
    let fixture = tempfile::tempdir().unwrap();
    let bridge = LibraryBridge::for_development(engine, fixture.path().join("queued-library")).unwrap();
    let source = fixture.path().join("synthetic.wav");
    let original: Vec<u8> = (0..2_097_152).map(|index| (index % 251) as u8).collect();
    std::fs::write(&source, &original).unwrap();
    let work = ImportWork {
        operation_id: uuid::Uuid::new_v4().to_string(),
        attempt_token: uuid::Uuid::new_v4().to_string(),
        source: source.clone(), title: Some("Durable import".into()),
    };
    let mut progress = Vec::new();
    let meeting = bridge.import_queued_work(&work,&AtomicBool::new(false),&mut |value| progress.push(value)).unwrap();
    assert_eq!(meeting.id,work.operation_id);
    assert_eq!(std::fs::read(&source).unwrap(),original);
    assert!(!progress.is_empty());
    assert!(progress.windows(2).all(|pair|pair[0]<=pair[1]));
    let queue = bridge.open_import_queue().unwrap();
    let history = queue.execute(QueueCommand::List).unwrap();
    assert_eq!(history.total,Some(1));
    assert_eq!(history.jobs[0].state,JobState::Succeeded);
    assert_eq!(history.jobs[0].attempt,1);
    drop(queue);
    std::fs::remove_file(&source).unwrap();
    assert_eq!(bridge.import_queued_work(&work,&AtomicBool::new(false),&mut |_| {}).unwrap().id,meeting.id);
    let queue = bridge.open_import_queue().unwrap();
    assert_eq!(queue.execute(QueueCommand::List).unwrap().total,Some(1));
    drop(queue);
    let wrong = ImportWork { attempt_token: uuid::Uuid::new_v4().to_string(), ..work };
    assert!(bridge.import_queued_work(&wrong,&AtomicBool::new(false),&mut |_| {}).is_err());
}
