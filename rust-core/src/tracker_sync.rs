//! Explicitly configured task-provider synchronisation. Tokens never enter this
//! journal. Remote writes are durable intentions, guarded by ETag/version and
//! reconciled after an uncertain response; deletes are always a visible conflict.
use crate::notes::{self, CapturedNote, NotesWorkspace};
use crate::task_workspace::TaskEvent;
use anyhow::{bail, ensure, Context, Result};
use reqwest::{blocking::Client, Method, Url};
use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

const MAX_ITEMS: usize = 9_000;
const MAX_BODY: u64 = 8 * 1_048_576;
const MAX_JOURNAL: usize = 24 * 1_048_576;
fn now() -> f64 {
    chrono::Utc::now().timestamp_millis() as f64 / 1000.0
}
fn digest(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}
fn id() -> String {
    uuid::Uuid::new_v4().to_string()
}
fn short(value: &str, max: usize) -> bool {
    value.len() <= max && !value.contains('\0')
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TrackerConfiguration {
    pub id: String,
    pub provider: String,
    pub account: String,
    #[serde(rename="folderID")] pub folder_id:Option<String>,
    pub organization_id: String,
    pub cloud_organization: bool,
    pub iam_token: bool,
    pub enabled: bool,
    pub push_enabled: bool,
    pub paused: bool,
    pub scopes: Vec<String>,
    pub scope_titles: BTreeMap<String, String>,
    pub expires_at: Option<f64>,
    pub status_mapping: BTreeMap<String, String>,
    pub last_sync: Option<f64>,
    pub retry_at: Option<f64>,
    pub error: Option<String>,
    pub requires_auth: bool,
    pub revision: u64,
}
impl Default for TrackerConfiguration {
    fn default() -> Self {
        Self {
            id: String::new(),
            provider: "google".into(),
            account: String::new(),
            folder_id:None,
            organization_id: String::new(),
            cloud_organization: false,
            iam_token: false,
            enabled: false,
            push_enabled: false,
            paused: false,
            scopes: vec![],
            scope_titles: BTreeMap::new(),
            expires_at: None,
            status_mapping: BTreeMap::from([
                ("todo".into(), "open".into()),
                ("doing".into(), "inProgress".into()),
                ("blocked".into(), "paused".into()),
                ("done".into(), "closed".into()),
            ]),
            last_sync: None,
            retry_at: None,
            error: None,
            requires_auth: false,
            revision: 0,
        }
    }
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Fields {
    title: String,
    text: String,
    status: String,
    due: String,
    owner: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Remote {
    id: String,
    scope: String,
    revision: String,
    fields: Fields,
    deleted: bool,
    url: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Binding {
    connection: String,
    scope: String,
    remote_id: String,
    local_id: String,
    remote: Remote,
    local: Fields,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Pending {
    id: String,
    connection: String,
    local_id: String,
    scope: String,
    remote_id: Option<String>,
    desired: Fields,
    base: Option<Remote>,
    sent: bool,
    attempts: u32,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackerConflict {
    pub id: String,
    pub connection: String,
    pub local_id: String,
    pub title: String,
    pub reason: String,
    pub local: Value,
    pub remote: Value,
    pub fingerprint: String,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Journal {
    configurations: Vec<TrackerConfiguration>,
    bindings: Vec<Binding>,
    pending: Vec<Pending>,
    conflicts: Vec<TrackerConflict>,
    detached: Vec<String>,
}

fn database(root: &Path) -> Result<Connection> {
    let dir = fs::canonicalize(notes::directory(root)?)?;
    let path = dir.join("tracker-sync.sqlite");
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let p = dir.join(format!("tracker-sync.sqlite{suffix}"));
        if let Ok(info) = fs::symlink_metadata(&p) {
            ensure!(
                info.is_file() && !info.file_type().is_symlink() && info.nlink() == 1,
                "Некорректный журнал синхронизации"
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
    let db = Connection::open_with_flags(
        &path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE
            | rusqlite::OpenFlags::SQLITE_OPEN_CREATE
            | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    db.busy_timeout(Duration::from_secs(5))?;
    db.execute_batch("PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS tracker_journal(id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL);")?;
    Ok(db)
}
fn load(db: &Connection) -> Result<Journal> {
    let text: Option<String> = db
        .query_row("SELECT payload FROM tracker_journal WHERE id=1", [], |r| {
            r.get(0)
        })
        .optional()?;
    match text {
        Some(text) => {
            ensure!(
                text.len() <= MAX_JOURNAL,
                "Журнал синхронизации слишком большой"
            );
            serde_json::from_str(&text).context("Повреждён журнал синхронизации. Данные сохранены.")
        }
        None => Ok(Journal::default()),
    }
}
fn ensure_tasks(root: &Path) -> Result<()> {
    ensure!(crate::ai::live_features(root)?.tasks, "Включите «Задачи и проекты» в настройках → Возможности.");
    Ok(())
}
fn connection_tasks(root:&Path,c:&TrackerConfiguration)->Result<()> {
    ensure!(crate::ai::live_features_for(root,None,c.folder_id.as_deref())?.tasks,"Задачи выключены в папке подключения трекера.");
    Ok(())
}
fn source_tasks(root:&Path,id:&str)->bool { crate::ai::live_features_for_input(root,&json!({"taskID":id})).is_ok_and(|f|f.tasks) }
fn save_active(root: &Path, db: &Connection, j: &Journal) -> Result<()> {
    ensure_tasks(root)?;
    save(db, j)
}
fn save(db: &Connection, j: &Journal) -> Result<()> {
    let text = serde_json::to_string(j)?;
    ensure!(
        text.len() <= MAX_JOURNAL,
        "Журнал синхронизации слишком большой"
    );
    db.execute("INSERT INTO tracker_journal(id,payload) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",[text])?;
    Ok(())
}
fn configuration(j: &Journal, connection: &str) -> Result<TrackerConfiguration> {
    j.configurations
        .iter()
        .find(|c| c.id == connection)
        .cloned()
        .context("Подключение трекера не найдено")
}
fn state(j: &Journal) -> Value {
    json!({"configurations":j.configurations,"conflicts":j.conflicts,"pending":j.pending.iter().map(|p|json!({"id":p.id,"connection":p.connection,"localID":p.local_id,"title":p.desired.title,"uncertain":p.sent,"attempts":p.attempts})).collect::<Vec<_>>(),"linkedCount":j.bindings.len(),"linkedTasks":j.bindings.iter().map(|b|json!({"connection":b.connection,"localID":b.local_id,"scope":b.scope,"remoteID":b.remote_id,"url":b.remote.url})).collect::<Vec<_>>()})
}
fn checked_config(c: &TrackerConfiguration) -> Result<()> {
    ensure!(
        c.scope_titles.len() <= 1000
            && c.scope_titles
                .iter()
                .all(|(key, value)| short(key, 1024) && short(value, 2000)),
        "Слишком большой список названий"
    );
    ensure!(
        ["google", "yandex"].contains(&c.provider.as_str()),
        "Неизвестный трекер"
    );
    ensure!(
        !c.account.trim().is_empty() && short(&c.account, 128),
        "Укажите имя подключаемого аккаунта"
    );
    ensure!(
        c.scopes.len() <= 100 && c.scopes.iter().all(|s| !s.is_empty() && short(s, 512)),
        "Некорректные списки задач"
    );
    ensure!(
        c.provider != "yandex"
            || (!c.organization_id.is_empty()
                && short(&c.organization_id, 128)
                && c.organization_id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')),
        "Укажите ID организации Яндекс Трекера"
    );
    ensure!(
        !c.iam_token || c.cloud_organization,
        "IAM-токен требует организацию Yandex Identity Hub"
    );
    if let Some(expiry) = c.expires_at {
        ensure!(
            expiry.is_finite() && expiry > 0.,
            "Некорректный срок токена"
        );
    }
    ensure!(
        c.status_mapping.len() <= 4
            && c.status_mapping
                .iter()
                .all(
                    |(k, v)| ["todo", "doing", "blocked", "done"].contains(&k.as_str())
                        && !v.is_empty()
                        && short(v, 128)
                ),
        "Некорректное соответствие статусов"
    );
    Ok(())
}
struct Api {
    root: PathBuf,
    client: Client,
    base: Url,
    config: TrackerConfiguration,
    token: String,
}
struct Reply {
    value: Value,
    pages: Option<usize>,
}
#[derive(Debug)]
struct ApiFailure {
    code: u16,
    retry_after: Option<f64>,
    message: String,
}
impl std::fmt::Display for ApiFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}
impl std::error::Error for ApiFailure {}
impl Api {
    fn new(root: &Path, config: TrackerConfiguration, input: &Value) -> Result<Self> {
        ensure_tasks(root)?;
        connection_tasks(root,&config)?;
        let token = input["token"].as_str().unwrap_or("").trim().to_string();
        ensure!(
            !token.is_empty() && token.len() <= 16_384 && !token.contains(['\r', '\n']),
            "Добавьте токен подключения в настройках"
        );
        if config.provider == "google" || config.iam_token {
            ensure!(
                config.expires_at.is_some_and(|v| v > now()),
                "Токен истёк. Обновите токен и срок действия в настройках подключения."
            );
        }
        let base = Url::parse(if config.provider == "google" {
            "https://tasks.googleapis.com"
        } else {
            "https://api.tracker.yandex.net"
        })?;
        #[cfg(test)]
        let base = if let Some(test) = input["testBaseURL"].as_str() {
            let url = Url::parse(test)?;
            ensure!(
                url.scheme() == "http" && url.host_str() == Some("127.0.0.1"),
                "Test endpoint must be loopback"
            );
            url
        } else {
            base
        };
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        Ok(Self {
            root: root.into(),
            client,
            base,
            config,
            token,
        })
    }
    fn url(&self, segments: &[&str]) -> Result<Url> {
        let mut url = self.base.clone();
        {
            let mut p = url
                .path_segments_mut()
                .map_err(|_| anyhow::anyhow!("Некорректный адрес трекера"))?;
            p.clear();
            for part in segments {
                p.push(part);
            }
        }
        Ok(url)
    }
    fn call(
        &self,
        method: Method,
        segments: &[&str],
        query: &[(&str, String)],
        body: Option<Value>,
        revision: Option<&str>,
    ) -> Result<Reply> {
        let mut request = self
            .client
            .request(method, self.url(segments)?)
            .query(query)
            .header(
                "Authorization",
                format!(
                    "{} {}",
                    if self.config.provider == "yandex" && !self.config.iam_token {
                        "OAuth"
                    } else {
                        "Bearer"
                    },
                    self.token
                ),
            )
            .header("Accept", "application/json");
        if self.config.provider == "yandex" {
            request = request.header(
                if self.config.cloud_organization {
                    "X-Cloud-Org-ID"
                } else {
                    "X-Org-ID"
                },
                &self.config.organization_id,
            );
        }
        if let Some(revision) = revision {
            if self.config.provider == "google" {
                request = request.header("If-Match", revision);
            }
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        // Never surface reqwest errors containing request URLs or response text:
        // providers can echo credentials or confidential remote content there.
        ensure_tasks(&self.root)?;
        connection_tasks(&self.root,&self.config)?;
        let response = request.send().map_err(|_| ApiFailure {
            code: 0,
            retry_after: None,
            message: "Трекер не ответил. Изменение сохранено; результат проверим перед повтором."
                .into(),
        })?;
        ensure_tasks(&self.root)?;
        connection_tasks(&self.root,&self.config)?;
        let code = response.status().as_u16();
        let pages = response
            .headers()
            .get("X-Total-Pages")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse().ok());
        let retry_after = response
            .headers()
            .get("Retry-After")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| {
                v.parse::<f64>().ok().or_else(|| {
                    chrono::DateTime::parse_from_rfc2822(v)
                        .ok()
                        .map(|t| (t.timestamp() as f64 - now()).max(1.))
                })
            });
        if !(200..300).contains(&code) {
            let message = match code {
                401 => "Токен истёк или отозван. Обновите подключение.",
                403 => "Недостаточно прав на выбранный список или очередь.",
                404 => "Задача или список недоступны. Локальная копия сохранена.",
                409 | 412 => "Задача изменилась в трекере. Требуется сверка изменений.",
                429 => "Трекер ограничил частоту запросов. Повторим позже.",
                _ => "Трекер временно не выполнил запрос. Изменения сохранены.",
            };
            return Err(ApiFailure {
                code,
                retry_after,
                message: message.into(),
            }
            .into());
        }
        ensure!(
            response.content_length().is_none_or(|n| n <= MAX_BODY),
            "Ответ трекера слишком большой"
        );
        let mut bytes = vec![];
        response.take(MAX_BODY + 1).read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() as u64 <= MAX_BODY,
            "Ответ трекера слишком большой"
        );
        let value = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).context("Трекер вернул неподдерживаемый ответ")?
        };
        Ok(Reply { value, pages })
    }
    fn scopes(&self) -> Result<Value> {
        let mut result = vec![];
        let mut token = String::new();
        let mut seen = HashSet::new();
        for page in 1..=100 {
            let reply = if self.config.provider == "google" {
                self.call(
                    Method::GET,
                    &["tasks", "v1", "users", "@me", "lists"],
                    &[("maxResults", "100".into()), ("pageToken", token.clone())],
                    None,
                    None,
                )?
            } else {
                self.call(
                    Method::GET,
                    &["v3", "queues"],
                    &[("perPage", "100".into()), ("page", page.to_string())],
                    None,
                    None,
                )?
            };
            let list = if self.config.provider == "google" {
                reply.value["items"].as_array().cloned().unwrap_or_default()
            } else {
                reply
                    .value
                    .as_array()
                    .context("Нет списка очередей")?
                    .clone()
            };
            for item in &list {
                let key = if self.config.provider == "google" {
                    item["id"].as_str()
                } else {
                    item["key"].as_str()
                }
                .context("Нет ID списка")?;
                result.push(json!({"id":key,"title":item[if self.config.provider=="google"{"title"}else{"name"}].as_str().unwrap_or(key)}));
            }
            ensure!(result.len() <= MAX_ITEMS, "Слишком много списков трекера");
            if self.config.provider == "google" {
                token = reply.value["nextPageToken"].as_str().unwrap_or("").into();
                if token.is_empty() {
                    return Ok(json!({"scopes":result}));
                }
                ensure!(seen.insert(token.clone()), "Трекер повторил страницу");
            } else if page
                >= reply
                    .pages
                    .unwrap_or(if list.len() < 100 { page } else { page + 1 })
            {
                return Ok(json!({"scopes":result}));
            }
        }
        bail!("Слишком много страниц списков. Выберите более узкое подключение")
    }
    fn remote(&self, scope: &str, value: &Value) -> Result<Remote> {
        let g = self.config.provider == "google";
        let remote_id = value[if g { "id" } else { "key" }]
            .as_str()
            .context("Нет ID внешней задачи")?
            .to_string();
        ensure!(short(&remote_id, 512), "Некорректный ID внешней задачи");
        let deleted = value["deleted"].as_bool().unwrap_or(false);
        let revision = if g {
            value["etag"].as_str().unwrap_or("").to_string()
        } else {
            value["version"]
                .as_u64()
                .map(|v| v.to_string())
                .unwrap_or_default()
        };
        ensure!(
            deleted || !revision.is_empty(),
            "Трекер не вернул ревизию задачи"
        );
        let raw_status = if g {
            value["status"].as_str().unwrap_or("needsAction")
        } else {
            value["status"]["key"].as_str().unwrap_or("open")
        };
        let status = if g {
            if raw_status == "completed" {
                "done"
            } else {
                "todo"
            }
        } else {
            self.config
                .status_mapping
                .iter()
                .find(|(_, v)| v.as_str() == raw_status)
                .map(|(k, _)| k.as_str())
                .unwrap_or(if value["resolution"].is_object() {
                    "done"
                } else {
                    "todo"
                })
        };
        let fields = Fields {
            title: value[if g { "title" } else { "summary" }]
                .as_str()
                .unwrap_or("Задача")
                .into(),
            text: strip_marker(
                value[if g { "notes" } else { "description" }]
                    .as_str()
                    .unwrap_or(""),
            )
            .into(),
            status: status.into(),
            due: value[if g { "due" } else { "dueDate" }]
                .as_str()
                .unwrap_or("")
                .chars()
                .take(10)
                .collect(),
            owner: if g {
                String::new()
            } else {
                value["assignee"]["id"].as_str().unwrap_or("").into()
            },
        };
        ensure!(
            short(&fields.title, 1024) && short(&fields.text, 100_000) && short(&fields.owner, 512),
            "Внешняя задача превышает допустимый размер"
        );
        let url = if g {
            value["webViewLink"]
                .as_str()
                .filter(|u| {
                    Url::parse(u).is_ok_and(|u| {
                        u.scheme() == "https" && u.host_str() == Some("tasks.google.com")
                    })
                })
                .unwrap_or("https://tasks.google.com/")
                .into()
        } else {
            format!("https://tracker.yandex.ru/{remote_id}")
        };
        Ok(Remote {
            id: remote_id,
            scope: scope.into(),
            revision,
            fields,
            deleted,
            url,
        })
    }
    fn tasks(&self, scope: &str) -> Result<Vec<Remote>> {
        let mut result = vec![];
        let mut token = String::new();
        let mut seen = HashSet::new();
        let mut ids = HashSet::new();
        for page in 1..=100 {
            let reply = if self.config.provider == "google" {
                self.call(
                    Method::GET,
                    &["tasks", "v1", "lists", scope, "tasks"],
                    &[
                        ("maxResults", "100".into()),
                        ("pageToken", token.clone()),
                        ("showCompleted", "true".into()),
                        ("showHidden", "true".into()),
                        ("showDeleted", "true".into()),
                    ],
                    None,
                    None,
                )?
            } else {
                self.call(
                    Method::POST,
                    &["v3", "issues", "_search"],
                    &[("perPage", "100".into()), ("page", page.to_string())],
                    Some(json!({"filter":{"queue":scope},"order":"+key"})),
                    None,
                )?
            };
            let list = if self.config.provider == "google" {
                reply.value["items"].as_array().cloned().unwrap_or_default()
            } else {
                reply.value.as_array().context("Нет списка задач")?.clone()
            };
            for value in &list {
                let remote = self.remote(scope, value)?;
                if ids.insert(remote.id.clone()) {
                    result.push(remote);
                }
            }
            ensure!(
                result.len() <= MAX_ITEMS,
                "В очереди больше 9000 задач. Сузьте выборку."
            );
            if self.config.provider == "google" {
                token = reply.value["nextPageToken"].as_str().unwrap_or("").into();
                if token.is_empty() {
                    return Ok(result);
                }
                ensure!(seen.insert(token.clone()), "Трекер повторил страницу задач");
            } else if page
                >= reply
                    .pages
                    .unwrap_or(if list.len() < 100 { page } else { page + 1 })
            {
                return Ok(result);
            }
        }
        bail!("Список задач неполный. Синхронизация остановлена без удаления данных.")
    }
    fn get(&self, scope: &str, remote_id: &str) -> Result<Remote> {
        let segments = if self.config.provider == "google" {
            vec!["tasks", "v1", "lists", scope, "tasks", remote_id]
        } else {
            vec!["v3", "issues", remote_id]
        };
        let reply = self.call(Method::GET, &segments, &[], None, None)?;
        self.remote(scope, &reply.value)
    }
    fn patch(&self, p: &Pending, remote: &Remote) -> Result<Remote> {
        if self.config.provider == "google" {
            ensure!(
                p.desired.text.chars().count() <= 8192,
                "Google Tasks принимает до 8192 символов описания"
            );
            let body = json!({"title":p.desired.title,"notes":p.desired.text,"status":if p.desired.status=="done"{"completed"}else{"needsAction"},"due":if p.desired.due.is_empty(){Value::Null}else{json!(format!("{}T00:00:00.000Z",date(&p.desired.due)?))},"completed":if p.desired.status=="done"{json!(chrono::Utc::now().to_rfc3339())}else{Value::Null}});
            let r = self.call(
                Method::PATCH,
                &["tasks", "v1", "lists", &p.scope, "tasks", &remote.id],
                &[],
                Some(body),
                Some(&remote.revision),
            )?;
            self.remote(&p.scope, &r.value)
        } else {
            let fields_equal = p.desired.title == remote.fields.title
                && p.desired.text == remote.fields.text
                && p.desired.due == remote.fields.due
                && p.desired.owner == remote.fields.owner;
            let mut current = remote.clone();
            if !fields_equal {
                let body = json!({"summary":p.desired.title,"description":p.desired.text,"dueDate":if p.desired.due.is_empty(){Value::Null}else{json!(date(&p.desired.due)?)},"assignee":if p.desired.owner.is_empty(){Value::Null}else{json!(p.desired.owner)}});
                let r = self.call(
                    Method::PATCH,
                    &["v3", "issues", &remote.id],
                    &[("version", remote.revision.clone())],
                    Some(body),
                    None,
                )?;
                current = self.remote(&p.scope, &r.value)?;
            }
            if current.fields.status != p.desired.status {
                let target = self
                    .config
                    .status_mapping
                    .get(&p.desired.status)
                    .context("Настройте соответствие статусов Яндекс Трекера")?;
                let r = self.call(
                    Method::GET,
                    &["v3", "issues", &remote.id, "transitions"],
                    &[],
                    None,
                    None,
                )?;
                let transitions = r
                    .value
                    .as_array()
                    .context("Нет доступных переходов задачи")?;
                let available = transitions
                    .iter()
                    .filter(|t| t["to"]["key"].as_str() == Some(target))
                    .collect::<Vec<_>>();
                ensure!(available.len()==1,"Для этого статуса нет однозначного перехода. Измените статус в Яндекс Трекере.");
                let transition = available[0]["id"].as_str().context("Нет ID перехода")?;
                self.call(
                    Method::POST,
                    &[
                        "v3",
                        "issues",
                        &remote.id,
                        "transitions",
                        transition,
                        "_execute",
                    ],
                    &[("version", current.revision.clone())],
                    Some(json!({})),
                    None,
                )?;
                current = self.get(&p.scope, &remote.id)?;
            }
            Ok(current)
        }
    }
    fn create(&self, p: &Pending) -> Result<Remote> {
        let marker = format!("[posle:{}]", p.id);
        let body = if self.config.provider == "google" {
            ensure!(
                (p.desired.text.len() + marker.len() + 2) <= 8192,
                "Google Tasks принимает до 8192 символов описания"
            );
            json!({"title":p.desired.title,"notes":format!("{}\n\n{}",p.desired.text,marker),"status":if p.desired.status=="done"{"completed"}else{"needsAction"},"due":if p.desired.due.is_empty(){Value::Null}else{json!(format!("{}T00:00:00.000Z",date(&p.desired.due)?))}})
        } else {
            json!({"queue":p.scope,"summary":p.desired.title,"description":format!("{}\n\n{}",p.desired.text,marker),"unique":format!("posle-{}",p.id),"dueDate":if p.desired.due.is_empty(){Value::Null}else{json!(date(&p.desired.due)?)},"assignee":if p.desired.owner.is_empty(){Value::Null}else{json!(p.desired.owner)}})
        };
        let segments = if self.config.provider == "google" {
            vec!["tasks", "v1", "lists", &p.scope, "tasks"]
        } else {
            vec!["v3", "issues"]
        };
        let reply = self.call(Method::POST, &segments, &[], Some(body), None)?;
        self.remote(&p.scope, &reply.value)
    }
    fn find_creation(&self, p: &Pending) -> Result<Option<Remote>> {
        // Scan all pages before deciding. An absent Google marker never grants a
        // new POST after an uncertain result: eventual consistency makes that unsafe.
        let marker = format!("[posle:{}]", p.id);
        let mut token = String::new();
        let mut matches = vec![];
        let mut seen = HashSet::new();
        for page in 1..=100 {
            let reply = if self.config.provider == "google" {
                self.call(
                    Method::GET,
                    &["tasks", "v1", "lists", &p.scope, "tasks"],
                    &[
                        ("maxResults", "100".into()),
                        ("pageToken", token.clone()),
                        ("showCompleted", "true".into()),
                        ("showHidden", "true".into()),
                        ("showDeleted", "true".into()),
                    ],
                    None,
                    None,
                )?
            } else {
                self.call(
                    Method::POST,
                    &["v3", "issues", "_search"],
                    &[("perPage", "100".into()), ("page", page.to_string())],
                    Some(json!({"filter":{"unique":format!("posle-{}",p.id)}})),
                    None,
                )?
            };
            let list = if self.config.provider == "google" {
                reply.value["items"].as_array().cloned().unwrap_or_default()
            } else {
                reply.value.as_array().context("Нет списка сверки")?.clone()
            };
            for item in &list {
                if self.config.provider == "yandex"
                    || item["notes"].as_str().is_some_and(|s| s.ends_with(&marker))
                {
                    matches.push(self.remote(&p.scope, item)?);
                }
            }
            ensure!(
                matches.len() <= 1,
                "Найдено несколько внешних задач. Разрешите конфликт вручную."
            );
            if self.config.provider == "google" {
                token = reply.value["nextPageToken"].as_str().unwrap_or("").into();
                if token.is_empty() {
                    return Ok(matches.pop());
                }
                ensure!(seen.insert(token.clone()), "Повтор страницы сверки");
            } else if page
                >= reply
                    .pages
                    .unwrap_or(if list.len() < 100 { page } else { page + 1 })
            {
                return Ok(matches.pop());
            }
        }
        bail!("Сверка создания не завершена. Повторная отправка остановлена.")
    }
}
fn date(value: &str) -> Result<&str> {
    ensure!(
        chrono::NaiveDate::parse_from_str(value, "%Y-%m-%d").is_ok(),
        "Для синхронизации срок должен быть датой ГГГГ-ММ-ДД"
    );
    Ok(value)
}
fn strip_marker(value: &str) -> &str {
    if let Some(at) = value.rfind("\n\n[posle:") {
        if value.ends_with(']')
            && value[at + 9..value.len() - 1]
                .bytes()
                .all(|b| b.is_ascii_hexdigit() || b == b'-')
        {
            return &value[..at];
        }
    }
    value
}
fn fields(workspace: &NotesWorkspace, local_id: &str, provider: &str) -> Option<Fields> {
    let note = workspace
        .notes
        .iter()
        .find(|n| n.id == local_id && n.kind == "task" && n.trashed_at.is_none())?;
    let status = if note.completed {
        "done".into()
    } else {
        workspace
            .task_workspaces
            .iter()
            .find(|r| r.note_id == local_id)
            .map(|r| r.status.clone())
            .filter(|s| s != "done")
            .unwrap_or("todo".into())
    };
    Some(Fields {
        title: note.title.clone(),
        text: note.text.clone(),
        status,
        due: note.due.clone(),
        owner: if provider == "google" {
            String::new()
        } else {
            note.owner.clone()
        },
    })
}
fn provider_fields(mut fields: Fields, provider: &str) -> Fields {
    if provider == "google" {
        fields.owner.clear();
        if fields.status != "done" {
            fields.status = "todo".into();
        }
    }
    fields
}
fn history(text: &str) -> TaskEvent {
    TaskEvent {
        id: id(),
        kind: "trackerSync".into(),
        text: text.into(),
        actor: "tracker".into(),
        created_at: now(),
        artifacts: vec![],
        snapshot: None,
        claim_id: None,
    }
}
fn apply_remote(
    root: &Path,
    c: &TrackerConfiguration,
    remote: &Remote,
    local_id: &str,
    expected: Option<&Fields>,
) -> Result<Fields> {
    ensure_tasks(root)?;
    connection_tasks(root,c)?;
    let dir = notes::directory(root)?;
    let _lock = notes::lock(&dir)?;
    let mut workspace = notes::load(&dir)?;
    connection_tasks(root,c)?;
    if workspace.notes.iter().any(|n|n.id==local_id) { ensure!(source_tasks(root,local_id),"Задачи выключены в папке локальной задачи"); }
    if let Some(expected) = expected {
        ensure!(
            fields(&workspace, local_id, &c.provider).as_ref() == Some(expected),
            "Локальная задача изменилась во время синхронизации. Повторите сверку."
        );
    }
    let receipt_id = format!(
        "tracker-import-{}",
        digest(&serde_json::to_string(&json!([
            c.id,
            remote.scope,
            remote.id,
            remote.revision
        ]))?)
    );
    if let Some(receipt) = workspace
        .task_operations
        .iter()
        .find(|op| op["operationID"].as_str() == Some(&receipt_id))
    {
        ensure!(
            fields(&workspace, local_id, &c.provider).is_some(),
            "Задача после импорта удалена. Автоматическое восстановление остановлено."
        );
        return Ok(serde_json::from_value(receipt["result"]["fields"].clone())
            .unwrap_or_else(|_| remote.fields.clone()));
    }
    let existing = workspace.notes.iter().position(|n| n.id == local_id);
    if let Some(i) = existing {
        ensure!(
            workspace.notes[i].trashed_at.is_none(),
            "Локальная задача удалена. Автоматическое восстановление остановлено."
        );
    }
    let mut local = remote.fields.clone();
    // Google has two states; preserve the local distinction doing/blocked when
    // remote remains needsAction. It cannot erase work-in-progress metadata.
    if c.provider == "google" && local.status == "todo" {
        if let Some(old) = fields(&workspace, local_id, "google") {
            if old.status == "doing" || old.status == "blocked" {
                local.status = old.status;
            }
        }
    }
    let mut note = if let Some(i) = existing {
        workspace.notes[i].clone()
    } else {
        CapturedNote {
            id: local_id.into(),
            kind: "task".into(),
            created_at: now(),
            updated_at: now(),
            revision: 0,
            text: String::new(),
            meeting_id: None,
            timestamp: None,
            source_url: String::new(),
            owner: String::new(),
            due: String::new(),
            completed: false,
            title: String::new(),
            content_rtf: String::new(),
            folder: String::new(),
            folder_id: c.folder_id.clone(),
            tags: vec![],
            pinned: false,
            trashed_at: None,
            attachments: vec![],
            expansion: None,
            task_origin: None,
            history: vec![],
            subtasks: vec![],
        }
    };
    if let Some(folder)=&note.folder_id { note.folder=workspace.folders.iter().find(|f|&f.id==folder).map(|f|f.name.clone()).context("Папка подключения удалена")?; }
    note.title = local.title.clone();
    note.text = local.text.clone();
    note.content_rtf.clear();
    note.due = local.due.clone();
    note.completed = local.status == "done";
    if c.provider != "google" {
        note.owner = local.owner.clone();
    }
    note.source_url = remote.url.clone();
    note.revision = note
        .revision
        .checked_add(1)
        .context("Слишком большая ревизия задачи")?;
    note.updated_at = now();
    if let Some(i) = existing {
        workspace.notes[i] = note;
    } else {
        workspace.notes.push(note);
    }
    let mut record = workspace
        .task_workspaces
        .iter()
        .find(|r| r.note_id == local_id)
        .cloned()
        .unwrap_or_default();
    record.note_id = local_id.into();
    record.source = c.provider.clone();
    record.external_url = remote.url.clone();
    record.status = local.status.clone();
    if record.project.is_empty() {
        record.project = c
            .scope_titles
            .get(&remote.scope)
            .cloned()
            .unwrap_or_else(|| remote.scope.clone());
    }
    record
        .history
        .push(history("Обновлено из внешнего трекера"));
    if record.history.len() > 500 {
        record.history.remove(0);
    }
    if let Some(i) = workspace
        .task_workspaces
        .iter()
        .position(|r| r.note_id == local_id)
    {
        workspace.task_workspaces[i] = record;
    } else {
        workspace.task_workspaces.push(record);
    }
    workspace.task_operations.push(json!({"operationID":receipt_id,"namespace":"tracker","createdAt":now(),"request":{"command":"tracker-import","connectionID":c.id,"remoteID":remote.id,"remoteRevision":remote.revision},"fingerprint":digest(&serde_json::to_string(remote)?),"result":{"localID":local_id,"fields":local},"undone":false}));
    // The receipt and canonical imported task commit in one SQLite transaction.
    ensure_tasks(root)?;
    notes::persist(&dir, &workspace)?;
    Ok(local)
}
fn local_fields(root: &Path, c: &TrackerConfiguration, id: &str) -> Result<Option<Fields>> {
    ensure!(crate::ai::live_features_for_input(root,&json!({"taskID":id}))?.tasks,"Задачи выключены в профиле этой папки; синхронизация приостановлена.");
    let workspace = notes::list(root)?;
    Ok(fields(&workspace, id, &c.provider))
}
fn conflict(
    j: &mut Journal,
    c: &TrackerConfiguration,
    b: &Binding,
    local: Option<&Fields>,
    remote: &Remote,
    reason: &str,
) -> Result<()> {
    let key = digest(&format!("{}:{}:{}", c.id, b.scope, b.remote_id));
    let local = serde_json::to_value(local)?;
    let remote = serde_json::to_value(remote)?;
    let fingerprint = digest(&serde_json::to_string(&json!([&local, &remote]))?);
    let value = TrackerConflict {
        id: key.clone(),
        connection: c.id.clone(),
        local_id: b.local_id.clone(),
        title: remote["fields"]["title"]
            .as_str()
            .unwrap_or("Задача")
            .into(),
        reason: reason.into(),
        local,
        remote,
        fingerprint,
    };
    j.conflicts.retain(|v| v.id != key);
    j.conflicts.push(value);
    Ok(())
}
fn detached_key(connection: &str, scope: &str, remote: &str) -> String {
    digest(&format!("{connection}:{scope}:{remote}"))
}
fn journal_detached(j: &Journal, c: &TrackerConfiguration, remote: &Remote) -> bool {
    j.detached
        .contains(&detached_key(&c.id, &remote.scope, &remote.id))
}
fn bind(
    j: &mut Journal,
    c: &TrackerConfiguration,
    remote: Remote,
    local_id: String,
    local: Fields,
) {
    j.bindings
        .retain(|b| !(b.connection == c.id && b.scope == remote.scope && b.remote_id == remote.id));
    j.bindings.push(Binding {
        connection: c.id.clone(),
        scope: remote.scope.clone(),
        remote_id: remote.id.clone(),
        local_id,
        remote,
        local,
    });
}
fn register_error(j: &mut Journal, c: &TrackerConfiguration, error: &anyhow::Error, attempt: u32) {
    if let Some(config) = j.configurations.iter_mut().find(|v| v.id == c.id) {
        let failure = error.downcast_ref::<ApiFailure>();
        config.requires_auth =
            failure.is_some_and(|e| e.code == 401) || error.to_string().contains("Токен истёк");
        config.error = Some(error.to_string());
        config.retry_at = if config.requires_auth {
            None
        } else {
            Some(
                now()
                    + failure
                        .and_then(|f| f.retry_after)
                        .filter(|v| v.is_finite())
                        .unwrap_or((15. * 2f64.powi(attempt.min(8) as i32)).min(3600.))
                        .clamp(5., 86_400.),
            )
        };
    }
}
fn canonical_intent(root: &Path, p: &Pending) -> Result<()> {
    ensure_tasks(root)?;
    let dir = notes::directory(root)?;
    let _lock = notes::lock(&dir)?;
    let mut workspace = notes::load(&dir)?;
    let operation_id = format!("tracker-write-{}", p.id);
    if workspace
        .task_operations
        .iter()
        .any(|v| v["operationID"].as_str() == Some(&operation_id))
    {
        return Ok(());
    }
    workspace.task_operations.push(json!({"operationID":operation_id,"namespace":"tracker","fingerprint":digest(&serde_json::to_string(p)?),"request":{"command":"tracker-write","connectionID":p.connection,"localID":p.local_id,"scope":p.scope,"remoteID":p.remote_id},"result":{"queued":true},"createdAt":now(),"undone":false}));
    ensure_tasks(root)?;
    notes::persist(&dir, &workspace)?;
    Ok(())
}
fn send_pending(
    root: &Path,
    db: &Connection,
    j: &mut Journal,
    api: &Api,
    creation_only: bool,
) -> Result<()> {
    let c = &api.config;
    for pending_id in j
        .pending
        .iter()
        .filter(|p| {
            p.connection == c.id
                && source_tasks(root,&p.local_id)
                && c.scopes.contains(&p.scope)
                && (!creation_only || p.remote_id.is_none())
        })
        .map(|p| p.id.clone())
        .collect::<Vec<_>>()
    {
        let index = j
            .pending
            .iter()
            .position(|p| p.id == pending_id)
            .context("Исчезла операция трекера")?;
        let mut pending = j.pending[index].clone();
        let current_local = local_fields(root, c, &pending.local_id)?;
        if current_local.is_none() {
            if let Some(binding) = j
                .bindings
                .iter()
                .find(|b| b.connection == c.id && b.local_id == pending.local_id)
                .cloned()
            {
                conflict(
                    j,
                    c,
                    &binding,
                    None,
                    &binding.remote,
                    "Локальная задача удалена; внешняя копия сохранена",
                )?;
                save_active(root, db, j)?;
            } else if !pending.sent {
                // A local trash action before the first POST cancels creation.
                j.pending.remove(index);
                save_active(root, db, j)?;
            } else {
                bail!("Локальная задача удалена, а результат отправки ещё не подтверждён. Проверьте внешний список; повторное создание остановлено.");
            }
            continue;
        }
        // Do not send an old queued edit after a newer local edit. A sent
        // operation must first be reconciled, then the newer edit gets queued.
        if !pending.sent && current_local.as_ref() != Some(&pending.desired) {
            j.pending.remove(index);
            save_active(root, db, j)?;
            continue;
        }
        canonical_intent(root, &pending)?;
        let result = (|| -> Result<Remote> {
            if let Some(remote_id) = &pending.remote_id {
                let current = api.get(&pending.scope, remote_id)?;
                ensure!(
                    !current.deleted,
                    "Внешняя задача удалена. Изменения сохранены локально."
                );
                let desired = provider_fields(pending.desired.clone(), &c.provider);
                if current.fields == desired {
                    return Ok(current);
                }
                let base = pending
                    .base
                    .as_ref()
                    .context("Нет исходной версии внешней задачи")?;
                // An interrupted Yandex update may already have changed fields,
                // but not status. Every differing field must equal base or target.
                let safe = merge_safe(&current.fields, &base.fields, &desired);
                if !safe {
                    let binding = j
                        .bindings
                        .iter()
                        .find(|b| b.connection == c.id && b.local_id == pending.local_id)
                        .cloned()
                        .context("Нет связи задачи")?;
                    conflict(
                        j,
                        c,
                        &binding,
                        current_local.as_ref(),
                        &current,
                        "Изменено и здесь, и в трекере",
                    )?;
                    bail!("Обнаружен конфликт. Выберите версию задачи в настройках синхронизации.");
                }
                pending.sent = true;
                pending.attempts = pending.attempts.saturating_add(1);
                j.pending[index] = pending.clone();
                save_active(root, db, j)?;
                api.patch(&pending, &current)
            } else {
                if pending.sent {
                    if let Some(remote) = api.find_creation(&pending)? {
                        return if remote.fields
                            == provider_fields(pending.desired.clone(), &c.provider)
                        {
                            Ok(remote)
                        } else {
                            api.patch(&pending, &remote)
                        };
                    }
                    if c.provider == "google" {
                        bail!("Создание Google Tasks ещё не подтверждено. Повторный POST остановлен, чтобы не создать дубликат. Проверьте позже.");
                    }
                }
                pending.sent = true;
                pending.attempts = pending.attempts.saturating_add(1);
                j.pending[index] = pending.clone();
                save_active(root, db, j)?;
                let remote = api.create(&pending)?;
                if remote.fields == provider_fields(pending.desired.clone(), &c.provider) {
                    Ok(remote)
                } else {
                    api.patch(&pending, &remote)
                }
            }
        })();
        match result {
            Ok(remote) => {
                // Keep local changes made while the network was in flight. The
                // accepted baseline is exactly the sent target, never a reread.
                let local = pending.desired.clone();
                bind(j, c, remote, pending.local_id.clone(), local);
                j.pending.retain(|p| p.id != pending.id);
                save_active(root, db, j)?;
            }
            Err(error) => {
                register_error(j, c, &error, pending.attempts);
                save_active(root, db, j)?;
                return Err(error);
            }
        }
    }
    Ok(())
}
fn merge_safe(current: &Fields, base: &Fields, target: &Fields) -> bool {
    [
        (&current.title, &base.title, &target.title),
        (&current.text, &base.text, &target.text),
        (&current.status, &base.status, &target.status),
        (&current.due, &base.due, &target.due),
        (&current.owner, &base.owner, &target.owner),
    ]
    .iter()
    .all(|(c, b, t)| c == b || c == t)
}
fn sync(
    root: &Path,
    db: &Connection,
    j: &mut Journal,
    c: TrackerConfiguration,
    input: &Value,
) -> Result<Value> {
    ensure_tasks(root)?;
    connection_tasks(root,&c)?;
    ensure!(
        c.enabled && !c.paused,
        "Синхронизация выключена или приостановлена"
    );
    ensure!(!c.scopes.is_empty(), "Выберите списки задач или очереди");
    if !input["force"].as_bool().unwrap_or(false) {
        ensure!(
            c.retry_at.is_none_or(|t| t <= now()),
            "Синхронизация ожидает повторной попытки"
        );
    }
    let api = match Api::new(root, c.clone(), input) {
        Ok(api) => api,
        Err(error) => {
            register_error(j, &c, &error, 0);
            save_active(root, db, j)?;
            return Err(error);
        }
    };
    // Fetch every selected page before any import or outbound mutation. An
    // interrupted pull must never infer remote deletion from a partial list.
    let mut all = vec![];
    let mut import_bytes = 0usize;
    for scope in &c.scopes {
        match api.tasks(scope) {
            Ok(tasks) => {
                import_bytes = import_bytes.saturating_add(
                    tasks
                        .iter()
                        .map(|r| {
                            r.fields.title.len()
                                + r.fields.text.len()
                                + r.fields.owner.len()
                                + r.id.len()
                                + 512
                        })
                        .sum::<usize>(),
                );
                ensure!(
                    import_bytes <= 16 * 1_048_576,
                    "Выбрано слишком много текста задач. Сократите списки."
                );
                all.extend(tasks)
            }
            Err(error) => {
                register_error(j, &c, &error, 1);
                save_active(root, db, j)?;
                return Err(error);
            }
        }
        ensure!(
            all.len() <= MAX_ITEMS,
            "Выбрано больше 9000 задач. Сократите списки."
        );
    }
    // Reconcile creations before importing the fetched snapshot, otherwise an
    // accepted-but-unacknowledged create could become a second local task.
    if c.push_enabled {
        send_pending(root, db, j, &api, true)?;
    }
    let known = all
        .iter()
        .map(|r| (r.scope.clone(), r.id.clone()))
        .collect::<HashSet<_>>();
    let missing = j
        .bindings
        .iter()
        .filter(|b| {
            b.connection == c.id
                && source_tasks(root,&b.local_id)
                && c.scopes.contains(&b.scope)
                && !known.contains(&(b.scope.clone(), b.remote_id.clone()))
        })
        .cloned()
        .collect::<Vec<_>>();
    for binding in missing {
        match api.get(&binding.scope, &binding.remote_id) {
            Ok(remote) => all.push(remote),
            Err(error)
                if error
                    .downcast_ref::<ApiFailure>()
                    .is_some_and(|e| e.code == 404) =>
            {
                let mut remote = binding.remote.clone();
                remote.deleted = true;
                let local = local_fields(root, &c, &binding.local_id)?;
                conflict(
                    j,
                    &c,
                    &binding,
                    local.as_ref(),
                    &remote,
                    "Внешняя задача недоступна; локальная копия сохранена",
                )?;
            }
            Err(error) => {
                register_error(j, &c, &error, 1);
                save_active(root, db, j)?;
                return Err(error);
            }
        }
    }
    for remote in all {
        if journal_detached(j, &c, &remote) {
            continue;
        }
        let existing = j
            .bindings
            .iter()
            .find(|b| b.connection == c.id && b.scope == remote.scope && b.remote_id == remote.id)
            .cloned();
        if let Some(binding) = existing {
            if !source_tasks(root,&binding.local_id) { continue; }
            if j.pending
                .iter()
                .any(|p| p.connection == c.id && p.local_id == binding.local_id)
            {
                continue;
            }
            let local = local_fields(root, &c, &binding.local_id)?;
            if remote.deleted || local.is_none() {
                conflict(
                    j,
                    &c,
                    &binding,
                    local.as_ref(),
                    &remote,
                    if remote.deleted {
                        "Удалено во внешнем трекере; локальная копия сохранена"
                    } else {
                        "Локальная задача удалена; внешняя копия сохранена"
                    },
                )?;
                continue;
            }
            let local = local.unwrap();
            let local_changed = local != binding.local;
            let remote_changed = remote.fields != binding.remote.fields;
            if local_changed
                && remote_changed
                && provider_fields(local.clone(), &c.provider) != remote.fields
            {
                conflict(
                    j,
                    &c,
                    &binding,
                    Some(&local),
                    &remote,
                    "Изменено и здесь, и в трекере",
                )?;
                continue;
            }
            if remote_changed && !local_changed {
                let updated = apply_remote(root, &c, &remote, &binding.local_id, Some(&local))?;
                bind(j, &c, remote, binding.local_id, updated);
            } else if local_changed && provider_fields(local.clone(), &c.provider) != remote.fields
            {
                if c.push_enabled
                    && !j
                        .conflicts
                        .iter()
                        .any(|v| v.connection == c.id && v.local_id == binding.local_id)
                {
                    j.pending.push(Pending {
                        id: id(),
                        connection: c.id.clone(),
                        local_id: binding.local_id,
                        scope: remote.scope.clone(),
                        remote_id: Some(remote.id.clone()),
                        desired: local,
                        base: Some(remote),
                        sent: false,
                        attempts: 0,
                    });
                }
            } else {
                j.conflicts
                    .retain(|v| !(v.connection == c.id && v.local_id == binding.local_id));
                bind(j, &c, remote, binding.local_id, local);
            }
        } else if !remote.deleted {
            let local_id = format!(
                "tracker-{}",
                &digest(&format!("{}:{}:{}", c.id, remote.scope, remote.id))[..48]
            );
            let local = apply_remote(root, &c, &remote, &local_id, None)?;
            bind(j, &c, remote, local_id, local);
        }
        save_active(root, db, j)?;
    }
    save_active(root, db, j)?;
    if c.push_enabled {
        send_pending(root, db, j, &api, false)?;
    }
    if let Some(config) = j.configurations.iter_mut().find(|v| v.id == c.id) {
        config.last_sync = Some(now());
        config.retry_at = None;
        config.error = None;
        config.requires_auth = false;
    }
    save_active(root, db, j)?;
    Ok(state(j))
}

/// Only the native settings/idle coordinator calls this bridge. Credentials are
/// passed in memory for one invocation and are never returned in state/errors.
pub fn request(root: &Path, command: &str, input: &Value) -> Result<Value> {
    if ["tracker-scopes", "tracker-sync", "tracker-export"].contains(&command) || (command == "tracker-resolve" && input["resolution"] != "unlink") { ensure_tasks(root)?; }
    // Reading committed state never waits for the network-session flock. The
    // settings panel can open while a slow provider is being paginated.
    if command == "tracker-state" {
        return Ok(state(&load(&database(root)?)?));
    }
    let directory = notes::directory(root)?;
    let lockpath = directory.join(".tracker-sync.lock");
    if let Ok(info) = fs::symlink_metadata(&lockpath) {
        ensure!(
            info.is_file() && !info.file_type().is_symlink() && info.nlink() == 1,
            "Некорректная блокировка трекера"
        );
    }
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(lockpath)?;
    lock.lock()?;
    let db = database(root)?;
    let mut journal = load(&db)?;
    if command == "tracker-state" {
        return Ok(state(&journal));
    }
    if command == "tracker-configure" {
        let mut c: TrackerConfiguration = serde_json::from_value(input["configuration"].clone())
            .context("Нет параметров подключения")?;
        checked_config(&c)?;
        if c.enabled { ensure_tasks(root)?; connection_tasks(root,&c)?; }
        if c.id.is_empty() {
            c.id = id();
        }
        ensure!(
            c.id.len() <= 128 && c.id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'),
            "Некорректный ID подключения"
        );
        if let Some(old) = journal.configurations.iter().find(|v| v.id == c.id) {
            ensure!(
                input["expectedRevision"].as_u64() == Some(old.revision),
                "Подключение изменилось. Обновите настройки."
            );
            ensure!(
                (old.provider == c.provider
                    && old.account == c.account
                    && old.organization_id == c.organization_id
                    && old.cloud_organization == c.cloud_organization),
                "Для другого аккаунта создайте новое подключение"
            );
            c.last_sync = old.last_sync;
            c.revision = old
                .revision
                .checked_add(1)
                .context("Большая ревизия подключения")?;
        } else {
            ensure!(
                journal.configurations.len() < 10,
                "Можно подключить до 10 аккаунтов трекеров"
            );
            c.revision = 1;
        }
        c.error = None;
        c.retry_at = None;
        c.requires_auth = false;
        journal.configurations.retain(|v| v.id != c.id);
        if c.enabled { ensure_tasks(root)?; connection_tasks(root,&c)?; }
        journal.configurations.push(c);
        save(&db, &journal)?;
        return Ok(state(&journal));
    }
    let connection = input["connectionID"]
        .as_str()
        .context("Нет ID подключения")?;
    let c = configuration(&journal, connection)?;
    match command {
        "tracker-scopes" => Api::new(root, c, input)?.scopes(),
        "tracker-sync" => sync(root, &db, &mut journal, c, input),
        "tracker-disconnect" => {
            ensure!(
                input["expectedRevision"].as_u64() == Some(c.revision),
                "Подключение изменилось. Обновите настройки."
            );
            // Disable first; never erase local tasks, receipts or uncertain sends.
            if let Some(value) = journal
                .configurations
                .iter_mut()
                .find(|v| v.id == connection)
            {
                value.enabled = false;
                value.push_enabled = false;
                value.revision += 1;
                value.requires_auth = false;
                value.error = None;
            }
            save(&db, &journal)?;
            Ok(state(&journal))
        }
        "tracker-export" => {
            ensure!(
                c.enabled && c.push_enabled && !c.paused,
                "Включите отправку изменений для этого подключения"
            );
            let local = input["taskID"]
                .as_str()
                .context("Нет задачи")?
                .strip_prefix("manual:")
                .unwrap_or(input["taskID"].as_str().unwrap());
            let scope = input["scope"].as_str().context("Нет списка назначения")?;
            ensure!(
                c.scopes.iter().any(|s| s == scope),
                "Список не выбран в подключении"
            );
            ensure!(
                !journal.bindings.iter().any(|b| b.local_id == local)
                    && !journal.pending.iter().any(|p| p.local_id == local),
                "Задача уже связана с трекером или ожидает отправки"
            );
            let desired = local_fields(root, &c, local)?.context("Локальная задача недоступна")?;
            ensure!(!desired.title.trim().is_empty(), "Задаче нужно название");
            if !desired.due.is_empty() {
                date(&desired.due)?;
            }
            journal.pending.push(Pending {
                id: id(),
                connection: c.id.clone(),
                local_id: local.into(),
                scope: scope.into(),
                remote_id: None,
                desired,
                base: None,
                sent: false,
                attempts: 0,
            });
            if command != "tracker-resolve" || input["resolution"] != "unlink" { ensure_tasks(root)?; }
            save(&db, &journal)?;
            Ok(state(&journal))
        }
        "tracker-resolve" => {
            let conflict_id = input["conflictID"].as_str().context("Нет конфликта")?;
            let conflict = journal
                .conflicts
                .iter()
                .find(|v| v.id == conflict_id && v.connection == connection)
                .cloned()
                .context("Конфликт уже разрешён")?;
            ensure!(
                input["fingerprint"].as_str() == Some(&conflict.fingerprint),
                "Конфликт изменился. Обновите сравнение."
            );
            let resolution = input["resolution"].as_str().context("Выберите версию")?;
            let binding = journal
                .bindings
                .iter()
                .find(|b| b.connection == connection && b.local_id == conflict.local_id)
                .cloned()
                .context("Связь задачи не найдена")?;
            if resolution == "unlink" {
                journal
                    .detached
                    .push(detached_key(connection, &binding.scope, &binding.remote_id));
                journal
                    .bindings
                    .retain(|b| !(b.connection == connection && b.local_id == binding.local_id));
                journal
                    .pending
                    .retain(|p| !(p.connection == connection && p.local_id == binding.local_id));
            } else {
                let api = Api::new(root, c.clone(), input)?;
                let remote = api.get(&binding.scope, &binding.remote_id)?;
                let local = local_fields(root, &c, &binding.local_id)?;
                ensure!(
                    serde_json::to_value(&local)? == conflict.local
                        && serde_json::to_value(&remote)? == conflict.remote,
                    "Данные изменились после сравнения. Выполните синхронизацию заново."
                );
                ensure!(
                    !remote.deleted,
                    "Внешняя задача удалена. Сохраните локальную копию, разорвав связь."
                );
                if resolution == "remote" {
                    let fields =
                        apply_remote(root, &c, &remote, &binding.local_id, local.as_ref())?;
                    bind(&mut journal, &c, remote, binding.local_id.clone(), fields);
                    journal.pending.retain(|p| {
                        !(p.connection == connection && p.local_id == binding.local_id)
                    });
                } else if resolution == "local" {
                    ensure!(c.push_enabled, "Отправка изменений выключена");
                    let local = local.context("Локальная задача удалена")?;
                    journal.pending.retain(|p| {
                        !(p.connection == connection && p.local_id == binding.local_id)
                    });
                    journal.pending.push(Pending {
                        id: id(),
                        connection: c.id.clone(),
                        local_id: binding.local_id.clone(),
                        scope: binding.scope.clone(),
                        remote_id: Some(binding.remote_id.clone()),
                        desired: local,
                        base: Some(remote),
                        sent: false,
                        attempts: 0,
                    });
                } else {
                    bail!("Неизвестный способ разрешения конфликта");
                }
            }
            journal.conflicts.retain(|v| v.id != conflict_id);
            if command != "tracker-resolve" || input["resolution"] != "unlink" { ensure_tasks(root)?; }
            save(&db, &journal)?;
            Ok(state(&journal))
        }
        _ => bail!("Неизвестная команда синхронизации трекера"),
    }
}

#[cfg(test)]
mod tests;
