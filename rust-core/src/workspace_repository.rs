//! Canonical, transactional storage for the notes/task workspace.
//!
//! Callers which mutate the workspace retain `notes::lock` across load/save.
//! The SQLite snapshot, entity catalogue, operation receipts and change outbox
//! are committed together. `notes/workspace.json` is a disposable compatibility
//! export; it is never imported after the first committed database snapshot.
use anyhow::{bail, ensure, Context, Result};
use rusqlite::{
    params, Connection, OpenFlags, OptionalExtension, Transaction, TransactionBehavior,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

const VERSION: i64 = 1;
pub(crate) const MAX_WORKSPACE: u64 = 32 * 1_048_576;
const DATABASE: &str = "core.sqlite";
const MARKER: &str = ".core-sqlite-migrated";
const BACKUP: &str = "workspace.pre-sqlite.json";

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSnapshot {
    pub revision: u64,
    pub fingerprint: String,
    pub value: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceEvent {
    pub id: String,
    pub revision: u64,
    pub kind: String,
    pub created_at: f64,
    pub payload: Value,
}

fn hash(value: &Value) -> Result<String> {
    Ok(format!("{:x}", Sha256::digest(serde_json::to_vec(value)?)))
}
fn now() -> f64 {
    chrono::Utc::now().timestamp_millis() as f64 / 1000.0
}
fn ordinary(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(info) => {
            ensure!(
                info.is_file() && !info.file_type().is_symlink() && info.nlink() == 1,
                "Некорректный файл базы приложения: {}",
                path.file_name().unwrap_or_default().to_string_lossy()
            );
            Ok(true)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error.into()),
    }
}
fn root(directory: &Path) -> Result<&Path> {
    ensure!(
        directory.file_name().is_some_and(|name| name == "notes"),
        "Некорректная папка заметок"
    );
    directory.parent().context("Нет папки библиотеки")
}
fn open(directory: &Path) -> Result<Connection> {
    let root = root(directory)?;
    // macOS exposes /var and /tmp through system symlinks. SQLite NOFOLLOW
    // rejects symlinks in any path component, so resolve the already validated
    // private directory while still refusing a symlink at the database leaf.
    let path = fs::canonicalize(root)?.join(DATABASE);
    let exists = ordinary(&path)?;
    let marked = ordinary(&directory.join(MARKER))?;
    ensure!(exists || !marked,
        "База приложения отсутствует. Автоматический повторный импорт старых заметок остановлен; восстановите core.sqlite из резервной копии.");
    for suffix in ["-journal", "-wal", "-shm"] {
        ordinary(&root.join(format!("{DATABASE}{suffix}")))?;
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
    let mut connection = Connection::open_with_flags(
        &path,
        OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_NO_MUTEX
            | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    connection.busy_timeout(Duration::from_secs(5))?;
    connection.execute_batch(
        "PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL;",
    )?;
    let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    ensure!(
        version <= VERSION,
        "База создана более новой версией «After». Обновите приложение."
    );
    // A malformed/corrupt database is never replaced with a legacy JSON file.
    let mode: String = connection.pragma_query_value(None, "journal_mode", |row| row.get(0))?;
    if mode != "wal" {
        connection.pragma_update(None, "journal_mode", "WAL")?;
    }
    if version == 0 {
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute_batch("\
            CREATE TABLE IF NOT EXISTS workspace_state(\
                singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL CHECK(revision>=1),\
                fingerprint TEXT NOT NULL, payload TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);\
            CREATE TABLE IF NOT EXISTS workspace_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);\
            CREATE TABLE IF NOT EXISTS workspace_entities(\
                kind TEXT NOT NULL, entity_id TEXT NOT NULL, entity_revision INTEGER NOT NULL,\
                workspace_revision INTEGER NOT NULL, fingerprint TEXT NOT NULL, updated_at REAL NOT NULL,\
                deleted INTEGER NOT NULL CHECK(deleted IN (0,1)), PRIMARY KEY(kind,entity_id));\
            CREATE INDEX IF NOT EXISTS workspace_entities_live ON workspace_entities(kind,deleted,updated_at);\
            CREATE TABLE IF NOT EXISTS operation_receipts(\
                namespace TEXT NOT NULL, operation_id TEXT NOT NULL, workspace_revision INTEGER NOT NULL,\
                payload TEXT NOT NULL, PRIMARY KEY(namespace,operation_id));\
            CREATE TABLE IF NOT EXISTS workspace_outbox(\
                event_id TEXT PRIMARY KEY, revision INTEGER NOT NULL UNIQUE, kind TEXT NOT NULL,\
                created_at REAL NOT NULL, payload TEXT NOT NULL);\
            CREATE TABLE IF NOT EXISTS workspace_outbox_deliveries(\
                consumer TEXT NOT NULL, event_id TEXT NOT NULL REFERENCES workspace_outbox(event_id),\
                acknowledged_at REAL NOT NULL, PRIMARY KEY(consumer,event_id));")?;
        transaction.pragma_update(None, "user_version", VERSION)?;
        transaction.commit()?;
    }
    for suffix in ["", "-journal", "-wal", "-shm"] {
        let path = root.join(format!("{DATABASE}{suffix}"));
        if ordinary(&path)? {
            fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        }
    }
    Ok(connection)
}
fn read_bytes(path: &Path) -> Result<Option<Vec<u8>>> {
    if !ordinary(path)? {
        return Ok(None);
    }
    let info = fs::metadata(path)?;
    ensure!(
        info.len() <= MAX_WORKSPACE,
        "Библиотека заметок слишком большая"
    );
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let mut bytes = Vec::new();
    file.take(MAX_WORKSPACE + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= MAX_WORKSPACE,
        "Библиотека заметок слишком большая"
    );
    Ok(Some(bytes))
}
fn validate(value: &Value) -> Result<crate::notes::NotesWorkspace> {
    ensure!(
        value.is_object() && serde_json::to_vec(value)?.len() as u64 <= MAX_WORKSPACE,
        "Библиотека заметок слишком большая или имеет неверный формат"
    );
    let data = serde_json::from_value(value.clone())
        .context("Не удалось прочитать заметки. Исходные данные сохранены.")?;
    crate::notes::validate_workspace(&data)?;
    Ok(data)
}
fn read_snapshot(connection: &Connection) -> Result<Option<WorkspaceSnapshot>> {
    let row: Option<(i64, String, String)> = connection
        .query_row(
            "SELECT revision,fingerprint,payload FROM workspace_state WHERE singleton=1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    row.map(|(revision, fingerprint, payload)| -> Result<_> {
        ensure!(
            revision > 0 && payload.len() as u64 <= MAX_WORKSPACE,
            "Некорректная база заметок"
        );
        let value: Value =
            serde_json::from_str(&payload).context("Повреждены данные заметок. База сохранена.")?;
        ensure!(
            hash(&value)? == fingerprint,
            "Не совпадает контрольная сумма заметок. База сохранена."
        );
        validate(&value)?;
        Ok(WorkspaceSnapshot {
            revision: revision as u64,
            fingerprint,
            value,
        })
    })
    .transpose()
}
fn sync_parent(path: &Path) {
    if let Some(parent) = path.parent() {
        if let Ok(file) = File::open(parent) {
            let _ = file.sync_all();
        }
    }
}
fn backup(directory: &Path, bytes: &[u8]) -> Result<PathBuf> {
    let path = directory.join(BACKUP);
    if ordinary(&path)? {
        ensure!(read_bytes(&path)?.as_deref() == Some(bytes),
            "Исходные заметки изменились после подготовки миграции. Резервная копия сохранена; автоматический импорт остановлен.");
        return Ok(path);
    }
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    sync_parent(&path);
    Ok(path)
}
fn marker(directory: &Path) -> Result<()> {
    let path = directory.join(MARKER);
    if ordinary(&path)? {
        return Ok(());
    }
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)?;
    file.write_all(b"core.sqlite is canonical; workspace.json is an export\n")?;
    file.sync_all()?;
    sync_parent(&path);
    Ok(())
}
fn initialize(connection: &mut Connection, directory: &Path) -> Result<WorkspaceSnapshot> {
    if let Some(snapshot) = read_snapshot(connection)? {
        let mut migrated = snapshot.value.clone();
        let snapshot = if crate::folders::migrate_legacy(&mut migrated)? {
            validate(&migrated)?;
            let transaction=connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let result=commit(&transaction,Some(&snapshot),migrated,"workspace.folders-migrated")?;
            transaction.commit()?;result
        } else {snapshot};
        marker(directory)?;
        return Ok(snapshot);
    }
    ensure!(!ordinary(&directory.join(MARKER))?,
        "В базе отсутствует основное состояние заметок. Повторный импорт остановлен; восстановите core.sqlite из резервной копии.");
    let imported: Option<String> = connection
        .query_row(
            "SELECT value FROM workspace_metadata WHERE key='legacyImported'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    ensure!(
        imported.is_none(),
        "Основное состояние базы повреждено. Повторный импорт остановлен."
    );
    // Validate before creating a backup or committing any canonical state.
    let legacy = read_bytes(&directory.join("workspace.json"))?;
    let value: Value = match &legacy {
        Some(bytes) => serde_json::from_slice(bytes)
            .context("Не удалось прочитать заметки. Исходный файл сохранён.")?,
        None => serde_json::to_value(crate::notes::defaults())?,
    };
    validate(&value)?;
    let mut value = canonicalize_aliases(&value);
    crate::folders::migrate_legacy(&mut value)?;
    validate(&value)?;
    if let Some(bytes) = &legacy {
        backup(directory, bytes)?;
    }
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    // SQLite protects first use even when a future caller does not own flock.
    if let Some(snapshot) = read_snapshot(&transaction)? {
        transaction.commit()?;
        marker(directory)?;
        return Ok(snapshot);
    }
    let snapshot = commit(&transaction, None, value, "workspace.initialized")?;
    transaction.execute(
        "INSERT INTO workspace_metadata(key,value) VALUES('legacyImported',?1)",
        [if legacy.is_some() { "true" } else { "false" }],
    )?;
    if let Some(bytes) = legacy {
        transaction.execute(
            "INSERT INTO workspace_metadata(key,value) VALUES('legacySHA256',?1)",
            [format!("{:x}", Sha256::digest(&bytes))],
        )?;
    }
    transaction.commit()?;
    marker(directory)?;
    Ok(snapshot)
}

fn canonicalize_aliases(value: &Value) -> Value {
    let mut value = value.clone();
    for (section, aliases) in [
        (
            "notes",
            &[
                ("meetingId", "meetingID"),
                ("sourceUrl", "sourceURL"),
                ("contentRtf", "contentRTF"),
                ("folderId", "folderID"),
            ][..],
        ),
        (
            "contexts",
            &[("meetingId", "meetingID"), ("templateId", "templateID"), ("folderId", "folderID")][..],
        ),
    ] {
        for item in value
            .get_mut(section)
            .and_then(Value::as_array_mut)
            .into_iter()
            .flatten()
        {
            if let Some(object) = item.as_object_mut() {
                for (alias, canonical) in aliases {
                    if let Some(old) = object.remove(*alias) {
                        object.entry((*canonical).to_string()).or_insert(old);
                    }
                }
            }
        }
    }
    value
}

/// Preserve forward-compatible fields that typed editors do not understand.
/// Known fields intentionally removed by the editor stay removed. Array entries
/// are matched by stable entity identity, so deleted notes are never resurrected.
fn preserve_unknown(raw: &Value, known: &Value, edited: &Value) -> Value {
    match (raw, known, edited) {
        (Value::Object(raw), Value::Object(known), Value::Object(edited)) => {
            let mut result = edited.clone();
            for (key, old_raw) in raw {
                match (known.get(key), result.get_mut(key)) {
                    (None, None) => {
                        result.insert(key.clone(), old_raw.clone());
                    }
                    (Some(old_known), Some(new)) => {
                        *new = preserve_unknown(old_raw, old_known, new);
                    }
                    _ => {}
                }
            }
            Value::Object(result)
        }
        (Value::Array(raw), Value::Array(known), Value::Array(edited)) => Value::Array(
            edited
                .iter()
                .enumerate()
                .map(|(index, new)| {
                    let identity = entity_identity(new);
                    let old_index = if let Some(identity) = identity {
                        known
                            .iter()
                            .position(|value| entity_identity(value).as_ref() == Some(&identity))
                    } else if raw == known {
                        None
                    } else {
                        Some(index)
                    };
                    match old_index.and_then(|i| Some((raw.get(i)?, known.get(i)?))) {
                        Some((old_raw, old_known)) => preserve_unknown(old_raw, old_known, new),
                        None => new.clone(),
                    }
                })
                .collect(),
        ),
        _ => edited.clone(),
    }
}
fn entity_identity(value: &Value) -> Option<(String, String)> {
    for key in ["id", "noteID", "meetingID", "operationID", "planID"] {
        if let Some(id) = value[key].as_str() {
            return Some((key.into(), id.into()));
        }
    }
    None
}
#[derive(Clone)]
struct Entity {
    revision: u64,
    updated_at: f64,
    fingerprint: String,
}
fn entities(value: &Value) -> Result<BTreeMap<(String, String), Entity>> {
    let mut result = BTreeMap::new();
    for (section, kind, id_key) in [
        ("notes", "note", "id"),
        ("folders", "folder", "id"),
        ("templates", "template", "id"),
        ("contexts", "meetingContext", "meetingID"),
        ("taskWorkspaces", "task", "noteID"),
    ] {
        for item in value[section].as_array().into_iter().flatten() {
            let id = item[id_key]
                .as_str()
                .or_else(|| {
                    if id_key == "meetingID" {
                        item["meetingId"].as_str()
                    } else {
                        None
                    }
                })
                .context("У записи нет идентификатора")?;
            ensure!(
                !result.contains_key(&(kind.into(), id.into())),
                "Повторный идентификатор записи"
            );
            result.insert(
                (kind.into(), id.into()),
                Entity {
                    revision: item["revision"].as_u64().unwrap_or(0),
                    updated_at: item["updatedAt"].as_f64().unwrap_or(0.0),
                    fingerprint: hash(item)?,
                },
            );
        }
    }
    Ok(result)
}
fn receipt_rows(value: &Value) -> Result<BTreeMap<(String, String), Value>> {
    let mut rows = BTreeMap::new();
    for (field, namespace) in [("voiceOperations", "voice"), ("taskOperations", "task")] {
        for item in value[field].as_array().into_iter().flatten() {
            let id = item["operationID"]
                .as_str()
                .context("У операции нет идентификатора")?;
            ensure!(
                !id.is_empty() && id.len() <= 256 && !id.contains('\0'),
                "Некорректный ID операции"
            );
            ensure!(
                rows.insert((namespace.into(), id.into()), item.clone())
                    .is_none(),
                "Повторный ID операции"
            );
        }
    }
    Ok(rows)
}
fn commit(
    transaction: &Transaction<'_>,
    previous: Option<&WorkspaceSnapshot>,
    value: Value,
    kind: &str,
) -> Result<WorkspaceSnapshot> {
    validate(&value)?;
    if let Some(previous) = previous {
        let current: (i64, String) = transaction.query_row(
            "SELECT revision,fingerprint FROM workspace_state WHERE singleton=1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        ensure!(
            current.0 as u64 == previous.revision && current.1 == previous.fingerprint,
            "Библиотека изменилась. Повторите действие с актуальными данными."
        );
    }
    let fingerprint = hash(&value)?;
    if let Some(previous) = previous.filter(|snapshot| snapshot.fingerprint == fingerprint) {
        return Ok(previous.clone());
    }
    let revision = previous.map_or(Ok(1), |old| {
        old.revision
            .checked_add(1)
            .context("Слишком большая ревизия библиотеки")
    })?;
    ensure!(
        revision <= i64::MAX as u64,
        "Слишком большая ревизия библиотеки"
    );
    let timestamp = now();
    let payload = serde_json::to_string(&value)?;
    match previous {
        Some(previous) => {
            ensure!(transaction.execute("UPDATE workspace_state SET revision=?1,fingerprint=?2,payload=?3,updated_at=?4 WHERE singleton=1 AND revision=?5 AND fingerprint=?6",
                params![revision as i64,fingerprint,payload,timestamp,previous.revision as i64,previous.fingerprint])? == 1,
                "Библиотека изменилась. Повторите действие с актуальными данными.");
        }
        None => {
            transaction.execute(
                "INSERT INTO workspace_state VALUES(1,?1,?2,?3,?4,?4)",
                params![revision as i64, fingerprint, payload, timestamp],
            )?;
        }
    }
    let old = previous
        .map(|old| entities(&old.value))
        .transpose()?
        .unwrap_or_default();
    let new = entities(&value)?;
    let mut changes = vec![];
    let keys: BTreeSet<_> = old.keys().chain(new.keys()).collect();
    for key in keys {
        let before = old.get(key);
        let after = new.get(key);
        if before.map(|v| &v.fingerprint) == after.map(|v| &v.fingerprint) {
            continue;
        }
        let (entity_revision, entity_updated, digest, deleted) = match after {
            Some(entity) => (
                entity.revision.min(i64::MAX as u64),
                entity.updated_at,
                entity.fingerprint.as_str(),
                0,
            ),
            None => (
                before
                    .map_or(0, |v| v.revision)
                    .saturating_add(1)
                    .min(i64::MAX as u64),
                timestamp,
                "",
                1,
            ),
        };
        transaction.execute("INSERT INTO workspace_entities(kind,entity_id,entity_revision,workspace_revision,fingerprint,updated_at,deleted) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(kind,entity_id) DO UPDATE SET entity_revision=excluded.entity_revision,workspace_revision=excluded.workspace_revision,fingerprint=excluded.fingerprint,updated_at=excluded.updated_at,deleted=excluded.deleted",
            params![key.0,key.1,entity_revision as i64,revision as i64,digest,entity_updated,deleted])?;
        changes.push(json!({"kind":key.0,"id":key.1,"change":if deleted == 1 { "delete" } else { "upsert" },"fingerprint":digest}));
    }
    let mut operations = vec![];
    let old_receipts = previous
        .map(|snapshot| receipt_rows(&snapshot.value))
        .transpose()?
        .unwrap_or_default();
    for ((namespace, id), receipt) in receipt_rows(&value)? {
        if old_receipts.get(&(namespace.clone(), id.clone())) == Some(&receipt) {
            continue;
        }
        let existing: Option<String> = transaction
            .query_row(
                "SELECT payload FROM operation_receipts WHERE namespace=?1 AND operation_id=?2",
                params![namespace, id],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(existing) = existing {
            let existing: Value = serde_json::from_str(&existing)?;
            for key in ["fingerprint", "requestHash", "applyRequestHash", "planID"] {
                if let (Some(before), Some(after)) = (
                    existing.get(key).filter(|value| !value.is_null()),
                    receipt.get(key).filter(|value| !value.is_null()),
                ) {
                    ensure!(
                        before == after,
                        "Этот ID операции уже использован с другим содержимым"
                    );
                }
            }
        }
        let serialized = serde_json::to_string(&receipt)?;
        transaction.execute("INSERT INTO operation_receipts(namespace,operation_id,workspace_revision,payload) VALUES(?1,?2,?3,?4) ON CONFLICT(namespace,operation_id) DO UPDATE SET workspace_revision=excluded.workspace_revision,payload=excluded.payload WHERE payload<>excluded.payload",
            params![namespace,id,revision as i64,serialized])?;
        operations.push(json!({"namespace":namespace,"id":id}));
    }
    let event = json!({"schemaVersion":1,"workspaceRevision":revision,"changes":changes,"operationIDs":operations});
    transaction.execute("INSERT INTO workspace_outbox(event_id,revision,kind,created_at,payload) VALUES(?1,?2,?3,?4,?5)",
        params![uuid::Uuid::new_v4().to_string(),revision as i64,kind,timestamp,serde_json::to_string(&event)?])?;
    Ok(WorkspaceSnapshot {
        revision,
        fingerprint,
        value,
    })
}
fn compatibility_export(directory: &Path, snapshot: &WorkspaceSnapshot, changed: bool) {
    // A failed export does not turn an already committed mutation into a failure.
    // Reads never parse this obsolete copy. Missing exports can be regenerated;
    // externally edited exports do not become a second source of truth.
    let path = directory.join("workspace.json");
    let exists = match ordinary(&path) {
        Ok(true) => {
            if fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).is_err() {
                return;
            }
            true
        }
        Ok(false) => false,
        Err(_) => return,
    };
    if changed || !exists {
        let _ = crate::storage::atomic_json(&path, &snapshot.value);
    }
}

/// Caller owns the notes lock. This deliberately does not recover corrections,
/// allowing their journal to compare the canonical database without recursion.
pub(crate) fn load_locked(directory: &Path) -> Result<WorkspaceSnapshot> {
    let mut connection = open(directory)?;
    let snapshot = initialize(&mut connection, directory)?;
    compatibility_export(directory, &snapshot, false);
    Ok(snapshot)
}
pub(crate) fn persist_locked(
    directory: &Path,
    data: &crate::notes::NotesWorkspace,
) -> Result<WorkspaceSnapshot> {
    let mut connection = open(directory)?;
    let previous = initialize(&mut connection, directory)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let previous_known = serde_json::to_value(serde_json::from_value::<
        crate::notes::NotesWorkspace,
    >(previous.value.clone())?)?;
    let value = preserve_unknown(
        &previous.value,
        &previous_known,
        &serde_json::to_value(data)?,
    );
    let snapshot = commit(&transaction, Some(&previous), value, "workspace.changed")?;
    transaction.commit()?;
    compatibility_export(directory, &snapshot, snapshot.revision != previous.revision);
    Ok(snapshot)
}

/// Read the last committed profile state without taking notes::lock. Policy
/// checks also run inside workspace mutations; recursively acquiring flock
/// would deadlock. This function never initializes, migrates, or writes SQLite.
pub(crate) fn read_committed(root: &Path) -> Result<Value> {
    ensure!(root.is_absolute(), "Нужен абсолютный путь библиотеки");
    let path=root.join(DATABASE);
    if ordinary(&path)? {
        let connection=Connection::open_with_flags(&path,OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
        connection.busy_timeout(Duration::from_secs(5))?;
        if let Some(snapshot)=read_snapshot(&connection)? { return Ok(snapshot.value); }
        bail!("В базе отсутствует основное состояние библиотеки");
    }
    ensure!(!ordinary(&root.join("notes").join(MARKER))?,"База библиотеки отсутствует. Восстановите core.sqlite из резервной копии.");
    let legacy=root.join("notes/workspace.json");
    let value=match read_bytes(&legacy)? { Some(bytes)=>serde_json::from_slice(&bytes).context("Не удалось прочитать библиотеку")?,None=>serde_json::to_value(crate::notes::defaults())? };
    validate(&value)?;Ok(value)
}

/// Stable snapshot for integrations. All existing corrections are recovered first.
pub fn snapshot(root: &Path) -> Result<WorkspaceSnapshot> {
    let directory = crate::notes::directory(root)?;
    let _lock = crate::notes::lock(&directory)?;
    crate::corrections::recover_notes_transaction(&directory)?;
    load_locked(&directory)
}
/// Optimistic replacement for new repository clients. Unknown fields from the
/// current snapshot are retained; a stale revision cannot overwrite newer work.
pub fn compare_and_save(
    root: &Path,
    expected_revision: u64,
    value: &Value,
) -> Result<WorkspaceSnapshot> {
    let directory = crate::notes::directory(root)?;
    let _lock = crate::notes::lock(&directory)?;
    crate::corrections::recover_notes_transaction(&directory)?;
    let mut connection = open(&directory)?;
    let previous = initialize(&mut connection, &directory)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(
        previous.revision == expected_revision,
        "Библиотека изменилась. Повторите действие с актуальными данными."
    );
    let known = serde_json::to_value(serde_json::from_value::<crate::notes::NotesWorkspace>(
        previous.value.clone(),
    )?)?;
    validate(value)?;
    let merged = preserve_unknown(&previous.value, &known, &canonicalize_aliases(value));
    let snapshot = commit(&transaction, Some(&previous), merged, "workspace.changed")?;
    transaction.commit()?;
    compatibility_export(
        &directory,
        &snapshot,
        snapshot.revision != previous.revision,
    );
    Ok(snapshot)
}
fn consumer_id(consumer: &str) -> Result<()> {
    ensure!(
        !consumer.is_empty()
            && consumer.len() <= 128
            && consumer
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.')),
        "Некорректное имя обработчика изменений"
    );
    Ok(())
}
/// At-least-once, ordered delivery. Acknowledge an event only after its derived
/// index / remote receipt is durable. Each consumer has independent delivery.
pub fn pending_events(root: &Path, consumer: &str, limit: usize) -> Result<Vec<WorkspaceEvent>> {
    consumer_id(consumer)?;
    ensure!((1..=500).contains(&limit), "Укажите от 1 до 500 событий");
    let directory = crate::notes::directory(root)?;
    let _lock = crate::notes::lock(&directory)?;
    crate::corrections::recover_notes_transaction(&directory)?;
    let mut connection = open(&directory)?;
    initialize(&mut connection, &directory)?;
    let mut query = connection.prepare("SELECT event_id,revision,kind,created_at,payload FROM workspace_outbox e WHERE NOT EXISTS(SELECT 1 FROM workspace_outbox_deliveries d WHERE d.event_id=e.event_id AND d.consumer=?1) ORDER BY revision LIMIT ?2")?;
    let rows = query
        .query_map(params![consumer, limit as i64], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, f64>(3)?,
                row.get::<_, String>(4)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    rows.into_iter()
        .map(|(id, revision, kind, created_at, payload)| {
            Ok(WorkspaceEvent {
                id,
                revision: revision as u64,
                kind,
                created_at,
                payload: serde_json::from_str(&payload)?,
            })
        })
        .collect()
}
pub fn acknowledge_event(root: &Path, consumer: &str, event_id: &str) -> Result<()> {
    consumer_id(consumer)?;
    ensure!(
        !event_id.is_empty() && event_id.len() <= 128,
        "Некорректный ID события"
    );
    let directory = crate::notes::directory(root)?;
    let _lock = crate::notes::lock(&directory)?;
    let mut connection = open(&directory)?;
    initialize(&mut connection, &directory)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(
        transaction
            .query_row(
                "SELECT 1 FROM workspace_outbox WHERE event_id=?1",
                [event_id],
                |_| Ok(())
            )
            .optional()?
            .is_some(),
        "Событие не найдено"
    );
    transaction.execute("INSERT OR IGNORE INTO workspace_outbox_deliveries(consumer,event_id,acknowledged_at) VALUES(?1,?2,?3)",params![consumer,event_id,now()])?;
    transaction.commit()?;
    Ok(())
}
pub fn operation_receipt(
    root: &Path,
    namespace: &str,
    operation_id: &str,
) -> Result<Option<Value>> {
    let directory = crate::notes::directory(root)?;
    let _lock = crate::notes::lock(&directory)?;
    operation_receipt_locked(&directory, namespace, operation_id)
}

/// Read a durable receipt while the caller already owns notes::lock. The
/// bounded workspace journal may have evicted its presentation copy.
pub(crate) fn operation_receipt_locked(
    directory: &Path,
    namespace: &str,
    operation_id: &str,
) -> Result<Option<Value>> {
    ensure!(
        ["voice", "task"].contains(&namespace)
            && !operation_id.is_empty()
            && operation_id.len() <= 256,
        "Некорректная операция"
    );
    let mut connection = open(directory)?;
    initialize(&mut connection, directory)?;
    let payload: Option<String> = connection
        .query_row(
            "SELECT payload FROM operation_receipts WHERE namespace=?1 AND operation_id=?2",
            params![namespace, operation_id],
            |row| row.get(0),
        )
        .optional()?;
    payload
        .map(|payload| serde_json::from_str(&payload).map_err(Into::into))
        .transpose()
}

#[cfg(test)]
mod tests;
