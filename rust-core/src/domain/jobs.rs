//! Durable job data and resource admission policy, independent of storage and OS.
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    pub kind: String,
    #[serde(rename = "objectID", alias = "objectId")]
    pub object_id: String,
    pub input_revision: String,
    pub config: Value,
    pub resource: String,
    pub dependencies: Vec<String>,
    pub state: String,
    pub progress: f64,
    pub message: String,
    pub created_at: f64,
    pub updated_at: f64,
    pub attempt: u64,
    pub cancel_requested: bool,
    pub paid: bool,
    pub title: String,
    pub result: Option<Value>,
}

pub(crate) fn chatgpt_account(job: &Job) -> Option<&str> {
    let settings = &job.config["settings"];
    if settings["mode"] != "cloud"
        || settings["cloudProvider"] != "chatgpt"
        || job.config["command"] != job.kind
        || !["summarize", "example", "expand-notes", "voice-plan"].contains(&job.kind.as_str())
    {
        return None;
    }
    settings["chatGPTAccountID"]
        .as_str()
        .filter(|account| !account.is_empty())
}

/// Called while the repository holds its claim transaction. Capacity counts and
/// same-object exclusion must be evaluated against one consistent snapshot.
pub(crate) fn resource_available(job: &Job, running: &[&Job]) -> bool {
    let capacity = if job.resource == "local-heavy" { 1 } else { 2 };
    running
        .iter()
        .filter(|other| other.resource == job.resource)
        .count()
        < capacity
        && !running.iter().any(|other| other.object_id == job.object_id)
}

pub(crate) fn secret_free(value: &Value, depth: usize) -> Result<()> {
    ensure!(depth < 32, "Слишком сложная конфигурация задания");
    match value {
        Value::Object(map) => {
            for (key, value) in map {
                let normalized = key.to_ascii_lowercase().replace(['_', '-'], "");
                ensure!(
                    ![
                        "apikey",
                        "authorization",
                        "accesskey",
                        "token",
                        "accesstoken",
                        "refreshtoken",
                        "secret",
                        "password",
                        "credential",
                        "credentials",
                        "cookie",
                        "headers"
                    ]
                    .contains(&normalized.as_str()),
                    "Секреты задания должны оставаться в защищённом хранилище"
                );
                secret_free(value, depth + 1)?;
            }
        }
        Value::Array(values) => {
            for value in values {
                secret_free(value, depth + 1)?;
            }
        }
        Value::String(text) if text.starts_with("http://") || text.starts_with("https://") => {
            let url = url::Url::parse(text).context("Некорректный адрес в конфигурации задания")?;
            ensure!(
                url.username().is_empty() && url.password().is_none(),
                "Пароль нельзя сохранять в адресе задания"
            );
            for (key, _) in url.query_pairs() {
                let key = key.to_ascii_lowercase().replace(['_', '-'], "");
                ensure!(
                    ![
                        "key",
                        "apikey",
                        "token",
                        "accesstoken",
                        "secret",
                        "password"
                    ]
                    .contains(&key.as_str()),
                    "Секреты нельзя сохранять в адресе задания"
                );
            }
        }
        _ => {}
    }
    Ok(())
}

pub(crate) fn reached_chatgpt_limit(message: &str) -> bool {
    let Some((status, detail)) = message
        .strip_prefix("ChatGPT: HTTP ")
        .and_then(|value| value.split_once(" · "))
    else {
        return false;
    };
    status.len() == 3
        && status.bytes().all(|byte| byte.is_ascii_digit())
        && detail.starts_with("subscription_sharing_usage_limit_exceeded.")
}
