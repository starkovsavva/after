//! Submission is independent of SQL and of publication/process execution policy.
use super::speech_work::{SpeechWork, KIND};
use crate::domain::jobs::{Job, JobDefinition, JobResource};
use anyhow::{ensure, Result};
pub(crate) trait SubmissionPort {
    fn pending(&self, meeting: &str) -> Result<Option<Job>>;
    fn prepare(&self, meeting: &str) -> Result<SpeechWork>;
    fn operation(&self, id: &str) -> Result<Option<Job>>;
    fn revision(&self, meeting: &str) -> Result<String>;
    fn insert(&self, definition: JobDefinition) -> Result<(Job, bool)>;
}
pub(crate) struct Submitted {
    pub job: Job,
    pub created: bool,
}
pub(crate) fn enqueue(port: &impl SubmissionPort, work: SpeechWork) -> Result<(Job, bool)> {
    work.validate()?;
    if let Some(job) = port.operation(&work.operation_id)? {
        ensure!(
            job.config == serde_json::to_value(&work)?,
            "Speech operation identity was reused"
        );
        return Ok((job, true));
    }
    ensure!(
        port.revision(&work.meeting_id)? == work.input_revision,
        "Speech source or result changed before enqueue"
    );
    port.insert(JobDefinition {
        kind: KIND.into(),
        object_id: work.operation_id.clone(),
        input_revision: work.input_revision.clone(),
        config: serde_json::to_value(work)?,
        resource: JobResource::LocalHeavy,
        dependencies: Vec::new(),
        title: "Transcribe meeting".into(),
        paid: false,
    })
}
pub(crate) fn submit(port: &impl SubmissionPort, meeting: &str) -> Result<Submitted> {
    ensure!(
        uuid::Uuid::parse_str(meeting)?.to_string() == meeting,
        "Invalid meeting identity"
    );
    if let Some(job) = port.pending(meeting)? {
        let work = SpeechWork::from_job(&job)?;
        ensure!(
            work.meeting_id == meeting
                && ["queued", "running", "interrupted", "blocked"].contains(&job.state.as_str()),
            "Invalid pending speech work"
        );
        return Ok(Submitted {
            job,
            created: false,
        });
    }
    let work = port.prepare(meeting)?;
    ensure!(
        work.meeting_id == meeting,
        "Prepared speech meeting changed"
    );
    let (job, deduplicated) = enqueue(port, work)?;
    Ok(Submitted {
        job,
        created: !deduplicated,
    })
}
