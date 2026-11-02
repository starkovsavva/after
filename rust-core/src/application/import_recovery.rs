//! Read-only receipt reconciliation; no worker execution or implicit retries.
use super::import_ports::{
    input_for_job, ImportReceipts, ImportRecoveryStore, IMPORT_JOB_KIND,
};
use anyhow::Result;

pub(crate) use super::job_recovery::RecoveryReport;
pub(crate) fn reconcile<R: ImportReceipts + ?Sized>(
    store: &dyn ImportRecoveryStore,
    receipts: &R,
    after: Option<&str>,
) -> Result<RecoveryReport> {
    super::job_recovery::reconcile(
        store,
        IMPORT_JOB_KIND,
        |job| input_for_job(job).and_then(|input| receipts.committed(&input)),
        after,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::import_ports::ImportRecoveryOutcome;
    use crate::{
        application::import_ports::ImportInput,
        domain::jobs::{Job, JobDefinition, JobResource},
    };
    use std::{
        collections::{BTreeMap, HashSet},
        sync::Mutex,
    };
    fn job(index: u128, state: &str, cancelled: bool) -> Job {
        let input = ImportInput {
            operation_id: uuid::Uuid::from_u128(index + 10_000).to_string(),
            attempt_token: uuid::Uuid::from_u128(index + 20_000).to_string(),
            source_path: std::env::temp_dir().join("private-source.wav"),
            title: None,
        };
        let mut job = JobDefinition {
            kind: IMPORT_JOB_KIND.into(),
            object_id: input.operation_id.clone(),
            input_revision: "v1".into(),
            config: serde_json::to_value(input).unwrap(),
            resource: JobResource::LocalHeavy,
            dependencies: Vec::new(),
            title: "Import".into(),
            paid: false,
        }
        .into_job(uuid::Uuid::from_u128(index).to_string(), 1.0);
        job.state = state.into();
        job.attempt = 1;
        job.cancel_requested = cancelled;
        job
    }
    #[derive(Default)]
    struct Store {
        jobs: Vec<Job>,
        writes: Mutex<Vec<(String, ImportRecoveryOutcome)>>,
        stale: HashSet<String>,
    }
    impl ImportRecoveryStore for Store {
        fn candidates(&self, after: Option<&str>, limit: usize) -> Result<Vec<Job>> {
            Ok(self
                .jobs
                .iter()
                .filter(|job| after.is_none_or(|after| job.id.as_str() > after))
                .take(limit)
                .cloned()
                .collect())
        }
        fn resolve(&self, observed: &Job, outcome: ImportRecoveryOutcome) -> Result<bool> {
            if self.stale.contains(&observed.id) {
                return Ok(false);
            }
            self.writes
                .lock()
                .unwrap()
                .push((observed.id.clone(), outcome));
            Ok(true)
        }
    }
    struct Receipts(BTreeMap<String, Option<bool>>);
    impl ImportReceipts for Receipts {
        fn committed(&self, input: &ImportInput) -> Result<bool> {
            match self
                .0
                .get(&input.operation_id)
                .copied()
                .unwrap_or(Some(false))
            {
                Some(value) => Ok(value),
                None => anyhow::bail!("sensitive unreadable receipt: private-source.wav"),
            }
        }
    }
    #[test]
    fn published_wins_cancel_but_missing_and_unknown_receipts_have_distinct_outcomes() {
        let jobs = vec![
            job(1, "running", true),
            job(2, "running", true),
            job(3, "running", true),
        ];
        let receipts = Receipts(BTreeMap::from([
            (jobs[0].object_id.clone(), Some(true)),
            (jobs[2].object_id.clone(), None),
        ]));
        let store = Store {
            jobs,
            ..Default::default()
        };
        let report = reconcile(&store, &receipts, None).unwrap();
        assert_eq!(
            (
                report.published,
                report.cancelled,
                report.interrupted,
                report.unresolved
            ),
            (1, 1, 1, 1)
        );
        assert_eq!(
            store
                .writes
                .lock()
                .unwrap()
                .iter()
                .map(|(_, outcome)| *outcome)
                .collect::<Vec<_>>(),
            [
                ImportRecoveryOutcome::Published,
                ImportRecoveryOutcome::Cancelled,
                ImportRecoveryOutcome::Unresolved
            ]
        );
        assert!(!serde_json::to_string(&report)
            .unwrap()
            .contains("private-source"));
    }
    #[test]
    fn interrupted_history_is_rechecked_without_rewriting_known_negative_or_unknown_rows() {
        let jobs = vec![
            job(1, "interrupted", false),
            job(2, "interrupted", false),
            job(3, "interrupted", false),
            job(4, "interrupted", true),
        ];
        let receipts = Receipts(BTreeMap::from([
            (jobs[0].object_id.clone(), Some(true)),
            (jobs[2].object_id.clone(), None),
        ]));
        let store = Store {
            jobs,
            ..Default::default()
        };
        let report = reconcile(&store, &receipts, None).unwrap();
        assert_eq!(
            (
                report.published,
                report.cancelled,
                report.interrupted,
                report.unresolved
            ),
            (1, 1, 0, 1)
        );
        assert_eq!(store.writes.lock().unwrap().len(), 2);
    }
    #[test]
    fn recovery_advances_over_multiple_pages_and_leaves_changed_attempts_untouched() {
        let jobs: Vec<_> = (1..=73).map(|index| job(index, "running", false)).collect();
        let stale = HashSet::from([jobs[2].id.clone()]);
        let store = Store {
            jobs,
            stale,
            ..Default::default()
        };
        let receipts = Receipts(BTreeMap::new());
        let first = reconcile(&store, &receipts, None).unwrap();
        assert!(first.has_more);
        assert_eq!(first.examined, 64);
        assert_eq!(first.stale, 1);
        let last = reconcile(&store, &receipts, first.next_cursor.as_deref()).unwrap();
        assert!(!last.has_more);
        assert_eq!(last.examined, 9);
        let writes = store.writes.lock().unwrap();
        assert_eq!(writes.len(), 72);
        assert!(!writes.iter().any(|(id, _)| store.stale.contains(id)));
    }
    #[test]
    fn malformed_input_is_unresolved_and_invalid_store_pages_cannot_repair_records() {
        let mut malformed = job(1, "running", false);
        malformed.config["command"] = serde_json::json!("execute");
        let store = Store {
            jobs: vec![malformed],
            ..Default::default()
        };
        assert_eq!(
            reconcile(&store, &Receipts(BTreeMap::new()), None)
                .unwrap()
                .unresolved,
            1
        );
        let mut foreign = job(1, "running", false);
        foreign.kind = "summarize".into();
        let store = Store {
            jobs: vec![foreign],
            ..Default::default()
        };
        assert!(reconcile(&store, &Receipts(BTreeMap::new()), None).is_err());
        assert!(store.writes.lock().unwrap().is_empty());
    }
}
