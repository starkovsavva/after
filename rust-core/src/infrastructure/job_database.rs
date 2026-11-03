//! Protected jobs.sqlite connection and compatible schema migrations.
use anyhow::{ensure, Result};
use rusqlite::{params, OpenFlags, TransactionBehavior};
use serde_json::Value;
use std::{fs, path::Path, time::Duration};

pub(super) fn open(root: &Path) -> Result<crate::platform_fs::GuardedConnection> {
    crate::platform_fs::private_directory(root)?;
    // Resolve system aliases such as macOS /tmp after validating the leaf.
    // SQLite NOFOLLOW also rejects symlinks in ancestor path components.
    let root = fs::canonicalize(root)?;
    let path = root.join("jobs.sqlite");
    for name in [
        "jobs.sqlite",
        "jobs.sqlite-journal",
        "jobs.sqlite-wal",
        "jobs.sqlite-shm",
    ] {
        crate::platform_fs::ordinary_single_file(&root.join(name))?;
    }
    let _file = crate::platform_fs::open_private(&path, false)?;
    let mut connection = crate::platform_fs::sqlite_connection(
        &path,
        OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_NO_MUTEX
            | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    connection.busy_timeout(Duration::from_secs(5))?;
    connection.execute_batch("PRAGMA foreign_keys=ON;")?;
    let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    ensure!(
        version <= 2,
        "Очередь создана более новой версией приложения"
    );
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
