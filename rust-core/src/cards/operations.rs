//! Recoverable bulk card edits. The redo journal is private and durable before
//! any deck is published; retries never apply a different selection or content.
use super::workspace::{fingerprint, read, text, valid_card};
use crate::storage::{atomic_json, meeting_directory, meeting_lock, regular_json};
use anyhow::{bail, ensure, Context, Result};
use chrono::Utc;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    path::{Path, PathBuf},
};
use uuid::Uuid;

pub(super) const RETENTION_MS: i64 = 30 * 86_400_000;
fn now() -> i64 {
    Utc::now().timestamp_millis()
}
fn alive(item: &Value, at: i64) -> bool {
    item["deletedAt"]
        .as_i64()
        .is_some_and(|deleted| deleted <= at && at - deleted < RETENTION_MS)
}
fn trash_key(item: &Value) -> String {
    item["trashID"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| fingerprint(item))
}
pub(super) fn archive(card: Value, operation: Option<&str>, at: i64) -> Value {
    json!({"trashID":Uuid::new_v4().to_string(),"card":card,"deletedAt":at,"operationID":operation})
}
pub(super) fn list(root: &Path, input: &Value) -> Result<Value> {
    let mut entries = Vec::new();
    let mut errors = Vec::new();
    for meeting in crate::storage::list_meetings(root)? {
        let id = text(&meeting, "id")?;
        if input["meetingID"]
            .as_str()
            .is_some_and(|wanted| wanted != id)
        {
            continue;
        }
        let result = (|| -> Result<()> {
            let dir = meeting_directory(root, id)?;
            let _lock = meeting_lock(&dir)?;
            let summary = read(&dir.join("summary.json"), Value::Null)?;
            for item in summary["archivedCards"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|item| alive(item, now()))
            {
                let card = &item["card"];
                if !valid_card(card) {
                    continue;
                }
                entries.push(json!({"id":trash_key(item),"trashID":trash_key(item),"meetingID":id,"cardID":card["id"],"title":card["front"],"detail":card["back"],"meetingTitle":meeting["title"],"deletedAt":item["deletedAt"].as_i64().unwrap() as f64/1000.0,"expiresAt":(item["deletedAt"].as_i64().unwrap()+RETENTION_MS) as f64/1000.0,"fingerprint":fingerprint(item)}));
            }
            Ok(())
        })();
        if let Err(e) = result {
            errors.push(format!(
                "{}: {e}",
                meeting["title"].as_str().unwrap_or("Карточки")
            ));
        }
    }
    Ok(json!({"entries":entries,"errors":errors}))
}
fn restore(root: &Path, input: &Value) -> Result<Value> {
    let id = text(input, "meetingID")?;
    let dir = meeting_directory(root, id)?;
    let _lock = meeting_lock(&dir)?;
    let mut summary = regular_json(&dir.join("summary.json"))?;
    let archived = summary["archivedCards"]
        .as_array()
        .context("В корзине нет карточек")?;
    let index = archived
        .iter()
        .position(|item| trash_key(item) == input["trashID"].as_str().unwrap_or(""))
        .context("Карточка уже восстановлена или удалена из корзины")?;
    let item = archived[index].clone();
    ensure!(
        fingerprint(&item) == text(input, "expectedFingerprint")?,
        "Корзина изменилась. Обновите список."
    );
    ensure!(
        alive(&item, now()),
        "Срок восстановления карточки истёк (30 дней)"
    );
    let card = &item["card"];
    ensure!(valid_card(card), "Повреждена карточка в корзине");
    let cards = summary["cards"]
        .as_array_mut()
        .context("Повреждена колода")?;
    ensure!(
        !cards.iter().any(|c| c["id"] == card["id"]),
        "Карточка с таким ID уже существует"
    );
    ensure!(cards.len() < 10_000, "В колоде уже 10 000 карточек");
    cards.push(card.clone());
    summary["archivedCards"]
        .as_array_mut()
        .unwrap()
        .remove(index);
    atomic_json(&dir.join("summary.json"), &summary)?;
    Ok(json!({"restored":true,"meetingID":id,"cardID":card["id"]}))
}
fn purge(root: &Path) -> Result<Value> {
    let mut count = 0;
    for meeting in crate::storage::list_meetings(root)? {
        let dir = meeting_directory(root, text(&meeting, "id")?)?;
        let _lock = meeting_lock(&dir)?;
        let mut summary = read(&dir.join("summary.json"), Value::Null)?;
        let Some(archived) = summary["archivedCards"].as_array_mut() else {
            continue;
        };
        let before = archived.len();
        let at = now();
        // Unknown dates remain available for diagnosis; never silently discard
        // malformed data just because it cannot be displayed in normal trash.
        archived.retain(|item| {
            item["deletedAt"]
                .as_i64()
                .is_none_or(|deleted| at - deleted < RETENTION_MS)
        });
        if archived.len() != before {
            count += before - archived.len();
            atomic_json(&dir.join("summary.json"), &summary)?;
        }
    }
    // Successful, expired journals contain snapshots of deleted cards too.
    // Remove them with the same retention; interrupted operations stay intact.
    let operations = operation_dir(root)?;
    let _lock = meeting_lock(&operations)?;
    for entry in fs::read_dir(&operations)? {
        let entry = entry?;
        if entry.path().extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        if let Ok(journal) = read_journal(&entry.path()) {
            if journal["committed"] == true
                && journal["undoPending"] != true
                && journal["createdAt"]
                    .as_i64()
                    .is_some_and(|at| now() - at >= RETENTION_MS)
            {
                fs::remove_file(entry.path())?;
            }
        }
    }
    Ok(json!({"purged":count}))
}
fn operation_dir(root: &Path) -> Result<PathBuf> {
    let dir = root.join("card-operations");
    use std::os::unix::fs::DirBuilderExt;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&dir)?;
    let info = fs::symlink_metadata(&dir)?;
    ensure!(
        info.is_dir() && !info.file_type().is_symlink(),
        "Некорректная папка операций карточек"
    );
    Ok(dir)
}
fn read_journal(path: &Path) -> Result<Value> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    const LIMIT: u64 = 64 * 1_048_576;
    let meta = fs::symlink_metadata(path)?;
    ensure!(
        meta.is_file() && !meta.file_type().is_symlink() && meta.len() <= LIMIT,
        "Некорректный журнал карточек"
    );
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let mut bytes = Vec::new();
    file.take(LIMIT + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= LIMIT,
        "Слишком большой журнал карточек"
    );
    Ok(serde_json::from_slice(&bytes)?)
}
fn valid_operation(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn journal_path(root: &Path, id: &str) -> Result<PathBuf> {
    ensure!(valid_operation(id), "Некорректный ID операции карточек");
    Ok(operation_dir(root)?.join(format!("{id}.json")))
}
fn lock_decks(root: &Path, changes: &[Value]) -> Result<Vec<fs::File>> {
    let ids: std::collections::BTreeSet<_> = changes
        .iter()
        .map(|c| text(c, "meetingID"))
        .collect::<Result<_>>()?;
    ids.into_iter()
        .map(|id| meeting_lock(&meeting_directory(root, id)?))
        .collect()
}
fn mutate_summary(
    summary: &mut Value,
    change: &Value,
    action: &str,
    operation: &str,
    at: i64,
) -> Result<()> {
    let id = text(change, "cardID")?;
    if action == "restoreCards" {
        let archived = summary["archivedCards"]
            .as_array()
            .context("Нет карточек в корзине")?;
        let index = archived
            .iter()
            .position(|item| trash_key(item) == change["trashID"].as_str().unwrap_or(""))
            .context("Карточка уже восстановлена")?;
        let item = archived[index].clone();
        ensure!(
            fingerprint(&item) == text(change, "expectedFingerprint")? && alive(&item, at),
            "Карточка в корзине изменилась или прошло 30 дней"
        );
        ensure!(
            item["card"]["id"] == id && valid_card(&item["card"]),
            "Некорректная карточка в корзине"
        );
        let cards = summary["cards"].as_array_mut().context("Нет колоды")?;
        ensure!(
            !cards.iter().any(|c| c["id"] == id) && cards.len() < 10_000,
            "Карточка уже существует или колода переполнена"
        );
        cards.push(item["card"].clone());
        summary["archivedCards"]
            .as_array_mut()
            .unwrap()
            .remove(index);
        return Ok(());
    }
    let cards = summary["cards"].as_array_mut().context("Нет колоды")?;
    let index = cards
        .iter()
        .position(|c| c["id"] == id)
        .context("Карточка удалена")?;
    ensure!(
        fingerprint(&cards[index]) == text(change, "expectedFingerprint")?,
        "Карточка изменилась. Подготовьте поручение заново."
    );
    if action == "trashCards" {
        let old = cards.remove(index);
        if summary.get("archivedCards").is_none() {
            summary["archivedCards"] = json!([]);
        }
        summary["archivedCards"]
            .as_array_mut()
            .context("Повреждена корзина карточек")?
            .push(archive(old, Some(operation), at));
    } else {
        ensure!(
            action == "rewriteCards",
            "Неизвестное действие с карточками"
        );
        for key in ["front", "back"] {
            let value = text(change, key)?.trim();
            ensure!(
                !value.is_empty() && value.len() <= 6000 && !value.contains('\0'),
                "Некорректный текст карточки"
            );
            cards[index][key] = json!(value);
        }
        cards[index]["editedAt"] = json!(at);
    }
    Ok(())
}
fn finish(root: &Path, path: &Path, journal: &mut Value) -> Result<Value> {
    let decks = journal["decks"]
        .as_array()
        .context("Повреждена операция карточек")?;
    let lock_changes: Vec<_> = decks
        .iter()
        .map(|d| json!({"meetingID":d["meetingID"]}))
        .collect();
    let _locks = lock_decks(root, &lock_changes)?;
    // Validate every deck before writing any. A redo recovers only the exact
    // before/after snapshots; unrelated edits cannot be overwritten by retry.
    for deck in decks {
        let current =
            regular_json(&meeting_directory(root, text(deck, "meetingID")?)?.join("summary.json"))?;
        ensure!(
            current == deck["before"] || current == deck["after"],
            "Карточки изменились во время восстановления операции. Данные сохранены."
        );
    }
    for deck in decks {
        atomic_json(
            &meeting_directory(root, text(deck, "meetingID")?)?.join("summary.json"),
            &deck["after"],
        )?;
    }
    journal["committed"] = json!(true);
    atomic_json(path, journal)?;
    Ok(
        json!({"saved":true,"operationID":journal["operationID"],"count":journal["count"],"meetingID":journal["decks"][0]["meetingID"],"action":journal["action"]}),
    )
}
fn apply(root: &Path, input: &Value) -> Result<Value> {
    let operation = text(input, "operationID")?;
    let path = journal_path(root, operation)?;
    let dir = operation_dir(root)?;
    let _operation_lock = meeting_lock(&dir)?;
    let digest = fingerprint(&json!({"action":input["action"],"changes":input["changes"]}));
    if path.exists() {
        let mut journal = read_journal(&path)?;
        ensure!(
            journal["requestFingerprint"] == digest,
            "Операция уже выполнена с другим набором карточек"
        );
        ensure!(journal["undone"] != true, "Изменение карточек уже отменено");
        if journal["committed"] == true {
            return Ok(
                json!({"saved":true,"operationID":operation,"count":journal["count"],"meetingID":journal["decks"][0]["meetingID"],"action":journal["action"]}),
            );
        }
        return finish(root, &path, &mut journal);
    }
    let action = text(input, "action")?;
    ensure!(
        ["rewriteCards", "trashCards", "restoreCards"].contains(&action),
        "Неизвестное действие с карточками"
    );
    let changes = input["changes"].as_array().context("Выберите карточки")?;
    ensure!(
        !changes.is_empty() && changes.len() <= 500,
        "За одно поручение можно изменить от 1 до 500 карточек"
    );
    let _locks = lock_decks(root, changes)?;
    let mut decks: BTreeMap<String, Value> = BTreeMap::new();
    let mut seen = HashSet::new();
    let at = now();
    for change in changes {
        let id = text(change, "meetingID")?;
        let card = text(change, "cardID")?;
        ensure!(seen.insert((id, card)), "Карточка повторяется в поручении");
        if !decks.contains_key(id) {
            let before = regular_json(&meeting_directory(root, id)?.join("summary.json"))?;
            decks.insert(
                id.to_owned(),
                json!({"meetingID":id,"before":before,"after":before}),
            );
        }
        let deck = decks.get_mut(id).unwrap();
        mutate_summary(&mut deck["after"], change, action, operation, at)?;
    }
    let mut journal = json!({"operationID":operation,"requestFingerprint":digest,"action":action,"count":changes.len(),"createdAt":at,"decks":decks.into_values().collect::<Vec<_>>(),"committed":false,"undone":false});
    ensure!(
        serde_json::to_vec(&journal)?.len() <= 32 * 1_048_576,
        "Поручение слишком большое. Разделите его по колодам."
    );
    for deck in journal["decks"].as_array().unwrap() {
        ensure!(
            serde_json::to_vec_pretty(&deck["after"])?.len() < 8 * 1_048_576,
            "Колода превышает 8 МБ"
        );
    }
    atomic_json(&path, &journal)?;
    // All deck locks are already held; publish without reacquiring flock.
    for deck in journal["decks"].as_array().unwrap() {
        atomic_json(
            &meeting_directory(root, text(deck, "meetingID")?)?.join("summary.json"),
            &deck["after"],
        )?;
    }
    journal["committed"] = json!(true);
    atomic_json(&path, &journal)?;
    Ok(
        json!({"saved":true,"operationID":operation,"count":changes.len(),"meetingID":journal["decks"][0]["meetingID"],"action":action}),
    )
}
fn undo(root: &Path, input: &Value) -> Result<Value> {
    let path = journal_path(root, text(input, "operationID")?)?;
    let _lock = meeting_lock(&operation_dir(root)?)?;
    let mut journal = read_journal(&path)?;
    ensure!(
        journal["committed"] == true,
        "Сначала завершите операцию карточек"
    );
    if journal["undone"] == true {
        return Ok(json!({"undone":true}));
    }
    ensure!(
        journal["undoPending"] == true
            || journal["createdAt"]
                .as_i64()
                .is_some_and(|at| now() - at < RETENTION_MS),
        "Срок отмены истёк (30 дней)"
    );
    let decks = journal["decks"]
        .as_array()
        .context("Повреждена операция карточек")?;
    let changes: Vec<_> = decks
        .iter()
        .map(|d| json!({"meetingID":d["meetingID"]}))
        .collect();
    let _locks = lock_decks(root, &changes)?;
    for deck in decks {
        let current =
            regular_json(&meeting_directory(root, text(deck, "meetingID")?)?.join("summary.json"))?;
        ensure!(
            current == deck["after"] || journal["undoPending"] == true && current == deck["before"],
            "Карточки после поручения изменились. Отмена сохранит новые данные."
        );
    }
    journal["undoPending"] = json!(true);
    atomic_json(&path, &journal)?;
    for deck in journal["decks"].as_array().unwrap() {
        atomic_json(
            &meeting_directory(root, text(deck, "meetingID")?)?.join("summary.json"),
            &deck["before"],
        )?;
    }
    journal["undone"] = json!(true);
    journal["undoPending"] = json!(false);
    atomic_json(&path, &journal)?;
    Ok(json!({"undone":true}))
}
fn recover(root: &Path) -> Result<Value> {
    let directory = operation_dir(root)?;
    let mut pending = Vec::new();
    {
        let _lock = meeting_lock(&directory)?;
        for entry in fs::read_dir(&directory)?.take(1000) {
            let entry = entry?;
            if entry.path().extension().and_then(|s| s.to_str()) != Some("json") {
                continue;
            }
            let journal = read_journal(&entry.path())?;
            if journal["committed"] != true || journal["undoPending"] == true {
                pending.push((entry.path(), journal));
            }
        }
    }
    let mut recovered = 0;
    let mut errors = Vec::new();
    for (path, mut journal) in pending {
        let outcome = if journal["undoPending"] == true {
            undo(root, &json!({"operationID":journal["operationID"]}))
        } else {
            let _lock = meeting_lock(&directory)?;
            // Re-read after waiting: another process may already have recovered.
            journal = read_journal(&path)?;
            if journal["committed"] == true {
                continue;
            }
            finish(root, &path, &mut journal)
        };
        match outcome {
            Ok(_) => recovered += 1,
            Err(error) => errors.push(error.to_string()),
        }
    }
    Ok(json!({"recovered":recovered,"errors":errors}))
}
pub(super) fn dispatch(root: &Path, input: &Value) -> Result<Value> {
    match input["command"].as_str() {
        Some("card-trash-list") => list(root, input),
        Some("card-restore") => restore(root, input),
        Some("card-trash-purge") => purge(root),
        Some("cards-batch-apply") => apply(root, input),
        Some("cards-batch-undo") => undo(root, input),
        Some("cards-batch-recover") => recover(root),
        _ => bail!("Неизвестная операция карточек"),
    }
}

#[cfg(test)]
mod tests;
