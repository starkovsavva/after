//! Explicitly approved immutable agent shares. This store is independent of
//! legacy task grants/settings. It is not a sandbox for same-user shell access.
//! The user reviews exact copies before approval. Edits/deletion of originals
//! do not edit or revoke the copy; revocation is a distinct atomic action here.
use anyhow::{bail, ensure, Context, Result};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;
use uuid::Uuid;

pub mod stdio;
const MAX_SOURCES: usize = 50;
const MAX_SOURCE_BYTES: usize = 64 * 1024;
const MAX_PACKAGE_BYTES: usize = 1024 * 1024;
const PENDING_TTL: i64 = 600;
const SHARE_TTL: i64 = 24 * 3600;
fn now() -> i64 {
    chrono::Utc::now().timestamp()
}
fn uuid() -> String {
    Uuid::new_v4().to_string()
}
fn hash(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}
fn text<'a>(value: &'a Value, key: &str, max: usize) -> Result<&'a str> {
    let s = value[key]
        .as_str()
        .context("Отсутствует текстовый параметр")?;
    ensure!(
        !s.is_empty() && s.len() <= max && !s.contains('\0'),
        "Некорректный текстовый параметр"
    );
    Ok(s)
}
fn ordinary(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(info) => ensure!(
            info.is_file() && !info.file_type().is_symlink() && info.nlink() == 1,
            "Некорректное хранилище снимков"
        ),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
    }
    Ok(())
}
fn directory(root: &Path) -> Result<PathBuf> {
    ensure!(root.is_absolute(), "Нужен абсолютный путь библиотеки");
    crate::notes::directory(root)?;
    let dir = fs::canonicalize(root)?.join("agent-shares");
    match fs::symlink_metadata(&dir) {
        Ok(info) => ensure!(
            info.is_dir() && !info.file_type().is_symlink(),
            "Некорректная папка снимков"
        ),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => fs::create_dir(&dir)?,
        Err(e) => return Err(e.into()),
    }
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    Ok(dir)
}
/// Every protected write holds this shared gate through the actual stdout
/// write. Revocation/master disable obtains exclusive access, even cross-process.
fn gate(root: &Path, exclusive: bool) -> Result<File> {
    let path = directory(root)?.join("publication.lock");
    ordinary(&path)?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    ensure!(
        file.metadata()?.nlink() == 1,
        "Некорректная блокировка снимков"
    );
    if exclusive {
        file.lock()?;
    } else {
        file.lock_shared()?;
    }
    Ok(file)
}
fn open(root: &Path) -> Result<Connection> {
    let dir = directory(root)?;
    let path = dir.join("shares.sqlite");
    ordinary(&path)?;
    for s in ["-journal", "-wal", "-shm"] {
        ordinary(&dir.join(format!("shares.sqlite{s}")))?;
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
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    db.busy_timeout(Duration::from_secs(3))?;
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    ensure!(
        version == 0 || version == 1,
        "Неподдерживаемая версия снимков"
    );
    db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL; PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON;
        CREATE TABLE IF NOT EXISTS share_settings(singleton INTEGER PRIMARY KEY CHECK(singleton=1),enabled INTEGER NOT NULL,revision INTEGER NOT NULL);
        INSERT OR IGNORE INTO share_settings VALUES(1,0,0);
        CREATE TABLE IF NOT EXISTS share_sessions(id TEXT PRIMARY KEY,secret_hash TEXT NOT NULL,code TEXT NOT NULL UNIQUE,label TEXT NOT NULL,created INTEGER NOT NULL,last_seen INTEGER NOT NULL,closed INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS share_drafts(id TEXT PRIMARY KEY,task_id TEXT NOT NULL,title TEXT NOT NULL,created INTEGER NOT NULL,expires INTEGER NOT NULL,digest TEXT NOT NULL,package TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS shares(id TEXT PRIMARY KEY,session_id TEXT NOT NULL UNIQUE,task_id TEXT NOT NULL,title TEXT NOT NULL,created INTEGER NOT NULL,expires INTEGER NOT NULL,revoked INTEGER NOT NULL,digest TEXT NOT NULL,package TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS share_reports(id TEXT PRIMARY KEY,share_id TEXT NOT NULL REFERENCES shares(id),created INTEGER NOT NULL,text TEXT NOT NULL,artifacts TEXT NOT NULL,evidence TEXT NOT NULL,completed INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS share_writes(share_id TEXT NOT NULL,operation_id TEXT NOT NULL,request_hash TEXT NOT NULL,result TEXT NOT NULL,PRIMARY KEY(share_id,operation_id));
        CREATE TABLE IF NOT EXISTS share_reads(share_id TEXT NOT NULL,source_id TEXT NOT NULL,fingerprint TEXT NOT NULL,PRIMARY KEY(share_id,source_id));
        PRAGMA user_version=1;")?;
    Ok(db)
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Source {
    id: String,
    kind: String,
    title: String,
    text: String,
    fingerprint: String,
    origin_id: String,
    revision: u64,
}
impl Source {
    fn public(&self, full: bool) -> Value {
        json!({"id":self.id,"kind":self.kind,"title":self.title,"fingerprint":self.fingerprint,"revision":self.revision,
    "text":if full {self.text.as_str()}else{prefix(&self.text,700)},"truncated":!full&&self.text.len()>700})
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Package {
    task_id: String,
    task_title: String,
    created_at: i64,
    sources: Vec<Source>,
}
fn prefix(value: &str, max: usize) -> &str {
    let mut end = value.len().min(max);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    &value[..end]
}
fn settings(db: &Connection) -> Result<Value> {
    db.query_row(
        "SELECT enabled,revision FROM share_settings WHERE singleton=1",
        [],
        |r| Ok(json!({"enabled":r.get::<_,i64>(0)?!=0,"revision":r.get::<_,i64>(1)?})),
    )
    .map_err(Into::into)
}
fn source_from_note(root: &Path, id: &str, revision: u64) -> Result<Source> {
    let note = crate::notes::load_note_snapshot(root, id)?;
    ensure!(
        note.kind == "note" && note.trashed_at.is_none() && note.revision == revision,
        "Заметка изменилась. Обновите выбор."
    );
    ensure!(
        crate::ai::FeatureResolver::new(root)?
            .features_for(&json!({"noteID":id}))?
            .knowledge_base,
        "Заметка недоступна для базы знаний"
    );
    ensure!(
        note.text.len() <= MAX_SOURCE_BYTES,
        "Заметка слишком большая для снимка"
    );
    let title = if note.title.trim().is_empty() {
        prefix(note.text.lines().next().unwrap_or("Заметка"), 200).to_owned()
    } else {
        note.title.clone()
    };
    Ok(Source {
        id: uuid(),
        kind: "note".into(),
        title,
        text: note.text.clone(),
        fingerprint: crate::knowledge::note_fingerprint(&note),
        origin_id: note.id,
        revision: note.revision,
    })
}
fn prepare(root: &Path, input: &Value) -> Result<Value> {
    let task_id = text(input, "taskID", 256)?;
    let task =
        crate::task_workspace::dispatch(root, &json!({"command":"task-get","taskID":task_id}))?;
    ensure!(
        crate::ai::live_features_for_input(root, &json!({"taskID":task_id}))?.tasks,
        "Задачи выключены"
    );
    let selected = input["sources"].as_array().context("Выберите заметки")?;
    ensure!(
        !selected.is_empty() && selected.len() <= MAX_SOURCES,
        "Выберите от 1 до 50 заметок"
    );
    let task_text = task["text"].as_str().unwrap_or("");
    ensure!(
        task_text.len() <= MAX_SOURCE_BYTES,
        "Задача слишком большая для снимка"
    );
    let mut package = Package {
        task_id: task_id.into(),
        task_title: task["title"].as_str().unwrap_or("Задача").into(),
        created_at: now(),
        sources: vec![Source {
            id: uuid(),
            kind: "task".into(),
            title: task["title"].as_str().unwrap_or("Задача").into(),
            text: task_text.into(),
            fingerprint: hash(&task.to_string()),
            origin_id: task_id.into(),
            revision: task["revision"].as_u64().unwrap_or(0),
        }],
    };
    let mut seen = HashSet::new();
    for value in selected {
        let id = text(value, "noteID", 256)?;
        ensure!(seen.insert(id), "Повторная заметка");
        let revision = value["revision"].as_u64().context("Нет версии заметки")?;
        package.sources.push(source_from_note(root, id, revision)?);
    }
    let serialized = serde_json::to_string(&package)?;
    ensure!(
        serialized.len() <= MAX_PACKAGE_BYTES,
        "Снимок превышает 1 МБ. Уменьшите область."
    );
    let db = open(root)?;
    db.execute("DELETE FROM share_drafts WHERE expires<=?1", [now()])?;
    let count: i64 = db.query_row("SELECT count(*) FROM share_drafts", [], |r| r.get(0))?;
    ensure!(count < 50, "Слишком много открытых предпросмотров");
    let id = uuid();
    let digest = hash(&serialized);
    db.execute(
        "INSERT INTO share_drafts VALUES(?1,?2,?3,?4,?5,?6,?7)",
        params![
            id,
            task_id,
            package.task_title,
            now(),
            now() + PENDING_TTL,
            digest,
            serialized
        ],
    )?;
    Ok(
        json!({"id":id,"digest":digest,"createdAt":package.created_at,"title":package.task_title,"sources":package.sources.iter().map(|s|s.public(true)).collect::<Vec<_>>()}),
    )
}
fn approve(root: &Path, input: &Value) -> Result<Value> {
    let _gate = gate(root, true)?;
    let mut db = open(root)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(
        settings(&tx)?["enabled"] == true,
        "Включите передачу снимков агентам"
    );
    let draft_id = text(input, "draftID", 64)?;
    let expected = text(input, "digest", 64)?;
    let session = text(input, "sessionID", 64)?;
    let row: Option<(String, String, String, String)> = tx
        .query_row(
            "SELECT task_id,title,digest,package FROM share_drafts WHERE id=?1 AND expires>?2",
            params![draft_id, now()],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()?;
    let (task, title, digest, package) =
        row.context("Предпросмотр истёк. Подготовьте новый снимок.")?;
    ensure!(
        digest == expected && hash(&package) == digest,
        "Снимок изменился"
    );
    let pending:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM share_sessions s WHERE s.id=?1 AND s.closed=0 AND s.last_seen>?2 AND NOT EXISTS(SELECT 1 FROM shares g WHERE g.session_id=s.id))",params![session,now()-PENDING_TTL],|r|r.get(0))?;
    ensure!(pending, "Подключение завершено или уже подтверждено");
    let count: i64 = tx.query_row("SELECT count(*) FROM shares", [], |r| r.get(0))?;
    ensure!(count < 1000, "Достигнут предел сохранённых снимков");
    let id = uuid();
    tx.execute(
        "INSERT INTO shares VALUES(?1,?2,?3,?4,?5,?6,0,?7,?8)",
        params![
            id,
            session,
            task,
            title,
            now(),
            now() + SHARE_TTL,
            digest,
            package
        ],
    )?;
    tx.execute("DELETE FROM share_drafts WHERE id=?1", [draft_id])?;
    tx.commit()?;
    Ok(json!({"id":id,"expiresAt":now()+SHARE_TTL,"digest":digest}))
}
/// A credential is generated by the server, retained only in this process, and
/// never accepted from a tool argument or exposed in responses/configuration.
struct Session {
    id: String,
    secret: String,
}
fn connect(root: &Path, label: &str) -> Result<Session> {
    let db = open(root)?;
    db.execute("UPDATE share_sessions SET closed=1 WHERE last_seen<=?1 AND NOT EXISTS(SELECT 1 FROM shares WHERE shares.session_id=share_sessions.id AND shares.revoked=0 AND shares.expires>?2)",params![now()-PENDING_TTL,now()])?;
    let pending: i64 = db.query_row(
        "SELECT count(*) FROM share_sessions WHERE closed=0",
        [],
        |r| r.get(0),
    )?;
    ensure!(pending < 100, "Слишком много подключений");
    let session = Session {
        id: uuid(),
        secret: format!("{}{}", uuid(), uuid()),
    };
    for _ in 0..8 {
        let code = Uuid::new_v4().simple().to_string()[..8].to_uppercase();
        let inserted=db.execute("INSERT OR IGNORE INTO share_sessions(id,secret_hash,code,label,created,last_seen) VALUES(?1,?2,?3,?4,?5,?5)",params![session.id,hash(&session.secret),code,prefix(label,100),now()])?;
        if inserted == 1 {
            return Ok(session);
        }
    }
    bail!("Не удалось создать код подключения")
}
fn authenticated(db: &Connection, s: &Session) -> Result<()> {
    let valid: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM share_sessions WHERE id=?1 AND secret_hash=?2 AND closed=0)",
        params![s.id, hash(&s.secret)],
        |r| r.get(0),
    )?;
    ensure!(valid, "Подключение завершено");
    Ok(())
}
/// Rotate a transport's private credential without reopening stdio. This only
/// requests new consent: every prior share is revoked and no grant is copied.
/// The caller must hold the exclusive publication gate through its response.
fn renew(root: &Path, previous: &Session) -> Result<Session> {
    let mut db = open(root)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    // Expired pending sessions may already have been closed by cleanup. Their
    // in-process credential can request a fresh code but cannot authorize data.
    let label: String = tx
        .query_row(
            "SELECT label FROM share_sessions WHERE id=?1 AND secret_hash=?2",
            params![previous.id, hash(&previous.secret)],
            |r| r.get(0),
        )
        .optional()?
        .context("Подключение недоступно")?;
    tx.execute(
        "UPDATE shares SET revoked=1 WHERE session_id=?1",
        [&previous.id],
    )?;
    tx.execute(
        "UPDATE share_sessions SET closed=1 WHERE id=?1",
        [&previous.id],
    )?;
    let next = Session {
        id: uuid(),
        secret: format!("{}{}", uuid(), uuid()),
    };
    for _ in 0..8 {
        let code = Uuid::new_v4().simple().to_string()[..8].to_uppercase();
        let inserted = tx.execute("INSERT OR IGNORE INTO share_sessions(id,secret_hash,code,label,created,last_seen) VALUES(?1,?2,?3,?4,?5,?5)", params![next.id,hash(&next.secret),code,label,now()])?;
        if inserted == 1 {
            tx.execute("DELETE FROM share_sessions WHERE id=?1 AND NOT EXISTS(SELECT 1 FROM shares WHERE session_id=?1)", [&previous.id])?;
            tx.commit()?;
            return Ok(next);
        }
    }
    bail!("Не удалось создать код подключения")
}
fn authorized(db: &Connection, s: &Session) -> Result<(String, Package)> {
    authenticated(db, s)?;
    ensure!(
        settings(db)?["enabled"] == true,
        "Передача снимков выключена"
    );
    let row: Option<(String, String, String)> = db
        .query_row(
            "SELECT id,digest,package FROM shares WHERE session_id=?1 AND revoked=0 AND expires>?2",
            params![s.id, now()],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    let (id, digest, serialized) =
        row.context("Подтвердите снимок в After или запросите новый доступ")?;
    ensure!(hash(&serialized) == digest, "Снимок повреждён");
    Ok((id, serde_json::from_str(&serialized)?))
}
fn status(root: &Path, s: &Session) -> Result<Value> {
    let db = open(root)?;
    authenticated(&db, s)?;
    db.execute(
        "UPDATE share_sessions SET last_seen=?1 WHERE id=?2",
        params![now(), s.id],
    )?;
    let code: String = db.query_row(
        "SELECT code FROM share_sessions WHERE id=?1",
        [&s.id],
        |r| r.get(0),
    )?;
    let snapshot_id = authorized(&db, s).ok().map(|(id, _)| id);
    let approved = snapshot_id.is_some();
    let previously_approved: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM shares WHERE session_id=?1)",
        [&s.id],
        |r| r.get(0),
    )?;
    let instructions = if !approved && previously_approved {
        "The previous snapshot is no longer available. Call after_share_request_snapshot to obtain a new connection code, then ask the user to inspect and approve a new snapshot in After. This does not grant access automatically."
    } else {
        "In After open the task menu → Share a snapshot with an agent. Match this connection code, inspect the exact materials and approve. Originals are not live-linked; access expires after 24 hours or explicit revocation. Call after_share_sources to list all approved sources. To request a different or refreshed copy on this connection, call after_share_request_snapshot; it revokes the current copy and requires new user approval."
    };
    Ok(
        json!({"approved":approved,"snapshotID":snapshot_id,"connectionCode":code,"requiresNewRequest":!approved&&previously_approved,"instructions":instructions}),
    )
}
fn strict_args(args: &Value, keys: &[&str]) -> Result<()> {
    let obj = args.as_object().context("Ожидается объект параметров")?;
    ensure!(
        obj.keys().all(|k| keys.contains(&k.as_str())),
        "Неизвестный параметр инструмента"
    );
    Ok(())
}
fn tool(db: &mut Connection, s: &Session, name: &str, args: &Value) -> Result<Value> {
    let (share, package) = authorized(db, s)?;
    match name {
        "after_share_sources" => {
            strict_args(args, &[])?;
            let sources = package
                .sources
                .iter()
                .map(|source| {
                    json!({
                        "id":source.id,"kind":source.kind,"title":source.title,
                        "fingerprint":source.fingerprint,"revision":source.revision
                    })
                })
                .collect::<Vec<_>>();
            Ok(
                json!({"snapshotID":share,"sources":sources,"capturedAt":package.created_at,"scope":"approvedImmutableSnapshot"}),
            )
        }
        "after_share_search" => {
            strict_args(args, &["query", "limit"])?;
            let query = text(args, "query", 500)?;
            let limit = match args.get("limit") {
                None => 8,
                Some(v) => v.as_u64().context("Лимит должен быть целым числом")?,
            };
            ensure!((1..=20).contains(&limit), "Некорректный лимит");
            let matcher = crate::search::QueryMatcher::new(query)?;
            ensure!(matcher.has_terms(), "Добавьте слова для поиска");
            let mut sources = package
                .sources
                .iter()
                .filter(|src| matcher.matches(&src.title) || matcher.matches(&src.text))
                .collect::<Vec<_>>();
            sources.sort_by(|a, b| {
                matcher
                    .matches(&b.title)
                    .cmp(&matcher.matches(&a.title))
                    .then_with(|| a.id.cmp(&b.id))
            });
            let truncated = sources.len() > limit as usize;
            let sources = sources
                .into_iter()
                .take(limit as usize)
                .map(|v| v.public(false))
                .collect::<Vec<_>>();
            Ok(
                json!({"snapshotID":share,"sources":sources,"truncated":truncated,"capturedAt":package.created_at,"scope":"approvedImmutableSnapshot"}),
            )
        }
        "after_share_read" => {
            strict_args(args, &["sourceID", "fingerprint"])?;
            let source_id = text(args, "sourceID", 64)?;
            let fingerprint = text(args, "fingerprint", 64)?;
            let source = package
                .sources
                .iter()
                .find(|v| v.id == source_id && v.fingerprint == fingerprint)
                .context("Источник не входит в этот снимок")?;
            db.execute(
                "INSERT OR IGNORE INTO share_reads VALUES(?1,?2,?3)",
                params![share, source.id, source.fingerprint],
            )?;
            let mut result = source.public(true);
            result["snapshotID"] = json!(share);
            Ok(result)
        }
        "after_share_report" => {
            strict_args(
                args,
                &[
                    "snapshotID",
                    "operationID",
                    "text",
                    "artifacts",
                    "evidence",
                    "completed",
                ],
            )?;
            // A receipt fence, not an authority selector: the transport already
            // selected its only grant. Stale work cannot enter a renewed share,
            // including reports with no evidence or an idempotent retry.
            ensure!(
                text(args, "snapshotID", 64)? == share,
                "Отчёт относится к другому снимку"
            );
            let operation = text(args, "operationID", 128)?;
            let body = text(args, "text", 20_000)?;
            let digest = hash(&args.to_string());
            let old:Option<(String,String)>=db.query_row("SELECT request_hash,result FROM share_writes WHERE share_id=?1 AND operation_id=?2",params![share,operation],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
            if let Some((old, result)) = old {
                ensure!(old == digest, "Повтор операции изменён");
                return Ok(serde_json::from_str(&result)?);
            }
            let artifacts = match args.get("artifacts") {
                None => vec![],
                Some(v) => v
                    .as_array()
                    .context("Артефакты должны быть списком")?
                    .clone(),
            };
            ensure!(artifacts.len() <= 8, "Слишком много артефактов");
            for artifact in &artifacts {
                strict_args(artifact, &["title", "text", "url"])?;
                text(artifact, "title", 300)?;
                let content = match artifact.get("text") {
                    None => "",
                    Some(v) => v.as_str().context("Текст артефакта должен быть строкой")?,
                };
                ensure!(content.len() <= 8_000, "Артефакт слишком большой");
                if let Some(value) = artifact.get("url") {
                    let url = value
                        .as_str()
                        .context("Ссылка артефакта должна быть строкой")?;
                    let parsed = reqwest::Url::parse(url)?;
                    ensure!(
                        url.len() <= 4000
                            && ["https", "http"].contains(&parsed.scheme())
                            && parsed.host_str().is_some()
                            && parsed.username().is_empty()
                            && parsed.password().is_none(),
                        "Недопустимая ссылка артефакта"
                    );
                }
            }
            let evidence = match args.get("evidence") {
                None => vec![],
                Some(v) => v
                    .as_array()
                    .context("Источники должны быть списком")?
                    .clone(),
            };
            ensure!(
                evidence.len() <= MAX_SOURCES + 1,
                "Слишком много источников"
            );
            let mut normalized_evidence = Vec::new();
            let mut seen = HashSet::new();
            for item in &evidence {
                strict_args(item, &["sourceID", "fingerprint"])?;
                let id = text(item, "sourceID", 64)?;
                let fp = text(item, "fingerprint", 64)?;
                ensure!(seen.insert(id), "Повтор источника");
                let read:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM share_reads WHERE share_id=?1 AND source_id=?2 AND fingerprint=?3)",params![share,id,fp],|r|r.get(0))?;
                ensure!(read, "Сначала прочитайте цитируемый источник этого снимка");
                let source = package
                    .sources
                    .iter()
                    .find(|source| source.id == id && source.fingerprint == fp)
                    .context("Источник не входит в снимок")?;
                normalized_evidence
                    .push(json!({"sourceID":id,"fingerprint":fp,"title":source.title}));
            }
            let completed = match args.get("completed") {
                None => false,
                Some(v) => v
                    .as_bool()
                    .context("Статус должен быть логическим значением")?,
            };
            let id = uuid();
            let result = json!({"id":id,"completed":completed,"taskStatusChanged":false});
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let count: i64 = tx.query_row(
                "SELECT count(*) FROM share_reports WHERE share_id=?1",
                [&share],
                |r| r.get(0),
            )?;
            ensure!(count < 100, "Достигнут предел отчётов");
            tx.execute(
                "INSERT INTO share_reports VALUES(?1,?2,?3,?4,?5,?6,?7)",
                params![
                    id,
                    share,
                    now(),
                    body,
                    serde_json::to_string(&artifacts)?,
                    serde_json::to_string(&normalized_evidence)?,
                    completed as i64
                ],
            )?;
            tx.execute(
                "INSERT INTO share_writes VALUES(?1,?2,?3,?4)",
                params![share, operation, digest, result.to_string()],
            )?;
            tx.commit()?;
            Ok(result)
        }
        _ => bail!("Неизвестный инструмент снимка"),
    }
}
fn history(root: &Path, input: &Value) -> Result<Value> {
    let db = open(root)?;
    let task = text(input, "taskID", 256)?;
    let offset = input["offset"].as_u64().unwrap_or(0);
    ensure!(offset <= 100_000, "Некорректная страница");
    let mut q=db.prepare("SELECT id,title,created,expires,revoked,digest,json_array_length(package,'$.sources') FROM shares WHERE task_id=?1 ORDER BY created DESC,id LIMIT 1000")?;
    let shares=q.query_map([task],|r|Ok(json!({"id":r.get::<_,String>(0)?,"title":r.get::<_,String>(1)?,"createdAt":r.get::<_,i64>(2)?,"expiresAt":r.get::<_,i64>(3)?,"revoked":r.get::<_,i64>(4)?!=0,"digest":r.get::<_,String>(5)?,"sourceCount":r.get::<_,i64>(6)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    let total: i64 = db.query_row(
        "SELECT count(*) FROM share_reports r JOIN shares s ON s.id=r.share_id WHERE s.task_id=?1",
        [task],
        |r| r.get(0),
    )?;
    let mut q=db.prepare("SELECT r.id,r.share_id,r.created,r.text,r.artifacts,r.evidence,r.completed FROM share_reports r JOIN shares s ON s.id=r.share_id WHERE s.task_id=?1 ORDER BY r.created DESC,r.id LIMIT 10 OFFSET ?2")?;
    let reports=q.query_map(params![task,offset as i64],|r|Ok(json!({"id":r.get::<_,String>(0)?,"shareID":r.get::<_,String>(1)?,"createdAt":r.get::<_,i64>(2)?,"text":r.get::<_,String>(3)?,"artifacts":serde_json::from_str::<Value>(&r.get::<_,String>(4)?).unwrap_or(json!([])),"evidence":serde_json::from_str::<Value>(&r.get::<_,String>(5)?).unwrap_or(json!([])),"completed":r.get::<_,i64>(6)?!=0})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    let next = offset + reports.len() as u64;
    Ok(
        json!({"shares":shares,"reports":reports,"nextOffset":if next<(total as u64){Some(next)}else{None}}),
    )
}
/// Native-only control surface; these commands are NOT exposed as MCP tools.
pub fn dispatch(root: &Path, input: &Value) -> Result<Value> {
    match input["command"].as_str().context("Нет команды")? {
        "agent-share-settings" => {
            let _gate = gate(root, true)?;
            let mut db = open(root)?;
            if let Some(enabled) = input["enabled"].as_bool() {
                let revision = input["expectedRevision"]
                    .as_i64()
                    .context("Нет ревизии настроек")?;
                let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
                ensure!(tx.execute("UPDATE share_settings SET enabled=?1,revision=revision+1 WHERE singleton=1 AND revision=?2",params![enabled as i64,revision])?==1,"Настройки изменились");
                if !enabled {
                    tx.execute("UPDATE shares SET revoked=1 WHERE revoked=0", [])?;
                }
                tx.commit()?;
            }
            settings(&db)
        }
        "agent-share-preview" => prepare(root, input),
        "agent-share-approve" => approve(root, input),
        "agent-share-connections" => {
            let db = open(root)?;
            let mut q=db.prepare("SELECT s.id,s.code,s.label,s.created FROM share_sessions s WHERE s.closed=0 AND s.last_seen>?1 AND NOT EXISTS(SELECT 1 FROM shares g WHERE g.session_id=s.id) ORDER BY s.created DESC LIMIT 100")?;
            let sessions=q.query_map([now()-PENDING_TTL],|r|Ok(json!({"id":r.get::<_,String>(0)?,"code":r.get::<_,String>(1)?,"label":r.get::<_,String>(2)?,"createdAt":r.get::<_,i64>(3)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
            Ok(json!({"connections":sessions}))
        }
        "agent-share-revoke" => {
            let _gate = gate(root, true)?;
            let db = open(root)?;
            let id = text(input, "shareID", 64)?;
            db.execute("UPDATE shares SET revoked=1 WHERE id=?1", [id])?;
            Ok(json!({"revoked":true}))
        }
        "agent-share-history" => history(root, input),
        "agent-share-snapshot" => {
            let db = open(root)?;
            let id = text(input, "shareID", 64)?;
            let serialized: String = db
                .query_row("SELECT package FROM shares WHERE id=?1", [id], |r| r.get(0))
                .optional()?
                .context("Снимок недоступен")?;
            let package: Package = serde_json::from_str(&serialized)?;
            Ok(
                json!({"title":package.task_title,"createdAt":package.created_at,"sources":package.sources.iter().map(|s|s.public(true)).collect::<Vec<_>>()}),
            )
        }
        _ => bail!("Неизвестная команда снимков"),
    }
}

#[cfg(test)]
mod tests;
