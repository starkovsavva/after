//! Native host → real speech service, without inference, models or personal data.
#![cfg(all(debug_assertions, unix))]
use after_desktop::{
    bridge::LibraryBridge,
    queue_models::JobState,
    speech_queue::{SpeechCommand, SpeechQueue},
    worker_host::ImportWork,
};
use serde_json::json;
use std::{
    path::{Path, PathBuf},
    sync::atomic::AtomicBool,
};

fn engine() -> PathBuf {
    std::env::var_os("AFTER_TEST_ENGINE_PATH")
        .expect("Set AFTER_TEST_ENGINE_PATH")
        .into()
}
fn backend() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("binaries/speech-backend")
}
fn fixture() -> tempfile::TempDir {
    tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap()
}
fn bridge(engine: &Path, root: &Path, backend: &Path) -> LibraryBridge {
    LibraryBridge::for_development_with_backend(
        engine.to_owned(),
        root.to_owned(),
        backend.to_owned(),
    )
    .unwrap()
}
#[test]
#[ignore = "Requires staged canonical engine and speech source"]
fn speech_owner_is_exclusive_independent_of_import_and_startup_never_runs_inference() {
    let engine = engine();
    let backend = backend();
    let fixture = fixture();
    let root = fixture.path().join("library");
    let bridge = bridge(&engine, &root, &backend);
    let source = fixture.path().join("synthetic.wav");
    std::fs::write(&source, b"synthetic; never decoded").unwrap();
    let work = ImportWork {
        operation_id: uuid::Uuid::new_v4().to_string(),
        attempt_token: uuid::Uuid::new_v4().to_string(),
        source: source.clone(),
        title: None,
    };
    let meeting = bridge
        .import_work(&work, &AtomicBool::new(false), &mut |_| {})
        .unwrap();
    let queue = bridge.open_speech_queue().unwrap();
    // Preparation has no implicit speech defaults or queue writes.
    assert!(queue
        .execute(SpeechCommand::Prepare {
            meeting_id: meeting.id.clone()
        })
        .is_err());
    assert_eq!(
        queue
            .execute(SpeechCommand::History { after: None })
            .unwrap()
            .total,
        Some(0)
    );
    std::fs::write(
        root.join("settings.json"),
        json!({"speechMode":"local","diarization":false,
        "asrModelPath":"/unused/never-executed","asrModelFormat":"onnx",
        "speechApiKey":"private-settings-fixture","integrationToken":"private-settings-fixture"})
        .to_string(),
    )
    .unwrap();
    let input = queue
        .execute(SpeechCommand::Prepare {
            meeting_id: meeting.id.clone(),
        })
        .unwrap()
        .prepared
        .unwrap();
    assert_eq!(input.meeting_id, meeting.id);
    assert!(!serde_json::to_string(&input)
        .unwrap()
        .contains("private-settings-fixture"));
    assert_eq!(
        queue
            .execute(SpeechCommand::History { after: None })
            .unwrap()
            .total,
        Some(0)
    );
    // Selection is immutable even if global settings change before enqueue.
    std::fs::write(root.join("settings.json"), br#"{"speechMode":"cloud"}"#).unwrap();
    assert_eq!(input.settings["speechMode"], "local");
    assert_eq!(bridge.open_speech_queue().err().unwrap().code, "busy");
    let imports = bridge.open_import_queue().unwrap();
    use after_desktop::import_queue::{ImportQueue, QueueCommand};
    assert_eq!(
        imports
            .execute(QueueCommand::History { after: None })
            .unwrap()
            .total,
        Some(0)
    );
    let job = queue
        .execute(SpeechCommand::Enqueue {
            input: input.clone(),
        })
        .unwrap()
        .job
        .unwrap();
    assert_eq!(job.state, JobState::Queued);
    assert_eq!(job.meeting_id.as_deref(), Some(meeting.id.as_str()));
    assert!(queue
        .execute(SpeechCommand::Enqueue { input })
        .unwrap()
        .deduplicated
        .unwrap());
    assert!(queue
        .execute(SpeechCommand::Cancel {
            job_id: job.id.clone(),
            expected_attempt: 1
        })
        .is_err());
    assert_eq!(
        queue
            .execute(SpeechCommand::Get {
                job_id: job.id.clone()
            })
            .unwrap()
            .job
            .unwrap()
            .state,
        JobState::Queued
    );
    drop(queue);
    let queue = bridge.open_speech_queue().unwrap();
    let history = queue
        .execute(SpeechCommand::History { after: None })
        .unwrap();
    assert_eq!(history.total, Some(1));
    assert_eq!(history.jobs[0].state, JobState::Queued);
    let visible = serde_json::to_value(&history.jobs).unwrap().to_string();
    for private in [
        "settings",
        "attemptToken",
        "operationId",
        "inputRevision",
        "unused",
    ] {
        assert!(!visible.contains(private));
    }
    assert_eq!(
        queue
            .execute(SpeechCommand::Cancel {
                job_id: job.id,
                expected_attempt: 0
            })
            .unwrap()
            .job
            .unwrap()
            .state,
        JobState::Cancelled
    );
    std::fs::write(
        root.join("settings.json"),
        json!({"speechMode":"local","diarization":false,
        "asrModelPath":"/unused/never-executed"})
        .to_string(),
    )
    .unwrap();
    let stale = queue
        .execute(SpeechCommand::Prepare {
            meeting_id: meeting.id.clone(),
        })
        .unwrap()
        .prepared
        .unwrap();
    std::fs::write(
        root.join("meetings").join(&meeting.id).join("source.wav"),
        b"changed canonical input",
    )
    .unwrap();
    assert!(queue
        .execute(SpeechCommand::Enqueue { input: stale })
        .is_err());
    assert_eq!(
        queue
            .execute(SpeechCommand::History { after: None })
            .unwrap()
            .total,
        Some(1)
    );
    assert_eq!(std::fs::read(&source).unwrap(), b"synthetic; never decoded");
    assert!(!root
        .join("meetings")
        .join(meeting.id)
        .join("transcript.json")
        .exists());
    assert!(!root.join("runtime").exists());
}

#[test]
#[ignore = "Requires staged canonical engine and speech source"]
fn changed_backend_stops_the_owner_before_any_further_queue_request() {
    let fixture = fixture();
    let root = fixture.path().join("library");
    let selected = fixture.path().join("backend");
    std::fs::create_dir(&selected).unwrap();
    for entry in std::fs::read_dir(backend()).unwrap() {
        let entry = entry.unwrap();
        std::fs::copy(entry.path(), selected.join(entry.file_name())).unwrap();
    }
    let bridge = bridge(&engine(), &root, &selected);
    let queue = bridge.open_speech_queue().unwrap();
    let script = selected.join("engine.py");
    let original = std::fs::read(&script).unwrap();
    std::fs::write(&script, b"changed source; never executed").unwrap();
    assert_eq!(
        queue
            .execute(SpeechCommand::History { after: None })
            .err()
            .unwrap()
            .code,
        "speech_integrity"
    );
    std::fs::write(&script, original).unwrap();
    // The old Rust handle remains alive, but its native lease must be released.
    let successor = bridge.open_speech_queue().unwrap();
    assert_eq!(
        successor
            .execute(SpeechCommand::History { after: None })
            .unwrap()
            .total,
        Some(0)
    );
    assert_eq!(
        queue
            .execute(SpeechCommand::History { after: None })
            .err()
            .unwrap()
            .code,
        "engine_failure"
    );
}
