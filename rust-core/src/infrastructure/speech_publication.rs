//! Owned staging and compare-and-publish for native local speech jobs.
use crate::application::speech_execution::{SpeechPublication, SpeechReceipt, SpeechWork};
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{Read, Write},
    os::unix::fs::MetadataExt,
    path::{Component, Path, PathBuf},
};
const LIMIT: u64 = 64 * 1024 * 1024;
const RECEIPT: &str = "_posleSpeechReceipt";
const JOURNAL: &str = ".speech-publication.json";

fn bytes(path: &Path, limit: u64) -> Result<Option<Vec<u8>>> {
    match fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
        Ok(_) => {}
    }
    let file = crate::platform_fs::open_read(path)?;
    ensure!(
        file.metadata()?.len() <= limit,
        "Speech input exceeds its bound"
    );
    let mut out = Vec::new();
    file.take(limit + 1).read_to_end(&mut out)?;
    ensure!(out.len() as u64 <= limit, "Speech input exceeds its bound");
    Ok(Some(out))
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn file_digest(path: &Path) -> Result<String> {
    let mut file = crate::platform_fs::open_read(path)?;
    let before = file.metadata()?;
    let mut hash = Sha256::new();
    let mut buffer = [0; 64 * 1024];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    let after = file.metadata()?;
    ensure!(
        before.dev() == after.dev()
            && before.ino() == after.ino()
            && before.len() == after.len()
            && before.mtime_nsec() == after.mtime_nsec()
            && before.mtime() == after.mtime()
            && before.ctime() == after.ctime()
            && before.ctime_nsec() == after.ctime_nsec(),
        "Speech source changed while reading"
    );
    Ok(format!("{:x}", hash.finalize()))
}
fn name(value: &str) -> Result<()> {
    let mut parts = Path::new(value).components();
    ensure!(
        matches!(parts.next(), Some(Component::Normal(_)))
            && parts.next().is_none()
            && !value.contains('\0'),
        "Invalid speech source name"
    );
    Ok(())
}
struct Snapshot {
    revision: String,
    meta: Value,
    files: Vec<(String, String)>,
}
fn snapshot(directory: &Path) -> Result<Snapshot> {
    let meta: Value = serde_json::from_slice(
        &bytes(&directory.join("meta.json"), 1024 * 1024)?.context("Meeting is missing")?,
    )?;
    ensure!(
        meta["id"].as_str() == directory.file_name().and_then(|name| name.to_str()),
        "Meeting metadata identity changed"
    );
    ensure!(
        meta.get("recordingTracks").is_none_or(Value::is_boolean),
        "Invalid recording track selection"
    );
    let source = meta["source"].as_str().context("Meeting has no source")?;
    name(source)?;
    let mut files = vec![source.to_owned()];
    if meta["recordingTracks"].as_bool() == Some(true) {
        for source in ["system.m4a", "microphone.m4a"] {
            if fs::symlink_metadata(directory.join(source)).is_ok()
                && !files.iter().any(|v| v == source)
            {
                files.push(source.into());
            }
        }
    }
    let mut hashes = Vec::new();
    for source in &files {
        hashes.push((source.clone(), file_digest(&directory.join(source))?));
    }
    let transcript = bytes(&directory.join("transcript.json"), LIMIT)?.map(|v| digest(&v));
    let summary = bytes(&directory.join("summary.json"), 8 * 1024 * 1024)?.map(|v| digest(&v));
    let revision = digest(&serde_json::to_vec(
        &json!({"files":hashes,"tracks":meta.get("recordingTracks"),"transcript":transcript,"summary":summary}),
    )?);
    Ok(Snapshot {
        revision,
        meta,
        files: hashes,
    })
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Journal {
    version: u8,
    receipt: SpeechReceipt,
    previous_transcript: Option<String>,
    summary_hash: Option<String>,
    retired_summary: String,
}
fn receipt(directory: &Path) -> Result<Option<SpeechReceipt>> {
    let Some(raw) = bytes(&directory.join("transcript.json"), LIMIT)? else {
        return Ok(None);
    };
    let value: Value = serde_json::from_slice(&raw)?;
    if value.get(RECEIPT).is_some() {
        crate::domain::speech::validate_transcript(&value)?;
    }
    value
        .get(RECEIPT)
        .map(|value| serde_json::from_value(value.clone()).map_err(Into::into))
        .transpose()
}
fn sync(directory: &Path) -> Result<()> {
    File::open(directory)?.sync_all()?;
    Ok(())
}
/// Must hold the canonical meeting lock. Never infer/retry during recovery.
fn recover(directory: &Path) -> Result<()> {
    let Some(raw) = bytes(&directory.join(JOURNAL), 8192)? else {
        return Ok(());
    };
    let journal: Journal = serde_json::from_slice(&raw)?;
    ensure!(
        journal.version == 1 && journal.receipt.version == 1,
        "Unsupported speech publication journal"
    );
    let expected = format!(".speech-summary-{}", journal.receipt.attempt_token);
    ensure!(
        journal.retired_summary == expected
            && uuid::Uuid::parse_str(&journal.receipt.attempt_token)?.to_string()
                == journal.receipt.attempt_token,
        "Invalid speech recovery path"
    );
    let retired = directory.join(&journal.retired_summary);
    if receipt(directory)?.as_ref() == Some(&journal.receipt) {
        if bytes(&retired, 8 * 1024 * 1024)?.is_some() {
            fs::remove_file(&retired)?;
        }
    } else {
        let actual = bytes(&directory.join("transcript.json"), LIMIT)?.map(|v| digest(&v));
        ensure!(
            actual == journal.previous_transcript,
            "Speech publication outcome is unresolved"
        );
        let summary = directory.join("summary.json");
        let current = bytes(&summary, 8 * 1024 * 1024)?.map(|v| digest(&v));
        let backup = bytes(&retired, 8 * 1024 * 1024)?.map(|v| digest(&v));
        if backup.is_some() {
            ensure!(
                current.is_none() && backup == journal.summary_hash,
                "Speech summary recovery is unresolved"
            );
            fs::rename(&retired, &summary)?;
        } else {
            ensure!(
                current == journal.summary_hash,
                "Speech summary recovery is unresolved"
            );
        }
    }
    sync(directory)?;
    fs::remove_file(directory.join(JOURNAL))?;
    sync(directory)
}

pub(crate) struct Publication<'a> {
    pub root: &'a Path,
}
pub(crate) struct Stage {
    pub directory: PathBuf,
    pinned: File,
    original: File,
    receipt: SpeechReceipt,
}
impl Drop for Stage {
    fn drop(&mut self) {
        if let (Ok(actual), Ok(held)) = (
            fs::symlink_metadata(&self.directory),
            self.pinned.metadata(),
        ) {
            if actual.is_dir() && actual.dev() == held.dev() && actual.ino() == held.ino() {
                let _ = fs::remove_dir_all(&self.directory);
            }
        }
    }
}
impl Publication<'_> {
    pub fn inspect(&self, meeting: &str) -> Result<String> {
        let directory = crate::storage::meeting_directory(self.root, meeting)?;
        let _lock = crate::storage::meeting_lock(&directory)?;
        recover(&directory)?;
        Ok(snapshot(&directory)?.revision)
    }
}
impl SpeechPublication for Publication<'_> {
    type Stage = Stage;
    fn committed(&self, work: &SpeechWork) -> Result<bool> {
        let directory = crate::storage::meeting_directory(self.root, &work.meeting_id)?;
        let _lock = crate::storage::meeting_lock(&directory)?;
        if receipt(&directory)?.as_ref() == Some(&SpeechReceipt::for_work(work)) {
            let _ = recover(&directory);
            return Ok(true);
        }
        recover(&directory)?;
        Ok(receipt(&directory)?.as_ref() == Some(&SpeechReceipt::for_work(work)))
    }
    fn stage(&self, work: &SpeechWork) -> Result<Stage> {
        let directory = crate::storage::meeting_directory(self.root, &work.meeting_id)?;
        let original = crate::infrastructure::runtime_tree::open(&directory, true)?;
        let _lock = crate::storage::meeting_lock(&directory)?;
        recover(&directory)?;
        let before = snapshot(&directory)?;
        ensure!(
            before.revision == work.input_revision,
            "Speech source or result changed before execution"
        );
        let path = self
            .root
            .join(format!(".speech-work-{}", uuid::Uuid::new_v4()));
        crate::platform_fs::create_private_directory(&path)?;
        let stage = Stage {
            pinned: crate::infrastructure::runtime_tree::open(&path, true)?,
            directory: path,
            original,
            receipt: SpeechReceipt::for_work(work),
        };
        crate::storage::atomic_json(&stage.directory.join("meta.json"), &before.meta)?;
        for (name, expected) in &before.files {
            let mut input = crate::platform_fs::open_read(&directory.join(name))?;
            let mut output = crate::platform_fs::open_private(&stage.directory.join(name), true)?;
            std::io::copy(&mut input, &mut output)?;
            output.flush()?;
            ensure!(
                file_digest(&stage.directory.join(name))? == *expected,
                "Speech source changed during staging"
            );
        }
        ensure!(
            snapshot(&directory)?.revision == work.input_revision,
            "Speech input changed during staging"
        );
        Ok(stage)
    }
    fn directory(stage: &Stage) -> &Path {
        &stage.directory
    }
    fn publish(&self, work: &SpeechWork, stage: &Stage) -> Result<SpeechReceipt> {
        ensure!(
            stage.receipt == SpeechReceipt::for_work(work),
            "Speech stage belongs to another operation"
        );
        let actual_stage = fs::symlink_metadata(&stage.directory)?;
        let pinned_stage = stage.pinned.metadata()?;
        ensure!(
            actual_stage.is_dir()
                && actual_stage.dev() == pinned_stage.dev()
                && actual_stage.ino() == pinned_stage.ino(),
            "Speech staging directory changed"
        );
        let raw = bytes(&stage.directory.join("transcript.json"), LIMIT)?
            .context("Speech worker produced no transcript")?;
        let mut transcript: Value = serde_json::from_slice(&raw)?;
        crate::domain::speech::validate_transcript(&transcript)?;
        let result = SpeechReceipt::for_work(work);
        transcript
            .as_object_mut()
            .context("Invalid speech result")?
            .insert(RECEIPT.into(), serde_json::to_value(&result)?);
        ensure!(
            serde_json::to_vec_pretty(&transcript)?.len() < LIMIT as usize,
            "Speech result exceeds publication bound"
        );
        let directory = crate::storage::meeting_directory(self.root, &work.meeting_id)?;
        let _lock = crate::storage::meeting_lock(&directory)?;
        recover(&directory)?;
        let actual = fs::symlink_metadata(&directory)?;
        let held = stage.original.metadata()?;
        ensure!(
            actual.is_dir() && actual.dev() == held.dev() && actual.ino() == held.ino(),
            "Meeting incarnation changed during speech"
        );
        ensure!(
            snapshot(&directory)?.revision == work.input_revision,
            "Speech source or result changed during execution"
        );
        let summary = bytes(&directory.join("summary.json"), 8 * 1024 * 1024)?;
        let retired_summary = format!(".speech-summary-{}", work.attempt_token);
        ensure!(
            fs::symlink_metadata(directory.join(&retired_summary))
                .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound),
            "Unknown speech summary backup exists"
        );
        let journal = Journal {
            version: 1,
            receipt: result.clone(),
            previous_transcript: bytes(&directory.join("transcript.json"), LIMIT)?
                .map(|v| digest(&v)),
            summary_hash: summary.as_ref().map(|v| digest(v)),
            retired_summary,
        };
        crate::storage::atomic_json(&directory.join(JOURNAL), &journal)?;
        let publication = (|| -> Result<()> {
            if summary.is_some() {
                fs::rename(
                    directory.join("summary.json"),
                    directory.join(&journal.retired_summary),
                )?;
                sync(&directory)?;
            }
            crate::storage::atomic_json(&directory.join("transcript.json"), &transcript)
        })();
        if let Err(error) = publication {
            recover(&directory)?;
            return Err(error);
        }
        // Receipt and result are already one atomic file. Cleanup failure must
        // not turn successful inference into an invitation to rerun it.
        let _ = recover(&directory);
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::speech_execution::{execute, SpeechInference};
    use crate::application::speech_launch::SpeechSettings;
    fn fixture(root: &Path) -> (SpeechWork, PathBuf) {
        let id = uuid::Uuid::new_v4().to_string();
        let directory = crate::storage::meeting_directory(root, &id).unwrap();
        crate::platform_fs::create_private_directory(&directory).unwrap();
        crate::storage::atomic_json(
            &directory.join("meta.json"),
            &json!({"id":id,"source":"input.wav","title":"original"}),
        )
        .unwrap();
        fs::write(
            directory.join("input.wav"),
            b"synthetic input; never inferred in unit tests",
        )
        .unwrap();
        fs::write(directory.join("transcript.json"), b"{\"original\":true}").unwrap();
        fs::write(
            directory.join("summary.json"),
            b"{\"keep\":\"original summary\"}",
        )
        .unwrap();
        let revision = Publication { root }.inspect(&id).unwrap();
        (
            SpeechWork {
                version: 1,
                operation_id: uuid::Uuid::new_v4().to_string(),
                attempt_token: uuid::Uuid::new_v4().to_string(),
                meeting_id: id,
                input_revision: revision,
                settings: json!({"speechMode":"local","diarization":false}),
            },
            directory,
        )
    }
    fn output(stage: &Stage) {
        crate::storage::atomic_json(&stage.directory.join("transcript.json"), &json!({"duration":1.,"segments":[{"id":0,"start":0.,"end":1.,"text":"synthetic result"}]})).unwrap();
    }
    #[test]
    fn legacy_meeting_identity_survives_staging_publication_and_receipt_recovery() {
        for id in ["Meeting_2026-11-03", "ABCDEF12-3456-4789-ABCD-123456789ABC"] {
            let root = tempfile::tempdir().unwrap();
            let (mut work, old_directory) = fixture(root.path());
            let directory = root.path().join("meetings").join(id);
            fs::rename(old_directory, &directory).unwrap();
            crate::storage::atomic_json(
                &directory.join("meta.json"),
                &json!({"id":id,"source":"input.wav","title":"original"}),
            )
            .unwrap();
            let publication = Publication { root: root.path() };
            work.meeting_id = id.into();
            work.input_revision = publication.inspect(id).unwrap();
            work.validate().unwrap();
            let stage = publication.stage(&work).unwrap();
            output(&stage);
            let result = publication.publish(&work, &stage).unwrap();
            assert_eq!(result.meeting_id, id);
            assert_eq!(
                receipt(&directory).unwrap(),
                Some(SpeechReceipt::for_work(&work))
            );
            assert!(publication.committed(&work).unwrap());
            assert_eq!(
                fs::read(directory.join("input.wav")).unwrap(),
                b"synthetic input; never inferred in unit tests"
            );
            work.operation_id = "legacy-operation".into();
            assert!(work.validate().is_err());
        }
    }
    #[test]
    fn inference_is_isolated_and_atomic_receipt_prevents_repeat_execution() {
        let root = tempfile::tempdir().unwrap();
        let (work, directory) = fixture(root.path());
        let publication = Publication { root: root.path() };
        let stage = publication.stage(&work).unwrap();
        output(&stage);
        assert!(directory.join("summary.json").exists());
        assert_eq!(
            fs::read(directory.join("transcript.json")).unwrap(),
            b"{\"original\":true}"
        );
        assert_ne!(stage.directory, directory);
        let result = publication.publish(&work, &stage).unwrap();
        assert_eq!(receipt(&directory).unwrap(), Some(result));
        assert!(!directory.join("summary.json").exists());
        assert!(!directory.join(JOURNAL).exists());
        struct Never;
        impl SpeechInference for Never {
            fn transcribe(&self, _: &Path, _: SpeechSettings) -> Result<()> {
                panic!("already committed speech must never infer again")
            }
        }
        assert_eq!(
            execute(&publication, &Never, &work).unwrap(),
            SpeechReceipt::for_work(&work)
        );
        assert_eq!(
            fs::read(directory.join("input.wav")).unwrap(),
            b"synthetic input; never inferred in unit tests"
        );
    }
    #[test]
    fn lost_publication_acknowledgement_still_returns_the_exact_committed_receipt() {
        let root = tempfile::tempdir().unwrap();
        let (work, directory) = fixture(root.path());
        struct LostAck<'a>(Publication<'a>);
        impl SpeechPublication for LostAck<'_> {
            type Stage = Stage;
            fn committed(&self, work: &SpeechWork) -> Result<bool> {
                self.0.committed(work)
            }
            fn stage(&self, work: &SpeechWork) -> Result<Stage> {
                self.0.stage(work)
            }
            fn directory(stage: &Stage) -> &Path {
                &stage.directory
            }
            fn publish(&self, work: &SpeechWork, stage: &Stage) -> Result<SpeechReceipt> {
                self.0.publish(work, stage)?;
                anyhow::bail!("publication reply was lost")
            }
        }
        struct Inference;
        impl SpeechInference for Inference {
            fn transcribe(&self, directory: &Path, _: SpeechSettings) -> Result<()> {
                crate::storage::atomic_json(
                    &directory.join("transcript.json"),
                    &json!({"duration":1.,"segments":[]}),
                )
            }
        }
        let result = execute(
            &LostAck(Publication { root: root.path() }),
            &Inference,
            &work,
        )
        .unwrap();
        assert_eq!(result, SpeechReceipt::for_work(&work));
        assert_eq!(receipt(&directory).unwrap(), Some(result));
    }

    #[test]
    fn concurrent_source_or_result_edits_preserve_all_observed_data() {
        for changed in ["input.wav", "transcript.json", "summary.json"] {
            let root = tempfile::tempdir().unwrap();
            let (work, directory) = fixture(root.path());
            let publication = Publication { root: root.path() };
            let stage = publication.stage(&work).unwrap();
            output(&stage);
            fs::write(
                directory.join(changed),
                b"changed while inference was running",
            )
            .unwrap();
            let before: Vec<_> = ["input.wav", "transcript.json", "summary.json"]
                .into_iter()
                .map(|name| fs::read(directory.join(name)).unwrap())
                .collect();
            assert!(publication.publish(&work, &stage).is_err(), "{changed}");
            let after: Vec<_> = ["input.wav", "transcript.json", "summary.json"]
                .into_iter()
                .map(|name| fs::read(directory.join(name)).unwrap())
                .collect();
            assert_eq!(before, after);
            assert!(!directory.join(JOURNAL).exists());
        }
    }
    #[test]
    fn title_edits_survive_but_replaced_meeting_incarnations_are_rejected() {
        let root = tempfile::tempdir().unwrap();
        let (work, directory) = fixture(root.path());
        let publication = Publication { root: root.path() };
        let stage = publication.stage(&work).unwrap();
        output(&stage);
        let mut meta = crate::storage::regular_json(&directory.join("meta.json")).unwrap();
        meta["title"] = json!("edited while recognizing");
        crate::storage::atomic_json(&directory.join("meta.json"), &meta).unwrap();
        publication.publish(&work, &stage).unwrap();
        assert_eq!(
            crate::storage::regular_json(&directory.join("meta.json")).unwrap()["title"],
            "edited while recognizing"
        );
        let (work, directory) = fixture(root.path());
        let stage = publication.stage(&work).unwrap();
        output(&stage);
        fs::rename(&directory, directory.with_extension("old")).unwrap();
        crate::platform_fs::create_private_directory(&directory).unwrap();
        assert!(publication.publish(&work, &stage).is_err());
        assert!(!directory.join("transcript.json").exists());
    }
    #[test]
    fn stage_identity_invalid_output_and_source_aliases_cannot_publish() {
        let root = tempfile::tempdir().unwrap();
        let (work, directory) = fixture(root.path());
        let publication = Publication { root: root.path() };
        let stage = publication.stage(&work).unwrap();
        output(&stage);
        let mut foreign = work.clone();
        foreign.attempt_token = uuid::Uuid::new_v4().to_string();
        assert!(publication.publish(&foreign, &stage).is_err());
        let mut foreign_settings = work.clone();
        foreign_settings.settings["asrModelPath"] = json!("/another/model");
        assert!(publication.publish(&foreign_settings, &stage).is_err());
        crate::storage::atomic_json(
            &stage.directory.join("transcript.json"),
            &json!({"duration":1.,"segments":[{"id":0,"start":0.,"end":2.,"text":"invalid"}]}),
        )
        .unwrap();
        assert!(publication.publish(&work, &stage).is_err());
        fs::rename(&stage.directory, stage.directory.with_extension("moved")).unwrap();
        crate::platform_fs::create_private_directory(&stage.directory).unwrap();
        output(&stage);
        assert!(publication.publish(&work, &stage).is_err());
        fs::remove_file(directory.join("input.wav")).unwrap();
        std::os::unix::fs::symlink("transcript.json", directory.join("input.wav")).unwrap();
        assert!(publication.stage(&work).is_err());
        assert!(directory.join("summary.json").exists());
    }
    #[test]
    fn recovery_rolls_back_retirement_or_confirms_receipt_without_inference() {
        for committed in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let (work, directory) = fixture(root.path());
            let journal = Journal {
                version: 1,
                receipt: SpeechReceipt::for_work(&work),
                previous_transcript: Some(digest(
                    &fs::read(directory.join("transcript.json")).unwrap(),
                )),
                summary_hash: Some(digest(&fs::read(directory.join("summary.json")).unwrap())),
                retired_summary: format!(".speech-summary-{}", work.attempt_token),
            };
            crate::storage::atomic_json(&directory.join(JOURNAL), &journal).unwrap();
            fs::rename(
                directory.join("summary.json"),
                directory.join(&journal.retired_summary),
            )
            .unwrap();
            if committed {
                crate::storage::atomic_json(
                    &directory.join("transcript.json"),
                    &json!({"duration":1.,"segments":[],RECEIPT:journal.receipt}),
                )
                .unwrap();
            }
            recover(&directory).unwrap();
            assert!(!directory.join(JOURNAL).exists());
            assert_eq!(directory.join("summary.json").exists(), !committed);
            assert!(!directory.join(&journal.retired_summary).exists());
            if !committed {
                assert_eq!(
                    fs::read(directory.join("summary.json")).unwrap(),
                    b"{\"keep\":\"original summary\"}"
                );
            }
        }
    }
    #[test]
    fn unknown_recovery_outcome_retains_journal_and_backup() {
        let root = tempfile::tempdir().unwrap();
        let (work, directory) = fixture(root.path());
        let journal = Journal {
            version: 1,
            receipt: SpeechReceipt::for_work(&work),
            previous_transcript: Some("unknown".into()),
            summary_hash: None,
            retired_summary: format!(".speech-summary-{}", work.attempt_token),
        };
        crate::storage::atomic_json(&directory.join(JOURNAL), &journal).unwrap();
        fs::rename(
            directory.join("summary.json"),
            directory.join(&journal.retired_summary),
        )
        .unwrap();
        let before = fs::read(directory.join(&journal.retired_summary)).unwrap();
        assert!(recover(&directory).is_err());
        assert!(directory.join(JOURNAL).exists());
        assert_eq!(
            fs::read(directory.join(&journal.retired_summary)).unwrap(),
            before
        );
    }
}
