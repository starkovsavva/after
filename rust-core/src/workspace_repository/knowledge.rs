//! Canonical user decisions for knowledge links. All operations use the same
//! notes lock and SQLite transaction as the rest of the workspace.
use super::*;
use rusqlite::backup::Backup;
use std::os::unix::fs::DirBuilderExt;
use std::sync::{Mutex,OnceLock};
use uuid::Uuid;

const MIGRATION_DIR: &str = ".knowledge-migration";
const JOURNAL: &str = "current.json";
const KB_SCHEMA: i64 = 2;
const FINALIZED_KEY: &str = "knowledge_migration_finalized";
const MEETING_LINKS_TABLE:&str = "CREATE TABLE IF NOT EXISTS kb_meeting_links(\
    id TEXT PRIMARY KEY,note_id TEXT NOT NULL,source_key TEXT NOT NULL,source_ref TEXT NOT NULL,\
    revision INTEGER NOT NULL,deleted INTEGER NOT NULL,created_at REAL NOT NULL,updated_at REAL NOT NULL,\
    UNIQUE(note_id,source_key))";
const DELETE_CURSOR_KEY: &str = "knowledge_delete_cursor";

/// The extension has its own internal format. SQLite user_version remains 1
/// because no existing workspace table or its semantics are changed.
pub(super) fn has_extension(connection: &Connection) -> Result<bool> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='kb_state')",
        [], |row| row.get(0),
    )?)
}

fn finalized(connection: &Connection) -> Result<bool> {
    let value: Option<String> = connection.query_row(
        "SELECT value FROM workspace_metadata WHERE key=?1", [FINALIZED_KEY], |row| row.get(0)
    ).optional()?;
    Ok(value.as_deref() == Some("2"))
}
fn mark_finalized(connection: &Connection) -> Result<()> {
    connection.execute("INSERT OR REPLACE INTO workspace_metadata(key,value) VALUES(?1,'2')", [FINALIZED_KEY])?;
    Ok(())
}

fn uuid() -> String { Uuid::new_v4().to_string() }
fn required_string<'a>(input: &'a Value, key: &str) -> Result<&'a str> {
    input[key].as_str().with_context(|| format!("Нет поля {key}"))
}
fn identifier(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128 &&
        value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn revision(input: &Value, key: &str) -> Result<u64> {
    input[key].as_u64().with_context(|| format!("Нет ревизии {key}"))
}
fn migration_dir(root: &Path) -> Result<PathBuf> {
    let directory = root.join(MIGRATION_DIR);
    match fs::symlink_metadata(&directory) {
        Ok(meta) => ensure!(meta.is_dir() && !meta.file_type().is_symlink(), "Некорректная папка резервной копии"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::DirBuilder::new().mode(0o700).create(&directory)?;
        }
        Err(error) => return Err(error.into()),
    }
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
    Ok(fs::canonicalize(directory)?)
}
fn backup_path(directory: &Path, value: &Value, key: &str) -> Result<PathBuf> {
    let name = required_string(value, key)?;
    ensure!(name.len() <= 100 && name.ends_with(".sqlite") &&
        name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.')),
        "Некорректное имя резервной копии");
    Ok(directory.join(name))
}
fn sqlite_backup(source: &Connection, path: &Path) -> Result<()> {
    // Create the destination ourselves: SQLite must never follow an existing
    // symlink, replace another file, or publish a partial backup as complete.
    let file = OpenOptions::new().write(true).create_new(true).mode(0o600)
        .custom_flags(libc::O_NOFOLLOW).open(path)?;
    drop(file);
    let result = (|| -> Result<()> {
        let mut destination = Connection::open_with_flags(path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW)?;
        {
            let backup = Backup::new(source, &mut destination)?;
            backup.run_to_completion(128, Duration::from_millis(10), None)?;
        }
        let check: String = destination.pragma_query_value(None, "integrity_check", |row| row.get(0))?;
        ensure!(check == "ok", "Проверка резервной копии не прошла");
        drop(destination);
        File::open(path)?.sync_all()?;
        sync_parent(path);
        Ok(())
    })();
    if result.is_err() { let _ = fs::remove_file(path); }
    result
}
fn check_backup(path: &Path, expected_revision: u64, expected_fingerprint: &str) -> Result<()> {
    ensure!(ordinary(path)?, "Не найдена резервная копия базы знаний");
    let connection = Connection::open_with_flags(path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW)?;
    let check: String = connection.pragma_query_value(None, "integrity_check", |row| row.get(0))?;
    ensure!(check == "ok", "Резервная копия повреждена");
    let snapshot = read_snapshot(&connection)?.context("В резервной копии нет заметок")?;
    ensure!(snapshot.revision == expected_revision && snapshot.fingerprint == expected_fingerprint &&
        hash(&snapshot.value)? == snapshot.fingerprint, "Резервная копия не совпадает с исходной библиотекой");
    Ok(())
}
fn write_journal(path: &Path, value: &Value) -> Result<()> {
    crate::storage::atomic_json(path, value)?;
    File::open(path)?.sync_all()?;
    sync_parent(path);
    Ok(())
}
pub(super) fn assert_migration_ready(connection: &Connection, root: &Path) -> Result<()> {
    // Once the completion marker is durable, backups and the external journal
    // are no longer needed for normal reads. Their removal must not make a
    // healthy, already-migrated library inaccessible.
    if finalized(connection)? { return Ok(()); }
    let directory=root.join(MIGRATION_DIR);
    let metadata=fs::symlink_metadata(&directory)?;
    ensure!(metadata.is_dir() && !metadata.file_type().is_symlink(), "Некорректный журнал обновления");
    let path=directory.join(JOURNAL);
    let bytes=read_bytes(&path)?.context("Не найден журнал обновления базы знаний")?;
    let journal:Value=serde_json::from_slice(&bytes)?;
    ensure!(journal["schema"] == KB_SCHEMA && journal["state"] == "committed",
        "Обновление базы знаний прервано. Перезапустите After для восстановления.");
    Ok(())
}

/// Complete an interrupted post-commit migration before any new workspace
/// operation. The old schema is never re-imported over the committed database.
pub(super) fn recover_migration(connection: &Connection, root: &Path) -> Result<()> {
    if finalized(connection)? { return Ok(()); }
    let directory = migration_dir(root)?;
    let path = directory.join(JOURNAL);
    let bytes = read_bytes(&path)?.context("Не найден журнал обновления базы знаний. Восстановите резервную копию.")?;
    let mut journal: Value = serde_json::from_slice(&bytes)?;
    ensure!(journal["schema"] == KB_SCHEMA, "Некорректный журнал обновления");
    let backup = backup_path(&directory, &journal, "coreBackup")?;
    let state: Option<String> = connection.query_row("SELECT library_id FROM kb_state WHERE singleton=1", [], |row| row.get(0)).optional()?;
    ensure!(state.as_deref().is_some_and(|value| Uuid::parse_str(value).is_ok()), "Обновление базы знаний не завершено");
    if journal["state"] == "prepared" {
        check_backup(&backup, revision(&journal, "workspaceRevision")?, required_string(&journal, "workspaceFingerprint")?)?;
        let current = read_snapshot(connection)?.context("В базе отсутствует основное состояние")?;
        let original_revision = revision(&journal, "workspaceRevision")?;
        ensure!(hash(&current.value)? == current.fingerprint && current.revision >= original_revision,
            "После прерванного обновления обнаружены повреждённые данные. Требуется восстановление.");
        if current.revision == original_revision {
            ensure!(current.fingerprint == required_string(&journal, "workspaceFingerprint")?,
                "После прерванного обновления обнаружены изменения. Требуется восстановление.");
        } else {
            // A released v1 writer may legitimately save a note after the
            // extension transaction committed and this process crashed.
            // Before finalization no new client can write KB decisions, and
            // the old client does not know these tables. Never accept a newer
            // snapshot if any KB operation actually ran in that gap.
            let kb_revision: i64 = connection.query_row("SELECT revision FROM kb_state WHERE singleton=1", [], |r| r.get(0))?;
            let changed: i64 = connection.query_row(
                "SELECT (SELECT COUNT(*) FROM kb_links)+(SELECT COUNT(*) FROM kb_feedback)+(SELECT COUNT(*) FROM kb_operations)+(SELECT COUNT(*) FROM kb_events)",
                [], |r| r.get(0))?;
            ensure!(kb_revision == 0 && changed == 0, "После прерванного обновления изменились связи. Требуется восстановление.");
        }
        journal["state"] = json!("committed");
        write_journal(&path, &journal)?;
    } else {
        ensure!(journal["state"] == "committed", "Некорректное состояние журнала обновления");
    }
    // This marker is written only after the committed journal is durable.
    // A crash before this point still follows the recovery path above.
    mark_finalized(connection)?;
    Ok(())
}

/// A reserved jobs transaction prevents new queue writes during the backup and
/// the core migration. No jobs schema or worker is modified by this step.
fn lock_jobs(root: &Path) -> Result<Option<Connection>> {
    let path = root.join("jobs.sqlite");
    if !ordinary(&path)? { return Ok(None); }
    for suffix in ["-journal", "-wal", "-shm"] { ordinary(&root.join(format!("jobs.sqlite{suffix}")))?; }
    let path=fs::canonicalize(root)?.join("jobs.sqlite");
    let connection = Connection::open_with_flags(&path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW)?;
    connection.busy_timeout(Duration::from_secs(5))?;
    let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    ensure!(version <= 2, "Очередь создана более новой версией After");
    connection.execute_batch("BEGIN IMMEDIATE")?;
    if version > 0 {
        let active: i64 = connection.query_row(
            "SELECT COUNT(*) FROM jobs WHERE state IN ('queued','running')", [], |row| row.get(0))?;
        ensure!(active == 0, "Дождитесь завершения фоновых задач перед включением базы знаний");
    }
    Ok(Some(connection))
}
pub(super) fn migrate(connection: &mut Connection, directory: &Path, snapshot: &WorkspaceSnapshot) -> Result<()> {
    let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    ensure!(version == WORKSPACE_VERSION, "Неподдерживаемая версия базы знаний");
    if has_extension(connection)? {
        // Existing prerelease libraries may predate saved collections. This
        // additive table contains only user-authored decisions and leaves the
        // released v1 workspace format and its writers unchanged.
        connection.execute_batch("CREATE TABLE IF NOT EXISTS kb_collections(id TEXT PRIMARY KEY,name TEXT NOT NULL,members TEXT NOT NULL,pinned INTEGER NOT NULL,hidden INTEGER NOT NULL,revision INTEGER NOT NULL,created_at REAL NOT NULL,updated_at REAL NOT NULL)")?;
        connection.execute_batch(MEETING_LINKS_TABLE)?;
        reconcile_removed(connection,snapshot.revision)?;
        return Ok(());
    }
    let root = root(directory)?;
    let jobs = lock_jobs(root)?;
    let destination = migration_dir(root)?;
    let nonce = uuid();
    let core_name = format!("core-v1-{nonce}.sqlite");
    let core_path = destination.join(&core_name);
    sqlite_backup(connection, &core_path)?;
    check_backup(&core_path, snapshot.revision, &snapshot.fingerprint)?;
    let jobs_name = if jobs.is_some() {
        let name = format!("jobs-v2-{nonce}.sqlite");
        let source = Connection::open_with_flags(fs::canonicalize(root)?.join("jobs.sqlite"),
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW)?;
        sqlite_backup(&source, &destination.join(&name))?;
        Some(name)
    } else { None };
    let journal_path = destination.join(JOURNAL);
    let mut journal = json!({"schema":KB_SCHEMA,"state":"prepared","coreBackup":core_name,
        "jobsBackup":jobs_name,"workspaceRevision":snapshot.revision,"workspaceFingerprint":snapshot.fingerprint});
    write_journal(&journal_path, &journal)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch("\
        CREATE TABLE kb_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),\
            library_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>=0), fingerprint TEXT NOT NULL);\
        CREATE TABLE kb_links(id TEXT PRIMARY KEY, from_id TEXT NOT NULL, to_id TEXT NOT NULL,\
            relation TEXT NOT NULL, reason TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>=1),\
            deleted INTEGER NOT NULL CHECK(deleted IN (0,1)), created_at REAL NOT NULL, updated_at REAL NOT NULL);\
        CREATE UNIQUE INDEX kb_links_active_pair ON kb_links(from_id,to_id,relation) WHERE deleted=0;\
        CREATE INDEX kb_links_from ON kb_links(from_id,deleted);\
        CREATE INDEX kb_links_to ON kb_links(to_id,deleted);\
        CREATE TABLE kb_feedback(first_id TEXT NOT NULL, second_id TEXT NOT NULL, blocked INTEGER NOT NULL CHECK(blocked IN (0,1)),\
            revision INTEGER NOT NULL CHECK(revision>=1), updated_at REAL NOT NULL, PRIMARY KEY(first_id,second_id));\
        CREATE TABLE kb_operations(operation_id TEXT PRIMARY KEY, request_hash TEXT NOT NULL, kind TEXT NOT NULL,\
            before_value TEXT NOT NULL, after_value TEXT NOT NULL, result TEXT NOT NULL, undone INTEGER NOT NULL DEFAULT 0);\
        CREATE TABLE kb_events(operation_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, kind TEXT NOT NULL, created_at REAL NOT NULL);\
        CREATE TABLE kb_collections(id TEXT PRIMARY KEY,name TEXT NOT NULL,members TEXT NOT NULL,pinned INTEGER NOT NULL,hidden INTEGER NOT NULL,revision INTEGER NOT NULL,created_at REAL NOT NULL,updated_at REAL NOT NULL);")?;
    transaction.execute_batch(MEETING_LINKS_TABLE)?;
    transaction.execute("INSERT INTO kb_state VALUES(1,?1,0,?2)",
        params![uuid(), hash(&json!({"links":[],"feedback":[]}))?])?;
    transaction.execute("INSERT OR REPLACE INTO workspace_metadata(key,value) VALUES(?1,?2)",
        params![DELETE_CURSOR_KEY,snapshot.revision.to_string()])?;
    transaction.commit()?;
    journal["state"] = json!("committed");
    write_journal(&journal_path, &journal)?;
    mark_finalized(connection)?;
    // Dropping this connection rolls the empty jobs transaction back.
    drop(jobs);
    Ok(())
}

fn enabled(root: &Path, source: Option<&str>) -> Result<bool> {
    let profiles = crate::ai::FeatureResolver::new(root)?;
    if let Some(id) = source {
        Ok(profiles.features_for(&json!({"noteID":id}))?.knowledge_base)
    } else {
        Ok(crate::ai::live_features(root)?.knowledge_base)
    }
}
fn enabled_anywhere(root: &Path) -> Result<bool> {
    Ok(crate::folders::available_features(root)?.knowledge_base)
}
fn note<'a>(workspace: &'a crate::notes::NotesWorkspace, id: &str, require_live: bool) -> Result<&'a crate::notes::CapturedNote> {
    ensure!(identifier(id), "Некорректный идентификатор заметки");
    let note = workspace.notes.iter().find(|n| n.id == id && n.kind == "note").context("Заметка больше недоступна")?;
    ensure!(!require_live || note.trashed_at.is_none(), "Заметка находится в корзине");
    Ok(note)
}
pub(super) fn state(connection: &Connection) -> Result<(String, u64, String)> {
    connection.query_row("SELECT library_id,revision,fingerprint FROM kb_state WHERE singleton=1", [], |row|
        Ok((row.get(0)?, row.get::<_,i64>(1)? as u64, row.get(2)?))).map_err(Into::into)
}
fn link_row(connection: &Connection, from: &str, to: &str) -> Result<Option<Value>> {
    connection.query_row("SELECT id,reason,revision,deleted,created_at,updated_at FROM kb_links WHERE from_id=?1 AND to_id=?2 AND relation='manual_link' ORDER BY deleted,updated_at DESC LIMIT 1",
        params![from,to], |r| Ok(json!({"id":r.get::<_,String>(0)?,"fromID":from,"toID":to,"relation":"manual_link",
            "reason":r.get::<_,String>(1)?,"revision":r.get::<_,i64>(2)?,"deleted":r.get::<_,i64>(3)? != 0,
            "createdAt":r.get::<_,f64>(4)?,"updatedAt":r.get::<_,f64>(5)?}))).optional().map_err(Into::into)
}
fn ordered_pair<'a>(a: &'a str,b: &'a str) -> (&'a str,&'a str) {
    if a < b { (a,b) } else { (b,a) }
}
fn feedback_row(connection: &Connection, first: &str, second: &str) -> Result<Option<Value>> {
    connection.query_row("SELECT blocked,revision,updated_at FROM kb_feedback WHERE first_id=?1 AND second_id=?2",
        params![first,second],|r| Ok(json!({"firstID":first,"secondID":second,"blocked":r.get::<_,i64>(0)? != 0,
            "revision":r.get::<_,i64>(1)?,"updatedAt":r.get::<_,f64>(2)?}))).optional().map_err(Into::into)
}
pub(super) fn list_links(connection: &Connection) -> Result<Vec<Value>> {
    let mut stmt=connection.prepare("SELECT id,from_id,to_id,reason,revision,deleted,created_at,updated_at FROM kb_links ORDER BY id")?;
    let rows=stmt.query_map([],|r| Ok(json!({"id":r.get::<_,String>(0)?,"fromID":r.get::<_,String>(1)?,
        "toID":r.get::<_,String>(2)?,"relation":"manual_link","reason":r.get::<_,String>(3)?,
        "revision":r.get::<_,i64>(4)?,"deleted":r.get::<_,i64>(5)? != 0,
        "createdAt":r.get::<_,f64>(6)?,"updatedAt":r.get::<_,f64>(7)?})))?;
    rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
}
pub(super) fn list_collections(connection: &Connection) -> Result<Vec<Value>> {
    let mut stmt=connection.prepare("SELECT id,name,members,pinned,hidden,revision,created_at,updated_at FROM kb_collections ORDER BY pinned DESC,updated_at DESC,id")?;
    let rows=stmt.query_map([],|r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,
        r.get::<_,i64>(3)?,r.get::<_,i64>(4)?,r.get::<_,i64>(5)?,r.get::<_,f64>(6)?,r.get::<_,f64>(7)?)))?;
    let mut result=Vec::new();
    for row in rows {
        let (id,name,members,pinned,hidden,revision,created_at,updated_at)=row?;
        let members:Vec<String>=serde_json::from_str(&members).context("Повреждён состав подборки")?;
        ensure!(Uuid::parse_str(&id).is_ok() && name.len()<=500 && !name.trim().is_empty() &&
            (1..=200).contains(&members.len()) && members.iter().all(|id|identifier(id)) &&
            (0..=1).contains(&pinned) && (0..=1).contains(&hidden) && revision>=1,"Повреждена подборка");
        result.push(json!({"id":id,"name":name,"members":members,"pinned":pinned!=0,"hidden":hidden!=0,
            "revision":revision,"createdAt":created_at,"updatedAt":updated_at}));
    }
    Ok(result)
}
fn collection_row(connection:&Connection,id:&str)->Result<Option<Value>> {
    Ok(list_collections(connection)?.into_iter().find(|row|row["id"]==id))
}
/// Only stable source references are persisted, never meeting titles, excerpts
/// or transcript text. Content and permissions are re-read on every use.
fn meeting_source_ref(source:&crate::knowledge_meetings::MeetingSource)->Value {
    json!({"meetingID":source.meeting_id,"kind":source.kind,"segmentID":source.segment_id,
        "itemIndex":source.item_index,"contentFingerprint":source.content_fingerprint,
        "policyFingerprint":source.policy_fingerprint})
}
// Older builds included the complete AI profile in stored refs. A model change
// does not change a content version; snapshot() checks present access separately.
fn meeting_ref_matches(source:&crate::knowledge_meetings::MeetingSource,saved:&Value)->bool {
    let current=meeting_source_ref(source);
    ["meetingID","kind","segmentID","itemIndex","contentFingerprint"].iter()
        .all(|field|current[*field]==saved[*field])
}
fn redact_meeting_operation(mut result:Value)->Value {
    if let Some(link)=result.get_mut("link").and_then(Value::as_object_mut) {
        link.remove("sourceRef");
        link.remove("sourceKey");
        link.remove("noteID");
    }
    result
}
pub(super) fn list_meeting_links(connection:&Connection,note_id:Option<&str>)->Result<Vec<Value>> {
    let mut statement=connection.prepare("SELECT id,note_id,source_key,source_ref,revision,deleted,created_at,updated_at FROM kb_meeting_links WHERE (?1 IS NULL OR note_id=?1) ORDER BY id")?;
    let rows=statement.query_map([note_id],|row|Ok((row.get::<_,String>(0)?,row.get::<_,String>(1)?,row.get::<_,String>(2)?,row.get::<_,String>(3)?,row.get::<_,i64>(4)?,row.get::<_,i64>(5)?,row.get::<_,f64>(6)?,row.get::<_,f64>(7)?)))?;
    let mut result=Vec::new();
    for row in rows {
        let (id,note,key,raw,revision,deleted,created,updated)=row?;
        let source:Value=serde_json::from_str(&raw).context("Повреждена ссылка на встречу")?;
        ensure!(Uuid::parse_str(&id).is_ok() && identifier(&note) && key.len()==64 && key.bytes().all(|b|b.is_ascii_hexdigit()) &&
            source["meetingID"].as_str().is_some_and(identifier) && ["transcript","summary"].contains(&source["kind"].as_str().unwrap_or("")) &&
            source["contentFingerprint"].as_str().is_some_and(|fp|fp.len()==64 && fp.bytes().all(|b|b.is_ascii_hexdigit())) &&
            revision>=1 && (0..=1).contains(&deleted),"Повреждена ссылка на встречу");
        result.push(json!({"id":id,"noteID":note,"sourceKey":key,"sourceRef":source,
            "revision":revision,"deleted":deleted!=0,"createdAt":created,"updatedAt":updated}));
    }
    Ok(result)
}
pub(super) fn fingerprint(connection: &Connection) -> Result<String> {
    let links=list_links(connection)?;
    let mut query=connection.prepare("SELECT first_id,second_id,blocked,revision FROM kb_feedback ORDER BY first_id,second_id")?;
    let feedback=query.query_map([],|r| Ok(json!({"firstID":r.get::<_,String>(0)?,"secondID":r.get::<_,String>(1)?,
        "blocked":r.get::<_,i64>(2)? != 0,"revision":r.get::<_,i64>(3)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    let collections=list_collections(connection)?;
    let meeting_links=list_meeting_links(connection,None)?;
    hash(&json!({"links":links,"feedback":feedback,"collections":collections,"meetingLinks":meeting_links}))
}
fn references_removed(value:&Value, removed:&BTreeSet<String>) -> bool {
    if let Some(object)=value.as_object() {
        for key in ["fromID","toID","firstID","secondID","noteID"] {
            if object.get(key).and_then(Value::as_str).is_some_and(|id|removed.contains(id)) {return true;}
        }
        if object.get("members").and_then(Value::as_array).is_some_and(|members|
            members.iter().filter_map(Value::as_str).any(|id|removed.contains(id))) {return true;}
    }
    false
}

/// Prune references in the same SQLite transaction as a new client's hard
/// delete. Redacted operation receipts remain as replay tombstones, so an old
/// operation ID cannot resurrect a link after an identifier is reused.
pub(super) fn prune_removed(transaction:&Transaction<'_>,removed:&BTreeSet<String>)->Result<bool> {
    if removed.is_empty() || !has_extension(transaction)? {return Ok(false);}
    transaction.execute_batch("CREATE TABLE IF NOT EXISTS kb_collections(id TEXT PRIMARY KEY,name TEXT NOT NULL,members TEXT NOT NULL,pinned INTEGER NOT NULL,hidden INTEGER NOT NULL,revision INTEGER NOT NULL,created_at REAL NOT NULL,updated_at REAL NOT NULL)")?;
    transaction.execute_batch(MEETING_LINKS_TABLE)?;
    let mut changed=super::knowledge_rebuild::prune_removed(transaction,removed)?;
    for id in removed {
        changed |= transaction.execute("DELETE FROM kb_links WHERE from_id=?1 OR to_id=?1",[id])? > 0;
        changed |= transaction.execute("DELETE FROM kb_feedback WHERE first_id=?1 OR second_id=?1",[id])? > 0;
        changed |= transaction.execute("DELETE FROM kb_meeting_links WHERE note_id=?1",[id])? > 0;
    }
    for collection in list_collections(transaction)? {
        let members=collection["members"].as_array().context("Повреждена подборка")?;
        let kept=members.iter().filter_map(Value::as_str).filter(|id|!removed.contains(*id)).collect::<Vec<_>>();
        if kept.len()==members.len() {continue;}
        let id=required_string(&collection,"id")?;
        if kept.is_empty() {
            transaction.execute("DELETE FROM kb_collections WHERE id=?1",[id])?;
        } else {
            transaction.execute("UPDATE kb_collections SET members=?1,revision=revision+1,updated_at=?2 WHERE id=?3",
                params![serde_json::to_string(&kept)?,now(),id])?;
        }
        changed=true;
    }
    let operations={
        let mut query=transaction.prepare("SELECT operation_id,before_value,after_value,request_hash FROM kb_operations")?;
        let rows=query.query_map([],|row|Ok((row.get::<_,String>(0)?,row.get::<_,String>(1)?,row.get::<_,String>(2)?,row.get::<_,String>(3)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        rows
    };
    for (id,before,after,request_hash) in operations {
        let before:Value=serde_json::from_str(&before)?; let after:Value=serde_json::from_str(&after)?;
        if !references_removed(&before,removed) && !references_removed(&after,removed) {continue;}
        let result=json!({"redacted":true,"undone":true});
        transaction.execute("UPDATE kb_operations SET before_value='null',after_value='null',result=?1,undone=1 WHERE operation_id=?2",
            params![serde_json::to_string(&result)?,id])?;
        transaction.execute("UPDATE operation_receipts SET payload=?1 WHERE namespace='knowledge' AND operation_id=?2",
            params![serde_json::to_string(&json!({"requestHash":request_hash,"result":result}))?,id])?;
        changed=true;
    }
    if changed {
        let (_,current,_)=state(transaction)?;
        let next=current.checked_add(1).context("Слишком большая ревизия базы знаний")?;
        ensure!(next<=i64::MAX as u64,"Слишком большая ревизия базы знаний");
        let digest=fingerprint(transaction)?;
        transaction.execute("UPDATE kb_state SET revision=?1,fingerprint=?2 WHERE singleton=1",params![next as i64,digest])?;
        transaction.execute("INSERT INTO kb_events VALUES(?1,?2,'source-purged',?3)",params![uuid(),next as i64,now()])?;
    }
    Ok(changed)
}

/// Released clients cannot call our cleanup hook. Their normal outbox contains
/// the deleted IDs, so consume those events before any new KB read or write.
/// This also detects delete+recreate of the same ID between two KB launches.
fn reconcile_removed(connection:&mut Connection,current_revision:u64)->Result<()> {
    let transaction=connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let cursor:Option<String>=transaction.query_row("SELECT value FROM workspace_metadata WHERE key=?1",
        [DELETE_CURSOR_KEY],|row|row.get(0)).optional()?;
    let previous=cursor.as_deref().map(str::parse::<u64>).transpose().context("Повреждён журнал базы знаний")?
        .unwrap_or(current_revision);
    ensure!(previous<=current_revision,"Повреждён журнал базы знаний");
    let events={
        let mut query=transaction.prepare("SELECT payload FROM workspace_outbox WHERE revision>?1 AND revision<=?2 ORDER BY revision,event_id")?;
        let rows=query.query_map(params![previous as i64,current_revision as i64],|row|row.get::<_,String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        rows
    };
    let mut removed=BTreeSet::new();
    for payload in events {
        let event:Value=serde_json::from_str(&payload).context("Повреждён журнал изменений")?;
        for change in event["changes"].as_array().into_iter().flatten() {
            if change["kind"]=="note" && change["change"]=="delete" {
                let id=required_string(change,"id")?;
                ensure!(identifier(id),"Повреждён журнал изменений");
                removed.insert(id.to_owned());
            }
        }
    }
    prune_removed(&transaction,&removed)?;
    transaction.execute("INSERT OR REPLACE INTO workspace_metadata(key,value) VALUES(?1,?2)",
        params![DELETE_CURSOR_KEY,current_revision.to_string()])?;
    transaction.commit()?;
    Ok(())
}
fn snapshot(root: &Path, connection: &Connection, workspace: &WorkspaceSnapshot, input: &Value) -> Result<Value> {
    ensure!(enabled_anywhere(root)?, "Включите базу знаний в настройках");
    let (library_id,kb_revision,kb_fingerprint)=state(connection)?;
    let data: crate::notes::NotesWorkspace=serde_json::from_value(workspace.value.clone())?;
    let mut links=Vec::new();
    if let Some(id)=input["noteID"].as_str() {
        note(&data,id,true)?;
        ensure!(enabled(root,Some(id))?, "База знаний выключена в этой папке");
        for link in list_links(connection)? {
            if link["deleted"] == true || (link["fromID"] != id && link["toID"] != id) { continue; }
            let other=if link["fromID"] == id { link["toID"].as_str().unwrap_or("") } else { link["fromID"].as_str().unwrap_or("") };
            if note(&data,other,true).is_ok() && enabled(root,Some(other)).unwrap_or(false) { links.push(link); }
        }
    }
    Ok(json!({"libraryID":library_id,"workspaceRevision":workspace.revision,"workspaceFingerprint":workspace.fingerprint,
        "kbRevision":kb_revision,"kbFingerprint":kb_fingerprint,"links":links}))
}

fn request_hash(input: &Value) -> Result<String> {
    let mut request=input.clone();
    if let Some(object)=request.as_object_mut() { object.remove("root"); }
    hash(&request)
}
fn operation_id(input: &Value) -> Result<&str> {
    let id=required_string(input,"operationID")?;
    ensure!(Uuid::parse_str(id).is_ok(), "Некорректный идентификатор операции");
    Ok(id)
}
fn replay(connection: &Connection, id: &str, digest: &str) -> Result<Option<Value>> {
    let row: Option<(String,String,bool)>=connection.query_row(
        "SELECT request_hash,result,undone FROM kb_operations WHERE operation_id=?1",[id],
        |r| Ok((r.get(0)?,r.get(1)?,r.get::<_,i64>(2)? != 0))).optional()?;
    let Some((previous,result,undone))=row else { return Ok(None) };
    ensure!(previous==digest, "Этот ID операции уже использован с другим содержимым");
    let mut result: Value=serde_json::from_str(&result)?;
    result["undone"]=json!(undone);
    Ok(Some(result))
}
fn advance(transaction: &Transaction<'_>, workspace: &WorkspaceSnapshot, kb_revision: u64,
           operation: &str, kind: &str) -> Result<(u64,u64,String)> {
    let next=workspace.revision.checked_add(1).context("Слишком большая ревизия библиотеки")?;
    let kb_next=kb_revision.checked_add(1).context("Слишком большая ревизия базы знаний")?;
    ensure!(next <= i64::MAX as u64 && kb_next <= i64::MAX as u64, "Слишком большая ревизия");
    ensure!(transaction.execute("UPDATE workspace_state SET revision=?1,updated_at=?2 WHERE singleton=1 AND revision=?3 AND fingerprint=?4",
        params![next as i64,now(),workspace.revision as i64,workspace.fingerprint])? == 1, "Библиотека изменилась. Обновите данные.");
    let digest=fingerprint(transaction)?;
    ensure!(transaction.execute("UPDATE kb_state SET revision=?1,fingerprint=?2 WHERE singleton=1 AND revision=?3",
        params![kb_next as i64,digest,kb_revision as i64])? == 1,"База знаний изменилась. Обновите данные.");
    let timestamp=now();
    transaction.execute("INSERT INTO workspace_outbox(event_id,revision,kind,created_at,payload) VALUES(?1,?2,'knowledge.changed',?3,?4)",
        params![uuid(),next as i64,timestamp,serde_json::to_string(&json!({"schemaVersion":1,"workspaceRevision":next,
            "knowledgeRevision":kb_next,"operationID":operation,"kind":kind}))?])?;
    transaction.execute("INSERT INTO kb_events VALUES(?1,?2,?3,?4)",params![operation,kb_next as i64,kind,timestamp])?;
    Ok((next,kb_next,digest))
}
fn record(transaction: &Transaction<'_>, input: &Value, kind: &str, before: &Value, after: &Value, result: &Value) -> Result<()> {
    let id=operation_id(input)?; let digest=request_hash(input)?;
    let serialized=serde_json::to_string(result)?;
    transaction.execute("INSERT INTO kb_operations VALUES(?1,?2,?3,?4,?5,?6,0)",
        params![id,digest,kind,serde_json::to_string(before)?,serde_json::to_string(after)?,serialized])?;
    transaction.execute("INSERT INTO operation_receipts(namespace,operation_id,workspace_revision,payload) VALUES('knowledge',?1,?2,?3)",
        params![id,result["workspaceRevision"].as_i64().context("Нет ревизии результата")?,
            serde_json::to_string(&json!({"requestHash":digest,"result":result}))?])?;
    Ok(())
}
/// A saved collection is an explicit snapshot of note IDs, independent of the
/// disposable topic cache. Editing a collection never edits its source notes.
fn change_collection(root:&Path,connection:&mut Connection,workspace:&WorkspaceSnapshot,input:&Value)->Result<Value> {
    let operation=operation_id(input)?;
    let digest=request_hash(input)?;
    let action=required_string(input,"action")?;
    ensure!(["create","rename","hide","unhide","pin","unpin","add-sources","remove-source"].contains(&action),"Неизвестное действие с подборкой");
    let data:crate::notes::NotesWorkspace=serde_json::from_value(workspace.value.clone())?;
    let target=if action=="create" {operation} else {required_string(input,"collectionID")?};
    ensure!(Uuid::parse_str(target).is_ok(),"Некорректная подборка");
    let before=collection_row(connection,target)?;
    if action=="create" {
        let sources=input["sources"].as_array().context("Нет заметок подборки")?;
        ensure!((1..=200).contains(&sources.len()) && sources.iter().all(|source|
            source["noteID"].as_str().is_some_and(|id|note(&data,id,true).is_ok() && enabled(root,Some(id)).unwrap_or(false))),
            "Заметка недоступна");
    } else {
        let row=before.as_ref().context("Подборка больше недоступна")?;
        ensure!(row["members"].as_array().into_iter().flatten().filter_map(Value::as_str)
            .any(|id|note(&data,id,true).is_ok() && enabled(root,Some(id)).unwrap_or(false)),"Подборка недоступна");
    }
    if let Some(result)=replay(connection,operation,&digest)? {return Ok(result);}
    let (_,kb_revision,_)=state(connection)?;
    ensure!(revision(input,"expectedWorkspaceRevision")?==workspace.revision &&
        revision(input,"expectedKBRevision")?==kb_revision,"Заметки или подборки изменились. Обновите данные.");
    if action=="create" { ensure!(before.is_none(),"Подборка уже существует"); }
    else { ensure!(revision(input,"expectedRevision")?==revision(before.as_ref().unwrap(),"revision")?,"Подборка изменилась. Обновите данные."); }
    let transaction=connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let timestamp=now();
    match action {
        "create" => {
            let title=required_string(input,"name")?.trim();
            ensure!(!title.is_empty() && title.len()<=500 && !title.chars().any(char::is_control),"Укажите название подборки до 500 байт");
            let values=input["sources"].as_array().context("Нет заметок подборки")?;
            ensure!((1..=200).contains(&values.len()),"В подборке должно быть от 1 до 200 заметок");
            let mut members=BTreeSet::new();
            for source in values {
                let id=required_string(source,"noteID")?;
                let current=note(&data,id,true)?;
                ensure!(members.insert(id.to_owned()) && current.revision==revision(source,"revision")? && enabled(root,Some(id))?,
                    "Заметка изменилась или недоступна. Обновите темы.");
            }
            let count:i64=transaction.query_row("SELECT COUNT(*) FROM kb_collections",[],|r|r.get(0))?;
            ensure!(count<1000,"Достигнут предел сохранённых подборок");
            let members=members.into_iter().collect::<Vec<_>>();
            ensure!(!list_collections(&transaction)?.iter().any(|row|row["members"]==json!(members)),"Такая подборка уже сохранена");
            transaction.execute("INSERT INTO kb_collections VALUES(?1,?2,?3,1,0,1,?4,?4)",
                params![target,title,serde_json::to_string(&members)?,timestamp])?;
        }
        "rename" => {
            let title=required_string(input,"name")?.trim();
            ensure!(!title.is_empty() && title.len()<=500 && !title.chars().any(char::is_control),"Укажите название подборки до 500 байт");
            transaction.execute("UPDATE kb_collections SET name=?1,revision=revision+1,updated_at=?2 WHERE id=?3",params![title,timestamp,target])?;
        }
        "hide" | "unhide" => { transaction.execute("UPDATE kb_collections SET hidden=?1,revision=revision+1,updated_at=?2 WHERE id=?3",
            params![if action=="hide" {1} else {0},timestamp,target])?; }
        "pin" | "unpin" => { transaction.execute("UPDATE kb_collections SET pinned=?1,revision=revision+1,updated_at=?2 WHERE id=?3",
            params![if action=="pin" {1} else {0},timestamp,target])?; }
        "add-sources" => {
            let values=input["sources"].as_array().context("Нет выбранных заметок")?;
            ensure!((1..=200).contains(&values.len()),"Выберите от 1 до 200 заметок");
            let row=before.as_ref().unwrap();
            let mut members=row["members"].as_array().context("Повреждена подборка")?.iter()
                .map(|v|v.as_str().map(str::to_owned).context("Повреждена подборка"))
                .collect::<Result<BTreeSet<_>>>()?;
            for source in values {
                let id=required_string(source,"noteID")?;
                let current=note(&data,id,true)?;
                ensure!(current.revision==revision(source,"revision")? && enabled(root,Some(id))?,
                    "Заметка изменилась или недоступна. Обновите данные.");
                ensure!(members.insert(id.to_owned()),"Эта заметка уже в подборке");
            }
            ensure!(members.len()<=200,"В подборке может быть не более 200 заметок");
            transaction.execute("UPDATE kb_collections SET members=?1,revision=revision+1,updated_at=?2 WHERE id=?3",
                params![serde_json::to_string(&members.into_iter().collect::<Vec<_>>())?,timestamp,target])?;
        }
        "remove-source" => {
            let id=required_string(input,"noteID")?;
            let current=note(&data,id,true)?;
            ensure!(current.revision==revision(input,"noteRevision")? && enabled(root,Some(id))?,
                "Заметка изменилась или недоступна. Обновите данные.");
            let row=before.as_ref().unwrap();
            let mut members=row["members"].as_array().context("Повреждена подборка")?.iter()
                .map(|v|v.as_str().map(str::to_owned).context("Повреждена подборка"))
                .collect::<Result<BTreeSet<_>>>()?;
            ensure!(members.remove(id),"Этой заметки больше нет в подборке");
            ensure!(!members.is_empty(),"В подборке должна остаться хотя бы одна заметка");
            transaction.execute("UPDATE kb_collections SET members=?1,revision=revision+1,updated_at=?2 WHERE id=?3",
                params![serde_json::to_string(&members.into_iter().collect::<Vec<_>>())?,timestamp,target])?;
        }
        _ => unreachable!(),
    }
    let after=collection_row(&transaction,target)?.context("Не удалось сохранить подборку")?;
    let (workspace_revision,knowledge_revision,kb_fingerprint)=advance(&transaction,workspace,kb_revision,operation,"collection")?;
    let result=json!({"operationID":operation,"workspaceRevision":workspace_revision,"kbRevision":knowledge_revision,
        "kbFingerprint":kb_fingerprint,"collectionID":after["id"],"revision":after["revision"],"undone":false});
    record(&transaction,input,"collection",&before.unwrap_or(Value::Null),&after,&result)?;
    transaction.commit()?;
    Ok(result)
}
fn change_link(root: &Path, connection: &mut Connection, workspace: &WorkspaceSnapshot, input: &Value) -> Result<Value> {
    let from=required_string(input,"fromID")?; let to=required_string(input,"toID")?;
    ensure!(from != to, "Нельзя связать заметку с самой собой");
    let data:crate::notes::NotesWorkspace=serde_json::from_value(workspace.value.clone())?;
    let a=note(&data,from,true)?; let b=note(&data,to,true)?;
    ensure!(enabled(root,Some(from))? && enabled(root,Some(to))?, "База знаний выключена в одной из папок");
    let id=operation_id(input)?; let digest=request_hash(input)?;
    if let Some(result)=replay(connection,id,&digest)? { return Ok(result); }
    let (_,kb_revision,_)=state(connection)?;
    ensure!(revision(input,"expectedWorkspaceRevision")? == workspace.revision &&
        revision(input,"expectedKBRevision")? == kb_revision &&
        revision(input,"expectedFromRevision")? == a.revision &&
        revision(input,"expectedToRevision")? == b.revision,
        "Заметки или связи изменились. Обновите данные.");
    let action=required_string(input,"action")?;
    ensure!(["add","remove"].contains(&action), "Неизвестное действие со связью");
    let reason=input["reason"].as_str().unwrap_or("").trim();
    ensure!(reason.len()<=2000 && !reason.contains('\0'), "Слишком длинное описание связи");
    let transaction=connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let before=link_row(&transaction,from,to)?;
    let timestamp=now();
    match (action,before.as_ref()) {
        ("add",Some(row)) if row["deleted"] == false => bail!("Эта связь уже существует"),
        ("add",Some(row)) => {
            transaction.execute("UPDATE kb_links SET reason=?1,revision=revision+1,deleted=0,updated_at=?2 WHERE id=?3",
                params![reason,timestamp,row["id"].as_str().unwrap()])?;
        }
        ("add",None) => {
            let count: i64 = transaction.query_row("SELECT COUNT(*) FROM kb_links", [], |row| row.get(0))?;
            ensure!(count < 10_000, "Достигнут предел сохранённых связей");
            transaction.execute("INSERT INTO kb_links VALUES(?1,?2,?3,'manual_link',?4,1,0,?5,?5)",
                params![uuid(),from,to,reason,timestamp])?;
        }
        ("remove",Some(row)) if row["deleted"] == false => {
            transaction.execute("UPDATE kb_links SET revision=revision+1,deleted=1,updated_at=?1 WHERE id=?2",
                params![timestamp,row["id"].as_str().unwrap()])?;
        }
        ("remove",_) => bail!("Связь уже удалена"),
        _ => unreachable!(),
    }
    let after=link_row(&transaction,from,to)?.context("Не удалось сохранить связь")?;
    let (workspace_revision,knowledge_revision,kb_fingerprint)=advance(&transaction,workspace,kb_revision,id,"link")?;
    let result=json!({"operationID":id,"workspaceRevision":workspace_revision,"kbRevision":knowledge_revision,
        "kbFingerprint":kb_fingerprint,"link":after,"undone":false});
    record(&transaction,input,"link",&before.unwrap_or(Value::Null),&after,&result)?;
    transaction.commit()?;
    Ok(result)
}

fn change_meeting_link(root:&Path,connection:&mut Connection,workspace:&WorkspaceSnapshot,input:&Value,
                       checked_source:Option<&crate::knowledge_meetings::MeetingSource>)->Result<Value> {
    let note_id=required_string(input,"noteID")?;
    let data:crate::notes::NotesWorkspace=serde_json::from_value(workspace.value.clone())?;
    let current_note=note(&data,note_id,true)?;
    ensure!(enabled(root,Some(note_id))?,"База знаний выключена в этой папке");
    let operation=operation_id(input)?; let digest=request_hash(input)?;
    if let Some(result)=replay(connection,operation,&digest)? {return Ok(redact_meeting_operation(result));}
    let (_,kb_revision,_)=state(connection)?;
    ensure!(revision(input,"expectedWorkspaceRevision")?==workspace.revision && revision(input,"expectedKBRevision")?==kb_revision &&
        revision(input,"noteRevision")?==current_note.revision,"Заметка или связи изменились. Обновите данные.");
    let action=required_string(input,"action")?;
    ensure!(["add","remove"].contains(&action),"Неизвестное действие со связью");
    let (key,source_ref,requested_id)=if action=="add" {
        let source=checked_source.context("Источник встречи не подтверждён")?;
        let stable=json!([source.meeting_id,source.kind,source.segment_id,source.item_index]);
        (hash(&stable)?,Some(meeting_source_ref(source)),None)
    } else {
        let id=required_string(input,"linkID")?;
        ensure!(Uuid::parse_str(id).is_ok(),"Некорректная связь");
        let row=list_meeting_links(connection,Some(note_id))?.into_iter().find(|row|row["id"]==id).context("Связь уже удалена")?;
        (required_string(&row,"sourceKey")?.to_owned(),None,Some(id.to_owned()))
    };
    let transaction=connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let before=list_meeting_links(&transaction,Some(note_id))?.into_iter().find(|row|row["sourceKey"]==key);
    let timestamp=now();
    match (action,before.as_ref()) {
        ("add",Some(row)) if row["deleted"]==false => bail!("Эта связь уже существует"),
        ("add",Some(row)) => {transaction.execute("UPDATE kb_meeting_links SET source_ref=?1,revision=revision+1,deleted=0,updated_at=?2 WHERE id=?3",
            params![source_ref.as_ref().context("Нет источника")?.to_string(),timestamp,required_string(row,"id")?])?;},
        ("add",None) => {
            let count:i64=transaction.query_row("SELECT COUNT(*) FROM kb_meeting_links",[],|row|row.get(0))?;
            ensure!(count<10_000,"Достигнут предел сохранённых связей");
            transaction.execute("INSERT INTO kb_meeting_links VALUES(?1,?2,?3,?4,1,0,?5,?5)",
                params![uuid(),note_id,key,source_ref.as_ref().context("Нет источника")?.to_string(),timestamp])?;
        }
        ("remove",Some(row)) if row["deleted"]==false && row["id"].as_str()==requested_id.as_deref() => {
            transaction.execute("UPDATE kb_meeting_links SET revision=revision+1,deleted=1,updated_at=?1 WHERE id=?2",params![timestamp,requested_id])?;
        }
        _ => bail!("Связь уже удалена"),
    }
    let after=list_meeting_links(&transaction,Some(note_id))?.into_iter().find(|row|row["sourceKey"]==key).context("Не удалось сохранить связь")?;
    let (workspace_revision,knowledge_revision,kb_fingerprint)=advance(&transaction,workspace,kb_revision,operation,"meeting-link")?;
    let result=redact_meeting_operation(json!({"operationID":operation,"workspaceRevision":workspace_revision,"kbRevision":knowledge_revision,
        "kbFingerprint":kb_fingerprint,"link":after,"undone":false}));
    record(&transaction,input,"meeting-link",&before.unwrap_or(Value::Null),&after,&result)?;
    transaction.commit()?;
    Ok(result)
}

/// Load references under the workspace lock, then resolve each meeting after
/// releasing it. A stale/revoked source has no title, excerpt or meeting ID in
/// the response; the user can still remove the unavailable reference.
fn meeting_links(root:&Path,input:&Value)->Result<Value> {
    let note_id=required_string(input,"noteID")?;
    let (rows,workspace_revision,kb_revision)={
        let directory=crate::notes::directory(root)?; let _lock=crate::notes::lock(&directory)?;
        let mut connection=open(&directory)?; let workspace=initialize(&mut connection,&directory)?;
        ensure!(enabled(root,Some(note_id))?,"База знаний выключена в этой папке");
        migrate(&mut connection,&directory,&workspace)?;
        let data:crate::notes::NotesWorkspace=serde_json::from_value(workspace.value.clone())?;
        let current=note(&data,note_id,true)?;
        ensure!(revision(input,"noteRevision")?==current.revision,"Заметка изменилась. Обновите связи.");
        let (_,kb_revision,_)=state(&connection)?;
        (list_meeting_links(&connection,Some(note_id))?,workspace.revision,kb_revision)
    };
    let mut visible=Vec::new();
    let mut checked=Vec::new();
    for row in rows.into_iter().filter(|row|row["deleted"]==false) {
        let saved=&row["sourceRef"];
        let resolved=saved["meetingID"].as_str().and_then(|id|crate::knowledge_meetings::snapshot(root,id,None).ok())
            .and_then(|(items,_)|items.into_iter().find(|source|meeting_ref_matches(source,saved)));
        if let Some(source)=resolved {
            if crate::knowledge_meetings::validate(root,&source,None) {
                checked.push(source.clone());
                visible.push(json!({"id":row["id"],"revision":row["revision"],"source":source,"available":true}));
                continue;
            }
        }
        visible.push(json!({"id":row["id"],"revision":row["revision"],"available":false}));
    }
    ensure!(checked.iter().all(|source|crate::knowledge_meetings::validate(root,source,None)),
        "Материал изменился или стал недоступен. Обновите подсказки.");
    let directory=crate::notes::directory(root)?; let _lock=crate::notes::lock(&directory)?;
    let mut connection=open(&directory)?; let workspace=initialize(&mut connection,&directory)?;
    let (_,current_kb,_)=state(&connection)?;
    ensure!(workspace.revision==workspace_revision && current_kb==kb_revision && enabled(root,Some(note_id))?,
        "Заметка или связи изменились. Обновите данные.");
    Ok(json!({"items":visible,"workspaceRevision":workspace_revision,"kbRevision":kb_revision}))
}
/// Reverse lookup exposes only note IDs and revisions, and only while both the
/// note and the exact saved meeting source remain accessible and unchanged.
fn meeting_backlinks(root:&Path,input:&Value)->Result<Value> {
    let id=required_string(input,"meetingID")?;
    ensure!(identifier(id),"Некорректная встреча");
    let (sources,partial_source)=crate::knowledge_meetings::snapshot(root,id,None)?;
    let (rows,workspace_revision,kb_revision)={
        let directory=crate::notes::directory(root)?; let _lock=crate::notes::lock(&directory)?;
        let mut connection=open(&directory)?; let workspace=initialize(&mut connection,&directory)?;
        migrate(&mut connection,&directory,&workspace)?;
        let data:crate::notes::NotesWorkspace=serde_json::from_value(workspace.value.clone())?;
        let (_,kb_revision,_)=state(&connection)?;
        let mut rows=Vec::new();
        for row in list_meeting_links(&connection,None)?.into_iter().filter(|row|row["deleted"]==false && row["sourceRef"]["meetingID"]==id) {
            let Some(note_id)=row["noteID"].as_str() else {continue};
            if let Ok(current)=note(&data,note_id,true) {
                if enabled(root,Some(note_id))? {rows.push((row.clone(),current.revision));}
            }
        }
        (rows,workspace.revision,kb_revision)
    };
    let mut items=Vec::new(); let mut checked=Vec::new(); let mut partial=partial_source;
    for (row,note_revision) in rows {
        if let Some(source)=sources.iter().find(|source|meeting_ref_matches(source,&row["sourceRef"])) {
            if items.len()>=100 {partial=true; break;}
            checked.push(source.clone());
            items.push(json!({"id":row["id"],"noteID":row["noteID"],"noteRevision":note_revision}));
        }
    }
    ensure!(checked.iter().all(|source|crate::knowledge_meetings::validate(root,source,None)),"Материал встречи изменился. Обновите связи.");
    let directory=crate::notes::directory(root)?; let _lock=crate::notes::lock(&directory)?;
    let mut connection=open(&directory)?; let workspace=initialize(&mut connection,&directory)?;
    let (_,current_kb,_)=state(&connection)?;
    ensure!(workspace.revision==workspace_revision && current_kb==kb_revision,"Заметки или связи изменились. Обновите данные.");
    for item in &items {ensure!(enabled(root,item["noteID"].as_str())?,"База знаний выключена в папке заметки");}
    Ok(json!({"items":items,"partial":partial,"workspaceRevision":workspace_revision,"kbRevision":kb_revision}))
}
fn change_feedback(root: &Path, connection: &mut Connection, workspace: &WorkspaceSnapshot, input: &Value) -> Result<Value> {
    let a=required_string(input,"fromID")?; let b=required_string(input,"toID")?;
    ensure!(a != b, "Нельзя запретить связь заметки с собой");
    let data:crate::notes::NotesWorkspace=serde_json::from_value(workspace.value.clone())?;
    let first_note=note(&data,a,true)?; let second_note=note(&data,b,true)?;
    ensure!(enabled(root,Some(a))? && enabled(root,Some(b))?, "База знаний выключена в одной из папок");
    let id=operation_id(input)?; let digest=request_hash(input)?;
    if let Some(result)=replay(connection,id,&digest)? { return Ok(result); }
    let (_,kb_revision,_)=state(connection)?;
    ensure!(revision(input,"expectedWorkspaceRevision")? == workspace.revision &&
        revision(input,"expectedKBRevision")? == kb_revision &&
        revision(input,"expectedFromRevision")? == first_note.revision &&
        revision(input,"expectedToRevision")? == second_note.revision,
        "Заметки или связи изменились. Обновите данные.");
    let blocked=input["blocked"].as_bool().context("Укажите решение о связи")?;
    let (first,second)=ordered_pair(a,b);
    let transaction=connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let before=feedback_row(&transaction,first,second)?;
    ensure!(before.as_ref().and_then(|v|v["blocked"].as_bool()) != Some(blocked), "Это решение уже сохранено");
    transaction.execute("INSERT INTO kb_feedback(first_id,second_id,blocked,revision,updated_at) VALUES(?1,?2,?3,1,?4)\
        ON CONFLICT(first_id,second_id) DO UPDATE SET blocked=excluded.blocked,revision=kb_feedback.revision+1,updated_at=excluded.updated_at",
        params![first,second,if blocked {1} else {0},now()])?;
    let after=feedback_row(&transaction,first,second)?.context("Не удалось сохранить решение")?;
    let (workspace_revision,knowledge_revision,kb_fingerprint)=advance(&transaction,workspace,kb_revision,id,"feedback")?;
    let result=json!({"operationID":id,"workspaceRevision":workspace_revision,"kbRevision":knowledge_revision,
        "kbFingerprint":kb_fingerprint,"feedback":after,"undone":false});
    record(&transaction,input,"feedback",&before.unwrap_or(Value::Null),&after,&result)?;
    transaction.commit()?;
    Ok(result)
}
fn undo_link(root: &Path, connection: &mut Connection, workspace: &WorkspaceSnapshot, input: &Value, checked_meeting_ref: Option<&Value>) -> Result<Value> {
    let operation=operation_id(input)?; let digest=request_hash(input)?;
    let original=required_string(input,"targetOperationID")?;
    ensure!(Uuid::parse_str(original).is_ok() && original != operation, "Некорректная операция отмены");
    let row: Option<(String,String,String,bool)> = connection.query_row(
        "SELECT kind,before_value,after_value,undone FROM kb_operations WHERE operation_id=?1",[original],
        |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get::<_,i64>(3)? != 0))).optional()?;
    let (kind,before,after,undone)=row.context("Операция больше недоступна")?;
    ensure!(kind == "link" || kind == "feedback" || kind == "meeting-link", "Эту операцию нельзя отменить здесь");
    let before:Value=serde_json::from_str(&before)?;
    let after:Value=serde_json::from_str(&after)?;
    // Restoring a versioned source requires a fresh permission/content check,
    // including when replaying an old successful receipt.
    if kind=="meeting-link" && !before.is_null() && before["deleted"]==false {
        ensure!(checked_meeting_ref==Some(&before["sourceRef"]), "Материал изменился или стал недоступен. Отмена остановлена.");
    }
    let (from,to)=if kind == "link" {(required_string(&after,"fromID")?,required_string(&after,"toID")?)}
        else if kind == "meeting-link" {let id=required_string(&after,"noteID")?; (id,id)}
        else {(required_string(&after,"firstID")?,required_string(&after,"secondID")?)};
    let data:crate::notes::NotesWorkspace=serde_json::from_value(workspace.value.clone())?;
    note(&data,from,true)?; note(&data,to,true)?;
    ensure!(enabled(root,Some(from))? && enabled(root,Some(to))?, "База знаний выключена в одной из папок");
    if let Some(result)=replay(connection,operation,&digest)? {
        return Ok(if kind=="meeting-link" {redact_meeting_operation(result)} else {result});
    }
    ensure!(!undone, "Операция уже отменена");
    let (_,kb_revision,_)=state(connection)?;
    ensure!(revision(input,"expectedWorkspaceRevision")? == workspace.revision &&
        revision(input,"expectedKBRevision")? == kb_revision, "Заметки или связи изменились. Обновите данные.");
    let transaction=connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current=if kind == "link" {link_row(&transaction,from,to)?} else if kind == "meeting-link" {
        list_meeting_links(&transaction,Some(from))?.into_iter().find(|row|row["id"]==after["id"])
    } else {feedback_row(&transaction,from,to)?}
        .context("Связь уже изменена")?;
    ensure!(current == after, "Связь изменилась после этого действия. Отмена остановлена.");
    let restored=if kind == "link" {
        let deleted=if before.is_null() { true } else { before["deleted"].as_bool().context("Некорректная история связи")? };
        let reason=if before.is_null() { "" } else { required_string(&before,"reason")? };
        ensure!(transaction.execute("UPDATE kb_links SET reason=?1,revision=revision+1,deleted=?2,updated_at=?3 WHERE id=?4 AND revision=?5",
            params![reason,if deleted {1} else {0},now(),required_string(&current,"id")?,revision(&current,"revision")? as i64])? == 1,
            "Связь уже изменилась");
        link_row(&transaction,from,to)?.context("Не удалось отменить связь")?
    } else if kind == "meeting-link" {
        let deleted=before.is_null() || before["deleted"]==true;
        let source=if before.is_null() {&current["sourceRef"]} else {&before["sourceRef"]};
        if !deleted { ensure!(checked_meeting_ref==Some(source), "Материал изменился или стал недоступен. Отмена остановлена."); }
        ensure!(transaction.execute("UPDATE kb_meeting_links SET source_ref=?1,revision=revision+1,deleted=?2,updated_at=?3 WHERE id=?4 AND revision=?5",
            params![source.to_string(),if deleted {1} else {0},now(),required_string(&current,"id")?,revision(&current,"revision")? as i64])? == 1,
            "Связь уже изменилась");
        list_meeting_links(&transaction,Some(from))?.into_iter().find(|row|row["id"]==current["id"]).context("Не удалось отменить связь")?
    } else if before.is_null() {
        ensure!(transaction.execute("DELETE FROM kb_feedback WHERE first_id=?1 AND second_id=?2 AND revision=?3",
            params![from,to,revision(&current,"revision")? as i64])? == 1,"Решение уже изменилось");
        Value::Null
    } else {
        let blocked=before["blocked"].as_bool().context("Некорректная история решения")?;
        ensure!(transaction.execute("UPDATE kb_feedback SET blocked=?1,revision=revision+1,updated_at=?2 WHERE first_id=?3 AND second_id=?4 AND revision=?5",
            params![if blocked {1} else {0},now(),from,to,revision(&current,"revision")? as i64])? == 1,"Решение уже изменилось");
        feedback_row(&transaction,from,to)?.context("Не удалось отменить решение")?
    };
    let undo_kind=if kind == "link" {"undo-link"} else if kind == "meeting-link" {"undo-meeting-link"} else {"undo-feedback"};
    let (workspace_revision,knowledge_revision,kb_fingerprint)=advance(&transaction,workspace,kb_revision,operation,undo_kind)?;
    let result=json!({"operationID":operation,"workspaceRevision":workspace_revision,"kbRevision":knowledge_revision,
        "kbFingerprint":kb_fingerprint,"link":restored,"undone":false});
    let result=if kind=="meeting-link" {redact_meeting_operation(result)} else {result};
    ensure!(transaction.execute("UPDATE kb_operations SET undone=1 WHERE operation_id=?1 AND undone=0",[original])? == 1,
        "Операция уже отменена");
    let receipt: String=transaction.query_row("SELECT payload FROM operation_receipts WHERE namespace='knowledge' AND operation_id=?1",
        [original],|r|r.get(0))?;
    let mut receipt:Value=serde_json::from_str(&receipt)?;
    receipt["result"]["undone"]=json!(true);
    transaction.execute("UPDATE operation_receipts SET payload=?1 WHERE namespace='knowledge' AND operation_id=?2",
        params![serde_json::to_string(&receipt)?,original])?;
    record(&transaction,input,undo_kind,&current,&restored,&result)?;
    transaction.commit()?;
    Ok(result)
}

/// Compute a bounded lexical shortlist outside the workspace lock. The result
/// is only a suggestion: it never creates links or calls a model. A publication
/// fence rejects it if either notes, decisions or feature policy changed.
fn suggestions(root: &Path, input: &Value) -> Result<Value> {
    const MAX_NOTES: usize = 1500;
    let id=required_string(input,"noteID")?;
    let (source, candidates, semantic_allowed, workspace_revision, kb_revision, policy_fingerprint, partial) = {
        let directory=crate::notes::directory(root)?;
        let _lock=crate::notes::lock(&directory)?;
        crate::corrections::recover_notes_transaction(&directory)?;
        let mut connection=open(&directory)?;
        let workspace=initialize(&mut connection,&directory)?;
        ensure!(enabled(root,Some(id))?, "База знаний выключена в этой папке");
        migrate(&mut connection,&directory,&workspace)?;
        let (_,kb_revision,_)=state(&connection)?;
        ensure!(revision(input,"expectedWorkspaceRevision")? == workspace.revision &&
            revision(input,"expectedKBRevision")? == kb_revision, "Заметки или связи изменились. Обновите данные.");
        let data:crate::notes::NotesWorkspace=serde_json::from_value(workspace.value.clone())?;
        let source=note(&data,id,true)?.clone();
        let profiles=crate::ai::FeatureResolver::new(root)?;
        let meeting_folders=data.contexts.iter().map(|context|
            (context.meeting_id.clone(),context.folder_id.clone())).collect::<BTreeMap<_,_>>();
        let mut all=data.notes.into_iter().filter(|n|n.kind=="note" && n.trashed_at.is_none() && n.id!=id)
            .collect::<Vec<_>>();
        all.sort_by(|a,b|b.updated_at.total_cmp(&a.updated_at).then_with(||a.id.cmp(&b.id)));
        let mut permissions:BTreeMap<Option<String>,bool>=BTreeMap::new();
        all.retain(|n| {
            let folder=n.folder_id.clone().or_else(||n.meeting_id.as_ref()
                .and_then(|meeting|meeting_folders.get(meeting).cloned().flatten()));
            *permissions.entry(folder.clone()).or_insert_with(||
                profiles.features_for(&json!({"folderID":folder})).is_ok_and(|f|f.knowledge_base))
        });
        let mut excluded=BTreeSet::new();
        for link in list_links(&connection)? {
            if link["deleted"] == true {continue;}
            if link["fromID"] == id {if let Some(other)=link["toID"].as_str(){excluded.insert(other.to_owned());}}
            if link["toID"] == id {if let Some(other)=link["fromID"].as_str(){excluded.insert(other.to_owned());}}
        }
        let mut query=connection.prepare("SELECT first_id,second_id FROM kb_feedback WHERE blocked=1 AND (first_id=?1 OR second_id=?1)")?;
        let pairs=query.query_map([id],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        for (a,b) in pairs {excluded.insert(if a==id {b} else {a});}
        // Scope and existing decisions must be applied before the limit. A
        // private folder or already rejected notes must not displace eligible
        // suggestions or affect whether this result is marked partial.
        all.retain(|n| !excluded.contains(&n.id));
        let partial=all.len()>MAX_NOTES;
        all.truncate(MAX_NOTES);
        let mut semantic_allowed=BTreeMap::new();
        for candidate in std::iter::once(&source).chain(all.iter()) {
            if profiles.features_for(&json!({"noteID":candidate.id})).is_ok_and(|f|f.semantic_search) {
                semantic_allowed.insert(candidate.id.clone(),crate::knowledge::note_fingerprint(candidate));
            }
        }
        let settings=if root.join("settings.json").exists() {crate::storage::regular_json(&root.join("settings.json"))?} else {json!({})};
        (source,all,semantic_allowed,workspace.revision,kb_revision,hash(&settings["features"])?,partial)
    };
    // Reuse only previously indexed vectors. An unavailable or stale index is
    // optional and never makes manual links or lexical suggestions fail.
    let semantic=crate::semantic::cached_note_similarities(root,id,&semantic_allowed).ok().flatten();
    let semantic_threshold=semantic.as_ref().map(|(_,manifest)|
        crate::semantic::manual_suggestion_threshold(root,manifest)).unwrap_or(0.82);
    let source_terms=crate::search::related_terms(&source.title,&source.text);
    let documents=candidates.into_iter()
        .map(|note| {
            let terms=crate::search::related_terms(&note.title,&note.text);
            (note,terms)
        }).collect::<Vec<_>>();
    let mut document_frequency:BTreeMap<String,usize>=BTreeMap::new();
    for key in source_terms.keys() {*document_frequency.entry(key.clone()).or_default()+=1;}
    for (_,terms) in &documents {for key in terms.keys(){*document_frequency.entry(key.clone()).or_default()+=1;}}
    let count=(documents.len()+1) as f64;
    let idf=|key: &str| ((count+1.0)/(*document_frequency.get(key).unwrap_or(&0) as f64+1.0)).ln()+1.0;
    let norm=|terms:&BTreeMap<String,(String,u32)>| terms.iter().map(|(key,(_,frequency))| {
        let weight=(1.0+(*frequency as f64).ln())*idf(key); weight*weight
    }).sum::<f64>().sqrt();
    let source_norm=norm(&source_terms);
    let mut ranked=Vec::new();
    {
        for (candidate,terms) in documents {
            let mut shared=source_terms.iter().filter_map(|(key,(word,frequency))|terms.get(key).map(|(_,other)| {
                let strength=(1.0+(*frequency as f64).ln())*(1.0+(*other as f64).ln())*idf(key).powi(2);
                (strength,word.clone())
            })).collect::<Vec<_>>();
            let candidate_norm=norm(&terms);
            let lexical=if shared.len()>=2 && source_norm>0.0 && candidate_norm>0.0 {
                shared.iter().map(|(strength,_)|strength).sum::<f64>()/(source_norm*candidate_norm)
            } else { 0.0 };
            let semantic_score=semantic.as_ref().and_then(|(scores,_)|scores.get(&candidate.id)).copied().filter(|score|*score>=semantic_threshold);
            if lexical<0.14 && semantic_score.is_none() {continue;}
            shared.sort_by(|a,b|b.0.total_cmp(&a.0).then_with(||a.1.cmp(&b.1)));
            let words=shared.into_iter().take(3).map(|(_,word)|word).collect::<Vec<_>>();
            let method=if semantic_score.is_some_and(|score|score*0.9>lexical) {"semantic"} else {"sharedTerms"};
            let score=lexical.max(semantic_score.unwrap_or(0.0)*0.9);
            ranked.push((score,candidate.id,candidate.revision,words,method));
        }
    }
    ranked.sort_by(|a,b|b.0.total_cmp(&a.0).then_with(||a.1.cmp(&b.1)));
    let items=ranked.into_iter().take(3).map(|(_,id,revision,words,method)|
        json!({"noteID":id,"revision":revision,"sharedTerms":words,"method":method})).collect::<Vec<_>>();
    #[cfg(test)]
    tests::pause_before_suggestion_publication(root);
    {
        let directory=crate::notes::directory(root)?;
        let _lock=crate::notes::lock(&directory)?;
        let mut connection=open(&directory)?;
        let current=initialize(&mut connection,&directory)?;
        let (_,current_kb,_)=state(&connection)?;
        let settings=if root.join("settings.json").exists() {crate::storage::regular_json(&root.join("settings.json"))?} else {json!({})};
        ensure!(current.revision==workspace_revision && current_kb==kb_revision &&
            hash(&settings["features"])?==policy_fingerprint && enabled(root,Some(id))? &&
            semantic.as_ref().is_none_or(|(_,manifest)|crate::semantic::cached_manifest_is_current(root,manifest)),
            "Заметки или настройки изменились. Обновите подсказки.");
        // The publication fence checks current policy for each returned note,
        // even though normal folder updates also advance workspace revision.
        // In particular, a semantic result requires both participants to retain
        // semantic permission in addition to knowledge-base permission.
        let profiles=crate::ai::FeatureResolver::new(root)?;
        let source_features=profiles.features_for(&json!({"noteID":id}))?;
        ensure!(source_features.knowledge_base, "Доступ к заметке изменился. Обновите подсказки.");
        for item in &items {
            let target=required_string(item,"noteID")?;
            let features=profiles.features_for(&json!({"noteID":target}))?;
            ensure!(features.knowledge_base &&
                (item["method"]!="semantic" || (source_features.semantic_search && features.semantic_search)),
                "Доступ к заметке изменился. Обновите подсказки.");
        }
    }
    Ok(json!({"workspaceRevision":workspace_revision,"kbRevision":kb_revision,"items":items,"partial":partial,
        "method":if semantic.is_some() {"mixed"} else {"sharedTerms"}}))
}

fn cache_dir(root: &Path) -> Result<PathBuf> {
    let mut directory=fs::canonicalize(root)?;
    for component in ["cache","knowledge"] {
        directory.push(component);
        match fs::symlink_metadata(&directory) {
            Ok(meta) => ensure!(meta.is_dir() && !meta.file_type().is_symlink(), "Некорректная папка кеша базы знаний"),
            Err(error) if error.kind()==std::io::ErrorKind::NotFound =>
                fs::DirBuilder::new().mode(0o700).create(&directory)?,
            Err(error) => return Err(error.into()),
        }
        fs::set_permissions(&directory,fs::Permissions::from_mode(0o700))?;
    }
    Ok(directory)
}
#[derive(Clone)]
struct TopicDraft { members: Vec<String>, revisions: Vec<u64>, terms: Vec<String>, semantic_members: BTreeSet<String> }

// A root-scoped generation prevents overlapping rebuilds from continuing
// after a newer request or the native recording UI cancels background work.
// It contains only hashed paths and never carries user content.
#[derive(Default)]
struct TopicGeneration { epoch:u64, active:Option<String>, cancelled:BTreeSet<String> }
static TOPIC_GENERATIONS: OnceLock<Mutex<BTreeMap<String,TopicGeneration>>> = OnceLock::new();
fn topic_key(root:&Path)->String {format!("{:x}",Sha256::digest(root.as_os_str().as_encoded_bytes()))}
fn begin_topic_generation(root:&Path,request:Option<&str>)->Result<(String,u64)> {
    if let Some(id)=request {ensure!(Uuid::parse_str(id).is_ok(),"Некорректный запрос построения тем");}
    let key=topic_key(root);
    let mut state=TOPIC_GENERATIONS.get_or_init(||Mutex::new(BTreeMap::new())).lock()
        .map_err(|_|anyhow::anyhow!("Не удалось остановить построение тем"))?;
    let value=state.entry(key.clone()).or_default();
    if let Some(id)=request {ensure!(!value.cancelled.remove(id),"Построение тем остановлено");}
    value.epoch=value.epoch.wrapping_add(1); value.active=request.map(str::to_owned);
    Ok((key,value.epoch))
}
#[cfg(test)]
fn advance_topic_generation(root:&Path)->Result<(String,u64)> {begin_topic_generation(root,None)}
fn cancel_topic_generation(root:&Path,request:Option<&str>)->Result<()> {
    if let Some(id)=request {ensure!(Uuid::parse_str(id).is_ok(),"Некорректный запрос построения тем");}
    let mut state=TOPIC_GENERATIONS.get_or_init(||Mutex::new(BTreeMap::new())).lock()
        .map_err(|_|anyhow::anyhow!("Не удалось остановить построение тем"))?;
    let value=state.entry(topic_key(root)).or_default();
    if request.is_none() || request==value.active.as_deref() {
        value.epoch=value.epoch.wrapping_add(1); value.active=None;
    } else if let Some(id)=request {
        // Cancellation can arrive just before the worker registers. Keep a
        // bounded set of IDs so that worker cannot start after recording does.
        if value.cancelled.len()>=1024 {value.cancelled.pop_first();}
        value.cancelled.insert(id.to_owned());
    }
    Ok(())
}
fn check_topic_generation(key:&str,expected:u64)->Result<()> {
    let state=TOPIC_GENERATIONS.get_or_init(||Mutex::new(BTreeMap::new())).lock()
        .map_err(|_|anyhow::anyhow!("Не удалось проверить построение тем"))?;
    ensure!(state.get(key).is_some_and(|value|value.epoch==expected),"Построение тем остановлено");
    Ok(())
}

/// Bounded, cross-library candidate generation. For small libraries score every
/// pair exactly. For larger ones use a local inverted term index and a coarse
/// semantic index, limiting neighbours per document before calculating scores.
/// The approximation is surfaced to the caller; no user decisions are lost.
fn topic_candidate_pairs(
    notes: &[crate::notes::CapturedNote],
    documents: &[BTreeMap<String,(String,u32)>],
    vectors: Option<&BTreeMap<String,Vec<f32>>>,
    manual: &BTreeSet<(String,String)>, generation:(&str,u64),
) -> Result<(BTreeSet<(usize,usize)>,bool)> {
    check_topic_generation(generation.0,generation.1)?;
    if notes.len() <= 200 {
        return Ok(((0..notes.len()).flat_map(|a|((a+1)..notes.len()).map(move |b|(a,b))).collect(),false));
    }
    let mut posting:BTreeMap<&str,Vec<usize>>=BTreeMap::new();
    for (index,doc) in documents.iter().enumerate() {
        for key in doc.keys() {posting.entry(key.as_str()).or_default().push(index);}
    }
    // Eight deterministic random hyperplanes provide approximate semantic
    // buckets. Exact cosine is still checked before any edge is accepted.
    let bucket=|vector:&[f32]| -> u8 {
        let mut sums=[0.0f64;8];
        for (dimension,value) in vector.iter().enumerate() {
            for (bit,sum) in sums.iter_mut().enumerate() {
                let mut x=(dimension as u64).wrapping_add(0x9e3779b97f4a7c15u64.wrapping_mul(bit as u64+1));
                x^=x>>30; x=x.wrapping_mul(0xbf58476d1ce4e5b9); x^=x>>27;
                *sum+=if x&1==0 {*value as f64} else {-(*value as f64)};
            }
        }
        sums.iter().enumerate().fold(0u8,|mask,(bit,sum)| if *sum>=0.0 {mask|(1<<bit)} else {mask})
    };
    let mut buckets:BTreeMap<u8,Vec<usize>>=BTreeMap::new();
    if let Some(vectors)=vectors {for (index,note) in notes.iter().enumerate() {
        if let Some(vector)=vectors.get(&note.id) {buckets.entry(bucket(vector)).or_default().push(index);}
    }}
    let mut pairs=BTreeSet::new();
    for (index,doc) in documents.iter().enumerate() {
        if index%32==0 {check_topic_generation(generation.0,generation.1)?;}
        let mut counts:BTreeMap<usize,u16>=BTreeMap::new();
        for term in doc.keys() {
            let Some(list)=posting.get(term.as_str()) else {continue};
            // Common words may occur in every document. Select a symmetric
            // local ring for each occurrence so late records are not starved.
            let start=if list.len()<=64 {0} else {list.binary_search(&index).unwrap_or(0).saturating_sub(16)};
            let end=if list.len()<=64 {list.len()} else {(start+33).min(list.len())};
            for candidate in &list[start..end] {
                if *candidate==index {continue;}
                let count=counts.entry(*candidate).or_default(); *count=count.saturating_add(1);
            }
        }
        let mut candidates=counts.into_iter().filter(|(_,count)|*count>=2).collect::<Vec<_>>();
        candidates.sort_by(|a,b|b.1.cmp(&a.1).then_with(||a.0.cmp(&b.0)));
        for (other,_) in candidates.into_iter().take(128) {pairs.insert((index.min(other),index.max(other)));}
        if let Some(vector)=vectors.and_then(|v|v.get(&notes[index].id)) {
            let key=bucket(vector); let mut selected=BTreeSet::new();
            for candidate_key in std::iter::once(key).chain((0..8).map(|bit|key^(1<<bit))) {
                if let Some(list)=buckets.get(&candidate_key) {
                    let pivot=list.partition_point(|candidate|*candidate<index);
                    let start=pivot.saturating_sub(8); let end=(pivot+8).min(list.len());
                    for other in &list[start..end] {if *other!=index {selected.insert(*other);}}
                }
            }
            for other in selected.into_iter().take(128) {pairs.insert((index.min(other),index.max(other)));}
        }
    }
    let by_id=notes.iter().enumerate().map(|(index,note)|(note.id.as_str(),index)).collect::<BTreeMap<_,_>>();
    for (a,b) in manual {
        if let (Some(&a),Some(&b))=(by_id.get(a.as_str()),by_id.get(b.as_str())) {
            if a!=b {pairs.insert((a.min(b),a.max(b)));}
        }
    }
    Ok((pairs,true))
}

/// Search every eligible note before applying pagination. The response never
/// contains content from another folder or from an opted-out profile.
fn search_notes(root: &Path, input: &Value) -> Result<Value> {
    let query=required_string(input,"query")?;
    ensure!(!query.trim().is_empty() && query.len()<=500 && !query.contains('\0'), "Введите поисковый запрос");
    let matcher=crate::search::QueryMatcher::new(query)?;
    ensure!(matcher.has_terms(), "Введите слова для поиска");
    let offset=input.get("offset").and_then(Value::as_u64).unwrap_or(0);
    ensure!(offset<=10_000_000, "Некорректная страница поиска");
    let offset=offset as usize;
    ensure!(input.get("folderID").is_none_or(|v|v.is_null() || v.is_string()), "Некорректная папка");
    let folder=input["folderID"].as_str();
    ensure!(folder.is_none_or(identifier), "Некорректная папка");
    let directory=crate::notes::directory(root)?;
    let _lock=crate::notes::lock(&directory)?;
    crate::corrections::recover_notes_transaction(&directory)?;
    let mut connection=open(&directory)?;
    let workspace=initialize(&mut connection,&directory)?;
    ensure!(enabled_anywhere(root)?, "Включите базу знаний в настройках");
    migrate(&mut connection,&directory,&workspace)?;
    ensure!(revision(input,"expectedWorkspaceRevision")?==workspace.revision, "Заметки изменились. Повторите поиск.");
    let original_settings=if root.join("settings.json").exists() {crate::storage::regular_json(&root.join("settings.json"))?} else {json!({})};
    let data:crate::notes::NotesWorkspace=serde_json::from_value(workspace.value.clone())?;
    let profiles=crate::ai::FeatureResolver::new(root)?;
    if let Some(folder)=folder {
        ensure!(profiles.features_for(&json!({"folderID":folder}))?.knowledge_base,"База знаний выключена в этой папке");
    }
    let meeting_folders=data.contexts.iter().map(|context|
        (context.meeting_id.clone(),context.folder_id.clone())).collect::<BTreeMap<_,_>>();
    let mut permissions:BTreeMap<Option<String>,bool>=BTreeMap::new();
    let mut found=Vec::new();
    for note in data.notes {
        if note.kind!="note" || note.trashed_at.is_some() {continue;}
        let current=note.folder_id.clone().or_else(||note.meeting_id.as_ref()
            .and_then(|meeting|meeting_folders.get(meeting).cloned().flatten()));
        if folder.is_some_and(|wanted|current.as_deref()!=Some(wanted)) {continue;}
        if !*permissions.entry(current.clone()).or_insert_with(||
            profiles.features_for(&json!({"folderID":current})).is_ok_and(|f|f.knowledge_base)) {continue;}
        if matcher.matches(&format!("{} {} {}",note.title,note.text,note.tags.join(" "))) {found.push(note);}
    }
    found.sort_by(|a,b|b.updated_at.total_cmp(&a.updated_at).then_with(||a.id.cmp(&b.id)));
    let total=found.len();
    let items=found.into_iter().skip(offset).take(50).map(|note|
        json!({"noteID":note.id,"revision":note.revision})).collect::<Vec<_>>();
    let final_settings=if root.join("settings.json").exists() {crate::storage::regular_json(&root.join("settings.json"))?} else {json!({})};
    ensure!(hash(&original_settings["features"])?==hash(&final_settings["features"])?, "Настройки изменились. Повторите поиск.");
    Ok(json!({"workspaceRevision":workspace.revision,"items":items,"total":total,"offset":offset,
        "nextOffset":if offset+items.len()<total {Some(offset+50)} else {None}}))
}

/// Rebuildable local groups combine explicit links, bounded term overlap and,
/// when available, fresh cached semantic vectors from the opted-in index.
/// They contain no AI-generated statements. IDs are matched to the previous
/// cache by member overlap; canonical links survive deleting the cache.
fn topics(root: &Path, input: &Value) -> Result<Value> {
    let (generation_key,generation)=begin_topic_generation(root,input["requestID"].as_str())?;
    // Groups are formed across the eligible library; pagination applies only
    // to the resulting groups, never to the documents used to form them.
    const MAX_NOTES: usize=10_000;
    const TOPIC_PAGE: usize=50;
    const MAX_SEMANTIC_NOTES: usize=1000;
    let offset=input.get("offset").and_then(Value::as_u64).unwrap_or(0);
    ensure!(offset <= 10_000_000 && offset % TOPIC_PAGE as u64 == 0, "Некорректная страница тем");
    let offset=offset as usize;
    ensure!(input.get("folderID").is_none_or(|value|value.is_null() || value.is_string()), "Некорректная папка");
    let folder=input["folderID"].as_str();
    ensure!(folder.is_none_or(identifier), "Некорректная папка");
    let (notes,manual,blocked,semantic_allowed,semantic_eligible,workspace_revision,kb_revision,policy_fingerprint,total) = {
        let directory=crate::notes::directory(root)?;
        let _lock=crate::notes::lock(&directory)?;
        crate::corrections::recover_notes_transaction(&directory)?;
        let mut connection=open(&directory)?;
        let workspace=initialize(&mut connection,&directory)?;
        ensure!(enabled_anywhere(root)?, "Включите базу знаний в настройках");
        migrate(&mut connection,&directory,&workspace)?;
        let (_,kb_revision,_)=state(&connection)?;
        ensure!(revision(input,"expectedWorkspaceRevision")?==workspace.revision &&
            revision(input,"expectedKBRevision")?==kb_revision, "Заметки или связи изменились. Обновите темы.");
        let data:crate::notes::NotesWorkspace=serde_json::from_value(workspace.value.clone())?;
        let profiles=crate::ai::FeatureResolver::new(root)?;
        if let Some(folder)=folder {
            ensure!(profiles.features_for(&json!({"folderID":folder}))?.knowledge_base, "База знаний выключена в этой папке");
        }
        let meeting_folders=data.contexts.iter().map(|context|
            (context.meeting_id.clone(),context.folder_id.clone())).collect::<BTreeMap<_,_>>();
        let mut permissions:BTreeMap<Option<String>,(bool,bool)>=BTreeMap::new();
        let mut notes=data.notes.into_iter().filter(|note|note.kind=="note" && note.trashed_at.is_none()).filter(|note| {
            let current=note.folder_id.clone().or_else(||note.meeting_id.as_ref()
                .and_then(|meeting|meeting_folders.get(meeting).cloned().flatten()));
            if folder.is_some_and(|wanted|current.as_deref()!=Some(wanted)) { return false; }
            permissions.entry(current.clone()).or_insert_with(||
                profiles.features_for(&json!({"folderID":current})).map(|f|(f.knowledge_base,f.semantic_search)).unwrap_or((false,false))).0
        }).collect::<Vec<_>>();
        notes.sort_by(|a,b|b.updated_at.total_cmp(&a.updated_at).then_with(||a.id.cmp(&b.id)));
        let total=notes.len();
        let mut notes=notes.into_iter().take(MAX_NOTES).collect::<Vec<_>>();
        notes.sort_by(|a,b|a.id.cmp(&b.id));
        let eligible=notes.iter().filter(|note| {
            let current=note.folder_id.clone().or_else(||note.meeting_id.as_ref()
                .and_then(|meeting|meeting_folders.get(meeting).cloned().flatten()));
            permissions.get(&current).is_some_and(|permissions|permissions.1)
        }).collect::<Vec<_>>();
        let semantic_eligible=eligible.len();
        let semantic_allowed=eligible.into_iter().take(MAX_SEMANTIC_NOTES)
            .map(|note|(note.id.clone(),crate::knowledge::note_fingerprint(note))).collect::<BTreeMap<_,_>>();
        let manual=list_links(&connection)?.into_iter().filter(|l|l["deleted"]==false).filter_map(|l|
            Some((l["fromID"].as_str()?.to_owned(),l["toID"].as_str()?.to_owned()))).collect::<BTreeSet<_>>();
        let mut query=connection.prepare("SELECT first_id,second_id FROM kb_feedback WHERE blocked=1")?;
        let blocked=query.query_map([],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?
            .collect::<rusqlite::Result<BTreeSet<_>>>()?;
        let settings=if root.join("settings.json").exists() {crate::storage::regular_json(&root.join("settings.json"))?} else {json!({})};
        (notes,manual,blocked,semantic_allowed,semantic_eligible,workspace.revision,kb_revision,hash(&settings["features"])?,total)
    };
    let semantic=crate::semantic::cached_topic_vectors(root,&semantic_allowed).ok().flatten();
    let semantic_indexed=semantic.as_ref().map_or(0,|(vectors,_)|vectors.len());
    let mut documents=Vec::with_capacity(notes.len());
    for (index,note) in notes.iter().enumerate() {
        if index%32==0 {check_topic_generation(&generation_key,generation)?;}
        documents.push(crate::search::related_terms(&note.title,&note.text));
    }
    let mut frequency:BTreeMap<String,usize>=BTreeMap::new();
    for terms in &documents { for term in terms.keys() {*frequency.entry(term.clone()).or_default()+=1;} }
    let count=documents.len() as f64;
    let idf=|key:&str| ((count+1.0)/(*frequency.get(key).unwrap_or(&0) as f64+1.0)).ln()+1.0;
    let norm=|terms:&BTreeMap<String,(String,u32)>| terms.iter().map(|(key,(_,frequency))| {
        let weight=(1.0+(*frequency as f64).ln())*idf(key); weight*weight
    }).sum::<f64>().sqrt();
    let norms=documents.iter().map(&norm).collect::<Vec<_>>();
    let mut neighbours=vec![Vec::<(usize,f64)>::new();notes.len()];
    let mut semantic_edges=BTreeSet::<(usize,usize)>::new();
    let (pairs,approximate)=topic_candidate_pairs(&notes,&documents,semantic.as_ref().map(|(vectors,_)|vectors),&manual,(&generation_key,generation))?;
    for (position,(a,b)) in pairs.into_iter().enumerate() {
            if position%256==0 {check_topic_generation(&generation_key,generation)?;}
            let (first,second)=ordered_pair(&notes[a].id,&notes[b].id);
            if blocked.contains(&(first.to_owned(),second.to_owned())) {continue;}
            let mut common=0usize; let mut dot=0.0;
            for (key,(_,left)) in &documents[a] {
                if let Some((_,right))=documents[b].get(key) {
                    common+=1;
                    dot+=(1.0+(*left as f64).ln())*(1.0+(*right as f64).ln())*idf(key).powi(2);
                }
            }
            let explicit=manual.contains(&(notes[a].id.clone(),notes[b].id.clone())) ||
                manual.contains(&(notes[b].id.clone(),notes[a].id.clone()));
            let lexical=if common>=2 && norms[a]>0.0 && norms[b]>0.0 {
                dot/(norms[a]*norms[b])
            } else {0.0};
            let similarity=semantic.as_ref().and_then(|(vectors,_)| Some((vectors.get(&notes[a].id)?,vectors.get(&notes[b].id)?)))
                .map(|(left,right)|left.iter().zip(right).map(|(x,y)|*x as f64 * *y as f64).sum::<f64>())
                .filter(|score|score.is_finite() && *score>=0.82)
                .map_or(0.0, |score|score.clamp(0.0,1.0)*0.9);
            let score=if explicit {1.0} else {lexical.max(similarity)};
            if !explicit && similarity > lexical { semantic_edges.insert((a,b)); }
            if score>=0.14 {neighbours[a].push((b,score)); neighbours[b].push((a,score));}
    }
    for neighbours in &mut neighbours {
        neighbours.sort_by(|a,b|b.1.total_cmp(&a.1).then_with(||notes[a.0].id.cmp(&notes[b.0].id)));
        neighbours.truncate(8);
    }
    let mut edges=vec![BTreeSet::<usize>::new();notes.len()];
    for a in 0..notes.len() {for (b,_) in &neighbours[a] {
        if neighbours[*b].iter().any(|(other,_)|*other==a) {edges[a].insert(*b);}
    }}
    let mut groups=Vec::<Vec<usize>>::new();
    let mut memberships=vec![0usize;notes.len()];
    for seed in 0..notes.len() {
        if seed%128==0 {check_topic_generation(&generation_key,generation)?;}
        if memberships[seed]>=3 {continue;}
        let mut group=vec![seed];
        for (candidate,_) in &neighbours[seed] {
            if !edges[seed].contains(candidate) || memberships[*candidate]>=3 {continue;}
            let blocked_pair=group.iter().any(|member| {
                let (a,b)=ordered_pair(&notes[*member].id,&notes[*candidate].id);
                blocked.contains(&(a.to_owned(),b.to_owned()))
            });
            let connected=group.iter().filter(|member|edges[**member].contains(candidate)).count();
            if !blocked_pair && connected*2>=group.len() {group.push(*candidate);}
        }
        group.sort_unstable(); group.dedup();
        if group.len()<4 || groups.iter().any(|old|old==&group) {continue;}
        let actual=group.iter().enumerate().map(|(i,a)|group.iter().skip(i+1)
            .filter(|b|edges[*a].contains(b)).count()).sum::<usize>();
        let possible=group.len()*(group.len()-1)/2;
        if actual*2<possible {continue;}
        for member in &group {memberships[*member]+=1;}
        groups.push(group);
        if groups.len()>=10_000 {break;}
    }
    let groups_truncated=groups.len()>=10_000;
    let group_total=groups.len();
    ensure!(offset==0 || offset<group_total, "Страница тем изменилась. Начните с первой страницы.");
    let drafts=groups.into_iter().map(|group| {
        let mut counts:BTreeMap<String,(usize,String)>=BTreeMap::new();
        for index in &group { for (stem,(word,_)) in &documents[*index] {
            let entry=counts.entry(stem.clone()).or_insert_with(||(0,word.clone())); entry.0+=1;
        }}
        let mut terms=counts.into_iter().filter(|(_,v)|v.0>=2).collect::<Vec<_>>();
        terms.sort_by(|a,b|b.1.0.cmp(&a.1.0).then_with(||a.0.cmp(&b.0)));
        let mut semantic_members=BTreeSet::new();
        for (i,a) in group.iter().enumerate() { for b in group.iter().skip(i+1) {
            if edges[*a].contains(b) && semantic_edges.contains(&(*a,*b)) {
                semantic_members.insert(notes[*a].id.clone()); semantic_members.insert(notes[*b].id.clone());
            }
        }}
        TopicDraft {members:group.iter().map(|i|notes[*i].id.clone()).collect(),
            revisions:group.iter().map(|i|notes[*i].revision).collect(),
            terms:terms.into_iter().take(3).map(|(_,(_,word))|word).collect(),
            semantic_members}
    }).collect::<Vec<_>>();
    #[cfg(test)]
    tests::pause_before_topic_publication(root);
    let (output,collections)={
        check_topic_generation(&generation_key,generation)?;
        let directory=crate::notes::directory(root)?;
        let _lock=crate::notes::lock(&directory)?;
        let mut connection=open(&directory)?;
        let current=initialize(&mut connection,&directory)?;
        let (_,current_kb,_)=state(&connection)?;
        let settings=if root.join("settings.json").exists() {crate::storage::regular_json(&root.join("settings.json"))?} else {json!({})};
        ensure!(current.revision==workspace_revision && current_kb==kb_revision &&
            hash(&settings["features"])?==policy_fingerprint && enabled_anywhere(root)? &&
            semantic.as_ref().is_none_or(|(_,manifest)|crate::semantic::cached_manifest_is_current(root,manifest)),
            "Заметки или настройки изменились. Обновите темы.");
        let profiles=crate::ai::FeatureResolver::new(root)?;
        let current_data:crate::notes::NotesWorkspace=serde_json::from_value(current.value.clone())?;
        let by_id=current_data.notes.iter().filter(|note|note.kind=="note" && note.trashed_at.is_none())
            .map(|note|(note.id.as_str(),note)).collect::<BTreeMap<_,_>>();
        let meeting_folders=current_data.contexts.iter().map(|context|
            (context.meeting_id.clone(),context.folder_id.clone())).collect::<BTreeMap<_,_>>();
        let mut scope_permissions:BTreeMap<Option<String>,(bool,bool)>=BTreeMap::new();
        for draft in &drafts { for id in &draft.members {
            let note=by_id.get(id.as_str()).context("Заметка больше недоступна")?;
            let current=note.folder_id.clone().or_else(||note.meeting_id.as_ref()
                .and_then(|meeting|meeting_folders.get(meeting).cloned().flatten()));
            let features=scope_permissions.entry(current.clone()).or_insert_with(||
                profiles.features_for(&json!({"folderID":current})).map(|f|(f.knowledge_base,f.semantic_search)).unwrap_or((false,false)));
            ensure!(features.0 && (!draft.semantic_members.contains(id) || features.1),
                "Доступ к заметке изменился. Обновите темы.");
        }}
        let base=folder.map(|id|format!("topics-folder-{id}")).unwrap_or_else(||"topics-all".into());
        let cache=cache_dir(root)?.join(format!("{base}-global.json"));
        let old=if ordinary(&cache)? {
            let bytes=read_bytes(&cache)?.unwrap_or_default();
            if bytes.len()<=16_000_000 {
                serde_json::from_slice::<Value>(&bytes).ok().filter(|value|value["schemaVersion"]==1 &&
                    value["topics"].as_array().is_some_and(|rows|rows.len()<=10_000 && rows.iter().all(|row|
                        row["id"].as_str().is_some_and(|id|Uuid::parse_str(id).is_ok()) &&
                        row["members"].as_array().is_some_and(|members|members.len()<=200 &&
                            members.iter().all(|v|v.as_str().is_some_and(identifier)))))).unwrap_or_else(||json!({"topics":[]}))
            } else {json!({"topics":[]})}
        } else {json!({"topics":[]})};
        let old=old["topics"].as_array().cloned().unwrap_or_default();
        let mut old_by_member:BTreeMap<&str,Vec<usize>>=BTreeMap::new();
        for (index,topic) in old.iter().enumerate() {for id in topic["members"].as_array().into_iter().flatten().filter_map(Value::as_str) {
            old_by_member.entry(id).or_default().push(index);
        }}
        let mut used=BTreeSet::<String>::new();
        let mut result=Vec::new(); let mut saved=Vec::new();
        for (index,draft) in drafts.into_iter().enumerate() {
            let members=draft.members.iter().cloned().collect::<BTreeSet<_>>();
            let possible=members.iter().flat_map(|id|old_by_member.get(id.as_str()).into_iter().flatten().copied()).collect::<BTreeSet<_>>();
            let mut matches=possible.into_iter().filter_map(|index| {
                let topic=&old[index];
                let id=topic["id"].as_str()?;
                if used.contains(id) {return None;}
                let previous=topic["members"].as_array()?.iter().filter_map(Value::as_str).map(str::to_owned).collect::<BTreeSet<_>>();
                let union=previous.union(&members).count();
                if union==0{return None;}
                let score=previous.intersection(&members).count() as f64/union as f64;
                (score>=0.65).then_some((score,id.to_owned()))
            }).collect::<Vec<_>>();
            matches.sort_by(|a,b|b.0.total_cmp(&a.0).then_with(||a.1.cmp(&b.1)));
            let id=matches.first().map(|(_,id)|id.clone()).unwrap_or_else(uuid);
            used.insert(id.clone());
            saved.push(json!({"id":id,"members":draft.members}));
            if index>=offset && index<offset+TOPIC_PAGE {
                let sources=draft.members.iter().zip(&draft.revisions).map(|(id,revision)|json!({"noteID":id,"revision":revision})).collect::<Vec<_>>();
                result.push(json!({"id":id,"terms":draft.terms,"sources":sources,
                    "method":if draft.semantic_members.is_empty() {"sharedTerms"} else {"mixed"}}));
            }
        }
        check_topic_generation(&generation_key,generation)?;
        crate::storage::atomic_json(&cache,&json!({"schemaVersion":1,"topics":saved}))?;
        let mut permissions:BTreeMap<Option<String>,bool>=BTreeMap::new();
        let mut collections=Vec::new();
        for row in list_collections(&connection)? {
            let total_members=row["members"].as_array().map_or(0,Vec::len);
            let sources=row["members"].as_array().into_iter().flatten().filter_map(Value::as_str).filter_map(|id| {
                let note=*by_id.get(id)?;
                let current=note.folder_id.clone().or_else(||note.meeting_id.as_ref()
                    .and_then(|meeting|meeting_folders.get(meeting).cloned().flatten()));
                if folder.is_some_and(|wanted|current.as_deref()!=Some(wanted)) {return None;}
                if !*permissions.entry(current.clone()).or_insert_with(||
                    profiles.features_for(&json!({"folderID":current})).is_ok_and(|f|f.knowledge_base)) {return None;}
                Some(json!({"noteID":note.id,"revision":note.revision}))
            }).collect::<Vec<_>>();
            if !sources.is_empty() {
                // A saved title may originally contain words from another
                // folder or from a note now in Trash. Do not publish that
                // title when any member is outside the current scope.
                let name_redacted=sources.len()!=total_members;
                collections.push(json!({"id":row["id"],"name":if name_redacted {""} else {row["name"].as_str().unwrap_or("")},
                    "nameRedacted":name_redacted,"pinned":row["pinned"],"hidden":row["hidden"],
                    "revision":row["revision"],"sources":sources}));
            }
        }
        (result,collections)
    };
    Ok(json!({"workspaceRevision":workspace_revision,"kbRevision":kb_revision,"topics":output,"collections":collections,
        "examined":notes.len(),"total":total,"topicTotal":group_total,"offset":offset,"nextOffset":if offset+output.len()<group_total {Some(offset+TOPIC_PAGE)} else {None},
        "partial":total>MAX_NOTES || groups_truncated || approximate,
        "noteLimitReached":total>MAX_NOTES,"topicLimitReached":groups_truncated,
        "approximate":approximate,"semanticIndexed":semantic_indexed,"semanticEligible":semantic_eligible,
        "method":if semantic.is_some() {"mixed"} else {"sharedTerms"}}))
}

pub(super) fn dispatch(root: &Path, input: &Value) -> Result<Value> {
    let command=required_string(input,"command")?;
    if command=="kb-topics-cancel" { cancel_topic_generation(root,input["requestID"].as_str())?; return Ok(json!({"cancelled":true})); }
    if command=="kb-suggestions" { return suggestions(root,input); }
    if command=="kb-topics" { return topics(root,input); }
    if command=="kb-mixed-topics-cancel" {cancel_topic_generation(&root.join(".mixed-topics"),input["requestID"].as_str())?;return Ok(json!({"cancelled":true}));}
    if command=="kb-mixed-topics" {
        let (key,generation)=begin_topic_generation(&root.join(".mixed-topics"),input["requestID"].as_str())?;
        return crate::knowledge_mixed_inventory::topics(root,input,||check_topic_generation(&key,generation).is_err());
    }
    if command=="kb-topic-source-validate" {return crate::knowledge_mixed_inventory::validate_source(root,input);}
    if command=="kb-note-search" { return search_notes(root,input); }
    if command=="kb-meeting-links" { return meeting_links(root,input); }
    if command=="kb-meeting-backlinks" { return meeting_backlinks(root,input); }
    // Resolve a potentially restored meeting outside the notes lock to avoid lock inversion.
    // A later CAS verifies the exact recorded reference before publishing the undo.
    let checked_meeting_ref=if command=="kb-undo" {
        let candidate=(|| -> Result<Option<Value>> {
            let directory=crate::notes::directory(root)?; let _lock=crate::notes::lock(&directory)?;
            let mut connection=open(&directory)?; let workspace=initialize(&mut connection,&directory)?;
            ensure!(enabled_anywhere(root)?,"Включите базу знаний в настройках");
            migrate(&mut connection,&directory,&workspace)?;
            let row:Option<(String,String)>=connection.query_row("SELECT kind,before_value FROM kb_operations WHERE operation_id=?1",
                [required_string(input,"targetOperationID")?],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
            let Some((kind,before))=row else {return Ok(None)};
            let before:Value=serde_json::from_str(&before)?;
            if kind=="meeting-link" && before["deleted"]==false {Ok(Some(before["sourceRef"].clone()))} else {Ok(None)}
        })()?;
        candidate.and_then(|saved| {
            let id=saved["meetingID"].as_str()?;
            let (items,_)=crate::knowledge_meetings::snapshot(root,id,None).ok()?;
            let source=items.into_iter().find(|source|meeting_ref_matches(source,&saved))?;
            if crate::knowledge_meetings::validate(root,&source,None) {Some(saved)} else {None}
        })
    } else {None};
    let checked_source=if command=="kb-meeting-link-change" && input["action"]=="add" {
        let source:crate::knowledge_meetings::MeetingSource=serde_json::from_value(input["source"].clone()).context("Некорректный источник встречи")?;
        ensure!(crate::knowledge_meetings::validate(root,&source,None),"Материал изменился или стал недоступен. Обновите подсказки.");
        Some(source)
    } else {None};
    ensure!(["kb-snapshot","kb-link-change","kb-meeting-link-change","kb-feedback-change","kb-collection-change","kb-undo"].contains(&command), "Неизвестная команда базы знаний");
    let directory=crate::notes::directory(root)?;
    let _lock=crate::notes::lock(&directory)?;
    crate::corrections::recover_notes_transaction(&directory)?;
    let mut connection=open(&directory)?;
    let workspace=initialize(&mut connection,&directory)?;
    ensure!(enabled_anywhere(root)?, "Включите базу знаний в настройках");
    migrate(&mut connection,&directory,&workspace)?;
    match command {
        "kb-snapshot" => snapshot(root,&connection,&workspace,input),
        "kb-link-change" => change_link(root,&mut connection,&workspace,input),
        "kb-meeting-link-change" => change_meeting_link(root,&mut connection,&workspace,input,checked_source.as_ref()),
        "kb-feedback-change" => change_feedback(root,&mut connection,&workspace,input),
        "kb-collection-change" => change_collection(root,&mut connection,&workspace,input),
        "kb-undo" => undo_link(root,&mut connection,&workspace,input,checked_meeting_ref.as_ref()),
        _ => unreachable!(),
    }
}

#[cfg(test)]
#[path = "knowledge/tests.rs"]
mod tests;
