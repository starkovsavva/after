//! Native host → real speech service, without inference, models or personal data.
#![cfg(all(debug_assertions, unix))]
use after_desktop::{
    bridge::LibraryBridge,
    queue_models::JobState,
    speech_queue::{SpeechCommand, SpeechInput, SpeechQueue},
    worker_host::ImportWork,
};
use serde_json::{json, Value};
use std::{
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
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
    let mut inspect = Command::new(&engine)
        .args(["--posle-speech-job", "--root"])
        .arg(&root)
        .arg("--backend")
        .arg(&backend)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    inspect
        .stdin
        .take()
        .unwrap()
        .write_all(json!({"inspect":meeting.id}).to_string().as_bytes())
        .unwrap();
    let output = inspect.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let result: Value = serde_json::from_slice(&output.stdout).unwrap();
    let input = SpeechInput {
        version: 1,
        operation_id: uuid::Uuid::new_v4().to_string(),
        attempt_token: uuid::Uuid::new_v4().to_string(),
        meeting_id: meeting.id.clone(),
        input_revision: result["speechJob"]["inputRevision"]
            .as_str()
            .unwrap()
            .into(),
        settings: json!({"speechMode":"local","diarization":false,"asrModelPath":"/unused/never-executed"}),
    };
    let queue = bridge.open_speech_queue().unwrap();
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
