//! Indexed pending-meeting lookup and the existing canonical submission adapters.
use crate::{
    application::{
        jobs::{JobCommand, JobReply},
        speech_submission::SubmissionPort,
        speech_work::{SpeechWork, KIND},
    },
    domain::jobs::{Job, JobDefinition},
};
use anyhow::{bail, ensure, Result};
use std::path::Path;
pub(crate) struct Submission<'a> {
    pub root: &'a Path,
}
impl Submission<'_> {
    fn queue(&self) -> super::attempt_store::ScopedAttemptStore<'_> {
        super::attempt_store::ScopedAttemptStore {
            root: self.root,
            kind: KIND,
            label: "Speech",
        }
    }
}
impl SubmissionPort for Submission<'_> {
    fn pending(&self, meeting: &str) -> Result<Option<Job>> {
        lookup(self.root, meeting, true)
    }
    fn prepare(&self, meeting: &str) -> Result<SpeechWork> {
        let _root = super::runtime_tree::open(self.root, true)?;
        crate::application::speech_preparation::prepare(
            &super::speech_preparation::Inputs { root: self.root },
            meeting,
        )
    }
    fn operation(&self, id: &str) -> Result<Option<Job>> {
        self.queue().queue().object_job(id)
    }
    fn revision(&self, meeting: &str) -> Result<String> {
        let _root = super::runtime_tree::open(self.root, true)?;
        super::speech_publication::Publication { root: self.root }.inspect(meeting)
    }
    fn insert(&self, definition: JobDefinition) -> Result<(Job, bool)> {
        match self.queue().queue().execute(JobCommand::Enqueue {
            definition,
            follow_ups: vec![],
        })? {
            JobReply::Enqueued {
                job, deduplicated, ..
            } => Ok((job, deduplicated)),
            _ => bail!("Invalid speech enqueue reply"),
        }
    }
}

pub(crate) fn latest(root: &Path, meeting: &str) -> Result<Option<Job>> {
    ensure!(
        crate::domain::meeting_ids::valid(meeting),
        "Invalid meeting identity"
    );
    if let Some(job) = lookup(root, meeting, true)? {
        return Ok(Some(job));
    }
    lookup(root, meeting, false)
}
fn lookup(root: &Path, meeting: &str, pending: bool) -> Result<Option<Job>> {
    let connection = super::job_database::open(root)?;
    connection.execute_batch("CREATE INDEX IF NOT EXISTS jobs_speech_meeting_created ON jobs(json_extract(payload,'$.config.meetingId'),created_at DESC,id DESC) WHERE json_extract(payload,'$.kind')='desktop-speech';")?;
    let sql = if pending {
        "SELECT id,state,payload FROM jobs WHERE json_extract(payload,'$.kind')='desktop-speech' AND state IN ('queued','running','interrupted','blocked') AND json_extract(payload,'$.config.meetingId')=?1 ORDER BY id LIMIT 2"
    } else {
        "SELECT id,state,payload FROM jobs WHERE json_extract(payload,'$.kind')='desktop-speech' AND json_extract(payload,'$.config.meetingId')=?1 ORDER BY created_at DESC,id DESC LIMIT 1"
    };
    let mut statement = connection.prepare(sql)?;
    let rows = statement.query_map([meeting], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
        ))
    })?;
    let mut found = None;
    for row in rows {
        let (id, state, payload) = row?;
        ensure!(
            found.is_none(),
            "Ambiguous unfinished speech jobs for this meeting"
        );
        let job: Job = serde_json::from_str(&payload)?;
        let work = SpeechWork::from_job(&job)?;
        ensure!(
            job.id == id && job.state == state && work.meeting_id == meeting,
            "Invalid speech identity"
        );
        found = Some(job);
    }
    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::{
        attempt_execution::{AttemptOutcome, AttemptStore},
        speech_submission,
    };
    use crate::domain::jobs::JobMutation;
    fn definition(work: &SpeechWork, kind: &str) -> JobDefinition {
        JobDefinition {
            kind: kind.into(),
            object_id: work.operation_id.clone(),
            input_revision: work.input_revision.clone(),
            config: serde_json::to_value(work).unwrap(),
            resource: crate::domain::jobs::JobResource::LocalHeavy,
            dependencies: vec![],
            title: "Synthetic".into(),
            paid: false,
        }
    }
    #[test]
    fn pending_lookup_ignores_history_limit_and_foreign_scope_and_preserves_ambiguity() {
        let root = tempfile::tempdir().unwrap();
        let meeting = "Meeting_2026-11-03".to_string();
        let directory = crate::storage::meeting_directory(root.path(), &meeting).unwrap();
        crate::platform_fs::create_private_directory(&directory).unwrap();
        crate::storage::atomic_json(
            &directory.join("meta.json"),
            &serde_json::json!({"id":meeting,"source":"source.wav"}),
        )
        .unwrap();
        std::fs::write(directory.join("source.wav"), b"original").unwrap();
        std::fs::write(root.path().join("settings.json"),serde_json::json!({"speechMode":"local","diarization":false,"asrModelPath":"/selected/model"}).to_string()).unwrap();
        let port = Submission { root: root.path() };
        let initial = speech_submission::submit(&port, &meeting).unwrap();
        assert!(initial.created);
        let store = port.queue();
        let mut work: SpeechWork = serde_json::from_value(initial.job.config.clone()).unwrap();
        store
            .queue()
            .execute(JobCommand::Claim(crate::application::jobs::ClaimRequest {
                job_id: Some(initial.job.id.clone()),
                allowed_resources: None,
                excluded_accounts: vec![],
            }))
            .unwrap();
        store
            .finish(&initial.job.id, 1, AttemptOutcome::Interrupted)
            .unwrap();
        for _ in 0..55 {
            work.operation_id = uuid::Uuid::new_v4().to_string();
            work.attempt_token = uuid::Uuid::new_v4().to_string();
            work.meeting_id = uuid::Uuid::new_v4().to_string();
            let (job, _) = port.insert(definition(&work, KIND)).unwrap();
            store
                .queue()
                .execute(JobCommand::Mutate {
                    id: job.id,
                    expected_attempt: Some(0),
                    mutation: JobMutation::Cancel,
                })
                .unwrap();
        }
        assert!(!store
            .queue()
            .history(None)
            .unwrap()
            .jobs
            .iter()
            .any(|job| job.id == initial.job.id));
        std::fs::write(
            root.path().join("settings.json"),
            br#"{"speechMode":"cloud"}"#,
        )
        .unwrap();
        let existing = speech_submission::submit(&port, &meeting).unwrap();
        assert!(!existing.created);
        assert_eq!(existing.job.id, initial.job.id);
        assert_eq!(
            latest(root.path(), &meeting).unwrap().unwrap().id,
            initial.job.id
        );
        let foreign = super::super::attempt_store::ScopedAttemptStore {
            root: root.path(),
            kind: "foreign",
            label: "Foreign",
        };
        work.meeting_id = meeting.clone();
        work.operation_id = uuid::Uuid::new_v4().to_string();
        foreign
            .queue()
            .execute(JobCommand::Enqueue {
                definition: definition(&work, "foreign"),
                follow_ups: vec![],
            })
            .unwrap();
        assert_eq!(port.pending(&meeting).unwrap().unwrap().id, initial.job.id);
        port.insert(definition(&work, KIND)).unwrap();
        assert!(port.pending(&meeting).is_err());
        assert_eq!(
            std::fs::read(directory.join("source.wav")).unwrap(),
            b"original"
        );
        assert!(!directory.join("transcript.json").exists());
    }
}
