//! Recoverable deletion. Notes remain in the transactional workspace; meeting
//! files move as a single directory inside the private library, never to Finder.
use anyhow::{bail, ensure, Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, DirBuilder};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub const RETENTION_SECONDS: f64 = 30.0 * 86_400.0;
fn now() -> f64 {
    chrono::Utc::now().timestamp_millis() as f64 / 1000.0
}
fn hash(value: &Value) -> String {
    format!("{:x}", Sha256::digest(value.to_string().as_bytes()))
}
fn id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn private(path: &Path) -> Result<()> {
    if let Ok(info) = fs::symlink_metadata(path) {
        ensure!(
            info.is_dir() && !info.file_type().is_symlink(),
            "Корзина должна быть обычной папкой"
        );
    }
    DirBuilder::new().recursive(true).mode(0o700).create(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}
fn archived(root: &Path, key: &str) -> Result<PathBuf> {
    ensure!(id(key), "Некорректный ID встречи");
    private(root)?;
    let base = root.join("trash");
    private(&base)?;
    let meetings = base.join("meetings");
    private(&meetings)?;
    let path = meetings.join(key);
    if let Ok(info) = fs::symlink_metadata(&path) {
        ensure!(
            info.is_dir() && !info.file_type().is_symlink(),
            "Некорректная папка в Корзине"
        );
    }
    Ok(path)
}
fn manifest(path: &Path) -> Result<Value> {
    crate::storage::regular_json(&path.join(".posle-trash.json"))
}
fn meeting_snapshot(root: &Path, key: &str, restore: bool) -> Result<Value> {
    let path = if restore {
        archived(root, key)?
    } else {
        crate::storage::meeting_directory(root, key)?
    };
    ensure!(path.is_dir(), "Встреча уже перемещена. Обновите данные.");
    let meta = crate::storage::regular_json(&path.join("meta.json"))?;
    ensure!(meta["id"] == key, "Некорректная встреча");
    let deleted = if restore {
        manifest(&path)?["deletedAt"]
            .as_f64()
            .context("Нет даты удаления")?
    } else {
        0.0
    };
    if restore {
        ensure!(
            deleted.is_finite()
                && deleted > 0.0
                && deleted <= now()
                && now() - deleted < RETENTION_SECONDS,
            "Срок восстановления встречи истёк"
        );
    }
    let mut versions = Vec::new();
    for entry in fs::read_dir(&path)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let info = fs::symlink_metadata(entry.path())?;
        ensure!(
            !info.file_type().is_symlink(),
            "Встреча содержит ссылку вместо файла"
        );
        versions.push(json!([
            name,
            info.len(),
            info.mtime(),
            info.mtime_nsec(),
            info.ino()
        ]));
    }
    versions.sort_by_key(Value::to_string);
    Ok(
        json!({"id":key,"kind":"meeting","meetingID":key,"title":meta["title"],"detail":"Запись, транскрипт, конспект и карточки", "deletedAt":deleted,"expiresAt":deleted+RETENTION_SECONDS,"fingerprint":hash(&json!({"meta":meta,"deletedAt":deleted,"versions":versions}))}),
    )
}
pub fn snapshot(root: &Path, kind: &str, key: &str, restore: bool) -> Result<Value> {
    ensure!(id(key), "Некорректный ID объекта");
    if kind == "meeting" {
        return meeting_snapshot(root, key, restore);
    }
    ensure!(
        ["note", "task"].contains(&kind),
        "Неизвестный тип объекта Корзины"
    );
    let workspace = crate::notes::list(root)?;
    let note = workspace
        .notes
        .iter()
        .find(|n| n.id == key)
        .context("Заметка или задача не найдена")?;
    note_snapshot(note, kind, restore)
}
fn note_snapshot(note: &crate::notes::CapturedNote, kind: &str, restore: bool) -> Result<Value> {
    ensure!(
        (kind == "task") == (note.kind == "task"),
        "Тип объекта изменился"
    );
    ensure!(
        note.trashed_at.is_some() == restore,
        "Состояние Корзины изменилось"
    );
    if let Some(deleted) = note.trashed_at {
        ensure!(
            deleted <= now() && now() - deleted < RETENTION_SECONDS,
            "Срок восстановления истёк"
        );
    }
    let title = if note.title.trim().is_empty() {
        note.text.lines().next().unwrap_or("Заметка")
    } else {
        &note.title
    };
    Ok(
        json!({"id":note.id,"kind":kind,"title":title.chars().take(160).collect::<String>(),"detail":note.text.chars().take(240).collect::<String>(),"revision":note.revision,"meetingID":note.meeting_id,"deletedAt":note.trashed_at,"expiresAt":note.trashed_at.map(|t|t+RETENTION_SECONDS),"fingerprint":hash(&serde_json::to_value(note)?)}),
    )
}
pub fn list(root: &Path) -> Result<Value> {
    let workspace = crate::notes::list(root)?;
    let mut entries = Vec::new();
    let mut errors = Vec::new();
    for note in &workspace.notes {
        if note.trashed_at.is_some() {
            if let Ok(value) = note_snapshot(
                note,
                if note.kind == "task" { "task" } else { "note" },
                true,
            ) {
                entries.push(value);
            }
        }
    }
    let base = archived(root, "placeholder")?
        .parent()
        .unwrap()
        .to_path_buf();
    for entry in fs::read_dir(base)?.take(10_000) {
        let Ok(entry) = entry else { continue };
        let Some(key) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if !id(&key) {
            continue;
        }
        match meeting_snapshot(root, &key, true) {
            Ok(value) => entries.push(value),
            Err(error) => {
                if entry.path().join("meta.json").exists() {
                    errors.push(json!({"kind":"meeting","id":key,"message":error.to_string()}));
                }
            }
        }
    }
    let cards = crate::cards::dispatch(root, &json!({"command":"card-trash-list"}))?;
    entries.extend(
        cards["entries"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .map(|mut item| {
                item["kind"] = json!("card");
                item
            }),
    );
    errors.extend(cards["errors"].as_array().cloned().unwrap_or_default());
    entries.sort_by(|a, b| {
        b["deletedAt"]
            .as_f64()
            .unwrap_or_default()
            .total_cmp(&a["deletedAt"].as_f64().unwrap_or_default())
    });
    Ok(json!({"entries":entries,"errors":errors,"retentionDays":30}))
}
fn result(key: &str, kind: &str, title: &Value, restore: bool, operation: &str) -> Value {
    let noun = match kind {
        "meeting" => "Встреча",
        "task" => "Задача",
        _ => "Заметка",
    };
    json!({"operationID":operation,"title":format!("{noun} {}",if restore{"восстановлена"}else{"в Корзине"}),"detail":if restore{format!("{} — снова в библиотеке",title.as_str().unwrap_or(""))}else{format!("{} — можно восстановить в течение 30 дней",title.as_str().unwrap_or(""))},"target":if restore{json!({"kind":if kind=="meeting"{"meeting"}else{kind},"id":key,"meetingID":if kind=="meeting"{json!(key)}else{Value::Null}})}else{json!({"kind":"trash","id":key})},"canUndo":false})
}
pub fn change(root: &Path, input: &Value) -> Result<Value> {
    let kind = input["kind"].as_str().context("Нет типа объекта")?;
    let key = input["id"].as_str().context("Нет объекта")?;
    ensure!(
        id(key) && ["note", "task", "meeting"].contains(&kind),
        "Некорректный объект Корзины"
    );
    let restore = input["restore"].as_bool().context("Нет действия")?;
    let fingerprint = input["expectedFingerprint"]
        .as_str()
        .context("Обновите объект перед изменением")?;
    let operation = input["operationID"].as_str().context("Нет ID операции")?;
    ensure!(id(operation), "Некорректный ID операции");
    let request_hash =
        hash(&json!({"kind":kind,"id":key,"restore":restore,"fingerprint":fingerprint}));
    let directory = crate::notes::directory(root)?;
    let _lock = crate::notes::lock(&directory)?;
    let mut workspace = crate::notes::load(&directory)?;
    if let Some(receipt) = workspace
        .voice_operations
        .iter()
        .find(|r| r["domainOperationID"] == operation && r["trashDomain"] == true)
    {
        ensure!(
            receipt["requestHash"] == request_hash,
            "Операция уже использована с другими параметрами"
        );
        return Ok(receipt["result"].clone());
    }
    let output = if kind == "meeting" {
        let active = crate::storage::meeting_directory(root, key)?;
        let deleted = archived(root, key)?;
        // Recover a crash after the atomic directory rename but before SQL receipt.
        let destination = if restore { &active } else { &deleted };
        if let Ok(old) = manifest(destination) {
            if old["operationID"] == operation {
                ensure!(
                    old["requestHash"] == request_hash,
                    "Операция уже выполнена с другими параметрами"
                );
                let output = old["result"].clone();
                record(
                    &directory,
                    &mut workspace,
                    operation,
                    &request_hash,
                    &output,
                )?;
                return Ok(output);
            }
        }
        let source = if restore { &deleted } else { &active };
        ensure!(
            source.is_dir() && !destination.exists(),
            "Встреча уже перемещена. Обновите данные."
        );
        let _meeting_lock = crate::storage::meeting_lock(source)?;
        let current = meeting_snapshot(root, key, restore)?;
        ensure!(
            current["fingerprint"] == fingerprint,
            "Встреча изменилась. Подготовьте действие заново."
        );
        let meta = crate::storage::regular_json(&source.join("meta.json"))?;
        ensure!(
            !["recording", "processing"]
                .iter()
                .any(|s| meta["status"] == *s),
            "Сначала завершите запись или обработку встречи"
        );
        let jobs = crate::jobs::dispatch(root, &json!({"command":"job-list"}))?;
        ensure!(
            !jobs["jobs"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|job| job["objectID"] == key
                    && ["queued", "running"].iter().any(|s| job["state"] == *s)),
            "Дождитесь завершения фоновых задач этой встречи"
        );
        let output = result(key, kind, &current["title"], restore, operation);
        let deleted_at = if restore {
            current["deletedAt"].clone()
        } else {
            json!(now())
        };
        crate::storage::atomic_json(
            &source.join(".posle-trash.json"),
            &json!({"id":key,"deletedAt":deleted_at,"operationID":operation,"requestHash":request_hash,"result":output}),
        )?;
        fs::rename(source, destination)
            .context("Не удалось переместить встречу; запись сохранена")?;
        output
    } else {
        let index = workspace
            .notes
            .iter()
            .position(|n| n.id == key)
            .context("Заметка или задача не найдена")?;
        let current = note_snapshot(&workspace.notes[index], kind, restore)?;
        ensure!(
            current["fingerprint"] == fingerprint,
            "Объект изменился. Подготовьте действие заново."
        );
        let note = &mut workspace.notes[index];
        note.trashed_at = if restore { None } else { Some(now()) };
        note.revision = note
            .revision
            .checked_add(1)
            .context("Слишком большая ревизия")?;
        note.updated_at = now();
        result(key, kind, &current["title"], restore, operation)
    };
    record(
        &directory,
        &mut workspace,
        operation,
        &request_hash,
        &output,
    )?;
    Ok(output)
}
fn record(
    directory: &Path,
    workspace: &mut crate::notes::NotesWorkspace,
    operation: &str,
    request_hash: &str,
    result: &Value,
) -> Result<()> {
    // Match the bounded presentation journal policy; never evict pending work.
    if workspace.voice_operations.len() >= 500 {
        let index = workspace
            .voice_operations
            .iter()
            .position(|r| r["pending"] != true)
            .context("Слишком много незавершённых поручений")?;
        workspace.voice_operations.remove(index);
    }
    workspace.voice_operations.push(json!({"trashDomain":true,"operationID":format!("trash-domain-{}",hash(&json!(operation))),"domainOperationID":operation,"requestHash":request_hash,"createdAt":now(),"result":result}));
    crate::notes::persist(directory, workspace)
}
fn purge(root: &Path) -> Result<Value> {
    let cutoff = now() - RETENTION_SECONDS;
    let mut removed = 0;
    let mut errors = Vec::new();
    for note in crate::notes::list(root)?.notes.into_iter().filter(|n| {
        n.trashed_at.is_some_and(|t| t <= cutoff) && !crate::notes::is_task_tombstone(n)
    }) {
        match crate::notes::delete_note(root, &note.id, note.revision) {
            Ok(_) => removed += 1,
            Err(error) => errors.push(error.to_string()),
        }
    }
    let directory = crate::notes::directory(root)?;
    let _lock = crate::notes::lock(&directory)?;
    let base = archived(root, "placeholder")?
        .parent()
        .unwrap()
        .to_path_buf();
    for entry in fs::read_dir(base)?.take(10_000) {
        let Ok(entry) = entry else { continue };
        let Some(key) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if !id(&key) {
            continue;
        }
        let path = archived(root, &key)?;
        if manifest(&path)
            .ok()
            .and_then(|v| v["deletedAt"].as_f64())
            .is_some_and(|t| t.is_finite() && t > 0.0 && t <= cutoff)
        {
            match fs::remove_dir_all(path) {
                Ok(_) => removed += 1,
                Err(error) => errors.push(error.to_string()),
            }
        }
    }
    drop(_lock);
    let cards = crate::cards::dispatch(root, &json!({"command":"card-trash-purge"}))?;
    Ok(json!({"removed":removed,"cards":cards,"errors":errors}))
}
pub fn dispatch(root: &Path, input: &Value) -> Result<Value> {
    match input["command"].as_str() {
        Some("trash-list") => list(root),
        Some("trash-snapshot") => snapshot(
            root,
            input["kind"].as_str().context("Нет типа")?,
            input["id"].as_str().context("Нет ID")?,
            input["restore"].as_bool().unwrap_or(false),
        ),
        Some("trash-change") => change(root, input),
        Some("trash-purge-expired") => purge(root),
        _ => bail!("Неизвестная команда Корзины"),
    }
}

#[cfg(test)]
mod tests;
