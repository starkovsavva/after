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
    let command = parse(value)?;
    let queue = JobQueue {
        repository: SqliteJobQueue { root },
        clock: SystemJobClock,
        ids: RandomJobIds,
    };
    Ok(encode(queue.execute(command)?))
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
