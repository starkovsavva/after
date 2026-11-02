//! Renderer read models are deliberately separate from private queue DTOs.
use crate::{
    import_queue::{HistoryCursor, JobState, QueueReply},
    models::HostError,
};
use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportHistory {
    pub jobs: Vec<ImportHistoryEntry>,
    pub total: u64,
    pub has_more: bool,
    pub next_cursor: Option<HistoryCursor>,
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
        Self::from_reply(reply, None)
    }
}
impl ImportHistory {
    pub fn from_reply(reply: QueueReply, after: Option<&HistoryCursor>) -> Result<Self, HostError> {
        let invalid = || HostError::new("invalid_response", "Import history is unavailable.");
        let total = reply.total.ok_or_else(invalid)?;
        let has_more = reply.has_more.ok_or_else(invalid)?;
        if reply.jobs.len() > 50
            || total < reply.jobs.len() as u64
            || has_more != reply.next_cursor.is_some()
            || (has_more && reply.jobs.len() != 50)
            || (after.is_none() && has_more != (total > reply.jobs.len() as u64))
        {
            return Err(invalid());
        }
        let mut ids = std::collections::HashSet::new();
        let mut previous = after.cloned();
        let jobs = reply
            .jobs
            .into_iter()
            .map(|job| {
                let cursor = HistoryCursor {
                    created_at: job.created_at.ok_or_else(invalid)?,
                    id: job.id.clone(),
                };
                if !cursor.valid()
                    || previous
                        .as_ref()
                        .is_some_and(|previous| !cursor.follows(previous))
                    || uuid::Uuid::parse_str(&job.object_id).is_err()
                    || !job.progress.is_finite()
                    || !(0.0..=1.0).contains(&job.progress)
                    || !ids.insert(job.id.clone())
                {
                    return Err(invalid());
                }
                previous = Some(cursor);
                Ok(ImportHistoryEntry {
                    job_id: job.id,
                    operation_id: job.object_id,
                    state: job.state,
                    progress: job.progress,
                    attempt: job.attempt,
                    cancel_requested: job.cancel_requested,
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        if has_more && reply.next_cursor.as_ref() != previous.as_ref() {
            return Err(invalid());
        }
        Ok(Self {
            jobs,
            total,
            has_more,
            next_cursor: reply.next_cursor,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn a_terminal_page_accepts_global_count_but_rejects_replayed_creation_keys() {
        let value = json!({"jobs":[{"id":"11111111-1111-4111-8111-111111111111","objectID":"22222222-2222-4222-8222-222222222222",
            "createdAt":1.0,"state":"interrupted","progress":0.0,"attempt":1,"cancelRequested":false}],"total":51,"hasMore":false,"nextCursor":null});
        let after = HistoryCursor {
            created_at: 2.0,
            id: uuid::Uuid::from_u128(3).to_string(),
        };
        assert!(ImportHistory::from_reply(
            serde_json::from_value(value.clone()).unwrap(),
            Some(&after)
        )
        .is_ok());
        assert!(ImportHistory::try_from(
            serde_json::from_value::<QueueReply>(value.clone()).unwrap()
        )
        .is_err());
        let replay = HistoryCursor {
            created_at: 1.0,
            id: "11111111-1111-4111-8111-111111111111".into(),
        };
        assert!(
            ImportHistory::from_reply(serde_json::from_value(value).unwrap(), Some(&replay))
                .is_err()
        );
    }
    #[test]
    fn a_continuation_must_match_the_last_row_of_a_full_ordered_page() {
        let jobs: Vec<_>=(1..=50).rev().map(|index|json!({"id":uuid::Uuid::from_u128(index).to_string(),
            "objectID":uuid::Uuid::from_u128(index+1000).to_string(),"createdAt":1_793_619_200.0000021,"state":"queued","progress":0.0,"attempt":0,"cancelRequested":false})).collect();
        let mut value = json!({"jobs":jobs,"total":51,"hasMore":true,"nextCursor":{"createdAt":1_793_619_200.0000021,"id":uuid::Uuid::from_u128(1).to_string()}});
        let exact = ImportHistory::try_from(
            serde_json::from_str::<QueueReply>(&value.to_string()).unwrap(),
        )
        .unwrap();
        assert_eq!(
            exact.next_cursor.unwrap().created_at.to_bits(),
            1_793_619_200.0000021f64.to_bits()
        );
        value["nextCursor"]["id"] = json!(uuid::Uuid::from_u128(2).to_string());
        assert!(
            ImportHistory::try_from(serde_json::from_value::<QueueReply>(value).unwrap()).is_err()
        );
    }

    #[test]
    fn renderer_history_has_only_explicit_grant_free_fields() {
        let reply: QueueReply = serde_json::from_value(json!({
            "jobs":[{"id":"11111111-1111-4111-8111-111111111111", "objectID":"22222222-2222-4222-8222-222222222222",
                "createdAt":1.0,"state":"interrupted", "progress":0.5,"attempt":1,"cancelRequested":false}],
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
