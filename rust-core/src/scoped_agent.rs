//! Private foundation for a future broker, not an agent-facing API.
//!
//! Grants never become legacy task materials. `Session` is an in-process
//! capability that the future native broker must keep out of prompts, logs,
//! command arguments and tool responses. No route exposes this module yet.
//! Reports and completion are isolated in this store; no legacy claim or
//! agent-facing route is created. A trusted transport is still required.
use anyhow::{ensure, Context, Result};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::time::Duration;
use uuid::Uuid;

const DB: &str = "kb-agent-grants.sqlite";
const MAX_SOURCES: usize = 50;
const MAX_LIFETIME: i64 = 24 * 60 * 60;
const MAX_RESPONSE: usize = 24 * 1024;

// A private, descriptor-bound transport prototype. No UI, CLI, FFI or MCP
// route exposes it; it is not a complete publication fence for old clients.
mod transport;

#[derive(Clone, Serialize, Deserialize, PartialEq)]
struct Source {
    id: String,
    folder: Option<String>,
    revision: u64,
    policy: String,
    // The same ID and revision may be reused after an old client deletes and
    // recreates a note. Old stored grants without this field fail closed.
    #[serde(default)]
    fingerprint: String,
    #[serde(default)]
    created_at: f64,
}

/// Never serialized, copied into tool output or accepted as a model argument.
struct Session {
    run: String,
    capability: String,
}

fn now() -> i64 { chrono::Utc::now().timestamp() }
fn id() -> String { Uuid::new_v4().to_string() }
fn digest(value: &str) -> String { format!("{:x}", Sha256::digest(value.as_bytes())) }
fn ordinary(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(m) => { ensure!(m.is_file() && !m.file_type().is_symlink() && m.nlink() == 1, "Некорректное хранилище разрешений"); Ok(true) }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e.into()),
    }
}
/// Serializes an explicit grant revocation against publication by the new
/// private transport, including across broker processes. This does NOT fence
/// old binaries which modify source/settings without this lock, so it is not
/// sufficient to expose the transport to an external agent.
fn publication_gate(root: &Path, exclusive: bool) -> Result<File> {
    let directory=crate::notes::directory(root)?;
    let path=directory.join(".scoped-publication.lock");
    ordinary(&path)?;
    let file=OpenOptions::new().read(true).write(true).create(true).truncate(false)
        .mode(0o600).custom_flags(libc::O_NOFOLLOW).open(path)?;
    let metadata=file.metadata()?;
    ensure!(metadata.is_file() && metadata.nlink()==1,"Некорректная блокировка разрешений");
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    if exclusive { file.lock()?; } else { file.lock_shared()?; }
    Ok(file)
}
fn open(root: &Path) -> Result<Connection> {
    open_with_timeout(root,Duration::from_secs(5))
}
fn open_with_timeout(root: &Path, timeout:Duration) -> Result<Connection> {
    crate::notes::directory(root)?;
    let root = fs::canonicalize(root)?;
    let path = root.join(DB);
    ordinary(&path)?;
    for suffix in ["-wal", "-shm", "-journal"] { ordinary(&root.join(format!("{DB}{suffix}")))?; }
    let file = OpenOptions::new().read(true).write(true).create(true).truncate(false)
        .mode(0o600).custom_flags(libc::O_NOFOLLOW).open(&path)?;
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE | OpenFlags::SQLITE_OPEN_NOFOLLOW)?;
    db.busy_timeout(timeout)?;
    db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS grants(id TEXT PRIMARY KEY,task TEXT NOT NULL,task_policy TEXT NOT NULL,epoch INTEGER NOT NULL,expires INTEGER NOT NULL,revoked INTEGER NOT NULL,sources TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS scoped_meta(key TEXT PRIMARY KEY,value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS scoped_source_deletions(note_id TEXT NOT NULL,workspace_revision INTEGER NOT NULL,PRIMARY KEY(note_id,workspace_revision));
        CREATE TABLE IF NOT EXISTS scoped_grant_revisions(grant_id TEXT PRIMARY KEY REFERENCES grants(id) ON DELETE CASCADE,workspace_revision INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY,grant_id TEXT NOT NULL REFERENCES grants(id),epoch INTEGER NOT NULL,capability_hash TEXT NOT NULL,expires INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS receipts(id TEXT PRIMARY KEY,run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,query_hash TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS receipt_sources(receipt_id TEXT NOT NULL REFERENCES receipts(id) ON DELETE CASCADE,source_id TEXT NOT NULL,note_id TEXT NOT NULL,fingerprint TEXT NOT NULL,PRIMARY KEY(receipt_id,source_id));
        CREATE TABLE IF NOT EXISTS scoped_run_state(run_id TEXT PRIMARY KEY,revision INTEGER NOT NULL,status TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS scoped_reports(id TEXT PRIMARY KEY,run_id TEXT NOT NULL,task_id TEXT NOT NULL,revision INTEGER NOT NULL,text TEXT NOT NULL,artifacts TEXT NOT NULL,evidence TEXT NOT NULL,evidence_version TEXT NOT NULL,created INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS scoped_report_revisions(report_id TEXT PRIMARY KEY REFERENCES scoped_reports(id) ON DELETE CASCADE,workspace_revision INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS scoped_report_disclosures(report_id TEXT NOT NULL REFERENCES scoped_reports(id) ON DELETE CASCADE,note_id TEXT NOT NULL,fingerprint TEXT NOT NULL,PRIMARY KEY(report_id,note_id));
        CREATE TABLE IF NOT EXISTS scoped_disclosure_identities(report_id TEXT NOT NULL,note_id TEXT NOT NULL,created_at REAL NOT NULL,PRIMARY KEY(report_id,note_id),FOREIGN KEY(report_id,note_id) REFERENCES scoped_report_disclosures(report_id,note_id) ON DELETE CASCADE);
        CREATE TABLE IF NOT EXISTS scoped_report_redactions(report_id TEXT NOT NULL REFERENCES scoped_reports(id) ON DELETE CASCADE,note_id TEXT NOT NULL,redacted_at INTEGER NOT NULL,PRIMARY KEY(report_id,note_id));
        CREATE TABLE IF NOT EXISTS scoped_writes(run_id TEXT NOT NULL,operation_id TEXT NOT NULL,request_hash TEXT NOT NULL,result TEXT NOT NULL,PRIMARY KEY(run_id,operation_id));")?;
    Ok(db)
}
fn task_allowed(root: &Path, task: &str) -> Result<String> {
    let settings = crate::task_workspace::dispatch(root, &json!({"command":"task-agent-settings"}))?;
    ensure!(settings["enabled"] == true, "Доступ агента отключён");
    let value = crate::task_workspace::dispatch(root, &json!({"command":"task-get", "taskID":task}))?;
    // A legacy MCP session can read claim IDs and impersonate the actor of a
    // shared TaskRecord. A protected run therefore may only coexist with a
    // task whose legacy agent access is off. The run and its future results
    // remain in this separate store, never in the old task claim/history.
    ensure!(value["agentAccess"]["enabled"] == false && crate::ai::live_features_for_input(root,&json!({"taskID":task}))?.tasks,
        "Отключите прежний доступ агента к задаче");
    Ok(digest(&json!([settings["revision"],value["revision"],value["sourceFingerprint"]]).to_string()))
}
fn source(root: &Path, id: &str, expected_revision: Option<u64>) -> Result<Source> {
    let note = crate::notes::load_note_snapshot(root,id)?;
    ensure!(note.kind == "note" && expected_revision.is_none_or(|revision| revision == note.revision), "Заметка изменилась или недоступна");
    let resolver = crate::ai::FeatureResolver::new(root)?;
    let target = json!({"noteID":id});
    ensure!(resolver.features_for(&target)?.knowledge_base, "Заметка недоступна");
    let profile = crate::ai::profile_for_input(root,&target)?;
    let settings = fs::symlink_metadata(root.join("settings.json"))?;
    ensure!(settings.is_file() && !settings.file_type().is_symlink(), "Настройки недоступны");
    let policy=digest(&json!([profile.fingerprint,settings.dev(),settings.ino(),settings.mtime(),settings.mtime_nsec(),settings.ctime(),settings.ctime_nsec()]).to_string());
    Ok(Source { id:id.into(), folder:resolver.folder_for(&target)?, revision:note.revision, policy,
        fingerprint:crate::knowledge::note_fingerprint(&note),created_at:note.created_at })
}

/// Native-only: receives the user's exact inspected IDs and revisions. The
/// result is not an authentication credential and must never be supplied as an
/// agent-selected scope. There is intentionally no external command for this.
fn create(root: &Path, task: &str, selected: &[(String,u64)], expires: i64) -> Result<String> {
    ensure!(!selected.is_empty() && selected.len() <= MAX_SOURCES && expires > now() && expires <= now() + MAX_LIFETIME, "Некорректный срок или область");
    // Initialize and drain old-client deletions before freezing a new grant.
    // The scoped write transaction prevents another run from publishing while
    // this source set and its workspace revision are captured.
    drop(open(root)?);
    reconcile_deleted_sources(root)?;
    let mut db = open(root)?;
    let tx=db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let before=crate::workspace_repository::snapshot(root)?.revision;
    let task_policy=task_allowed(root,task)?;
    let mut seen = HashSet::new();
    let mut sources = Vec::new();
    for (id,revision) in selected {
        ensure!(seen.insert(id), "Повторный источник");
        sources.push(source(root,id,Some(*revision))?);
    }
    ensure!(task_allowed(root,task)?==task_policy && crate::workspace_repository::snapshot(root)?.revision==before,
        "Задача или заметки изменились. Повторите выбор.");
    let grant = id();
    tx.execute("INSERT INTO grants(id,task,task_policy,epoch,expires,revoked,sources) VALUES(?1,?2,?3,1,?4,0,?5)",
        params![grant,task,task_policy,expires,serde_json::to_string(&sources)?])?;
    tx.execute("INSERT INTO scoped_grant_revisions(grant_id,workspace_revision) VALUES(?1,?2)",params![grant,before as i64])?;
    tx.commit()?;
    Ok(grant)
}

/// Creates a run and an opaque memory-only capability. This function belongs
/// on the native approval side of a future transport, never in an MCP tool.
fn begin(root: &Path, grant: &str) -> Result<Session> {
    reconcile_deleted_sources(root)?;
    let mut db = open(root)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let row: Option<(String,String,i64,i64,i64)> = tx.query_row("SELECT task,task_policy,epoch,expires,revoked FROM grants WHERE id=?1", [grant],
        |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional()?;
    let (task,task_policy,epoch,expires,revoked) = row.context("Разрешение недоступно")?;
    ensure!(revoked == 0 && expires > now(), "Разрешение недоступно");
    ensure!(task_allowed(root,&task)?==task_policy, "Задача изменилась");
    let session = Session { run:id(), capability:format!("{}{}",id(),id()) };
    tx.execute("INSERT INTO runs(id,grant_id,epoch,capability_hash,expires) VALUES(?1,?2,?3,?4,?5)",
        params![session.run,grant,epoch,digest(&session.capability),expires])?;
    tx.execute("INSERT INTO scoped_run_state(run_id,revision,status) VALUES(?1,0,'active')",[&session.run])?;
    // A stale or deleted source must reject the run itself, not merely fail on
    // its first search. The session is never returned if validation fails.
    authorize_db(root,&session,&tx)?;
    tx.commit()?;
    Ok(session)
}

/// Only an already-bound in-memory Session is accepted; no task ID, source
/// list, filesystem path, agent name or capability is accepted from the model.
fn authorize(root: &Path, session: &Session) -> Result<(String,Vec<String>)> {
    // An older application can delete sources without invoking the new hook.
    // Reconcile before preparing any scoped read, never while holding its DB
    // transaction (which would invert lock order or nest the connection).
    reconcile_deleted_sources(root)?;
    let db = open(root)?;
    authorize_db(root, session, &db)
}
fn authorize_db(root: &Path, session: &Session, db: &Connection) -> Result<(String,Vec<String>)> {
    let row: Option<(String,String,i64,i64,i64,String,i64,String)> = db.query_row(
        "SELECT g.task,g.task_policy,g.epoch,g.expires,g.revoked,g.sources,r.epoch,r.capability_hash FROM runs r JOIN grants g ON g.id=r.grant_id WHERE r.id=?1 AND r.expires>?2",
        params![session.run,now()], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?,r.get(7)?))).optional()?;
    let (task,task_policy,epoch,expires,revoked,serialized,run_epoch,capability_hash)=row.context("Сессия недоступна")?;
    ensure!(epoch==run_epoch && expires>now() && revoked==0 && capability_hash==digest(&session.capability), "Сессия недоступна");
    ensure!(task_allowed(root,&task)?==task_policy,"Задача изменилась");
    let sources:Vec<Source>=serde_json::from_str(&serialized)?;
    let baseline:Option<i64>=db.query_row("SELECT workspace_revision FROM scoped_grant_revisions WHERE grant_id=(SELECT grant_id FROM runs WHERE id=?1)",
        [&session.run],|r|r.get(0)).optional()?;
    let baseline=baseline.context("Требуется повторно предоставить доступ")?;
    for expected in &sources {
        let deleted:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM scoped_source_deletions WHERE note_id=?1 AND workspace_revision>?2)",
            params![expected.id,baseline],|r|r.get(0))?;
        ensure!(!deleted,"Область изменилась");
        let live = source(root,&expected.id,None)?;
        ensure!(&live == expected, "Область изменилась");
    }
    // Close the revocation race while source/profile checks were running.
    let current:Option<(i64,i64,i64)>=db.query_row("SELECT epoch,expires,revoked FROM grants WHERE id=(SELECT grant_id FROM runs WHERE id=?1)",
        [&session.run], |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
    ensure!(current.is_some_and(|(e,x,r)|e==epoch && x>now() && r==0), "Сессия недоступна");
    ensure!(task_allowed(root,&task)?==task_policy,"Задача изменилась");
    Ok((task,sources.into_iter().map(|s|s.id).collect()))
}

fn shorten(value:&str, maximum:usize)->(&str,bool) {
    let mut end=value.len().min(maximum);
    while !value.is_char_boundary(end) { end-=1; }
    (&value[..end],end<value.len())
}
fn run_state(db:&Connection, session:&Session)->Result<(i64,String)> {
    db.query_row("SELECT revision,status FROM scoped_run_state WHERE run_id=?1",[&session.run],
        |r|Ok((r.get(0)?,r.get(1)?))).optional()?.context("Сессия недоступна")
}
fn ensure_active(db:&Connection, session:&Session)->Result<i64> {
    let (revision,status)=run_state(db,session)?;
    ensure!(status=="active","Работа уже завершена");
    Ok(revision)
}

/// Internal bounded lexical search. Closed sources are excluded before the
/// ranking and limit; no shared corpus statistics or model calls are used.
/// The returned IDs are random per receipt, never the user's real note IDs.
fn search(root:&Path,session:&Session,query:&str,limit:usize)->Result<Value> {
    search_before_publish(root,session,query,limit,||{})
}
fn search_before_publish<F:FnOnce()>(root:&Path,session:&Session,query:&str,limit:usize,hook:F)->Result<Value> {
    ensure!(!query.trim().is_empty() && query.len()<=2000 && !query.contains('\0') && (1..=20).contains(&limit),"Некорректный запрос");
    let matcher=crate::search::QueryMatcher::new(query)?;
    ensure!(matcher.has_terms(),"Добавьте слова или числа в поисковый запрос");
    let (task,scope)=authorize(root,session)?;
    ensure_active(&open(root)?,session)?;
    let mut matches=Vec::new();
    for note_id in &scope {
        let note=crate::notes::load_note_snapshot(root,note_id)?;
        let title=if note.title.trim().is_empty() { note.text.lines().find(|line|!line.trim().is_empty()).unwrap_or("").chars().take(150).collect::<String>() } else { note.title.clone() };
        let title_match=matcher.matches(&title);
        if title_match || matcher.matches(&note.text) {
            matches.push((title_match,note,title));
        }
    }
    matches.sort_by(|a,b|b.0.cmp(&a.0).then_with(||a.1.id.cmp(&b.1.id)));
    let mut truncated=matches.len()>limit;
    let mut results=Vec::new();
    let mut stored=Vec::new();
    for (_,note,title) in matches.into_iter().take(limit) {
        let source_id=id();
        let fingerprint=crate::knowledge::note_fingerprint(&note);
        let (excerpt,excerpt_truncated)=shorten(&note.text,700);
        let (title,_)=shorten(&title,500);
        let hit=json!({"sourceID":source_id,"fingerprint":fingerprint,"kind":"note","title":title,"excerpt":excerpt,"excerptTruncated":excerpt_truncated});
        results.push(hit);
        if serde_json::to_vec(&results)?.len()>MAX_RESPONSE-1024 { results.pop(); truncated=true; break; }
        stored.push((source_id,note.id,fingerprint));
    }
    // Tests inject an actual independent revoke/edit here. The broker must
    // perform its own transport-level publication fence after this function;
    // a returned Value alone does not synchronize network delivery.
    hook();
    let mut db=open(root)?;
    let tx=db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(authorize_db(root,session,&tx)?==(task.clone(),scope.clone()),"Область изменилась");
    ensure_active(&tx,session)?;
    let count:i64=tx.query_row("SELECT COUNT(*) FROM receipts WHERE run_id=?1",[&session.run],|r|r.get(0))?;
    ensure!(count<100,"Достигнут предел поиска для этой сессии");
    let receipt=id();
    tx.execute("INSERT INTO receipts(id,run_id,query_hash) VALUES(?1,?2,?3)",params![receipt,session.run,digest(query)])?;
    for (source_id,note_id,fingerprint) in &stored {
        tx.execute("INSERT INTO receipt_sources(receipt_id,source_id,note_id,fingerprint) VALUES(?1,?2,?3,?4)",params![receipt,source_id,note_id,fingerprint])?;
    }
    // A source cannot be changed while we were constructing a receipt.
    for (_,note_id,fingerprint) in &stored {
        let note=crate::notes::load_note_snapshot(root,note_id)?;
        ensure!(crate::knowledge::note_fingerprint(&note)==*fingerprint,"Источник изменился");
    }
    authorize_db(root,session,&tx)?;
    tx.commit()?;
    ensure!(authorize(root,session)?==(task,scope),"Область изменилась");
    Ok(json!({"receiptID":receipt,"results":results,"truncated":truncated}))
}

/// Read only a source previously issued to this exact run. Receipts store IDs
/// and fingerprints, never note contents, and are invalidated by grant revoke.
fn read(root:&Path,session:&Session,receipt:&str,source_id:&str,fingerprint:&str)->Result<Value> {
    read_before_publish(root,session,receipt,source_id,fingerprint,||{})
}
fn read_before_publish<F:FnOnce()>(root:&Path,session:&Session,receipt:&str,source_id:&str,fingerprint:&str,hook:F)->Result<Value> {
    ensure!(Uuid::parse_str(receipt).is_ok() && Uuid::parse_str(source_id).is_ok() && fingerprint.len()==64 && fingerprint.bytes().all(|b|b.is_ascii_hexdigit()),"Источник недоступен");
    let (task,scope)=authorize(root,session)?;
    let db=open(root)?;
    ensure_active(&db,session)?;
    let row:Option<(String,String)>=db.query_row("SELECT s.note_id,s.fingerprint FROM receipt_sources s JOIN receipts r ON r.id=s.receipt_id WHERE r.id=?1 AND r.run_id=?2 AND s.source_id=?3",
        params![receipt,session.run,source_id],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
    let (note_id,issued_fingerprint)=row.context("Источник недоступен")?;
    ensure!(scope.contains(&note_id) && fingerprint==issued_fingerprint,"Источник недоступен");
    let note=crate::notes::load_note_snapshot(root,&note_id)?;
    ensure!(crate::knowledge::note_fingerprint(&note)==fingerprint,"Источник изменился");
    let (text,truncated)=shorten(&note.text,8*1024);
    let (title,_)=shorten(&note.title,500);
    let result=json!({"sourceID":source_id,"fingerprint":fingerprint,"kind":"note","title":title,"text":text,"truncated":truncated});
    ensure!(serde_json::to_vec(&result)?.len()<=MAX_RESPONSE,"Источник слишком большой");
    hook();
    let mut db=open(root)?;
    let tx=db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(authorize_db(root,session,&tx)?==(task.clone(),scope.clone()),"Область изменилась");
    ensure_active(&tx,session)?;
    let exists:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM receipt_sources s JOIN receipts r ON r.id=s.receipt_id WHERE r.id=?1 AND r.run_id=?2 AND s.source_id=?3 AND s.fingerprint=?4)",
        params![receipt,session.run,source_id,fingerprint],|r|r.get(0))?;
    ensure!(exists,"Источник недоступен");
    let latest=crate::notes::load_note_snapshot(root,&note_id)?;
    ensure!(crate::knowledge::note_fingerprint(&latest)==fingerprint,"Источник изменился");
    authorize_db(root,session,&tx)?;
    tx.commit()?;
    ensure!(authorize(root,session)?==(task,scope),"Область изменилась");
    Ok(result)
}

/// Results stay in the isolated run store until a future trusted broker can
/// publish them safely. They never become legacy TaskRecord claims/events.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all="camelCase")]
struct Artifact {
    title:String,
    kind:String,
    text:String,
    #[serde(default)]
    url:Option<String>,
}
fn validate_artifacts(artifacts:&[Artifact])->Result<()> {
    ensure!(artifacts.len()<=20,"Слишком много артефактов");
    for artifact in artifacts {
        ensure!(!artifact.title.trim().is_empty() && artifact.title.len()<=500 &&
            artifact.text.len()<=20_000 && !artifact.title.contains('\0') && !artifact.text.contains('\0') &&
            ["report","changes","file","link","pullRequest","commit","checks"].contains(&artifact.kind.as_str()),
            "Некорректный артефакт");
        if let Some(url)=&artifact.url {
            let parsed=reqwest::Url::parse(url).context("Некорректная ссылка артефакта")?;
            ensure!(url.len()<=4000 && ["http","https"].contains(&parsed.scheme()) &&
                parsed.host_str().is_some() && parsed.username().is_empty() && parsed.password().is_none(),
                "Некорректная ссылка артефакта");
        }
    }
    ensure!(serde_json::to_vec(artifacts)?.len()<=128*1024,"Артефакты слишком велики");
    Ok(())
}
/// Validate only receipts issued to this run and the exact versions they
/// disclosed. The digest has no report text and does not include receipt IDs.
fn evidence_version(root:&Path, db:&Connection, session:&Session, receipts:&[String], task:&str, scope:&[String])->Result<String> {
    ensure!(!receipts.is_empty() && receipts.len()<=20,"Укажите использованные источники");
    let mut ids=HashSet::new();
    let mut versions=Vec::<(String,String)>::new();
    for receipt in receipts {
        ensure!(Uuid::parse_str(receipt).is_ok() && ids.insert(receipt),"Некорректные источники");
        let issued:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM receipts WHERE id=?1 AND run_id=?2)",
            params![receipt,session.run],|r|r.get(0))?;
        ensure!(issued,"Источник недоступен");
        let mut statement=db.prepare("SELECT note_id,fingerprint FROM receipt_sources WHERE receipt_id=?1 ORDER BY note_id,fingerprint")?;
        let rows=statement.query_map([receipt],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        ensure!(!rows.is_empty(),"Источник недоступен");
        for (note_id,fingerprint) in rows {
            ensure!(scope.contains(&note_id),"Источник недоступен");
            let current=crate::notes::load_note_snapshot(root,&note_id)?;
            ensure!(crate::knowledge::note_fingerprint(&current)==fingerprint,"Источник изменился");
            versions.push((note_id,fingerprint));
        }
    }
    versions.sort(); versions.dedup();
    let (epoch,task_policy):(i64,String)=db.query_row(
        "SELECT g.epoch,g.task_policy FROM grants g JOIN runs r ON r.grant_id=g.id WHERE r.id=?1",
        [&session.run],|r|Ok((r.get(0)?,r.get(1)?)))?;
    Ok(digest(&json!([session.run,task,task_policy,epoch,versions]).to_string()))
}
fn prior_write(db:&Connection,session:&Session,operation:&str,request_hash:&str)->Result<Option<Value>> {
    let previous:Option<(String,String)>=db.query_row(
        "SELECT request_hash,result FROM scoped_writes WHERE run_id=?1 AND operation_id=?2",
        params![session.run,operation],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
    if let Some((hash,result))=previous {
        ensure!(hash==request_hash,"Операция уже использована для другого действия");
        return Ok(Some(serde_json::from_str(&result)?));
    }
    Ok(None)
}
fn report(root:&Path,session:&Session,expected_revision:i64,operation:&str,text:&str,
          artifacts:&[Artifact],receipts:&[String])->Result<Value> {
    ensure!(Uuid::parse_str(operation).is_ok() && expected_revision>=0 && text.len()<=20_000 &&
        !text.contains('\0') && (!text.trim().is_empty() || !artifacts.is_empty()),"Некорректный отчёт");
    validate_artifacts(artifacts)?;
    reconcile_deleted_sources(root)?;
    let request_hash=digest(&json!(["report",expected_revision,text,artifacts,receipts]).to_string());
    let mut db=open(root)?;
    let tx=db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let (task,scope)=authorize_db(root,session,&tx)?;
    let evidence=evidence_version(root,&tx,session,receipts,&task,&scope)?;
    if let Some(value)=prior_write(&tx,session,operation,&request_hash)? {
        tx.commit()?;
        ensure!(authorize(root,session)?==(task.clone(),scope.clone()) &&
            evidence_version(root,&open(root)?,session,receipts,&task,&scope)?==evidence,"Область изменилась");
        return Ok(value);
    }
    let revision=ensure_active(&tx,session)?;
    ensure!(revision==expected_revision,"Работа изменилась. Обновите состояние.");
    let count:i64=tx.query_row("SELECT COUNT(*) FROM scoped_reports WHERE run_id=?1",[&session.run],|r|r.get(0))?;
    ensure!(count<100,"Достигнут предел отчётов");
    let next=revision.checked_add(1).context("Ревизия исчерпана")?;
    let workspace_revision=crate::workspace_repository::snapshot(root)?.revision;
    let report_id=id();
    tx.execute("INSERT INTO scoped_reports(id,run_id,task_id,revision,text,artifacts,evidence,evidence_version,created) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
        params![report_id,session.run,task,next,text,serde_json::to_string(artifacts)?,serde_json::to_string(receipts)?,evidence,now()])?;
    tx.execute("INSERT INTO scoped_report_revisions(report_id,workspace_revision) VALUES(?1,?2)",params![report_id,workspace_revision as i64])?;
    // All allowed sources are conservative disclosure dependencies, even if
    // the agent omitted them from its own citations. Preserve only IDs and
    // fingerprints so a future native history adapter can revalidate or
    // redact after a note is removed, including after grant revocation.
    for note_id in &scope {
        let note=crate::notes::load_note_snapshot(root,note_id)?;
        tx.execute("INSERT INTO scoped_report_disclosures(report_id,note_id,fingerprint) VALUES(?1,?2,?3)",
            params![report_id,note_id,crate::knowledge::note_fingerprint(&note)])?;
        tx.execute("INSERT INTO scoped_disclosure_identities(report_id,note_id,created_at) VALUES(?1,?2,?3)",
            params![report_id,note_id,note.created_at])?;
    }
    tx.execute("UPDATE scoped_run_state SET revision=?1 WHERE run_id=?2 AND revision=?3",params![next,session.run,revision])?;
    let result=json!({"reportID":report_id,"revision":next,"evidenceVersion":evidence});
    tx.execute("INSERT INTO scoped_writes(run_id,operation_id,request_hash,result) VALUES(?1,?2,?3,?4)",
        params![session.run,operation,request_hash,result.to_string()])?;
    ensure!(authorize_db(root,session,&tx)?==(task.clone(),scope.clone()) &&
        evidence_version(root,&tx,session,receipts,&task,&scope)?==evidence,"Область изменилась");
    tx.commit()?;
    // A legacy writer does not participate in the scoped transaction. Drain
    // its durable deletions once more before returning a committed result.
    ensure!(authorize(root,session)?==(task.clone(),scope.clone()) &&
        evidence_version(root,&open(root)?,session,receipts,&task,&scope)?==evidence,"Область изменилась");
    Ok(result)
}
fn complete(root:&Path,session:&Session,expected_revision:i64,operation:&str)->Result<Value> {
    ensure!(Uuid::parse_str(operation).is_ok() && expected_revision>=0,"Некорректная операция");
    reconcile_deleted_sources(root)?;
    let request_hash=digest(&json!(["complete",expected_revision]).to_string());
    let mut db=open(root)?;
    let tx=db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let (task,scope)=authorize_db(root,session,&tx)?;
    let latest:Option<(String,String,String)>=tx.query_row(
        "SELECT id,evidence,evidence_version FROM scoped_reports WHERE run_id=?1 ORDER BY revision DESC LIMIT 1",
        [&session.run],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
    let (report_id,evidence_json,expected_evidence)=latest.context("Сначала сохраните отчёт с источниками")?;
    let receipts:Vec<String>=serde_json::from_str(&evidence_json)?;
    ensure!(evidence_version(root,&tx,session,&receipts,&task,&scope)?==expected_evidence,"Источники отчёта изменились");
    if let Some(value)=prior_write(&tx,session,operation,&request_hash)? {
        tx.commit()?;
        ensure!(authorize(root,session)?==(task.clone(),scope.clone()) &&
            evidence_version(root,&open(root)?,session,&receipts,&task,&scope)?==expected_evidence,"Область изменилась");
        return Ok(value);
    }
    let revision=ensure_active(&tx,session)?;
    ensure!(revision==expected_revision,"Работа изменилась. Обновите состояние.");
    let next=revision.checked_add(1).context("Ревизия исчерпана")?;
    tx.execute("UPDATE scoped_run_state SET revision=?1,status='complete' WHERE run_id=?2 AND revision=?3",params![next,session.run,revision])?;
    let result=json!({"reportID":report_id,"revision":next,"completed":true});
    tx.execute("INSERT INTO scoped_writes(run_id,operation_id,request_hash,result) VALUES(?1,?2,?3,?4)",
        params![session.run,operation,request_hash,result.to_string()])?;
    ensure!(authorize_db(root,session,&tx)?==(task.clone(),scope.clone()) &&
        evidence_version(root,&tx,session,&receipts,&task,&scope)?==expected_evidence,"Область изменилась");
    tx.commit()?;
    ensure!(authorize(root,session)?==(task.clone(),scope.clone()) &&
        evidence_version(root,&open(root)?,session,&receipts,&task,&scope)?==expected_evidence,"Область изменилась");
    Ok(result)
}

/// Remove managed source references after hard delete. Reports are user-owned
/// historical output, so their free-form text is preserved but never issued
/// to the agent after a dependency disappears. A redaction marker is durable
/// even if the same ID is later reused. Trash is reversible and does not create
/// a marker. This can also be run after an older client deleted a source.
/// Call only after releasing the notes lock: scoped operations acquire the
/// grant database before the workspace lock.
pub(crate) fn reconcile_deleted_sources(root:&Path)->Result<usize> {
    let path=fs::canonicalize(root)?.join(DB);
    if !ordinary(&path)? {return Ok(0);}
    let mut db=open_with_timeout(root,Duration::from_millis(100))?;
    let tx=db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let directory=crate::notes::directory(root)?;
    let _notes_lock=crate::notes::try_lock(&directory)?;
    crate::corrections::recover_notes_transaction(&directory)?;
    let snapshot=crate::workspace_repository::load_locked(&directory)?;
    let workspace:crate::notes::NotesWorkspace=serde_json::from_value(snapshot.value)?;
    let present:HashSet<String>=workspace.notes.into_iter().filter(|n|n.kind=="note")
        .map(|n|n.id).collect();
    let existing:i64=tx.query_row("SELECT (SELECT COUNT(*) FROM grants)+(SELECT COUNT(*) FROM scoped_reports)",[],|r|r.get(0))?;
    let cursor:Option<i64>=tx.query_row("SELECT value FROM scoped_meta WHERE key='outbox_revision'",[],|r|r.get(0)).optional()?;
    let cursor=cursor.unwrap_or(if existing==0 {snapshot.revision as i64} else {0});
    ensure!(cursor>=0 && cursor<=snapshot.revision as i64,"Повреждён журнал разрешений");
    let core_path=fs::canonicalize(root)?.join("core.sqlite");
    ensure!(ordinary(&core_path)?,"База заметок недоступна");
    let core=Connection::open_with_flags(&core_path,OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW)?;
    core.busy_timeout(Duration::from_millis(100))?;
    let mut query=core.prepare("SELECT revision,payload FROM workspace_outbox WHERE revision>?1 AND revision<=?2 ORDER BY revision,event_id LIMIT 100001")?;
    let events=query.query_map(params![cursor,snapshot.revision as i64],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    ensure!(events.len()<=100_000,"Журнал изменений слишком велик. Очистка отложена.");
    drop(query);
    for (revision,payload) in events {
        let event:Value=serde_json::from_str(&payload).context("Повреждён журнал изменений")?;
        for change in event["changes"].as_array().into_iter().flatten() {
            if change["kind"]!="note" || change["change"]!="delete" {continue;}
            let id=change["id"].as_str().context("Повреждён журнал изменений")?;
            ensure!(!id.is_empty() && id.len()<=128 && id.bytes().all(|b|b.is_ascii_alphanumeric() || b==b'-' || b==b'_'),"Повреждён журнал изменений");
            tx.execute("INSERT OR IGNORE INTO scoped_source_deletions(note_id,workspace_revision) VALUES(?1,?2)",params![id,revision])?;
            // Only reports/grants predating this exact delete are redacted;
            // a new grant for a later recreated note remains independent.
            tx.execute("INSERT OR IGNORE INTO scoped_report_redactions(report_id,note_id,redacted_at) SELECT d.report_id,d.note_id,?3 FROM scoped_report_disclosures d LEFT JOIN scoped_report_revisions v ON v.report_id=d.report_id WHERE d.note_id=?1 AND COALESCE(v.workspace_revision,0)<?2",params![id,revision,now()])?;
            tx.execute("DELETE FROM receipt_sources WHERE note_id=?1 AND receipt_id IN (SELECT c.id FROM receipts c JOIN runs r ON r.id=c.run_id LEFT JOIN scoped_grant_revisions g ON g.grant_id=r.grant_id WHERE COALESCE(g.workspace_revision,0)<?2)",params![id,revision])?;
        }
    }
    let mut statement=tx.prepare("SELECT note_id FROM scoped_report_disclosures UNION SELECT note_id FROM receipt_sources")?;
    let known=statement.query_map([],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
    drop(statement);
    let missing:Vec<_>=known.into_iter().filter(|id|!present.contains(id)).collect();
    for id in &missing {
        tx.execute("INSERT OR IGNORE INTO scoped_report_redactions(report_id,note_id,redacted_at) SELECT report_id,note_id,?2 FROM scoped_report_disclosures WHERE note_id=?1",params![id,now()])?;
        tx.execute("DELETE FROM receipt_sources WHERE note_id=?1",[id])?;
    }
    tx.execute("INSERT OR REPLACE INTO scoped_meta(key,value) VALUES('outbox_revision',?1)",[snapshot.revision as i64])?;
    tx.commit()?;
    Ok(missing.len())
}

/// A native-only history projection. Never expose raw rows through the legacy
/// task endpoint: an unavailable dependency produces only an opaque stub.
/// A future transport still needs an atomic fence through actual publication.
fn history_for_owner(root:&Path,task:&str)->Result<Value> {
    history_for_run(root,task,None)
}
fn history_for_run(root:&Path,task:&str,run:Option<&str>)->Result<Value> {
    reconcile_deleted_sources(root)?;
    ensure!(crate::ai::live_features_for_input(root,&json!({"taskID":task}))?.tasks,"Задача недоступна");
    let initial=crate::task_workspace::dispatch(root,&json!({"command":"task-get","taskID":task}))?;
    let db=open(root)?;
    // Agent scopes are applied inside SQL, before sorting, counts and limit.
    let mut statement=db.prepare("SELECT id,text,artifacts,created FROM scoped_reports WHERE task_id=?1 AND (?2 IS NULL OR run_id=?2) ORDER BY created DESC,revision DESC,id LIMIT 51")?;
    let rows=statement.query_map(params![task,run],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,i64>(3)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(statement);
    let mut truncated=rows.len()>50;
    let mut reports=Vec::new();
    for (report_id,text,artifacts_json,created) in rows.into_iter().take(50) {
        let mut q=db.prepare("SELECT note_id,fingerprint FROM scoped_report_disclosures WHERE report_id=?1 ORDER BY note_id")?;
        let deps=q.query_map([&report_id],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        drop(q);
        let redacted:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM scoped_report_redactions WHERE report_id=?1)",[&report_id],|r|r.get(0))?;
        let initial_sources:Option<Vec<Source>>=if redacted || deps.is_empty() {None} else {
            deps.iter().map(|(id,expected)| {
                let current=source(root,id,None).ok()?;
                let note=crate::notes::load_note_snapshot(root,id).ok()?;
                (crate::knowledge::note_fingerprint(&note)==*expected).then_some(current)
            }).collect()
        };
        let Some(initial_sources)=initial_sources else {
            reports.push(json!({"reportID":report_id,"createdAt":created,"available":false}));
            continue;
        };
        let artifacts:Vec<Artifact>=serde_json::from_str(&artifacts_json)?;
        validate_artifacts(&artifacts)?;
        let (excerpt,short)=shorten(&text,1200);
        let shown:Vec<_>=artifacts.iter().take(3).map(|artifact|json!({"title":artifact.title,"kind":artifact.kind})).collect();
        reports.push(json!({"reportID":report_id,"createdAt":created,"available":true,"excerpt":excerpt,
            "excerptTruncated":short,"artifacts":shown,"artifactsTruncated":artifacts.len()>3}));
        if serde_json::to_vec(&reports)?.len()>MAX_RESPONSE-1024 {reports.pop(); truncated=true; break;}
        // A concurrent source update or a policy change must not publish stale
        // text. Until a broker is available, no external route calls this.
        ensure!(deps.iter().zip(&initial_sources).all(|((id,expected),initial)|source(root,id,None).is_ok_and(|s|s==*initial) &&
            crate::notes::load_note_snapshot(root,id).is_ok_and(|n|crate::knowledge::note_fingerprint(&n)==*expected)) &&
            !db.query_row("SELECT EXISTS(SELECT 1 FROM scoped_report_redactions WHERE report_id=?1)",[&report_id],|r|r.get::<_,bool>(0))?,
            "История изменилась. Обновите результаты.");
    }
    let current=crate::task_workspace::dispatch(root,&json!({"command":"task-get","taskID":task}))?;
    ensure!(crate::ai::live_features_for_input(root,&json!({"taskID":task}))?.tasks &&
        current["revision"]==initial["revision"] && current["sourceFingerprint"]==initial["sourceFingerprint"],"Задача недоступна");
    Ok(json!({"reports":reports,"truncated":truncated}))
}

/// Repeated agent delivery is scoped to the original run and always requires
/// fresh grant, source and policy validation, including for prior receipts.
fn history_for_agent(root:&Path,session:&Session)->Result<Value> {
    reconcile_deleted_sources(root)?;
    let (task,scope)=authorize(root,session)?;
    let history=history_for_run(root,&task,Some(&session.run))?;
    let mut visible=Vec::new();
    for item in history["reports"].as_array().into_iter().flatten() {
        if item["available"]==true {visible.push(item.clone());}
    }
    ensure!(authorize(root,session)?==(task,scope),"Область изменилась");
    Ok(json!({"reports":visible,"truncated":history["truncated"]}))
}
fn revoke(root:&Path,grant:&str)->Result<()> {
    // Once revoke returns, any content publication started under the same
    // gate has completed; new publications revalidate and fail closed.
    let _publication=publication_gate(root,true)?;
    let mut db=open(root)?;
    let tx=db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(tx.execute("UPDATE grants SET epoch=epoch+1,revoked=1 WHERE id=?1 AND revoked=0",[grant])?==1,"Разрешение недоступно");
    tx.execute("DELETE FROM runs WHERE grant_id=?1",[grant])?;
    tx.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    fn request(root:&Path,command:&str,mut value:Value)->Value {
        value["command"]=json!(command);
        crate::task_workspace::dispatch(root,&value).unwrap()
    }
    #[test]
    fn history_is_scoped_and_hard_delete_removes_managed_references() {
        let directory=tempfile::tempdir().unwrap(); let root=directory.path();
        crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"tasks":true,"knowledgeBase":true}})).unwrap();
        let create_note=|id:&str, title:&str| {
            let note:crate::notes::CapturedNote=serde_json::from_value(json!({"id":id,"kind":"note","title":title,"text":"Пилотный договор","revision":0,"createdAt":1.0,"updatedAt":1.0})).unwrap();
            crate::notes::save_note(root,note).unwrap()
        };
        let first=create_note("first","Первый");
        let second=create_note("second","Второй");
        request(root,"task-agent-settings",json!({"enabled":true,"expectedRevision":0,"operationID":id()}));
        let task=request(root,"task-create",json!({"title":"Task","operationID":id()}));
        let task_id=task["id"].as_str().unwrap();
        let grant_a=create(root,task_id,&[(first.id.clone(),first.revision)],now()+600).unwrap();
        let session_a=begin(root,&grant_a).unwrap();
        let receipt_a=search(root,&session_a,"договор",10).unwrap()["receiptID"].as_str().unwrap().to_owned();
        let artifact=Artifact{title:"ARTIFACT-SECRET".into(),kind:"report".into(),text:"Содержание".into(),url:None};
        let report_a=report(root,&session_a,0,&id(),"FIRST-SECRET",&[artifact],&[receipt_a.clone()]).unwrap();
        let grant_b=create(root,task_id,&[(second.id.clone(),second.revision)],now()+600).unwrap();
        let session_b=begin(root,&grant_b).unwrap();
        let receipt_b=search(root,&session_b,"договор",10).unwrap()["receiptID"].as_str().unwrap().to_owned();
        report(root,&session_b,0,&id(),"SECOND-SECRET",&[],&[receipt_b]).unwrap();
        let history=history_for_owner(root,task_id).unwrap();
        assert_eq!(history["reports"].as_array().unwrap().len(),2);
        let own=history_for_agent(root,&session_a).unwrap();
        assert!(own.to_string().contains("FIRST-SECRET"));
        assert!(!own.to_string().contains("SECOND-SECRET"));

        // Reversible Trash must hide the source but retain managed references.
        let trashed=crate::notes::trash_note(root,"first",first.revision,false).unwrap();
        let hidden=history_for_owner(root,task_id).unwrap();
        assert!(!hidden.to_string().contains("FIRST-SECRET"));
        assert!(!hidden.to_string().contains("ARTIFACT-SECRET"));
        let db=open(root).unwrap();
        assert_eq!(db.query_row("SELECT COUNT(*) FROM receipt_sources WHERE note_id='first'",[],|r|r.get::<_,i64>(0)).unwrap(),1);
        assert_eq!(db.query_row("SELECT COUNT(*) FROM scoped_report_redactions",[],|r|r.get::<_,i64>(0)).unwrap(),0);
        drop(db);

        let deleted=crate::notes::delete_note(root,"first",trashed.revision).unwrap();
        assert_eq!(deleted["cleanupPending"],false);
        assert!(history_for_agent(root,&session_a).is_err());
        let after=history_for_owner(root,task_id).unwrap();
        assert!(!after.to_string().contains("FIRST-SECRET"));
        assert!(!after.to_string().contains("ARTIFACT-SECRET"));
        assert!(after.to_string().contains("SECOND-SECRET"));
        let db=open(root).unwrap();
        assert_eq!(db.query_row("SELECT COUNT(*) FROM receipt_sources WHERE note_id='first'",[],|r|r.get::<_,i64>(0)).unwrap(),0);
        assert_eq!(db.query_row("SELECT COUNT(*) FROM scoped_report_redactions WHERE report_id=?1",[report_a["reportID"].as_str().unwrap()],|r|r.get::<_,i64>(0)).unwrap(),1);
        // User-authored historical result remains in its native store; it is
        // hidden from both agent delivery and the default stale projection.
        assert_eq!(db.query_row("SELECT text FROM scoped_reports WHERE id=?1",[report_a["reportID"].as_str().unwrap()],|r|r.get::<_,String>(0)).unwrap(),"FIRST-SECRET");
        drop(db);
        let recreated=create_note("first","Первый");
        assert!(recreated.revision>0);
        assert!(!history_for_owner(root,task_id).unwrap().to_string().contains("FIRST-SECRET"));
    }
    #[test]
    fn legacy_hard_delete_is_reconciled_before_history_read() {
        let directory=tempfile::tempdir().unwrap(); let root=directory.path();
        crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"tasks":true,"knowledgeBase":true}})).unwrap();
        let note:crate::notes::CapturedNote=serde_json::from_value(json!({"id":"source","kind":"note","title":"Пилот","text":"Пилотный договор","revision":0,"createdAt":1.0,"updatedAt":1.0})).unwrap();
        let note=crate::notes::save_note(root,note).unwrap();
        request(root,"task-agent-settings",json!({"enabled":true,"expectedRevision":0,"operationID":id()}));
        let task=request(root,"task-create",json!({"title":"Task","operationID":id()}));
        let task_id=task["id"].as_str().unwrap();
        let grant=create(root,task_id,&[(note.id.clone(),note.revision)],now()+600).unwrap();
        let session=begin(root,&grant).unwrap();
        let receipt=search(root,&session,"пилот",10).unwrap()["receiptID"].as_str().unwrap().to_owned();
        report(root,&session,0,&id(),"REMOVED-SOURCE-TEXT",&[],&[receipt]).unwrap();
        // Simulate an older binary's workspace commit, bypassing the new hook.
        let dir=crate::notes::directory(root).unwrap();
        let guard=crate::notes::lock(&dir).unwrap();
        let mut workspace=crate::notes::load(&dir).unwrap();
        workspace.notes.retain(|n|n.id!="source");
        crate::notes::persist(&dir,&workspace).unwrap();
        drop(guard);
        let db=open(root).unwrap();
        assert_eq!(db.query_row("SELECT COUNT(*) FROM scoped_report_redactions",[],|r|r.get::<_,i64>(0)).unwrap(),0);
        drop(db);
        assert!(!history_for_owner(root,task_id).unwrap().to_string().contains("REMOVED-SOURCE-TEXT"));
        let db=open(root).unwrap();
        assert_eq!(db.query_row("SELECT COUNT(*) FROM receipt_sources WHERE note_id='source'",[],|r|r.get::<_,i64>(0)).unwrap(),0);
        assert_eq!(db.query_row("SELECT COUNT(*) FROM scoped_report_redactions",[],|r|r.get::<_,i64>(0)).unwrap(),1);
    }
    #[test]
    fn legacy_delete_and_recreate_same_id_cannot_revive_old_grant_or_report() {
        let directory=tempfile::tempdir().unwrap(); let root=directory.path();
        crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"tasks":true,"knowledgeBase":true}})).unwrap();
        let make=|text:&str| {
            let note:crate::notes::CapturedNote=serde_json::from_value(json!({"id":"reused","kind":"note","title":"Пилот","text":text,"revision":0,"createdAt":1.0,"updatedAt":1.0})).unwrap();
            crate::notes::save_note(root,note).unwrap()
        };
        let first=make("Пилотный старый договор");
        request(root,"task-agent-settings",json!({"enabled":true,"expectedRevision":0,"operationID":id()}));
        let task=request(root,"task-create",json!({"title":"Task","operationID":id()}));
        let task_id=task["id"].as_str().unwrap();
        let grant=create(root,task_id,&[(first.id.clone(),first.revision)],now()+600).unwrap();
        let old_session=begin(root,&grant).unwrap();
        let receipt=search(root,&old_session,"пилот",10).unwrap()["receiptID"].as_str().unwrap().to_owned();
        report(root,&old_session,0,&id(),"OLD-REPORT-SECRET",&[],&[receipt]).unwrap();
        // An old writer bypasses the hook and recreates byte-for-byte
        // identical metadata *during* preparation of a search response.
        // Even a full fingerprint comparison alone cannot distinguish reuse.
        assert!(search_before_publish(root,&old_session,"пилот",10,|| {
            let dir=crate::notes::directory(root).unwrap();
            let guard=crate::notes::lock(&dir).unwrap();
            let mut workspace=crate::notes::load(&dir).unwrap();
            workspace.notes.retain(|n|n.id!="reused");
            crate::notes::persist(&dir,&workspace).unwrap();
            workspace.notes.push(first.clone());
            crate::notes::persist(&dir,&workspace).unwrap();
            drop(guard);
        }).is_err());
        let second=crate::notes::load_note_snapshot(root,"reused").unwrap();
        assert_eq!(crate::knowledge::note_fingerprint(&first),crate::knowledge::note_fingerprint(&second));
        assert!(search(root,&old_session,"пилот",10).is_err());
        assert!(begin(root,&grant).is_err());
        assert!(!history_for_owner(root,task_id).unwrap().to_string().contains("OLD-REPORT-SECRET"));
        let db=open(root).unwrap();
        assert_eq!(db.query_row("SELECT COUNT(*) FROM scoped_source_deletions WHERE note_id='reused'",[],|r|r.get::<_,i64>(0)).unwrap(),1);
        assert_eq!(db.query_row("SELECT COUNT(*) FROM receipt_sources WHERE note_id='reused'",[],|r|r.get::<_,i64>(0)).unwrap(),0);
        drop(db);
        // Explicitly choosing the new source creates a new independent grant.
        let mut second=second;
        second.text="Пилотный НОВЫЙ SECRET".into();
        let second=crate::notes::save_note(root,second).unwrap();
        let fresh=create(root,task_id,&[(second.id.clone(),second.revision)],now()+600).unwrap();
        let new_session=begin(root,&fresh).unwrap();
        let new_result=search(root,&new_session,"пилот",10).unwrap();
        assert!(new_result.to_string().contains("НОВЫЙ SECRET"));
        let fresh_receipt=new_result["receiptID"].as_str().unwrap().to_owned();
        report(root,&new_session,0,&id(),"NEW-REPORT",&[],&[fresh_receipt]).unwrap();
        let history=history_for_owner(root,task_id).unwrap().to_string();
        assert!(history.contains("NEW-REPORT"));
        assert!(!history.contains("OLD-REPORT-SECRET"));
    }
    #[test]
    fn history_refuses_revoked_sources_tasks_and_agent_sessions() {
        let directory=tempfile::tempdir().unwrap(); let root=directory.path();
        let settings=|knowledge:bool,tasks:bool| crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"tasks":tasks,"knowledgeBase":knowledge}})).unwrap();
        settings(true,true);
        let note:crate::notes::CapturedNote=serde_json::from_value(json!({"id":"source","kind":"note","title":"Пилот","text":"Пилотный договор","revision":0,"createdAt":1.0,"updatedAt":1.0})).unwrap();
        let note=crate::notes::save_note(root,note).unwrap();
        request(root,"task-agent-settings",json!({"enabled":true,"expectedRevision":0,"operationID":id()}));
        let task=request(root,"task-create",json!({"title":"Task","operationID":id()}));
        let task_id=task["id"].as_str().unwrap();
        let grant=create(root,task_id,&[(note.id.clone(),note.revision)],now()+600).unwrap();
        let session=begin(root,&grant).unwrap();
        let receipt=search(root,&session,"пилот",10).unwrap()["receiptID"].as_str().unwrap().to_owned();
        report(root,&session,0,&id(),"CONFIDENTIAL",&[],&[receipt]).unwrap();
        assert!(history_for_owner(root,task_id).unwrap().to_string().contains("CONFIDENTIAL"));
        assert!(history_for_agent(root,&session).unwrap().to_string().contains("CONFIDENTIAL"));
        settings(false,true);
        assert!(!history_for_owner(root,task_id).unwrap().to_string().contains("CONFIDENTIAL"));
        assert!(history_for_agent(root,&session).is_err());
        settings(true,true);
        assert!(history_for_owner(root,task_id).unwrap().to_string().contains("CONFIDENTIAL"));
        assert!(history_for_agent(root,&session).is_err()); // Re-enabling cannot revive the old grant.
        settings(true,false);
        assert!(history_for_owner(root,task_id).is_err());
    }
    #[test]
    fn maintenance_is_nonblocking_and_a_busy_store_never_undoes_a_delete() {
        let directory=tempfile::tempdir().unwrap(); let root=directory.path();
        crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"tasks":true,"knowledgeBase":true}})).unwrap();
        let note:crate::notes::CapturedNote=serde_json::from_value(json!({"id":"source","kind":"note","text":"Текст","revision":0,"createdAt":1.0,"updatedAt":1.0})).unwrap();
        let note=crate::notes::save_note(root,note).unwrap();
        drop(open(root).unwrap());
        let notes_dir=crate::notes::directory(root).unwrap();
        let notes_guard=crate::notes::lock(&notes_dir).unwrap();
        let started=std::time::Instant::now();
        assert!(reconcile_deleted_sources(root).is_err());
        assert!(started.elapsed()<Duration::from_secs(2));
        drop(notes_guard);
        let db=open(root).unwrap();
        db.execute_batch("BEGIN IMMEDIATE").unwrap();
        let started=std::time::Instant::now();
        let deleted=crate::notes::delete_note(root,"source",note.revision).unwrap();
        assert_eq!(deleted["deleted"],true);
        assert_eq!(deleted["cleanupPending"],true);
        assert!(started.elapsed()<Duration::from_secs(2));
        db.execute_batch("ROLLBACK").unwrap();
        assert!(crate::notes::load_note_snapshot(root,"source").is_err());
        assert!(reconcile_deleted_sources(root).is_ok());
    }
    #[test]
    fn isolated_report_requires_fresh_evidence_and_completion_is_replay_safe() {
        let directory=tempfile::tempdir().unwrap(); let root=directory.path();
        crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"tasks":true,"knowledgeBase":true}})).unwrap();
        let note:crate::notes::CapturedNote=serde_json::from_value(json!({"id":"chosen","kind":"note","title":"Пилот","text":"Пилотный договор","revision":0,"createdAt":1.0,"updatedAt":1.0})).unwrap();
        let note=crate::notes::save_note(root,note).unwrap();
        let extra:crate::notes::CapturedNote=serde_json::from_value(json!({"id":"also-shared","kind":"note","title":"Контекст","text":"Дополнительный контекст","revision":0,"createdAt":1.0,"updatedAt":1.0})).unwrap();
        let extra=crate::notes::save_note(root,extra).unwrap();
        request(root,"task-agent-settings",json!({"enabled":true,"expectedRevision":0,"operationID":id()}));
        let task=request(root,"task-create",json!({"title":"Task","operationID":id()}));
        let task_id=task["id"].as_str().unwrap();
        let grant=create(root,task_id,&[(note.id.clone(),note.revision),(extra.id.clone(),extra.revision)],now()+600).unwrap();
        let session=begin(root,&grant).unwrap();
        let other=begin(root,&grant).unwrap();
        let result=search(root,&session,"пилот",10).unwrap();
        let receipts=vec![result["receiptID"].as_str().unwrap().to_owned()];
        let artifacts=vec![Artifact{title:"Итоги".into(),kind:"report".into(),text:"Договор найден".into(),url:None}];
        let op=id();
        assert!(report(root,&other,0,&id(),"Результат",&artifacts,&receipts).is_err());
        assert!(report(root,&session,0,&id(),"Результат",&artifacts,&[]).is_err());
        let mut invalid=artifacts.clone(); invalid[0].url=Some("file:///tmp/secret".into());
        assert!(report(root,&session,0,&id(),"Результат",&invalid,&receipts).is_err());
        let first=report(root,&session,0,&op,"Результат",&artifacts,&receipts).unwrap();
        assert_eq!(first["revision"],1);
        assert_eq!(report(root,&session,0,&op,"Результат",&artifacts,&receipts).unwrap(),first);
        assert!(report(root,&session,0,&op,"Другой результат",&artifacts,&receipts).is_err());
        assert!(complete(root,&session,0,&id()).is_err());
        let finish=id(); let completed=complete(root,&session,1,&finish).unwrap();
        assert_eq!(completed["revision"],2);
        assert_eq!(complete(root,&session,1,&finish).unwrap(),completed);
        assert!(search(root,&session,"пилот",10).is_err());
        // Nothing was inserted into the old task or exposed through its MCP.
        let current=request(root,"task-get",json!({"taskID":task_id}));
        assert_eq!(current["completed"],false);
        assert!(!current["history"].to_string().contains("Договор найден"));
        assert!(crate::task_workspace::dispatch(root,&json!({"command":"task-context","taskID":task_id,"agentOnly":true})).is_err());
        revoke(root,&grant).unwrap();
        assert!(complete(root,&session,1,&finish).is_err());
        assert!(report(root,&session,0,&op,"Результат",&artifacts,&receipts).is_err());
        let db=open(root).unwrap();
        let persisted:i64=db.query_row("SELECT COUNT(*) FROM scoped_reports WHERE id=?1",[first["reportID"].as_str().unwrap()],|r|r.get(0)).unwrap();
        assert_eq!(persisted,1); // Revoking agent access does not erase user data.
        let disclosures:Vec<String>=db.prepare("SELECT note_id FROM scoped_report_disclosures WHERE report_id=?1 ORDER BY note_id").unwrap()
            .query_map([first["reportID"].as_str().unwrap()],|r|r.get(0)).unwrap()
            .collect::<rusqlite::Result<Vec<_>>>().unwrap();
        assert_eq!(disclosures,vec!["also-shared","chosen"]); // Even the uncited grant member is retained.
    }
    #[test]
    fn report_completion_rejects_changed_source_and_legacy_access() {
        let directory=tempfile::tempdir().unwrap(); let root=directory.path();
        crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"tasks":true,"knowledgeBase":true}})).unwrap();
        let note:crate::notes::CapturedNote=serde_json::from_value(json!({"id":"source","kind":"note","title":"Пилот","text":"Пилотный договор","revision":0,"createdAt":1.0,"updatedAt":1.0})).unwrap();
        let note=crate::notes::save_note(root,note).unwrap();
        request(root,"task-agent-settings",json!({"enabled":true,"expectedRevision":0,"operationID":id()}));
        let task=request(root,"task-create",json!({"title":"Task","operationID":id()}));
        let task_id=task["id"].as_str().unwrap();
        let grant=create(root,task_id,&[(note.id.clone(),note.revision)],now()+600).unwrap();
        let session=begin(root,&grant).unwrap();
        let receipt=search(root,&session,"пилот",10).unwrap()["receiptID"].as_str().unwrap().to_owned();
        let operation=id();
        report(root,&session,0,&operation,"Найдено",&[],&[receipt.clone()]).unwrap();
        let mut edited=note.clone(); edited.text="Новое содержание".into();
        let edited=crate::notes::save_note(root,edited).unwrap();
        assert!(report(root,&session,0,&operation,"Найдено",&[],&[receipt]).is_err());
        assert!(complete(root,&session,1,&id()).is_err());
        let grant=create(root,task_id,&[(edited.id.clone(),edited.revision)],now()+600).unwrap();
        let session=begin(root,&grant).unwrap();
        let receipt=search(root,&session,"новое",10).unwrap()["receiptID"].as_str().unwrap().to_owned();
        report(root,&session,0,&id(),"Найдено",&[],&[receipt]).unwrap();
        let current=request(root,"task-get",json!({"taskID":task_id}));
        request(root,"task-details-update",json!({"taskID":task_id,"expectedRevision":current["revision"],"operationID":id(),"patch":{"agentAccess":{"enabled":true}}}));
        assert!(complete(root,&session,1,&id()).is_err());
    }
    #[test]
    fn fixed_grant_is_separate_from_legacy_and_session_revoke_prevents_replay() {
        let directory=tempfile::tempdir().unwrap(); let root=directory.path();
        crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"tasks":true,"knowledgeBase":true}})).unwrap();
        let note:crate::notes::CapturedNote=serde_json::from_value(json!({"id":"chosen","kind":"note","title":"Private","text":"Private text","revision":0,"createdAt":1.0,"updatedAt":1.0})).unwrap();
        let note=crate::notes::save_note(root,note).unwrap();
        request(root,"task-agent-settings",json!({"enabled":true,"expectedRevision":0,"operationID":id()}));
        let task=request(root,"task-create",json!({"title":"Task","operationID":id()}));
        let task_id=task["id"].as_str().unwrap();
        let grant=create(root,task_id,&[(note.id.clone(),note.revision)],now()+600).unwrap();
        let legacy=crate::task_workspace::dispatch(root,&json!({"command":"task-context","taskID":task_id,"agentOnly":true}));
        assert!(legacy.is_err());
        let session=begin(root,&grant).unwrap();
        let (target,sources)=authorize(root,&session).unwrap();
        assert_eq!(target,task_id); assert_eq!(sources,vec!["chosen"]);
        let forged=Session { run:session.run.clone(), capability:id() };
        assert!(authorize(root,&forged).is_err());
        let other=begin(root,&grant).unwrap();
        let swapped=Session { run:other.run.clone(), capability:session.capability.clone() };
        assert!(authorize(root,&swapped).is_err());
        let db=open(root).unwrap();
        let stored:String=db.query_row("SELECT capability_hash FROM runs WHERE id=?1",[&session.run],|r|r.get(0)).unwrap();
        assert_ne!(stored,session.capability); drop(db);
        revoke(root,&grant).unwrap();
        assert!(authorize(root,&session).is_err());
        assert!(begin(root,&grant).is_err());

        // A source edit is a conservative invalidation, not an opportunity
        // to return stale bytes from the earlier session.
        let grant=create(root,task_id,&[(note.id.clone(),note.revision)],now()+600).unwrap();
        let session=begin(root,&grant).unwrap();
        let mut edited=crate::notes::load_note_snapshot(root,&note.id).unwrap();
        edited.text="Edited".into();
        let edited=crate::notes::save_note(root,edited).unwrap();
        assert!(authorize(root,&session).is_err());

        // Turning a capability off and back on must not revive the old run.
        let grant=create(root,task_id,&[(edited.id.clone(),edited.revision)],now()+600).unwrap();
        let session=begin(root,&grant).unwrap();
        crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"tasks":true,"knowledgeBase":false}})).unwrap();
        assert!(authorize(root,&session).is_err());
        crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"tasks":true,"knowledgeBase":true}})).unwrap();
        assert!(authorize(root,&session).is_err());

        // Revoking and later re-enabling task access also invalidates the run.
        let grant=create(root,task_id,&[(edited.id.clone(),edited.revision)],now()+600).unwrap();
        let session=begin(root,&grant).unwrap();
        let current=request(root,"task-get",json!({"taskID":task_id}));
        let changed=request(root,"task-details-update",json!({"taskID":task_id,"expectedRevision":current["revision"],"operationID":id(),"patch":{"agentAccess":{"enabled":true}}}));
        assert!(authorize(root,&session).is_err());
        request(root,"task-details-update",json!({"taskID":task_id,"expectedRevision":changed["revision"],"operationID":id(),"patch":{"agentAccess":{"enabled":false}}}));
        assert!(authorize(root,&session).is_err());
        assert!(create(root,task_id,&[(edited.id.clone(),edited.revision+1)],now()+600).is_err());
        assert!(create(root,task_id,&[(edited.id.clone(),edited.revision)],now()-1).is_err());
    }

    #[test]
    fn scoped_search_read_stays_inside_run_and_fences_revocation_and_edits() {
        let directory=tempfile::tempdir().unwrap(); let root=directory.path();
        crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"tasks":true,"knowledgeBase":true}})).unwrap();
        let make=|id:&str,title:&str,text:&str| {
            let note:crate::notes::CapturedNote=serde_json::from_value(json!({"id":id,"kind":"note","title":title,"text":text,"revision":0,"createdAt":1.0,"updatedAt":1.0})).unwrap();
            crate::notes::save_note(root,note).unwrap()
        };
        let chosen=make("chosen-id","Пилот","Пилот, договор и важные условия");
        let hidden=make("hidden-id","Пилот тайное","Пилот PRIVATE-SECRET");
        request(root,"task-agent-settings",json!({"enabled":true,"expectedRevision":0,"operationID":id()}));
        let task=request(root,"task-create",json!({"title":"Task","operationID":id()}));
        let task_id=task["id"].as_str().unwrap();
        let grant=create(root,task_id,&[(chosen.id.clone(),chosen.revision)],now()+600).unwrap();
        let session=begin(root,&grant).unwrap();
        let first=search(root,&session,"пилот",10).unwrap();
        assert_eq!(first["results"].as_array().unwrap().len(),1);
        assert!(!first.to_string().contains("PRIVATE-SECRET"));
        assert!(!first.to_string().contains("chosen-id"));
        let mut changed_hidden=hidden.clone(); changed_hidden.text="Пилот DIFFERENT SECRET".into();
        crate::notes::save_note(root,changed_hidden).unwrap();
        let after=search(root,&session,"пилот",10).unwrap();
        assert_eq!(first["results"][0]["title"],after["results"][0]["title"]);
        assert_eq!(first["results"][0]["fingerprint"],after["results"][0]["fingerprint"]);
        let receipt=first["receiptID"].as_str().unwrap();
        let source_id=first["results"][0]["sourceID"].as_str().unwrap();
        let fp=first["results"][0]["fingerprint"].as_str().unwrap();
        assert_eq!(read(root,&session,receipt,source_id,fp).unwrap()["text"],chosen.text);
        let other=begin(root,&grant).unwrap();
        assert!(read(root,&other,receipt,source_id,fp).is_err());
        assert!(read(root,&session,receipt,source_id,&"0".repeat(64)).is_err());
        assert!(read(root,&session,receipt,&id(),fp).is_err());
        assert!(search(root,&session,"пилот",21).is_err());
        assert!(search(root,&session,&"a".repeat(2001),1).is_err());

        // A real independent revocation happens after results have been
        // prepared and before the receipt and value can be returned.
        assert!(search_before_publish(root,&session,"пилот",10,|| {
            std::thread::scope(|s| s.spawn(|| revoke(root,&grant).unwrap()).join().unwrap());
        }).is_err());
        assert!(read(root,&session,receipt,source_id,fp).is_err());
        let db=open(root).unwrap();
        let count:i64=db.query_row("SELECT COUNT(*) FROM receipts WHERE run_id=?1",[&session.run],|r|r.get(0)).unwrap();
        assert_eq!(count,0); drop(db);

        let grant=create(root,task_id,&[(chosen.id.clone(),chosen.revision)],now()+600).unwrap();
        let session=begin(root,&grant).unwrap();
        let result=search(root,&session,"пилот",10).unwrap();
        let receipt=result["receiptID"].as_str().unwrap();
        let source_id=result["results"][0]["sourceID"].as_str().unwrap();
        let fp=result["results"][0]["fingerprint"].as_str().unwrap();
        assert!(read_before_publish(root,&session,receipt,source_id,fp,|| {
            std::thread::scope(|s| s.spawn(|| {
                let mut note=crate::notes::load_note_snapshot(root,"chosen-id").unwrap();
                note.text="Changed while preparing the answer".into();
                crate::notes::save_note(root,note).unwrap();
            }).join().unwrap());
        }).is_err());
    }
}
