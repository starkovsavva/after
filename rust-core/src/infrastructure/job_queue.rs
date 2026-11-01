//! SQLite implementation of the application queue ports. No transport dispatch
//! or scheduling rules live here; a callback owns one immediate transaction.
use crate::application::job_ports::{
    JobMatchScope, JobQueueRepository, JobQueueTransaction, JobSelection,
};
use crate::domain::jobs::{Job, JobQueueSnapshot};
use anyhow::{ensure, Context, Result};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use serde_json::Value;
use std::{fs, path::Path, time::Duration};

fn open(root: &Path) -> Result<crate::platform_fs::GuardedConnection> {
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
fn query_jobs(connection: &Connection, sql: &str) -> Result<Vec<Job>> {
    let mut query = connection.prepare(sql)?;
    let rows = query.query_map([], |row| row.get::<_, String>(0))?;
    rows.map(|row| Ok(serde_json::from_str(&row?)?)).collect()
}
fn listed(connection: &Connection, kind: Option<&str>) -> Result<Vec<Job>> {
    fn rows(connection: &Connection, sql: &str, kind: Option<&str>) -> Result<Vec<Job>> {
        let mut query = connection.prepare(sql)?;
        let rows = query.query_map([kind], |row| row.get::<_, String>(0))?;
        rows.map(|row| Ok(serde_json::from_str(&row?)?)).collect()
    }
    let mut jobs = rows(connection,
        "SELECT payload FROM jobs WHERE state IN ('queued','running') AND (?1 IS NULL OR json_extract(payload,'$.kind')=?1) ORDER BY created_at,rowid", kind)?;
    jobs.extend(rows(connection,
        "SELECT payload FROM jobs WHERE state NOT IN ('queued','running') AND (?1 IS NULL OR json_extract(payload,'$.kind')=?1) ORDER BY updated_at DESC,rowid DESC LIMIT 50", kind)?);
    jobs.sort_by(|a, b| a.created_at.total_cmp(&b.created_at));
    Ok(jobs)
}

fn paused_chatgpt_jobs(connection: &Connection) -> Result<Vec<Job>> {
    query_jobs(connection, "SELECT jobs.payload FROM job_chatgpt_pauses JOIN jobs ON jobs.id=job_chatgpt_pauses.job_id ORDER BY jobs.created_at,jobs.rowid")
}

fn get(connection: &Connection, id: &str) -> Result<Job> {
    let text: String = connection
        .query_row("SELECT payload FROM jobs WHERE id=?1", [&id], |row| {
            row.get(0)
        })
        .optional()?
        .context("Задание больше недоступно")?;
    Ok(serde_json::from_str(&text)?)
}
fn persist(connection: &Connection, job: &Job) -> Result<()> {
    let existing: Option<String> = connection
        .query_row("SELECT payload FROM jobs WHERE id=?1", [&job.id], |row| {
            row.get(0)
        })
        .optional()?;
    let mut payload: Value = existing
        .map(|raw| serde_json::from_str(&raw))
        .transpose()?
        .unwrap_or_else(|| serde_json::json!({}));
    let fields = serde_json::to_value(job)?;
    payload
        .as_object_mut()
        .context("Некорректное задание")?
        .extend(fields.as_object().context("Некорректное задание")?.clone());
    connection.execute("INSERT INTO jobs(id,state,resource,object_id,dedup_key,created_at,updated_at,payload) VALUES(?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT(id) DO UPDATE SET state=excluded.state,updated_at=excluded.updated_at,payload=excluded.payload", params![job.id,job.state,job.resource,job.object_id,job.dedup_key()?,job.created_at,job.updated_at,serde_json::to_string(&payload)?])?;
    Ok(())
}

pub(crate) struct SqliteJobQueue<'a> {
    pub root: &'a Path,
}

impl JobQueueRepository for SqliteJobQueue<'_> {
    fn snapshot(&self, kind: Option<&str>) -> Result<JobQueueSnapshot> {
        let mut connection = open(self.root)?;
        // One read snapshot keeps jobs, counts and admission pauses consistent.
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Deferred)?;
        let jobs = listed(&transaction, kind)?;
        let total: i64 = transaction.query_row(
            "SELECT COUNT(*) FROM jobs WHERE ?1 IS NULL OR json_extract(payload,'$.kind')=?1",
            [kind],
            |row| row.get(0),
        )?;
        let paused_chatgpt_failures = paused_chatgpt_jobs(&transaction)?
            .into_iter()
            .filter(|job| kind.is_none_or(|kind| kind == job.kind))
            .collect();
        transaction.commit()?;
        Ok(JobQueueSnapshot {
            jobs,
            total: total.try_into().context("Некорректный размер очереди")?,
            paused_chatgpt_failures,
        })
    }

    fn recovery_candidates(
        &self,
        kind: &str,
        after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Job>> {
        ensure!((1..=256).contains(&limit), "Invalid recovery page limit");
        let connection = open(self.root)?;
        let mut statement = connection.prepare("SELECT id,payload FROM jobs WHERE state IN ('running','interrupted') AND json_extract(payload,'$.kind')=?1 AND id>?2 ORDER BY id LIMIT ?3")?;
        let rows = statement
            .query_map(params![kind, after.unwrap_or(""), limit as i64], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;
        rows.map(|row| {
            let (id, payload) = row?;
            let job: Job = serde_json::from_str(&payload)?;
            ensure!(job.id == id, "Invalid recovery record identity");
            Ok(job)
        })
        .collect()
    }

    fn get(&self, id: &str) -> Result<Job> {
        let connection = open(self.root)?;
        get(&connection, id)
    }

    fn transaction<T>(
        &self,
        action: impl FnOnce(&mut dyn JobQueueTransaction) -> Result<T>,
    ) -> Result<T> {
        let mut connection = open(self.root)?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let result = action(&mut SqliteQueueSession(&transaction))?;
        transaction.commit()?;
        Ok(result)
    }
}

struct SqliteQueueSession<'a>(&'a Connection);

impl JobQueueTransaction for SqliteQueueSession<'_> {
    fn selected(&self, selection: JobSelection) -> Result<Vec<Job>> {
        query_jobs(self.0, match selection {
            JobSelection::Active => "SELECT payload FROM jobs WHERE state IN ('queued','running') ORDER BY created_at,rowid",
            JobSelection::WaitingDependencies => "SELECT payload FROM jobs WHERE state IN ('queued','blocked') ORDER BY created_at,rowid",
            JobSelection::Running => "SELECT payload FROM jobs WHERE state='running'",
        })
    }

    fn get(&self, id: &str) -> Result<Job> {
        get(self.0, id)
    }

    fn state(&self, id: &str) -> Result<Option<String>> {
        Ok(self
            .0
            .query_row("SELECT state FROM jobs WHERE id=?1", [id], |row| {
                row.get::<_, String>(0)
            })
            .optional()?)
    }

    fn matching(&self, job: &Job, scope: JobMatchScope) -> Result<Option<Job>> {
        let sql = match scope {
            JobMatchScope::AnyState => "SELECT payload FROM jobs WHERE dedup_key=?1 ORDER BY created_at LIMIT 1",
            JobMatchScope::Pending => "SELECT payload FROM jobs WHERE dedup_key=?1 AND state IN ('queued','running','interrupted','blocked')",
        };
        self.0
            .query_row(sql, [job.dedup_key()?], |row| row.get::<_, String>(0))
            .optional()?
            .map(|text| Ok(serde_json::from_str(&text)?))
            .transpose()
    }

    fn active_count(&self) -> Result<u64> {
        let count: i64 = self.0.query_row(
            "SELECT COUNT(*) FROM jobs WHERE state IN ('queued','running')",
            [],
            |row| row.get(0),
        )?;
        count.try_into().context("Некорректный размер очереди")
    }

    fn paused_jobs(&self) -> Result<Vec<Job>> {
        paused_chatgpt_jobs(self.0)
    }

    fn save(&mut self, job: &Job) -> Result<()> {
        persist(self.0, job)
    }

    fn pause_account(&mut self, account: &str, job: &str) -> Result<()> {
        self.0.execute("INSERT INTO job_chatgpt_pauses(account_id,job_id) VALUES(?1,?2) ON CONFLICT(account_id) DO UPDATE SET job_id=excluded.job_id", params![account, job])?;
        Ok(())
    }

    fn resume_account(&mut self, account: &str) -> Result<()> {
        self.0.execute(
            "DELETE FROM job_chatgpt_pauses WHERE account_id=?1",
            [account],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::jobs::{reached_chatgpt_limit, JobDefinition, JobResource};
    use crate::jobs::dispatch;
    use serde_json::json;
    fn call(root: &Path, command: &str, mut fields: Value) -> Value {
        fields["command"] = json!(command);
        dispatch(root, &fields).unwrap()
    }
    fn enqueue(root: &Path, object: &str, resource: &str) -> Value {
        call(root,"job-enqueue",json!({"kind":"summarize","objectID":object,"resource":resource,"inputRevision":"v1","config":{"model":"local"}}))["job"].clone()
    }

    #[test]
    fn queue_mutations_preserve_unknown_compatible_payload_fields() {
        let root = tempfile::tempdir().unwrap();
        let initial = enqueue(root.path(), "future-compatible", "light");
        let id = initial["id"].as_str().unwrap().to_owned();
        let connection = open(root.path()).unwrap();
        let mut payload = initial;
        let extension = json!({"opaque":["keep",{"revision":7}]});
        payload["futureExtension"] = extension.clone();
        connection
            .execute(
                "UPDATE jobs SET payload=?1 WHERE id=?2",
                params![payload.to_string(), &id],
            )
            .unwrap();
        drop(connection);
        call(root.path(), "job-claim", json!({"jobID":id}));
        call(
            root.path(),
            "job-update",
            json!({"jobID":id,"expectedAttempt":1,"progress":0.5}),
        );
        call(root.path(), "job-recover", json!({}));
        let connection = open(root.path()).unwrap();
        let raw: String = connection
            .query_row("SELECT payload FROM jobs WHERE id=?1", [&id], |row| {
                row.get(0)
            })
            .unwrap();
        let persisted: Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(persisted["futureExtension"], extension);
        assert_eq!(persisted["state"], "interrupted");
    }

    #[test]
    fn a_future_queue_schema_is_never_opened_or_rewritten_by_an_old_adapter() {
        let root = tempfile::tempdir().unwrap();
        enqueue(root.path(), "future-schema", "light");
        let connection = open(root.path()).unwrap();
        connection.pragma_update(None, "user_version", 3).unwrap();
        drop(connection);
        let path = root.path().join("jobs.sqlite");
        let before = fs::read(&path).unwrap();
        assert!(SqliteJobQueue { root: root.path() }.snapshot(None).is_err());
        assert_eq!(fs::read(path).unwrap(), before);
    }
    #[test]
    fn failed_transaction_callback_rolls_back_job_and_account_pause() {
        let root = tempfile::tempdir().unwrap();
        let initial = enqueue(root.path(), "a", "cloud");
        let repository = SqliteJobQueue { root: root.path() };
        let result: Result<()> = repository.transaction(|session| {
            let mut job = session.get(initial["id"].as_str().unwrap())?;
            job.state = "running".into();
            session.save(&job)?;
            session.pause_account("fixture-account", &job.id)?;
            anyhow::bail!("injected callback failure")
        });
        assert!(result.is_err());
        let reopened = SqliteJobQueue { root: root.path() }.snapshot(None).unwrap();
        assert!(reopened.paused_chatgpt_failures.is_empty());
        assert_eq!(serde_json::to_value(&reopened.jobs[0]).unwrap(), initial);
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
    fn secrets_and_invalid_progress_are_rejected() {
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
    }
    #[test]
    fn linked_database_and_sidecars_are_rejected_before_touching_the_target() {
        for name in [
            "jobs.sqlite",
            "jobs.sqlite-journal",
            "jobs.sqlite-wal",
            "jobs.sqlite-shm",
        ] {
            let root = tempfile::tempdir().unwrap();
            let outside = tempfile::tempdir().unwrap();
            let target = outside.path().join("untouched");
            fs::write(&target, b"do not modify").unwrap();
            fs::hard_link(&target, root.path().join(name)).unwrap();
            assert!(
                dispatch(root.path(), &json!({"command":"job-list"})).is_err(),
                "{name}"
            );
            assert_eq!(fs::read(&target).unwrap(), b"do not modify");
        }
    }
    #[test]
    fn directories_cannot_be_used_as_database_or_sidecars() {
        for name in [
            "jobs.sqlite",
            "jobs.sqlite-journal",
            "jobs.sqlite-wal",
            "jobs.sqlite-shm",
        ] {
            let root = tempfile::tempdir().unwrap();
            fs::create_dir(root.path().join(name)).unwrap();
            assert!(
                dispatch(root.path(), &json!({"command":"job-list"})).is_err(),
                "{name}"
            );
        }
    }
    #[test]
    #[cfg(unix)]
    fn symlink_database_is_rejected_and_database_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        enqueue(root.path(), "a", "cloud");
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
            assert_eq!(
                call(root.path(), "job-claim", json!({"jobID":job["id"]}))["job"]["id"],
                job["id"]
            );
            call(
                root.path(),
                "job-update",
                json!({"jobID":job["id"],"state":"failed","message":message,"expectedAttempt":1}),
            );
        };
        // This separate failed job can later be explicitly retried. The quota
        // failure itself then remains in history and must not recreate a pause.
        let resume_a = plan("resume-a", "account-a", "example");
        finish(&resume_a, "Temporary provider failure");
        let quota_a = plan("quota-a", "account-a", "summarize");
        let quota_b = plan("quota-b", "account-b", "voice-plan");
        for job in [&quota_a, &quota_b] {
            finish(
                job,
                "ChatGPT: HTTP 200 · subscription_sharing_usage_limit_exceeded. Fixture limit.",
            );
        }
        let pending_a = plan("pending-a", "account-a", "example");
        let pending_b = plan("pending-b", "account-b", "example");
        for job in [&pending_a, &pending_b] {
            assert!(call(root.path(), "job-claim", json!({"jobID":job["id"]}))["job"].is_null());
        }
        // Neither other accounts nor API-key-backed speech inherits the pause.
        for job in [
            plan("other-account", "account-c", "example"),
            plan("speech", "account-a", "transcribe"),
        ] {
            assert_eq!(
                call(root.path(), "job-claim", json!({"jobID":job["id"]}))["job"]["id"],
                job["id"]
            );
            call(
                root.path(),
                "job-update",
                json!({"jobID":job["id"],"state":"succeeded"}),
            );
        }
        for index in 0..55 {
            let job = enqueue(root.path(), &format!("history-{index}"), "light");
            call(root.path(), "job-claim", json!({"jobID":job["id"]}));
            call(
                root.path(),
                "job-update",
                json!({"jobID":job["id"],"state":"succeeded"}),
            );
        }
        let list = call(root.path(), "job-list", json!({}));
        assert!(!list["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|job| job["id"] == quota_a["id"]));
        assert_eq!(list["pausedChatGPTFailures"].as_array().unwrap().len(), 2);
        assert!(dispatch(
            root.path(),
            &json!({"command":"job-retry","jobID":resume_a["id"],"confirmPaid":false})
        )
        .is_err());
        assert_eq!(
            call(root.path(), "job-list", json!({}))["pausedChatGPTFailures"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        call(
            root.path(),
            "job-retry",
            json!({"jobID":resume_a["id"],"confirmPaid":true}),
        );
        let reopened = call(root.path(), "job-list", json!({}));
        assert_eq!(
            reopened["pausedChatGPTFailures"].as_array().unwrap().len(),
            1
        );
        assert_eq!(reopened["pausedChatGPTFailures"][0]["id"], quota_b["id"]);
        assert_eq!(
            call(root.path(), "job-get", json!({"jobID":quota_a["id"]}))["job"]["state"],
            "failed"
        );
        assert_eq!(
            call(root.path(), "job-claim", json!({"jobID":pending_a["id"]}))["job"]["id"],
            pending_a["id"]
        );
        assert!(call(root.path(), "job-claim", json!({"jobID":pending_b["id"]}))["job"].is_null());
    }

    #[test]
    fn quota_pause_classification_requires_the_exact_transport_code() {
        assert!(reached_chatgpt_limit(
            "ChatGPT: HTTP 429 · subscription_sharing_usage_limit_exceeded. Retry later."
        ));
        for message in [
            "ChatGPT: HTTP 200 · subscription_sharing_usage_limit_exceeded_extra. Other code.",
            "ChatGPT: HTTP nope · subscription_sharing_usage_limit_exceeded. Not a status.",
            "Provider mentioned subscription_sharing_usage_limit_exceeded.",
        ] {
            assert!(!reached_chatgpt_limit(message));
        }
    }

    #[test]
    fn quota_pause_schema_migration_preserves_history_without_guessing_past_consent() {
        let root = tempfile::tempdir().unwrap();
        let job = enqueue(root.path(), "legacy", "cloud");
        call(root.path(), "job-claim", json!({"jobID":job["id"]}));
        call(
            root.path(),
            "job-update",
            json!({"jobID":job["id"],"state":"failed",
            "message":"ChatGPT: HTTP 200 · subscription_sharing_usage_limit_exceeded. Historical failure."}),
        );
        let connection = open(root.path()).unwrap();
        connection
            .execute_batch("DROP TABLE job_chatgpt_pauses; PRAGMA user_version=1;")
            .unwrap();
        drop(connection);
        let migrated = call(root.path(), "job-list", json!({}));
        assert_eq!(migrated["jobs"][0]["id"], job["id"]);
        assert!(migrated["pausedChatGPTFailures"]
            .as_array()
            .unwrap()
            .is_empty());
        assert_eq!(
            open(root.path())
                .unwrap()
                .pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
                .unwrap(),
            2
        );
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
        assert_eq!(
            call(
                root.path(),
                "job-update",
                json!({
                    "jobID":job["id"],"expectedAttempt":1,"state":"succeeded",
                    "progress":null,"message":[],"result":{"token":"ignored late result"}
                })
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
            let mut row = JobDefinition {
                kind: "example".into(),
                object_id: "history".into(),
                input_revision: String::new(),
                config: json!({}),
                resource: JobResource::Light,
                dependencies: Vec::new(),
                title: "example".into(),
                paid: false,
            }
            .into_job("history".into(), 1.0);
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
