//! Renderer read models are deliberately separate from private queue DTOs.
use crate::{
    import_queue::{JobState, QueueReply},
    models::HostError,
};
use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportHistory {
    pub jobs: Vec<ImportHistoryEntry>,
    pub total: u64,
    pub has_more: bool,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportHistoryEntry {
    pub job_id: String,
    pub operation_id: String,
    pub state: JobState,
    pub progress: f64,
    pub attempt: u64,
    pub cancel_requested: bool,
}
impl TryFrom<QueueReply> for ImportHistory {
    type Error = HostError;
    fn try_from(reply: QueueReply) -> Result<Self, Self::Error> {
        let invalid = || HostError::new("invalid_response", "Import history is unavailable.");
        let total = reply.total.ok_or_else(invalid)?;
        let has_more = reply.has_more.ok_or_else(invalid)?;
        if reply.jobs.len() > 50
            || total < reply.jobs.len() as u64
            || has_more != (total > reply.jobs.len() as u64)
        {
            return Err(invalid());
        }
        let mut ids = std::collections::HashSet::new();
        let jobs = reply
            .jobs
            .into_iter()
            .map(|job| {
                if uuid::Uuid::parse_str(&job.id).is_err()
                    || uuid::Uuid::parse_str(&job.object_id).is_err()
                    || !job.progress.is_finite()
                    || !(0.0..=1.0).contains(&job.progress)
                    || !ids.insert(job.id.clone())
                {
                    return Err(invalid());
                }
                Ok(ImportHistoryEntry {
                    job_id: job.id,
                    operation_id: job.object_id,
                    state: job.state,
                    progress: job.progress,
                    attempt: job.attempt,
                    cancel_requested: job.cancel_requested,
                })
            })
            .collect::<Result<_, _>>()?;
        Ok(Self {
            jobs,
            total,
            has_more,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn renderer_history_has_only_explicit_grant_free_fields() {
        let reply: QueueReply = serde_json::from_value(json!({
            "jobs":[{"id":"11111111-1111-4111-8111-111111111111", "objectID":"22222222-2222-4222-8222-222222222222",
                "state":"interrupted", "progress":0.5,"attempt":1,"cancelRequested":false}],
            "total":1,"hasMore":false,
            "privateExtension":{"sourcePath":"/private/source.wav","attemptToken":"secret"}
        })).unwrap();
        let public = serde_json::to_value(ImportHistory::try_from(reply).unwrap()).unwrap();
        assert_eq!(public["jobs"][0].as_object().unwrap().len(), 6);
        let text = public.to_string();
        for private in ["sourcePath", "attemptToken", "secret", "/private", "config"] {
            assert!(!text.contains(private));
        }
    }
    #[test]
    fn invalid_totals_and_duplicate_entries_are_not_presented_as_empty_history() {
        for value in [
            json!({"jobs":[],"total":1,"hasMore":false}),
            json!({"jobs":[]}),
        ] {
            assert!(
                ImportHistory::try_from(serde_json::from_value::<QueueReply>(value).unwrap())
                    .is_err()
            );
        }
    }
}
