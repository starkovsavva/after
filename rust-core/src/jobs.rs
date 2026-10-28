//! Durable native work queue. SQLite transactions own eligibility; executors own handles.
use anyhow::{bail, ensure, Context, Result};
use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs::{self, OpenOptions},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::Path,
    time::Duration,
};
use uuid::Uuid;

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

fn now() -> f64 {
    Utc::now().timestamp_millis() as f64 / 1000.0
}
fn bounded(text: &str, max: usize, label: &str) -> Result<()> {
    ensure!(
        text.len() <= max && !text.contains('\0'),
        "Некорректное поле задания: {label}"
    );
    Ok(())
}
fn field<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value[key]
        .as_str()
        .with_context(|| format!("Нет поля задания: {key}"))
}
fn secret_free(value: &Value, depth: usize) -> Result<()> {
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
                    "Секреты задания должны оставаться в Связке ключей"
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
            let url =
                reqwest::Url::parse(text).context("Некорректный адрес в конфигурации задания")?;
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
fn open(root: &Path) -> Result<Connection> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(root)?;
    let info = fs::symlink_metadata(root)?;
    ensure!(
        info.is_dir() && !info.file_type().is_symlink(),
        "Некорректная папка заданий"
    );
    fs::set_permissions(root, fs::Permissions::from_mode(0o700))?;
    let path = root.join("jobs.sqlite");
    for name in [
        "jobs.sqlite",
        "jobs.sqlite-journal",
        "jobs.sqlite-wal",
        "jobs.sqlite-shm",
    ] {
        if let Ok(info) = fs::symlink_metadata(root.join(name)) {
            ensure!(
                info.is_file() && !info.file_type().is_symlink(),
                "Некорректный файл очереди заданий"
            );
        }
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)?;
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    let mut connection = Connection::open(&path)?;
    connection.busy_timeout(Duration::from_secs(5))?;
    connection.execute_batch("PRAGMA foreign_keys=ON;")?;
    let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if version < 1 {
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute_batch("CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, state TEXT NOT NULL, resource TEXT NOT NULL, object_id TEXT NOT NULL, dedup_key TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL DEFAULT 0, payload TEXT NOT NULL);")?;
        let has_updated = {
            let mut query = transaction.prepare("PRAGMA table_info(jobs)")?;
            let columns = query
                .query_map([], |row| row.get::<_, String>(1))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            columns.iter().any(|column| column == "updated_at")
        };
        if !has_updated {
            transaction
                .execute_batch("ALTER TABLE jobs ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;")?;
        }
        let legacy = {
            let mut query =
                transaction.prepare("SELECT id,payload,created_at FROM jobs WHERE updated_at=0")?;
            let rows = query
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, f64>(2)?,
                    ))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            rows
        };
        for (id, payload, created) in legacy {
            let value: Value = serde_json::from_str(&payload)?;
            let updated = value["updatedAt"].as_f64().unwrap_or(created);
            transaction.execute(
                "UPDATE jobs SET updated_at=?1 WHERE id=?2",
                params![updated, id],
            )?;
        }
        transaction.execute_batch("CREATE UNIQUE INDEX IF NOT EXISTS jobs_pending_key_v2 ON jobs(dedup_key) WHERE state IN ('queued','running','interrupted','blocked'); CREATE INDEX IF NOT EXISTS jobs_state ON jobs(state,created_at); CREATE INDEX IF NOT EXISTS jobs_updated ON jobs(updated_at DESC); CREATE INDEX IF NOT EXISTS jobs_state_updated ON jobs(state,updated_at DESC);")?;
        transaction.pragma_update(None, "user_version", 1)?;
        transaction.commit()?;
    }
    if version < 2 {
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute_batch("CREATE TABLE IF NOT EXISTS job_chatgpt_pauses(account_id TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES jobs(id));")?;
        transaction.pragma_update(None, "user_version", 2)?;
        transaction.commit()?;
    }
    Ok(connection)
}
fn query_jobs(connection: &Connection, sql: &str) -> Result<Vec<Job>> {
    let mut query = connection.prepare(sql)?;
    let rows = query.query_map([], |row| row.get::<_, String>(0))?;
    rows.map(|row| Ok(serde_json::from_str(&row?)?)).collect()
}
fn listed(connection: &Connection) -> Result<Vec<Job>> {
    let mut jobs = query_jobs(
        connection,
        "SELECT payload FROM jobs WHERE state IN ('queued','running') ORDER BY created_at,rowid",
    )?;
    jobs.extend(query_jobs(connection,"SELECT payload FROM jobs WHERE state NOT IN ('queued','running') ORDER BY updated_at DESC,rowid DESC LIMIT 50")?);
    jobs.sort_by(|a, b| a.created_at.total_cmp(&b.created_at));
    Ok(jobs)
}
fn paused_chatgpt_jobs(connection: &Connection) -> Result<Vec<Job>> {
    query_jobs(connection, "SELECT jobs.payload FROM job_chatgpt_pauses JOIN jobs ON jobs.id=job_chatgpt_pauses.job_id ORDER BY jobs.created_at,jobs.rowid")
}
fn chatgpt_account(job: &Job) -> Option<&str> {
    let settings = &job.config["settings"];
    if settings["mode"] != "cloud" || settings["cloudProvider"] != "chatgpt"
        || job.config["command"] != job.kind
        || !["summarize", "example", "expand-notes", "voice-plan"].contains(&job.kind.as_str()) {
        return None;
    }
    settings["chatGPTAccountID"].as_str().filter(|account| !account.is_empty())
}
fn reached_chatgpt_limit(message: &str) -> bool {
    let Some((status, detail)) = message.strip_prefix("ChatGPT: HTTP ").and_then(|value| value.split_once(" · ")) else { return false; };
    status.len() == 3 && status.bytes().all(|byte| byte.is_ascii_digit())
        && detail.starts_with("subscription_sharing_usage_limit_exceeded.")
}

fn get(connection: &Connection, id: &str) -> Result<Job> {
    let text: String = connection
        .query_row("SELECT payload FROM jobs WHERE id=?1", [id], |row| {
            row.get(0)
        })
        .optional()?
        .context("Задание больше недоступно")?;
    Ok(serde_json::from_str(&text)?)
}
fn dedup(job: &Job) -> Result<String> {
    let value = json!([
        job.kind,
        job.object_id,
        job.input_revision,
        job.config,
        job.resource,
        job.dependencies
    ]);
    Ok(format!("{:x}", Sha256::digest(serde_json::to_vec(&value)?)))
}
fn persist(connection: &Connection, job: &Job) -> Result<()> {
    connection.execute("INSERT INTO jobs(id,state,resource,object_id,dedup_key,created_at,updated_at,payload) VALUES(?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT(id) DO UPDATE SET state=excluded.state,updated_at=excluded.updated_at,payload=excluded.payload", params![job.id,job.state,job.resource,job.object_id,dedup(job)?,job.created_at,job.updated_at,serde_json::to_string(job)?])?;
    Ok(())
}
fn make_job(value: &Value) -> Result<Job> {
    let kind = field(value, "kind")?;
    ensure!(
        !kind.is_empty()
            && kind.len() <= 64
            && kind
                .bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-'),
        "Неизвестный тип задания"
    );
    let object_id = field(value, "objectID")?;
    bounded(object_id, 512, "objectID")?;
    ensure!(!object_id.is_empty(), "Нет объекта задания");
    let input_revision = value["inputRevision"].as_str().unwrap_or("");
    bounded(input_revision, 512, "inputRevision")?;
    let resource = value["resource"].as_str().unwrap_or("light");
    ensure!(
        ["local-heavy", "cloud", "light"].contains(&resource),
        "Неизвестный ресурс задания"
    );
    let config = value.get("config").cloned().unwrap_or_else(|| json!({}));
    ensure!(
        config.is_object() && serde_json::to_vec(&config)?.len() <= 262_144,
        "Конфигурация задания слишком большая"
    );
    secret_free(&config, 0)?;
    let dependencies: Vec<String> = serde_json::from_value(
        value
            .get("dependencies")
            .cloned()
            .unwrap_or_else(|| json!([])),
    )?;
    ensure!(
        dependencies.len() <= 32
            && dependencies.iter().collect::<HashSet<_>>().len() == dependencies.len(),
        "Некорректные зависимости задания"
    );
    let title = value["title"].as_str().unwrap_or(kind);
    bounded(title, 512, "title")?;
    let time = now();
    let job = Job {
        id: Uuid::new_v4().to_string(),
        kind: kind.into(),
        object_id: object_id.into(),
        input_revision: input_revision.into(),
        config,
        resource: resource.into(),
        dependencies,
        state: "queued".into(),
        progress: 0.0,
        message: String::new(),
        created_at: time,
        updated_at: time,
        attempt: 0,
        cancel_requested: false,
        paid: value["paid"].as_bool().unwrap_or(false),
        title: title.into(),
        result: None,
    };
    Ok(job)
}
fn insert_job(connection: &Connection, job: Job, any_state: bool) -> Result<(Job, bool)> {
    let key = dedup(&job)?;
    let sql = if any_state {
        "SELECT payload FROM jobs WHERE dedup_key=?1 ORDER BY created_at LIMIT 1"
    } else {
        "SELECT payload FROM jobs WHERE dedup_key=?1 AND state IN ('queued','running','interrupted','blocked')"
    };
    if let Some(text) = connection
        .query_row(sql, [key], |row| row.get::<_, String>(0))
        .optional()?
    {
        return Ok((serde_json::from_str(&text)?, true));
    }
    for dependency in &job.dependencies {
        let _ = get(connection, dependency)?;
    }
    let pending: i64 = connection.query_row(
        "SELECT COUNT(*) FROM jobs WHERE state IN ('queued','running')",
        [],
        |row| row.get(0),
    )?;
    ensure!(
        pending < 256,
        "В очереди уже 256 операций. Дождитесь завершения или отмените лишние."
    );
    persist(connection, &job)?;
    Ok((job, false))
}
fn enqueue(connection: &mut Connection, value: &Value) -> Result<Value> {
    let parent = make_job(value)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let (parent, deduplicated) = insert_job(&transaction, parent, false)?;
    let follow_ups = match value.get("followUps") {
        None => Vec::new(),
        Some(value) => value
            .as_array()
            .context("Некорректные следующие этапы задания")?
            .clone(),
    };
    ensure!(
        follow_ups.len() <= 16,
        "Слишком много следующих этапов задания"
    );
    let mut children = Vec::new();
    for definition in follow_ups {
        let mut child = make_job(&definition)?;
        ensure!(
            child.object_id == parent.object_id,
            "Связанные этапы должны относиться к одному объекту"
        );
        child.input_revision = child.input_revision.replace("$parent", &parent.id);
        if !child.dependencies.contains(&parent.id) {
            child.dependencies.push(parent.id.clone());
        }
        // One child per exact parent attempt chain, including terminal children:
        // repeated subscriptions cannot revive an explicitly cancelled stage.
        let (child, _) = insert_job(&transaction, child, true)?;
        children.push(child);
    }
    transaction.commit()?;
    Ok(json!({"job":parent,"deduplicated":deduplicated,"followUps":children}))
}
/// A dependent stage never holds admission/power/update gates after its parent
/// stops. Only dependency-blocked stages revive after an explicit parent retry;
/// a user-cancelled child remains cancelled.
fn block_descendants(connection: &Connection) -> Result<()> {
    loop {
        let mut query=connection.prepare("SELECT payload FROM jobs WHERE state IN ('queued','blocked') ORDER BY created_at,rowid")?;
        let jobs = query
            .query_map([], |row| row.get::<_, String>(0))?
            .map(|row| Ok(serde_json::from_str::<Job>(&row?)?))
            .collect::<Result<Vec<_>>>()?;
        let mut changed = false;
        for mut job in jobs {
            let states = job
                .dependencies
                .iter()
                .map(|id| {
                    connection
                        .query_row("SELECT state FROM jobs WHERE id=?1", [id], |row| {
                            row.get::<_, String>(0)
                        })
                        .optional()
                })
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let blocked = states.iter().any(|state| {
                state.as_ref().is_none_or(|state| {
                    ["failed", "cancelled", "interrupted", "blocked"].contains(&state.as_str())
                })
            });
            if job.state == "queued" && blocked {
                job.state = "blocked".into();
                job.message =
                    "Предыдущий этап не завершён. Повторите его или отмените этот этап.".into();
            } else if job.state == "blocked"
                && states
                    .iter()
                    .all(|state| state.as_deref() == Some("succeeded"))
            {
                job.state = "queued".into();
                job.message.clear();
            } else {
                continue;
            }
            job.updated_at = now();
            persist(connection, &job)?;
            changed = true;
        }
        if !changed {
            return Ok(());
        }
    }
}

fn claim(connection: &mut Connection, value: &Value) -> Result<Value> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    block_descendants(&transaction)?;
    let jobs = query_jobs(
        &transaction,
        "SELECT payload FROM jobs WHERE state IN ('queued','running') ORDER BY created_at,rowid",
    )?;
    let running: Vec<_> = jobs.iter().filter(|job| job.state == "running").collect();
    let paused_accounts: HashSet<_> = paused_chatgpt_jobs(&transaction)?.iter()
        .filter_map(chatgpt_account).map(str::to_owned).collect();
    let wanted = value["jobID"].as_str();
    let allowed: Option<Vec<String>> = value
        .get("allowedResources")
        .map(|value| serde_json::from_value(value.clone()))
        .transpose()?;
    if let Some(allowed) = &allowed {
        ensure!(
            allowed
                .iter()
                .all(|resource| ["local-heavy", "cloud", "light"].contains(&resource.as_str())),
            "Неизвестный ресурс задания"
        );
    }
    let mut candidate = None;
    for job in jobs.iter().filter(|job| job.state == "queued") {
        if wanted.is_some_and(|id| id != job.id)
            || chatgpt_account(job).is_some_and(|account| paused_accounts.contains(account))
            || allowed
                .as_ref()
                .is_some_and(|allowed| !allowed.contains(&job.resource))
        {
            continue;
        }
        let capacity = if job.resource == "local-heavy" { 1 } else { 2 };
        if running
            .iter()
            .filter(|other| other.resource == job.resource)
            .count()
            >= capacity
            || running.iter().any(|other| other.object_id == job.object_id)
        {
            continue;
        }
        let states = job
            .dependencies
            .iter()
            .map(|id| {
                transaction
                    .query_row("SELECT state FROM jobs WHERE id=?1", [id], |row| {
                        row.get::<_, String>(0)
                    })
                    .optional()
            })
            .collect::<rusqlite::Result<Vec<_>>>()?;
        if states
            .iter()
            .all(|state| state.as_deref() == Some("succeeded"))
        {
            candidate = Some(job.clone());
            break;
        }
    }
    let Some(mut job) = candidate else {
        transaction.commit()?;
        return Ok(json!({"job":null}));
    };
    job.state = "running".into();
    job.progress = 0.0;
    job.message.clear();
    job.cancel_requested = false;
    job.attempt += 1;
    job.updated_at = now();
    persist(&transaction, &job)?;
    transaction.commit()?;
    Ok(json!({"job":job}))
}
fn mutate(connection: &mut Connection, value: &Value, operation: &str) -> Result<Value> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut job = get(&transaction, field(value, "jobID")?)?;
    let previous_state = job.state.clone();
    if let Some(attempt) = value["expectedAttempt"].as_u64() {
        ensure!(attempt == job.attempt, "Попытка задания уже изменилась");
    }
    match operation {
        "job-cancel" => {
            if ["queued", "blocked", "interrupted"].contains(&job.state.as_str()) {
                job.state = "cancelled".into();
                job.message = "Отменено".into();
            } else if job.state == "running" {
                job.cancel_requested = true;
                job.message = "Останавливаю…".into();
            }
        }
        "job-retry" => {
            ensure!(
                ["failed", "cancelled", "interrupted"].contains(&job.state.as_str()),
                "Это задание нельзя запустить повторно"
            );
            ensure!(
                !job.paid || job.attempt == 0 || value["confirmPaid"].as_bool() == Some(true),
                "Подтвердите повтор платного запроса: предыдущий запрос мог быть оплачен"
            );
            job.state = "queued".into();
            job.progress = 0.0;
            job.message.clear();
            job.cancel_requested = false;
            job.result = None;
        }
        "job-update" => {
            let state = value["state"].as_str().unwrap_or(&job.state).to_owned();
            ensure!(
                ["running", "succeeded", "failed", "cancelled", "interrupted"]
                    .contains(&state.as_str()),
                "Некорректное состояние задания"
            );
            if job.state != "running" {
                ensure!(
                    value["state"].as_str() == Some(job.state.as_str())
                        && ["succeeded", "failed", "cancelled"].contains(&job.state.as_str()),
                    "Задание уже завершено или не запущено"
                );
                // Repeated completion is idempotent. Late progress callbacks
                // never change an already published terminal result/message.
                return Ok(json!({"job":job}));
            }
            if let Some(progress) = value.get("progress") {
                let progress = progress.as_f64().context("Некорректный прогресс задания")?;
                ensure!(
                    progress.is_finite() && (0.0..=1.0).contains(&progress),
                    "Некорректный прогресс задания"
                );
                job.progress = progress;
            }
            if let Some(message) = value.get("message") {
                let message = message.as_str().context("Некорректное сообщение задания")?;
                bounded(message, 2000, "message")?;
                job.message = message.into();
            }
            if let Some(result) = value.get("result") {
                ensure!(
                    serde_json::to_vec(result)?.len() <= 262_144,
                    "Результат задания слишком большой"
                );
                secret_free(result, 0)?;
                job.result = Some(result.clone());
            }
            if state == "succeeded" {
                job.progress = 1.0;
            }
            job.state = state;
        }
        _ => bail!("Неизвестная операция задания"),
    }
    job.updated_at = now();
    persist(&transaction, &job)?;
    if let Some(account) = chatgpt_account(&job) {
        if operation == "job-update" && job.state == "failed" && reached_chatgpt_limit(&job.message) {
            transaction.execute("INSERT INTO job_chatgpt_pauses(account_id,job_id) VALUES(?1,?2) ON CONFLICT(account_id) DO UPDATE SET job_id=excluded.job_id", params![account, job.id])?;
        } else if operation == "job-retry" {
            // A rejected retry never reaches this point. Preserve the explicit
            // confirmation decision even across shutdown or a process crash.
            transaction.execute("DELETE FROM job_chatgpt_pauses WHERE account_id=?1", [account])?;
        }
    }
    if job.state != previous_state {
        block_descendants(&transaction)?;
    }
    transaction.commit()?;
    Ok(json!({"job":job}))
}
pub fn dispatch(root: &Path, value: &Value) -> Result<Value> {
    let mut connection = open(root)?;
    match field(value, "command")? {
        "job-enqueue" => enqueue(&mut connection, value),
        "job-list" => {
            let jobs = listed(&connection)?;
            let total: i64 =
                connection.query_row("SELECT COUNT(*) FROM jobs", [], |row| row.get(0))?;
            Ok(json!({"hasMore":total as usize>jobs.len(),"total":total,"jobs":jobs,"pausedChatGPTFailures":paused_chatgpt_jobs(&connection)?}))
        }
        "job-get" => Ok(json!({"job":get(&connection,field(value,"jobID")?)?})),
        "job-claim" => claim(&mut connection, value),
        command @ ("job-update" | "job-cancel" | "job-retry") => {
            mutate(&mut connection, value, command)
        }
        "job-recover" => {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let mut recovered = 0;
            for mut job in query_jobs(
                &transaction,
                "SELECT payload FROM jobs WHERE state='running'",
            )? {
                job.state = "interrupted".into();
                job.message = "Работа прервалась. Можно продолжить вручную.".into();
                job.cancel_requested = false;
                job.updated_at = now();
                persist(&transaction, &job)?;
                recovered += 1;
            }
            block_descendants(&transaction)?;
            transaction.commit()?;
            Ok(json!({"recovered":recovered,"jobs":listed(&connection)?}))
        }
        _ => bail!("Неизвестная команда очереди"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn call(root: &Path, command: &str, mut fields: Value) -> Value {
        fields["command"] = json!(command);
        dispatch(root, &fields).unwrap()
    }
    fn enqueue(root: &Path, object: &str, resource: &str) -> Value {
        call(root,"job-enqueue",json!({"kind":"summarize","objectID":object,"resource":resource,"inputRevision":"v1","config":{"model":"local"}}))["job"].clone()
    }
    #[test]
    fn dedup_survives_reopen_and_configuration_changes_are_distinct() {
        let root = tempfile::tempdir().unwrap();
        let job = enqueue(root.path(), "a", "cloud");
        assert_eq!(job["objectID"], "a");
        assert!(job.get("objectId").is_none());
        let again = call(
            root.path(),
            "job-enqueue",
            json!({"kind":"summarize","objectID":"a","resource":"cloud","inputRevision":"v1","config":{"model":"local"}}),
        );
        assert_eq!(again["job"]["id"], job["id"]);
        assert_eq!(again["deduplicated"], true);
        let changed = call(
            root.path(),
            "job-enqueue",
            json!({"kind":"summarize","objectID":"a","resource":"cloud","inputRevision":"v2"}),
        );
        assert_ne!(changed["job"]["id"], job["id"]);
    }
    #[test]
    fn resource_and_object_exclusion_are_atomic_across_connections() {
        let root = tempfile::tempdir().unwrap();
        for object in ["a", "b", "c"] {
            enqueue(root.path(), object, "cloud");
        }
        let path = root.path().to_owned();
        let other = path.clone();
        let a = std::thread::spawn(move || call(&path, "job-claim", json!({})));
        let b = std::thread::spawn(move || call(&other, "job-claim", json!({})));
        assert_ne!(
            a.join().unwrap()["job"]["id"],
            b.join().unwrap()["job"]["id"]
        );
        assert!(call(root.path(), "job-claim", json!({}))["job"].is_null());
        let local = enqueue(root.path(), "d", "local-heavy");
        enqueue(root.path(), "e", "local-heavy");
        assert_eq!(
            call(root.path(), "job-claim", json!({}))["job"]["id"],
            local["id"]
        );
        assert!(call(root.path(), "job-claim", json!({}))["job"].is_null());
        enqueue(root.path(), "d", "light");
        assert!(call(root.path(), "job-claim", json!({}))["job"].is_null());
    }
    #[test]
    fn dependencies_cancel_and_stale_attempts() {
        let root = tempfile::tempdir().unwrap();
        let parent = enqueue(root.path(), "a", "local-heavy");
        let child = call(
            root.path(),
            "job-enqueue",
            json!({"kind":"example","objectID":"b","dependencies":[parent["id"]]}),
        )["job"]
            .clone();
        assert!(call(root.path(), "job-claim", json!({"jobID":child["id"]}))["job"].is_null());
        call(root.path(), "job-claim", json!({"jobID":parent["id"]}));
        call(
            root.path(),
            "job-update",
            json!({"jobID":parent["id"],"state":"succeeded","expectedAttempt":1}),
        );
        call(root.path(), "job-claim", json!({"jobID":child["id"]}));
        let requested = call(root.path(), "job-cancel", json!({"jobID":child["id"]}));
        assert_eq!(requested["job"]["cancelRequested"], true);
        call(
            root.path(),
            "job-update",
            json!({"jobID":child["id"],"state":"cancelled","expectedAttempt":1}),
        );
        call(root.path(), "job-retry", json!({"jobID":child["id"]}));
        call(root.path(), "job-claim", json!({"jobID":child["id"]}));
        assert!(dispatch(root.path(),&json!({"command":"job-update","jobID":child["id"],"state":"succeeded","expectedAttempt":1})).is_err());
    }
    #[test]
    fn recovery_never_automatically_reissues_paid_calls() {
        let root = tempfile::tempdir().unwrap();
        let job = call(
            root.path(),
            "job-enqueue",
            json!({"kind":"summarize","objectID":"a","paid":true}),
        )["job"]
            .clone();
        call(root.path(), "job-claim", json!({}));
        call(root.path(), "job-recover", json!({}));
        assert!(call(root.path(), "job-claim", json!({}))["job"].is_null());
        assert!(dispatch(
            root.path(),
            &json!({"command":"job-retry","jobID":job["id"]})
        )
        .is_err());
        call(
            root.path(),
            "job-retry",
            json!({"jobID":job["id"],"confirmPaid":true}),
        );
        assert_eq!(
            call(root.path(), "job-claim", json!({}))["job"]["attempt"],
            2
        );
    }
    #[test]
    fn secrets_invalid_progress_and_symlink_database_are_rejected() {
        let root = tempfile::tempdir().unwrap();
        for config in [
            json!({"nested":{"api_key":"bad"}}),
            json!({"endpoint":"https://example.com?token=bad"}),
        ] {
            assert!(dispatch(
                root.path(),
                &json!({"command":"job-enqueue","kind":"example","objectID":"a","config":config})
            )
            .is_err());
        }
        let job = enqueue(root.path(), "a", "cloud");
        call(root.path(), "job-claim", json!({}));
        assert!(dispatch(
            root.path(),
            &json!({"command":"job-update","jobID":job["id"],"progress":2})
        )
        .is_err());
        let second = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(
            root.path().join("jobs.sqlite"),
            second.path().join("jobs.sqlite"),
        )
        .unwrap();
        assert!(dispatch(second.path(), &json!({"command":"job-list"})).is_err());
        assert_eq!(
            fs::metadata(root.path().join("jobs.sqlite"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    #[test]
    fn recording_can_defer_new_heavy_jobs_without_blocking_cloud() {
        let root = tempfile::tempdir().unwrap();
        enqueue(root.path(), "a", "local-heavy");
        let cloud = enqueue(root.path(), "b", "cloud");
        assert_eq!(
            call(
                root.path(),
                "job-claim",
                json!({"allowedResources":["cloud","light"]})
            )["job"]["id"],
            cloud["id"]
        );
        assert!(call(
            root.path(),
            "job-claim",
            json!({"allowedResources":["cloud","light"]})
        )["job"]
            .is_null());
        assert_eq!(
            call(root.path(), "job-claim", json!({}))["job"]["resource"],
            "local-heavy"
        );
    }

    #[test]
    fn chatgpt_quota_pause_survives_reopen_and_history_until_explicit_account_retry() {
        let root = tempfile::tempdir().unwrap();
        let plan = |object: &str, account: &str, command: &str| {
            call(root.path(), "job-enqueue", json!({"kind":command,"objectID":object,"resource":"cloud","paid":true,
                "config":{"command":command,"settings":{"mode":"cloud","cloudProvider":"chatgpt","chatGPTAccountID":account}}}))["job"].clone()
        };
        let finish = |job: &Value, message: &str| {
            assert_eq!(call(root.path(), "job-claim", json!({"jobID":job["id"]}))["job"]["id"], job["id"]);
            call(root.path(), "job-update", json!({"jobID":job["id"],"state":"failed","message":message,"expectedAttempt":1}));
        };
        // This separate failed job can later be explicitly retried. The quota
        // failure itself then remains in history and must not recreate a pause.
        let resume_a = plan("resume-a", "account-a", "example");
        finish(&resume_a, "Temporary provider failure");
        let quota_a = plan("quota-a", "account-a", "summarize");
        let quota_b = plan("quota-b", "account-b", "voice-plan");
        for job in [&quota_a, &quota_b] {
            finish(job, "ChatGPT: HTTP 200 · subscription_sharing_usage_limit_exceeded. Fixture limit.");
        }
        let pending_a = plan("pending-a", "account-a", "example");
        let pending_b = plan("pending-b", "account-b", "example");
        for job in [&pending_a, &pending_b] {
            assert!(call(root.path(), "job-claim", json!({"jobID":job["id"]}))["job"].is_null());
        }
        // Neither other accounts nor API-key-backed speech inherits the pause.
        for job in [plan("other-account", "account-c", "example"), plan("speech", "account-a", "transcribe")] {
            assert_eq!(call(root.path(), "job-claim", json!({"jobID":job["id"]}))["job"]["id"], job["id"]);
            call(root.path(), "job-update", json!({"jobID":job["id"],"state":"succeeded"}));
        }
        for index in 0..55 {
            let job = enqueue(root.path(), &format!("history-{index}"), "light");
            call(root.path(), "job-claim", json!({"jobID":job["id"]}));
            call(root.path(), "job-update", json!({"jobID":job["id"],"state":"succeeded"}));
        }
        let list = call(root.path(), "job-list", json!({}));
        assert!(!list["jobs"].as_array().unwrap().iter().any(|job| job["id"] == quota_a["id"]));
        assert_eq!(list["pausedChatGPTFailures"].as_array().unwrap().len(), 2);
        assert!(dispatch(root.path(), &json!({"command":"job-retry","jobID":resume_a["id"],"confirmPaid":false})).is_err());
        assert_eq!(call(root.path(), "job-list", json!({}))["pausedChatGPTFailures"].as_array().unwrap().len(), 2);
        call(root.path(), "job-retry", json!({"jobID":resume_a["id"],"confirmPaid":true}));
        let reopened = call(root.path(), "job-list", json!({}));
        assert_eq!(reopened["pausedChatGPTFailures"].as_array().unwrap().len(), 1);
        assert_eq!(reopened["pausedChatGPTFailures"][0]["id"], quota_b["id"]);
        assert_eq!(call(root.path(), "job-get", json!({"jobID":quota_a["id"]}))["job"]["state"], "failed");
        assert_eq!(call(root.path(), "job-claim", json!({"jobID":pending_a["id"]}))["job"]["id"], pending_a["id"]);
        assert!(call(root.path(), "job-claim", json!({"jobID":pending_b["id"]}))["job"].is_null());
    }

    #[test]
    fn quota_pause_classification_requires_the_exact_transport_code() {
        assert!(reached_chatgpt_limit("ChatGPT: HTTP 429 · subscription_sharing_usage_limit_exceeded. Retry later."));
        for message in ["ChatGPT: HTTP 200 · subscription_sharing_usage_limit_exceeded_extra. Other code.",
            "ChatGPT: HTTP nope · subscription_sharing_usage_limit_exceeded. Not a status.",
            "Provider mentioned subscription_sharing_usage_limit_exceeded."] {
            assert!(!reached_chatgpt_limit(message));
        }
    }

    #[test]
    fn quota_pause_schema_migration_preserves_history_without_guessing_past_consent() {
        let root = tempfile::tempdir().unwrap();
        let job = enqueue(root.path(), "legacy", "cloud");
        call(root.path(), "job-claim", json!({"jobID":job["id"]}));
        call(root.path(), "job-update", json!({"jobID":job["id"],"state":"failed",
            "message":"ChatGPT: HTTP 200 · subscription_sharing_usage_limit_exceeded. Historical failure."}));
        let connection = open(root.path()).unwrap();
        connection.execute_batch("DROP TABLE job_chatgpt_pauses; PRAGMA user_version=1;").unwrap();
        drop(connection);
        let migrated = call(root.path(), "job-list", json!({}));
        assert_eq!(migrated["jobs"][0]["id"], job["id"]);
        assert!(migrated["pausedChatGPTFailures"].as_array().unwrap().is_empty());
        assert_eq!(open(root.path()).unwrap().pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0)).unwrap(), 2);
    }

    #[test]
    fn completed_jobs_ignore_duplicate_completion_and_reject_late_progress() {
        let root = tempfile::tempdir().unwrap();
        let job = enqueue(root.path(), "a", "cloud");
        call(root.path(), "job-claim", json!({}));
        let done = call(
            root.path(),
            "job-update",
            json!({"jobID":job["id"],"expectedAttempt":1,"state":"succeeded","message":"Saved","result":{"saved":true}}),
        );
        assert_eq!(
            call(
                root.path(),
                "job-update",
                json!({"jobID":job["id"],"expectedAttempt":1,"state":"succeeded","message":"Old progress"})
            ),
            done
        );
        assert!(dispatch(root.path(),&json!({"command":"job-update","jobID":job["id"],"expectedAttempt":1,"message":"Late progress"})).is_err());
    }

    #[test]
    fn chained_stages_are_atomic_durable_and_not_revived_by_parent_dedup() {
        let root = tempfile::tempdir().unwrap();
        let input = json!({"kind":"transcribe","objectID":"a","resource":"local-heavy","followUps":[{"kind":"summarize","objectID":"a","resource":"local-heavy","inputRevision":"dependency:$parent"}]});
        let result = call(root.path(), "job-enqueue", input.clone());
        let parent = &result["job"];
        let child = &result["followUps"][0];
        assert_eq!(child["dependencies"], json!([parent["id"]]));
        assert_eq!(
            child["inputRevision"],
            format!("dependency:{}", parent["id"].as_str().unwrap())
        );
        assert!(call(root.path(), "job-claim", json!({"jobID":child["id"]}))["job"].is_null());
        call(root.path(), "job-cancel", json!({"jobID":child["id"]}));
        let again = call(root.path(), "job-enqueue", input);
        assert_eq!(again["followUps"][0]["id"], child["id"]);
        assert_eq!(again["followUps"][0]["state"], "cancelled");
        let broken = json!({"command":"job-enqueue","kind":"transcribe","objectID":"bad","followUps":[{"kind":"summarize","objectID":"bad","config":{"apiKey":"secret"}}]});
        assert!(dispatch(root.path(), &broken).is_err());
        assert_eq!(
            call(root.path(), "job-list", json!({}))["jobs"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        call(root.path(), "job-claim", json!({"jobID":parent["id"]}));
        call(
            root.path(),
            "job-update",
            json!({"jobID":parent["id"],"state":"interrupted"}),
        );
        assert_eq!(
            call(root.path(), "job-get", json!({"jobID":parent["id"]}))["job"]["state"],
            "interrupted"
        );
    }
    #[test]
    fn failed_or_cancelled_parent_releases_children_until_explicit_retry() {
        for terminal in ["failed", "cancelled"] {
            let root = tempfile::tempdir().unwrap();
            let result = call(
                root.path(),
                "job-enqueue",
                json!({"kind":"transcribe","objectID":"a","followUps":[{"kind":"summarize","objectID":"a","inputRevision":"dependency:$parent"}]}),
            );
            let parent = &result["job"];
            let child = &result["followUps"][0];
            call(root.path(), "job-claim", json!({"jobID":parent["id"]}));
            call(
                root.path(),
                "job-update",
                json!({"jobID":parent["id"],"state":terminal}),
            );
            let jobs = call(root.path(), "job-list", json!({}));
            assert!(jobs["jobs"]
                .as_array()
                .unwrap()
                .iter()
                .all(|job| job["state"] != "queued" && job["state"] != "running"));
            assert_eq!(
                call(root.path(), "job-get", json!({"jobID":child["id"]}))["job"]["state"],
                "blocked"
            );
            call(root.path(), "job-retry", json!({"jobID":parent["id"]}));
            call(root.path(), "job-claim", json!({"jobID":parent["id"]}));
            assert!(call(root.path(), "job-claim", json!({"jobID":child["id"]}))["job"].is_null());
            call(
                root.path(),
                "job-update",
                json!({"jobID":parent["id"],"state":"succeeded"}),
            );
            assert_eq!(
                call(root.path(), "job-claim", json!({"jobID":child["id"]}))["job"]["id"],
                child["id"]
            );
        }
    }
    #[test]
    fn explicitly_cancelled_child_does_not_revive_with_parent_retry() {
        let root = tempfile::tempdir().unwrap();
        let result = call(
            root.path(),
            "job-enqueue",
            json!({"kind":"transcribe","objectID":"a","followUps":[{"kind":"summarize","objectID":"a"}]}),
        );
        let parent = &result["job"];
        let child = &result["followUps"][0];
        call(root.path(), "job-cancel", json!({"jobID":child["id"]}));
        call(root.path(), "job-cancel", json!({"jobID":parent["id"]}));
        call(root.path(), "job-retry", json!({"jobID":parent["id"]}));
        call(root.path(), "job-claim", json!({"jobID":parent["id"]}));
        call(
            root.path(),
            "job-update",
            json!({"jobID":parent["id"],"state":"succeeded"}),
        );
        assert!(call(root.path(), "job-claim", json!({"jobID":child["id"]}))["job"].is_null());
        assert_eq!(
            call(root.path(), "job-get", json!({"jobID":child["id"]}))["job"]["state"],
            "cancelled"
        );
    }

    #[test]
    fn job_list_keeps_all_active_and_only_recent_history_but_dependencies_use_full_database() {
        let root = tempfile::tempdir().unwrap();
        let mut parent = Value::Null;
        for index in 0..60 {
            let job = enqueue(root.path(), &format!("old-{index}"), "light");
            call(root.path(), "job-claim", json!({"jobID":job["id"]}));
            call(
                root.path(),
                "job-update",
                json!({"jobID":job["id"],"state":"succeeded"}),
            );
            if index == 0 {
                parent = job;
            }
        }
        let child = call(
            root.path(),
            "job-enqueue",
            json!({"kind":"summarize","objectID":"child","dependencies":[parent["id"]]}),
        )["job"]
            .clone();
        let list = call(root.path(), "job-list", json!({}));
        assert_eq!(list["jobs"].as_array().unwrap().len(), 51);
        assert_eq!(list["hasMore"], true);
        assert_eq!(list["total"], 61);
        assert!(list["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .all(|job| job["id"] != parent["id"]));
        assert_eq!(
            call(root.path(), "job-claim", json!({"jobID":child["id"]}))["job"]["id"],
            child["id"]
        );
    }
    #[test]
    fn completed_history_never_prevents_new_work_but_pending_work_is_bounded() {
        let root = tempfile::tempdir().unwrap();
        let mut connection = open(root.path()).unwrap();
        {
            let transaction = connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .unwrap();
            let mut row = make_job(&json!({"kind":"example","objectID":"history"})).unwrap();
            row.state = "succeeded".into();
            row.created_at = 1.0;
            row.updated_at = 1.0;
            {
                let mut insert=transaction.prepare("INSERT INTO jobs(id,state,resource,object_id,dedup_key,created_at,updated_at,payload) VALUES(?1,'succeeded','light','history',?1,1,1,?2)").unwrap();
                for index in 0..20_001 {
                    row.id = format!("history-{index}");
                    insert
                        .execute(params![row.id, serde_json::to_string(&row).unwrap()])
                        .unwrap();
                }
            }
            transaction.commit().unwrap();
        }
        let newest = enqueue(root.path(), "newest", "cloud");
        assert_eq!(
            call(root.path(), "job-claim", json!({"jobID":newest["id"]}))["job"]["id"],
            newest["id"]
        );
        for index in 0..255 {
            enqueue(root.path(), &format!("pending-{index}"), "light");
        }
        assert!(dispatch(
            root.path(),
            &json!({"command":"job-enqueue","kind":"example","objectID":"overflow"})
        )
        .is_err());
    }
}
