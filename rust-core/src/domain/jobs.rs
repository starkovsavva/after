//! Durable job data and resource admission policy, independent of storage and OS.
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashSet;

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

pub(crate) struct JobQueueSnapshot {
    pub jobs: Vec<Job>,
    pub total: u64,
    pub paused_chatgpt_failures: Vec<Job>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum JobResource {
    LocalHeavy,
    Cloud,
    Light,
}

impl JobResource {
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "local-heavy" => Ok(Self::LocalHeavy),
            "cloud" => Ok(Self::Cloud),
            "light" => Ok(Self::Light),
            _ => anyhow::bail!("Неизвестный ресурс задания"),
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::LocalHeavy => "local-heavy",
            Self::Cloud => "cloud",
            Self::Light => "light",
        }
    }
}

pub(crate) struct JobDefinition {
    pub kind: String,
    pub object_id: String,
    pub input_revision: String,
    pub config: Value,
    pub resource: JobResource,
    pub dependencies: Vec<String>,
    pub title: String,
    pub paid: bool,
}

impl JobDefinition {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.kind.is_empty()
                && self.kind.len() <= 64
                && self
                    .kind
                    .bytes()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-'),
            "Неизвестный тип задания"
        );
        bounded(&self.object_id, 512, "objectID")?;
        ensure!(!self.object_id.is_empty(), "Нет объекта задания");
        bounded(&self.input_revision, 512, "inputRevision")?;
        ensure!(
            self.config.is_object() && serde_json::to_vec(&self.config)?.len() <= 262_144,
            "Конфигурация задания слишком большая"
        );
        secret_free(&self.config, 0)?;
        ensure!(
            self.dependencies.len() <= 32
                && self.dependencies.iter().collect::<HashSet<_>>().len()
                    == self.dependencies.len(),
            "Некорректные зависимости задания"
        );
        bounded(&self.title, 512, "title")
    }

    /// The caller validates before supplying effectful identity/time sources.
    pub fn into_job(self, id: String, time: f64) -> Job {
        Job {
            id,
            kind: self.kind,
            object_id: self.object_id,
            input_revision: self.input_revision,
            config: self.config,
            resource: self.resource.as_str().into(),
            dependencies: self.dependencies,
            state: "queued".into(),
            progress: 0.0,
            message: String::new(),
            created_at: time,
            updated_at: time,
            attempt: 0,
            cancel_requested: false,
            paid: self.paid,
            title: self.title,
            result: None,
        }
    }
}

/// Invalid legacy JSON fields remain distinguishable from absent fields. In
/// particular, repeated terminal completion ignores late progress/message data.
pub(crate) enum UpdateField<T> {
    Unchanged,
    Set(T),
    Invalid,
}

pub(crate) struct JobUpdate {
    pub state: Option<String>,
    pub progress: UpdateField<f64>,
    pub message: UpdateField<String>,
    pub result: Option<Value>,
}

pub(crate) enum JobMutation {
    Cancel,
    Retry { confirm_paid: bool },
    Update(JobUpdate),
}

impl Job {
    pub(crate) fn dedup_key(&self) -> Result<String> {
        let value = serde_json::json!([
            self.kind,
            self.object_id,
            self.input_revision,
            self.config,
            self.resource,
            self.dependencies
        ]);
        Ok(format!("{:x}", Sha256::digest(serde_json::to_vec(&value)?)))
    }

    /// Returns false only for an idempotent repeated completion. No update or
    /// account pause may be republished in that case. Time is supplied by caller.
    pub(crate) fn apply(&mut self, mutation: &JobMutation) -> Result<bool> {
        match mutation {
            JobMutation::Cancel => {
                if ["queued", "blocked", "interrupted"].contains(&self.state.as_str()) {
                    self.state = "cancelled".into();
                    self.message = "Отменено".into();
                } else if self.state == "running" {
                    self.cancel_requested = true;
                    self.message = "Останавливаю…".into();
                }
            }
            JobMutation::Retry { confirm_paid } => {
                ensure!(
                    ["failed", "cancelled", "interrupted"].contains(&self.state.as_str()),
                    "Это задание нельзя запустить повторно"
                );
                ensure!(
                    !self.paid || self.attempt == 0 || *confirm_paid,
                    "Подтвердите повтор платного запроса: предыдущий запрос мог быть оплачен"
                );
                self.state = "queued".into();
                self.progress = 0.0;
                self.message.clear();
                self.cancel_requested = false;
                self.result = None;
            }
            JobMutation::Update(update) => {
                let state = update.state.as_deref().unwrap_or(&self.state);
                ensure!(
                    ["running", "succeeded", "failed", "cancelled", "interrupted"].contains(&state),
                    "Некорректное состояние задания"
                );
                if self.state != "running" {
                    ensure!(
                        update.state.as_deref() == Some(self.state.as_str())
                            && ["succeeded", "failed", "cancelled"].contains(&self.state.as_str()),
                        "Задание уже завершено или не запущено"
                    );
                    return Ok(false);
                }
                match &update.progress {
                    UpdateField::Unchanged => {}
                    UpdateField::Set(progress) => ensure!(
                        progress.is_finite() && (0.0..=1.0).contains(progress),
                        "Некорректный прогресс задания"
                    ),
                    UpdateField::Invalid => anyhow::bail!("Некорректный прогресс задания"),
                }
                match &update.message {
                    UpdateField::Unchanged => {}
                    UpdateField::Set(message) => bounded(message, 2000, "message")?,
                    UpdateField::Invalid => anyhow::bail!("Некорректное сообщение задания"),
                }
                if let Some(result) = &update.result {
                    ensure!(
                        serde_json::to_vec(result)?.len() <= 262_144,
                        "Результат задания слишком большой"
                    );
                    secret_free(result, 0)?;
                }
                // Validate all fields before changing the in-memory model.
                let state = state.to_owned();
                if let UpdateField::Set(progress) = update.progress {
                    self.progress = progress;
                }
                if let UpdateField::Set(message) = &update.message {
                    self.message = message.clone();
                }
                if let Some(result) = &update.result {
                    self.result = Some(result.clone());
                }
                if state == "succeeded" {
                    self.progress = 1.0;
                }
                self.state = state;
            }
        }
        Ok(true)
    }
}

fn bounded(text: &str, max: usize, label: &str) -> Result<()> {
    ensure!(
        text.len() <= max && !text.contains('\0'),
        "Некорректное поле задания: {label}"
    );
    Ok(())
}

pub(crate) fn chatgpt_account(job: &Job) -> Option<&str> {
    // A failure may create a quota pause only for a matching typed operation.
    if job.config["command"] != job.kind {
        return None;
    }
    chatgpt_execution_account(&job.config)
}

/// Admission follows the actual saved execution route, as the native executor
/// does. A mismatched legacy kind must not bypass an existing pause/sign-out.
pub(crate) fn chatgpt_execution_account(config: &Value) -> Option<&str> {
    let settings = &config["settings"];
    if settings["mode"] != "cloud"
        || settings["cloudProvider"] != "chatgpt"
        || !["summarize", "example", "expand-notes", "voice-plan"]
            .contains(&config["command"].as_str().unwrap_or(""))
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
