//! Compatibility JSON transport and composition root for native queue clients.
use crate::application::jobs::{ClaimRequest, JobCommand, JobQueue, JobReply};
pub use crate::domain::jobs::Job;
use crate::domain::jobs::{JobDefinition, JobMutation, JobResource, JobUpdate, UpdateField};
use crate::infrastructure::{
    job_context::{RandomJobIds, SystemJobClock},
    job_queue::SqliteJobQueue,
};
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::path::Path;

pub fn dispatch(root: &Path, value: &Value) -> Result<Value> {
    if value["command"] == "job-runtime-event" {
        return runtime_event(value);
    }
    let command = parse(value)?;
    let queue = JobQueue {
        repository: SqliteJobQueue { root },
        clock: SystemJobClock,
        ids: RandomJobIds,
    };
    Ok(encode(queue.execute(command)?))
}

fn runtime_event(value: &Value) -> Result<Value> {
    use crate::domain::job_runtime::{RuntimeEvent, RuntimeState};
    let state = value.get("runtime").cloned().unwrap_or_else(|| json!({}));
    anyhow::ensure!(
        serde_json::to_vec(&state)?.len() <= 65_536,
        "Состояние исполнителя слишком большое"
    );
    let state: RuntimeState = serde_json::from_value(state)?;
    let event: RuntimeEvent = serde_json::from_value(value["event"].clone())?;
    let event = event.bounded();
    anyhow::ensure!(
        serde_json::to_vec(&event)?.len() <= 65_536,
        "Событие исполнителя слишком большое"
    );
    let (state, decision) = state.transition(event)?;
    anyhow::ensure!(
        serde_json::to_vec(&state)?.len() <= 65_536,
        "Состояние исполнителя слишком большое"
    );
    Ok(json!({"runtime":state,"decision":decision}))
}

fn field<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value[key]
        .as_str()
        .with_context(|| format!("Нет поля задания: {key}"))
}

fn definition(value: &Value) -> Result<JobDefinition> {
    let kind = field(value, "kind")?;
    Ok(JobDefinition {
        kind: kind.into(),
        object_id: field(value, "objectID")?.into(),
        input_revision: value["inputRevision"].as_str().unwrap_or("").into(),
        config: value.get("config").cloned().unwrap_or_else(|| json!({})),
        resource: JobResource::parse(value["resource"].as_str().unwrap_or("light"))?,
        dependencies: serde_json::from_value(
            value
                .get("dependencies")
                .cloned()
                .unwrap_or_else(|| json!([])),
        )?,
        title: value["title"].as_str().unwrap_or(kind).into(),
        paid: value["paid"].as_bool().unwrap_or(false),
    })
}

fn update_field<T>(
    value: Option<&Value>,
    decode: impl FnOnce(&Value) -> Option<T>,
) -> UpdateField<T> {
    match value {
        None => UpdateField::Unchanged,
        Some(value) => decode(value)
            .map(UpdateField::Set)
            .unwrap_or(UpdateField::Invalid),
    }
}

fn parse(value: &Value) -> Result<JobCommand> {
    Ok(match field(value, "command")? {
        "job-enqueue" => JobCommand::Enqueue {
            definition: definition(value)?,
            follow_ups: match value.get("followUps") {
                None => Vec::new(),
                Some(value) => value
                    .as_array()
                    .context("Некорректные следующие этапы задания")?
                    .iter()
                    .map(definition)
                    .collect::<Result<_>>()?,
            },
        },
        "job-list" => JobCommand::List,
        "job-get" => JobCommand::Get {
            id: field(value, "jobID")?.into(),
        },
        "job-claim" => JobCommand::Claim(ClaimRequest {
            job_id: value["jobID"].as_str().map(str::to_owned),
            excluded_accounts: {
                let accounts: Vec<String> = serde_json::from_value(
                    value
                        .get("excludedAccounts")
                        .cloned()
                        .unwrap_or_else(|| json!([])),
                )?;
                anyhow::ensure!(
                    accounts.len() <= 128
                        && accounts.iter().all(|account| !account.is_empty()
                            && account.len() <= 512
                            && !account.contains('\0')),
                    "Некорректные исключения учётных записей"
                );
                accounts
            },
            allowed_resources: value
                .get("allowedResources")
                .map(|value| -> Result<Vec<JobResource>> {
                    let resources: Vec<String> = serde_json::from_value(value.clone())?;
                    resources
                        .iter()
                        .map(|resource| JobResource::parse(resource))
                        .collect()
                })
                .transpose()?,
        }),
        command @ ("job-update" | "job-cancel" | "job-retry") => JobCommand::Mutate {
            id: field(value, "jobID")?.into(),
            expected_attempt: value["expectedAttempt"].as_u64(),
            mutation: match command {
                "job-cancel" => JobMutation::Cancel,
                "job-retry" => JobMutation::Retry {
                    confirm_paid: value["confirmPaid"].as_bool() == Some(true),
                },
                _ => JobMutation::Update(JobUpdate {
                    state: value["state"].as_str().map(str::to_owned),
                    progress: update_field(value.get("progress"), Value::as_f64),
                    message: update_field(value.get("message"), |value| {
                        value.as_str().map(str::to_owned)
                    }),
                    result: value.get("result").cloned(),
                }),
            },
        },
        "job-recover" => JobCommand::Recover,
        _ => bail!("Неизвестная команда очереди"),
    })
}

fn encode(reply: JobReply) -> Value {
    match reply {
        JobReply::Enqueued {
            job,
            deduplicated,
            follow_ups,
        } => json!({"job":job,"deduplicated":deduplicated,"followUps":follow_ups}),
        JobReply::Snapshot(snapshot) => json!({
            "hasMore":snapshot.total > snapshot.jobs.len() as u64,
            "total":snapshot.total,"jobs":snapshot.jobs,
            "pausedChatGPTFailures":snapshot.paused_chatgpt_failures,
        }),
        JobReply::Job(job) => json!({"job":job}),
        JobReply::Claimed(job) => json!({"job":job}),
        JobReply::Recovered { recovered, jobs } => json!({"recovered":recovered,"jobs":jobs}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(root: &Path, state: &mut Value, event: Value) -> Value {
        let response = dispatch(
            root,
            &json!({"command":"job-runtime-event","runtime":state,"event":event}),
        )
        .unwrap();
        *state = response["runtime"].clone();
        response["decision"].clone()
    }
    fn request(root: &Path, command: &str, mut fields: Value) -> Value {
        fields["command"] = json!(command);
        dispatch(root, &fields).unwrap()
    }

    #[test]
    fn live_coordinator_drives_durable_claim_progress_and_committed_cancellation() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        let job = request(
            root,
            "job-enqueue",
            json!({"kind":"example","objectID":"fixture"}),
        )["job"]
            .clone();
        let mut state = json!({});
        assert_eq!(
            event(root, &mut state, json!({"type":"start"}))["recover"],
            true
        );
        request(root, "job-recover", json!({}));
        event(root, &mut state, json!({"type":"ready"}));
        let plan = event(root, &mut state, json!({"type":"claim"}));
        let claimed = request(root, "job-claim", plan["claim"].clone())["job"].clone();
        assert_eq!(claimed["id"], job["id"]);
        let key = json!({"jobID":claimed["id"],"attempt":claimed["attempt"]});
        event(root, &mut state, json!({"type":"claimed","key":key}));
        let progress = event(
            root,
            &mut state,
            json!({"type":"progress","key":key,"nowMs":100,"isProgress":true,"fraction":3.0}),
        );
        assert_eq!(
            request(root, "job-update", progress["update"].clone())["job"]["progress"],
            1.0
        );
        request(root, "job-cancel", json!({"jobID":job["id"]}));
        event(root, &mut state, json!({"type":"cancel","jobID":job["id"]}));
        event(root, &mut state, json!({"type":"shutdown"}));
        let finish = event(
            root,
            &mut state,
            json!({"type":"finish","key":key,"outcome":{"type":"committed"},"cancelled":true}),
        );
        assert_eq!(finish["deliverCancelled"], false);
        assert_eq!(
            request(root, "job-update", finish["update"].clone())["job"]["state"],
            "succeeded"
        );
        let late = event(
            root,
            &mut state,
            json!({"type":"progress","key":key,"nowMs":500,"isProgress":false,"message":"late callback"}),
        );
        assert_eq!(late["accepted"], false);
        assert!(late["update"].is_null());
    }

    #[test]
    fn signout_claim_context_skips_one_account_without_cancelling_durable_work() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        let create = |object: &str, account: &str| {
            request(root, "job-enqueue", json!({
            "kind":"example","objectID":object,"resource":"cloud",
            "config":{"command":"example","settings":{"mode":"cloud","cloudProvider":"chatgpt","chatGPTAccountID":account}}
        }))["job"].clone()
        };
        let held = create("held", "signing-out");
        request(
            root,
            "job-enqueue",
            json!({
                "kind":"transcribe","objectID":"legacy-mismatch","resource":"cloud",
                "config":{"command":"example","settings":{"mode":"cloud","cloudProvider":"chatgpt","chatGPTAccountID":"signing-out"}}
            }),
        );
        let other = create("other", "other-account");
        let mut state = json!({});
        event(root, &mut state, json!({"type":"ready"}));
        event(
            root,
            &mut state,
            json!({"type":"signOut","account":"signing-out","closing":true}),
        );
        let plan = event(root, &mut state, json!({"type":"claim"}));
        assert_eq!(
            request(root, "job-claim", plan["claim"].clone())["job"]["id"],
            other["id"]
        );
        assert!(request(root, "job-claim", plan["claim"].clone())["job"].is_null());
        let held_status = request(root, "job-get", json!({"jobID":held["id"]}));
        assert_eq!(held_status["job"]["state"], "queued");
        assert_eq!(held_status["job"]["attempt"], 0);
        event(
            root,
            &mut state,
            json!({"type":"signOut","account":"signing-out","closing":false}),
        );
        let resumed = event(root, &mut state, json!({"type":"claim"}));
        assert_eq!(
            request(root, "job-claim", resumed["claim"].clone())["job"]["id"],
            held["id"]
        );
    }

    #[test]
    fn pure_runtime_rejects_future_secret_or_oversized_state_without_opening_a_library() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("never-created");
        for state in [
            json!({"version":2}),
            json!({"config":{"apiKey":"never accepted"}}),
            json!({"padding":"x".repeat(65536)}),
        ] {
            assert!(dispatch(
                &root,
                &json!({"command":"job-runtime-event","runtime":state,"event":{"type":"status"}})
            )
            .is_err());
            assert!(!root.exists());
        }
        assert!(dispatch(&root, &json!({"command":"job-runtime-event","runtime":{},"event":{"type":"progress","shell":"never accepted"}})).is_err());
        assert!(!root.exists());
    }

    #[test]
    fn quota_pause_cannot_be_bypassed_by_a_legacy_mismatched_job_kind() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        let config = json!({"command":"example","settings":{"mode":"cloud","cloudProvider":"chatgpt","chatGPTAccountID":"paused-account"}});
        let failure = request(
            root,
            "job-enqueue",
            json!({"kind":"example","objectID":"source","resource":"cloud","config":config}),
        )["job"]
            .clone();
        request(root, "job-claim", json!({"jobID":failure["id"]}));
        request(
            root,
            "job-update",
            json!({"jobID":failure["id"],"state":"failed","message":"ChatGPT: HTTP 429 · subscription_sharing_usage_limit_exceeded. Fixture."}),
        );
        let legacy = request(
            root,
            "job-enqueue",
            json!({"kind":"transcribe","objectID":"legacy","resource":"cloud","config":config}),
        )["job"]
            .clone();
        assert!(request(root, "job-claim", json!({}))["job"].is_null());
        assert_eq!(
            request(root, "job-get", json!({"jobID":legacy["id"]}))["job"]["attempt"],
            0
        );
    }

    #[test]
    fn unicode_worker_failure_fits_the_durable_limit_through_native_transport() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        let job = request(
            root,
            "job-enqueue",
            json!({"kind":"example","objectID":"unicode-failure"}),
        )["job"]
            .clone();
        let claimed = request(root, "job-claim", json!({"jobID":job["id"]}))["job"].clone();
        let key = json!({"jobID":claimed["id"],"attempt":claimed["attempt"]});
        let mut state = json!({});
        event(root, &mut state, json!({"type":"ready"}));
        event(root, &mut state, json!({"type":"claimed","key":key}));
        let failure = event(
            root,
            &mut state,
            json!({"type":"finish","key":key,"outcome":{
            "type":"failed","message":"👨‍👩‍👧‍👦".repeat(4000)
        },"cancelled":false}),
        );
        let stored = request(root, "job-update", failure["update"].clone());
        assert_eq!(stored["job"]["state"], "failed");
        assert!(stored["job"]["message"].as_str().unwrap().len() <= 2000);
    }

    #[cfg(unix)]
    #[test]
    fn runtime_decision_roundtrips_through_the_actual_native_json_abi() {
        use std::ffi::{CStr, CString};
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("pure-abi");
        let input = CString::new(json!({"root":root,"command":"job-runtime-event","runtime":{},"event":{"type":"start"}}).to_string()).unwrap();
        let response = unsafe {
            let output = crate::posle_request(input.as_ptr());
            assert!(!output.is_null());
            let bytes = CStr::from_ptr(output).to_bytes().to_vec();
            crate::posle_free_string(output);
            serde_json::from_slice::<Value>(&bytes).unwrap()
        };
        assert_eq!(response["ok"], true);
        assert_eq!(response["value"]["runtime"]["version"], 1);
        assert_eq!(response["value"]["decision"]["recover"], true);
        assert!(!root.exists());
    }
}
