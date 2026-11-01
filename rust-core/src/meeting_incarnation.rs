//! Test-only lifecycle journal experiment, not a source of publication rights.
//!
//! It establishes what a cooperative, transactional lifecycle can guarantee.
//! It cannot detect filesystem writes by old binaries, cannot atomically commit
//! a file operation with SQLite, and must never be used to enable meeting links.
//! No product route opens this journal; callers here provide disposable DBs.
use anyhow::{ensure, Result};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use uuid::Uuid;

fn valid_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128 &&
        value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn initialize(db: &Connection) -> Result<()> {
    db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS meeting_incarnations (
            meeting_id TEXT NOT NULL,
            incarnation TEXT NOT NULL UNIQUE,
            active INTEGER NOT NULL CHECK(active IN (0,1)),
            PRIMARY KEY (meeting_id,incarnation)
        );
        CREATE UNIQUE INDEX IF NOT EXISTS meeting_single_active_incarnation
            ON meeting_incarnations(meeting_id) WHERE active=1;")?;
    Ok(())
}

/// Register only a creation already admitted by a future coordinated storage
/// protocol. This function neither creates nor checks meeting files.
fn registered_create(db: &mut Connection, meeting_id: &str) -> Result<String> {
    ensure!(valid_id(meeting_id), "Некорректный идентификатор встречи");
    let tx=db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let active: bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM meeting_incarnations WHERE meeting_id=?1 AND active=1)",
        [meeting_id],|row|row.get(0))?;
    ensure!(!active, "Для встречи уже есть активная версия");
    let generation=Uuid::new_v4().to_string();
    tx.execute("INSERT INTO meeting_incarnations(meeting_id,incarnation,active) VALUES(?1,?2,1)",
        params![meeting_id,generation])?;
    tx.commit()?;
    Ok(generation)
}

/// Retire the exact active generation. A delayed deletion for an older
/// generation cannot retire a newer meeting with the same logical ID.
fn registered_delete(db: &mut Connection, meeting_id: &str, expected: &str) -> Result<()> {
    ensure!(valid_id(meeting_id) && Uuid::parse_str(expected).is_ok(), "Некорректная версия встречи");
    let tx=db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(tx.execute("UPDATE meeting_incarnations SET active=0 WHERE meeting_id=?1 AND incarnation=?2 AND active=1",
        params![meeting_id,expected])? == 1, "Версия встречи изменилась");
    tx.commit()?;
    Ok(())
}

fn journal_matches(db: &Connection, meeting_id: &str, expected: &str) -> Result<bool> {
    ensure!(valid_id(meeting_id) && Uuid::parse_str(expected).is_ok(), "Некорректная версия встречи");
    Ok(db.query_row("SELECT active FROM meeting_incarnations WHERE meeting_id=?1 AND incarnation=?2",
        params![meeting_id,expected],|row|row.get::<_,i64>(0)).optional()? == Some(1))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::{Arc, Barrier};
    use std::time::Duration;

    #[test]
    fn cooperative_delete_recreate_changes_identity_and_rejects_late_delete() {
        let mut db=Connection::open_in_memory().unwrap(); initialize(&db).unwrap();
        let old=registered_create(&mut db,"meeting").unwrap();
        assert!(journal_matches(&db,"meeting",&old).unwrap());
        registered_delete(&mut db,"meeting",&old).unwrap();
        let current=registered_create(&mut db,"meeting").unwrap();
        assert_ne!(old,current);
        assert!(!journal_matches(&db,"meeting",&old).unwrap());
        assert!(registered_delete(&mut db,"meeting",&old).is_err());
        assert!(journal_matches(&db,"meeting",&current).unwrap());
        assert!(!journal_matches(&db,"another",&current).unwrap());
        assert!(registered_create(&mut db,"meeting").is_err());
    }

    #[test]
    fn generations_persist_and_concurrent_creation_has_one_winner() {
        let root=tempfile::tempdir().unwrap(); let db_path=root.path().join("synthetic.sqlite");
        let first=Connection::open(&db_path).unwrap(); initialize(&first).unwrap(); drop(first);
        let barrier=Arc::new(Barrier::new(2));
        let mut threads=Vec::new();
        for _ in 0..2 {
            let path=db_path.clone(); let barrier=barrier.clone();
            threads.push(std::thread::spawn(move || {
                let mut db=Connection::open(path).unwrap(); db.busy_timeout(Duration::from_secs(5)).unwrap();
                barrier.wait(); registered_create(&mut db,"meeting")
            }));
        }
        let outcomes=threads.into_iter().map(|thread|thread.join().unwrap()).collect::<Vec<_>>();
        assert_eq!(outcomes.iter().filter(|result|result.is_ok()).count(),1);
        let active=outcomes.into_iter().find_map(Result::ok).unwrap();
        let mut db=Connection::open(&db_path).unwrap();
        assert!(journal_matches(&db,"meeting",&active).unwrap());
        registered_delete(&mut db,"meeting",&active).unwrap();
        drop(db);
        let mut restarted=Connection::open(db_path).unwrap();
        assert!(!journal_matches(&restarted,"meeting",&active).unwrap());
        let next=registered_create(&mut restarted,"meeting").unwrap();
        assert_ne!(next,active);
        assert!(!journal_matches(&restarted,"meeting",&active).unwrap());
    }

    #[test]
    fn uncoordinated_legacy_recreation_is_invisible_to_journal_so_feature_must_remain_closed() {
        let root=tempfile::tempdir().unwrap(); let directory=root.path().join("meeting");
        fs::create_dir(&directory).unwrap(); fs::write(directory.join("meta.json"),b"same").unwrap();
        let mut db=Connection::open_in_memory().unwrap(); initialize(&db).unwrap();
        let old=registered_create(&mut db,"meeting").unwrap();
        fs::remove_dir_all(&directory).unwrap(); fs::create_dir(&directory).unwrap();
        fs::write(directory.join("meta.json"),b"same").unwrap();
        // This deliberately demonstrates the boundary, not a security pass:
        // without coordinated file operations the journal wrongly matches.
        assert!(journal_matches(&db,"meeting",&old).unwrap());
    }
}
