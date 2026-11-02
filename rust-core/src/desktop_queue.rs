//! Native-only composition root for the desktop import executor. This transport
//! is deliberately not registered as a renderer command. Recovery requires an
//! exclusive executor lease; callers must not recover another live host.
use crate::application::import_ports::{ImportInput, IMPORT_JOB_KIND as KIND};
use crate::application::job_ports::JobHistoryCursor;
use crate::application::jobs::{ClaimRequest, JobCommand, JobQueue, JobReply};
use crate::domain::jobs::{Job, JobDefinition, JobMutation, JobResource, JobUpdate, UpdateField};
use crate::infrastructure::{
    job_context::{RandomJobIds, SystemJobClock},
    job_queue::SqliteJobQueue,
};
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::Path;

#[derive(Deserialize)]
#[serde(
    tag = "action",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub(crate) enum Request {
    Enqueue {
        input: ImportInput,
    },
    List {},
    History {
        after: Option<JobHistoryCursor>,
    },
    Get {
        job_id: String,
    },
    Run {
        job_id: String,
    },
    Claim {
        job_id: Option<String>,
    },
    Cancel {
        job_id: String,
        expected_attempt: u64,
    },
    Retry {
        job_id: String,
        expected_attempt: u64,
    },
    Update {
        job_id: String,
        expected_attempt: u64,
        state: State,
        progress: f64,
    },
    Recover {},
    Reconcile {
        after_job_id: Option<String>,
    },
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum State {
    Running,
    Succeeded,
    Failed,
    Cancelled,
    Interrupted,
}

pub(crate) fn id(value: &str) -> Result<()> {
    ensure!(
        crate::desktop_import::valid_import_id(value),
        "Invalid queue identifier"
    );
    Ok(())
}

pub(crate) fn execute(root: &Path, request: Request) -> Result<Value> {
    if let Request::History { after } = request {
        let page = queue(root).history(after.as_ref())?;
        let jobs: Vec<_> = page
            .jobs
            .iter()
            .map(|job| {
                let mut row = summary(job);
                row["createdAt"] = json!(job.created_at);
                row
            })
            .collect();
        return Ok(
            json!({"jobs":jobs,"total":page.total,"hasMore":page.next_cursor.is_some(),"nextCursor":page.next_cursor}),
        );
    }
    let command = match request {
        Request::Enqueue { input } => {
            input.validate()?;
            JobCommand::Enqueue {
                definition: JobDefinition {
                    kind: KIND.into(),
                    object_id: input.operation_id.clone(),
                    input_revision: "desktop-import-v1".into(),
                    config: serde_json::to_value(input)?,
                    resource: JobResource::LocalHeavy,
                    dependencies: Vec::new(),
                    title: "Import media".into(),
                    paid: false,
                },
                follow_ups: Vec::new(),
            }
        }
        Request::Reconcile { .. } | Request::Run { .. } => {
            anyhow::bail!("Import run requires its live executor")
        }
        Request::List {} => JobCommand::List,
        Request::History { .. } => unreachable!(),
        Request::Get { job_id } => {
            id(&job_id)?;
            JobCommand::Get { id: job_id }
        }
        Request::Claim { job_id } => {
            if let Some(id_value) = &job_id {
                id(id_value)?;
            }
            JobCommand::Claim(ClaimRequest {
                job_id,
                allowed_resources: None,
                excluded_accounts: Vec::new(),
            })
        }
        Request::Cancel {
            job_id,
            expected_attempt,
        } => {
            id(&job_id)?;
            JobCommand::Mutate {
                id: job_id,
                expected_attempt: Some(expected_attempt),
                mutation: JobMutation::Cancel,
            }
        }
        Request::Retry {
            job_id,
            expected_attempt,
        } => {
            id(&job_id)?;
            JobCommand::Mutate {
                id: job_id,
                expected_attempt: Some(expected_attempt),
                mutation: JobMutation::Retry {
                    confirm_paid: false,
                },
            }
        }
        Request::Update {
            job_id,
            expected_attempt,
            state,
            progress,
        } => {
            id(&job_id)?;
            let state = serde_json::to_value(state)?.as_str().unwrap().to_owned();
            JobCommand::Mutate {
                id: job_id,
                expected_attempt: Some(expected_attempt),
                mutation: JobMutation::Update(JobUpdate {
                    state: Some(state),
                    progress: UpdateField::Set(progress),
                    message: UpdateField::Unchanged,
                    result: None,
                }),
            }
        }
        Request::Recover {} => JobCommand::Recover,
    };
    let reply = queue(root).execute(command)?;
    Ok(match reply {
        JobReply::Enqueued {
            job, deduplicated, ..
        } => json!({"job":job,"deduplicated":deduplicated}),
        JobReply::Snapshot(snapshot) => {
            json!({"jobs":snapshot.jobs.iter().map(summary).collect::<Vec<_>>(),"total":snapshot.total,"hasMore":snapshot.total > snapshot.jobs.len() as u64})
        }
        JobReply::Job(job) => json!({"job":job}),
        JobReply::Claimed(job) => json!({"job":job}),
        JobReply::Recovered { recovered, jobs } => {
            json!({"recovered":recovered,"jobs":jobs.iter().map(summary).collect::<Vec<_>>()})
        }
    })
}

pub(crate) fn queue(root: &Path) -> JobQueue<SqliteJobQueue<'_>, SystemJobClock, RandomJobIds> {
    JobQueue {
        repository: SqliteJobQueue { root },
        clock: SystemJobClock,
        ids: RandomJobIds,
        kind: Some(KIND),
    }
}

/// List/recovery is a small read model, never a bulk export of native grants.
fn summary(job: &Job) -> Value {
    json!({"id":job.id,"objectID":job.object_id,"state":job.state,
        "progress":job.progress,"attempt":job.attempt,"cancelRequested":job.cancel_requested})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{desktop, jobs};

    fn request(root: &Path, arguments: Value) -> Value {
        let lease = crate::infrastructure::executor_lease::try_acquire(root)
            .unwrap()
            .unwrap();
        let mut executor = crate::desktop_queue_executor::Executor::new(lease);
        desktop::import_queue_envelope(&mut executor, arguments)
    }
    fn call(root: &Path, arguments: Value) -> Value {
        let reply = request(root, arguments);
        assert_eq!(reply["ok"], true, "{reply}");
        reply["result"].clone()
    }
    fn input(root: &Path) -> Value {
        json!({"operationId":uuid::Uuid::new_v4().to_string(), "attemptToken":uuid::Uuid::new_v4().to_string(),
            "sourcePath":root.join("source ü ;.wav"), "title":"Import"})
    }

    #[test]
    fn native_import_queue_persists_attempts_and_rejects_stale_mutations() {
        let root = tempfile::tempdir().unwrap();
        let input = input(root.path());
        let first = call(root.path(), json!({"action":"enqueue","input":input}));
        let id = first["job"]["id"].clone();
        let repeated = call(root.path(), json!({"action":"enqueue","input":input}));
        assert_eq!(repeated["deduplicated"], true);
        assert_eq!(repeated["job"]["id"], id);
        let claimed = call(root.path(), json!({"action":"claim","jobId":id}));
        assert_eq!(claimed["job"]["attempt"], 1);
        assert_eq!(claimed["job"]["config"], input);
        assert_eq!(
            call(
                root.path(),
                json!({"action":"cancel","jobId":id,"expectedAttempt":1})
            )["job"]["cancelRequested"],
            true
        );
        call(
            root.path(),
            json!({"action":"update","jobId":id,"expectedAttempt":1,"state":"cancelled","progress":0.5}),
        );
        call(
            root.path(),
            json!({"action":"retry","jobId":id,"expectedAttempt":1}),
        );
        assert_eq!(
            call(root.path(), json!({"action":"claim","jobId":id}))["job"]["attempt"],
            2
        );
        assert_eq!(
            request(
                root.path(),
                json!({"action":"update","jobId":id,"expectedAttempt":1,"state":"succeeded","progress":1})
            )["ok"],
            false
        );
        let recovered = call(root.path(), json!({"action":"recover"}));
        assert_eq!(recovered["recovered"], 1);
        assert_eq!(recovered["jobs"][0]["state"], "interrupted");
        assert!(recovered["jobs"][0].get("config").is_none());
        let snapshot = call(root.path(), json!({"action":"list"}));
        let encoded = serde_json::to_string(&snapshot).unwrap();
        assert!(!encoded.contains(input["sourcePath"].as_str().unwrap()));
        assert!(!encoded.contains(input["attemptToken"].as_str().unwrap()));
        assert!(snapshot["jobs"][0].get("config").is_none());
        assert!(call(root.path(), json!({"action":"claim","jobId":id}))["job"].is_null());
    }

    #[test]
    fn native_import_queue_cannot_recover_or_disclose_foreign_paid_jobs() {
        let root = tempfile::tempdir().unwrap();
        let foreign = jobs::dispatch(root.path(), &json!({"command":"job-enqueue", "kind":"summarize", "objectID":"foreign", "paid":true, "config":{"private":"native context"}})).unwrap()["job"].clone();
        let foreign_id = &foreign["id"];
        jobs::dispatch(
            root.path(),
            &json!({"command":"job-claim","jobID":foreign_id}),
        )
        .unwrap();
        let before = jobs::dispatch(
            root.path(),
            &json!({"command":"job-get","jobID":foreign_id}),
        )
        .unwrap();
        assert_eq!(
            request(root.path(), json!({"action":"get","jobId":foreign_id}))["ok"],
            false
        );
        assert_eq!(
            request(
                root.path(),
                json!({"action":"cancel","jobId":foreign_id,"expectedAttempt":1})
            )["ok"],
            false
        );
        assert_eq!(
            call(root.path(), json!({"action":"recover"}))["recovered"],
            0
        );
        assert_eq!(
            call(root.path(), json!({"action":"list"})),
            json!({"jobs":[],"total":0,"hasMore":false})
        );
        assert_eq!(
            jobs::dispatch(
                root.path(),
                &json!({"command":"job-get","jobID":foreign_id})
            )
            .unwrap(),
            before
        );
    }

    #[test]
    fn kind_filter_precedes_history_pagination_and_counts_use_the_same_scope() {
        let root = tempfile::tempdir().unwrap();
        let own = call(
            root.path(),
            json!({"action":"enqueue","input":input(root.path())}),
        );
        let id = own["job"]["id"].clone();
        call(
            root.path(),
            json!({"action":"cancel","jobId":id,"expectedAttempt":0}),
        );
        for index in 0..55 {
            let foreign = jobs::dispatch(root.path(), &json!({"command":"job-enqueue", "kind":"example", "objectID":format!("foreign-{index}")})).unwrap();
            jobs::dispatch(
                root.path(),
                &json!({"command":"job-cancel","jobID":foreign["job"]["id"]}),
            )
            .unwrap();
        }
        // Legacy history has already paginated the old import out.
        assert!(
            jobs::dispatch(root.path(), &json!({"command":"job-list"})).unwrap()["jobs"]
                .as_array()
                .unwrap()
                .iter()
                .all(|job| job["id"] != id)
        );
        let own_history = call(root.path(), json!({"action":"list"}));
        assert_eq!(own_history["total"], 1);
        assert_eq!(own_history["hasMore"], false);
        assert_eq!(own_history["jobs"].as_array().unwrap().len(), 1);
        assert_eq!(own_history["jobs"][0]["id"], id);
    }

    #[test]
    fn native_import_queue_accepts_only_a_closed_schema() {
        let root = tempfile::tempdir().unwrap();
        let mut invalid = input(root.path());
        invalid["environment"] = json!({"PATH":"elsewhere"});
        for arguments in [
            json!({"action":"enqueue","input":invalid}),
            json!({"action":"list","kind":"summarize"}),
            json!({"action":"execute","command":"delete-library"}),
            json!({"action":"get","jobId":"../../foreign"}),
            json!({"action":"update","jobId":uuid::Uuid::new_v4().to_string(),"state":"queued","progress":0,"expectedAttempt":1}),
        ] {
            assert_eq!(
                request(root.path(), arguments.clone())["ok"],
                false,
                "{arguments}"
            );
        }
        let mut invalid = input(root.path());
        invalid["sourcePath"] = json!("relative.wav");
        assert_eq!(
            request(root.path(), json!({"action":"enqueue","input":invalid}))["ok"],
            false
        );
        assert!(!root.path().join("jobs.sqlite").exists());
    }
}
