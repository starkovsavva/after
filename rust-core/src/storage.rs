//! Private, atomic meeting storage and FSRS scheduling.
//!
//! The JSON shape remains readable by the Swift UI and by Python's `fsrs.Card`.
//! FSRS memory updates and review intervals come from the official `fsrs` crate;
//! the short learning/relearning steps are scheduling policy, not an FSRS substitute.

use anyhow::{Context, Result, bail, ensure};
use chrono::{DateTime, Duration, SecondsFormat, Utc};
use fsrs::{FSRS, MemoryState};
use serde::Serialize;
use serde_json::{Map, Value, json};
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use uuid::Uuid;

const RETENTION: f32 = 0.9;
const SCHEDULER: &str = "fsrs-rs/6.6.2";
const ALLOWED_EXTENSIONS: &[&str] = &[
    "mp4", "mov", "m4a", "mp3", "wav", "aiff", "aif", "caf", "flac", "ogg", "webm", "mkv", "aac",
];
const MUTABLE_META_FIELDS: &[&str] = &[
    "title", "focus", "meetingPurpose", "generateCards", "status", "duration", "speakerNames", "completedTasks",
    "recordingTracks", "hasVideo", "error",
];

fn private_directory(path: &Path) -> Result<()> {
    DirBuilder::new().recursive(true).mode(0o700).create(path)
        .with_context(|| format!("Не удалось создать папку {}", path.display()))?;
    let info = fs::symlink_metadata(path)?;
    ensure!(info.is_dir() && !info.file_type().is_symlink(), "Папка данных не должна быть символической ссылкой: {}", path.display());
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

pub(crate) fn regular_json(path: &Path) -> Result<Value> {
    let info = fs::symlink_metadata(path)
        .with_context(|| format!("Файл не найден: {}", path.display()))?;
    ensure!(info.is_file() && !info.file_type().is_symlink(), "Ожидался обычный JSON-файл: {}", path.display());
    let file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path)?;
    serde_json::from_reader(BufReader::new(file))
        .with_context(|| format!("Не удалось прочитать JSON: {}", path.display()))
}

/// Bounded ordinary-file read for client projections. Read through O_NOFOLLOW
/// and enforce the limit again on the held descriptor; never accept a prefix.
pub(crate) fn regular_json_limited(path: &Path, limit: u64) -> Result<Value> {
    let info = fs::symlink_metadata(path)?;
    ensure!(info.is_file() && !info.file_type().is_symlink() && info.len() <= limit, "Некорректный или слишком большой файл библиотеки");
    let file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path)?;
    let metadata = file.metadata()?;
    ensure!(metadata.is_file() && metadata.len() <= limit, "Файл библиотеки слишком большой");
    let mut bytes = Vec::new();
    file.take(limit.saturating_add(1)).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 <= limit, "Файл библиотеки слишком большой");
    serde_json::from_slice(&bytes).context("Не удалось прочитать файл библиотеки")
}

/// Write a complete private file, fsync it, then replace the destination atomically.
/// A failed write preserves the previously committed JSON.
pub fn atomic_json<T: Serialize + ?Sized>(path: &Path, value: &T) -> Result<()> {
    let parent = path.parent().context("У JSON-файла нет родительской папки")?;
    private_directory(parent)?;
    let temporary = parent.join(format!(".posle-{}.tmp", Uuid::new_v4()));
    let result = (|| -> Result<()> {
        let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
        serde_json::to_writer_pretty(&mut file, value)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        // Some file systems do not implement directory fsync. The file itself
        // has already been synced and atomically committed in that case.
        if let Ok(directory) = File::open(parent) { let _ = directory.sync_all(); }
        Ok(())
    })();
    if result.is_err() { let _ = fs::remove_file(&temporary); }
    result.with_context(|| format!("Не удалось сохранить {}", path.display()))
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128
        && id.bytes().all(|character| character.is_ascii_alphanumeric() || character == b'-' || character == b'_')
}

/// Resolve only an immediate meeting directory; paths and symlink escapes fail.
pub fn meeting_directory(root: &Path, id: &str) -> Result<PathBuf> {
    ensure!(valid_id(id), "Некорректный идентификатор встречи");
    private_directory(root)?;
    let library = root.join("meetings");
    private_directory(&library)?;
    let directory = library.join(id);
    if directory.exists() || fs::symlink_metadata(&directory).is_ok() {
        let info = fs::symlink_metadata(&directory)?;
        ensure!(info.is_dir() && !info.file_type().is_symlink(), "Папка встречи не должна быть символической ссылкой");
    }
    Ok(directory)
}

fn compatible_meta(mut meta: Value, folder_id: &str) -> Result<Value> {
    let object = meta.as_object_mut().context("Метаданные должны быть объектом")?;
    ensure!(object.get("id").and_then(Value::as_str) == Some(folder_id), "Идентификатор встречи не совпадает с папкой");
    ensure!(object.get("title").and_then(Value::as_str).is_some(), "Нет названия встречи");
    ensure!(object.get("createdAt").and_then(Value::as_f64).is_some(), "Нет даты встречи");
    let source = object.get("source").and_then(Value::as_str).context("Нет исходной записи")?;
    ensure!(!source.is_empty() && Path::new(source).file_name().and_then(|name| name.to_str()) == Some(source), "Некорректный путь к исходной записи");
    for (key, default) in [
        ("status", json!("imported")), ("duration", json!(0)),
        ("speakerNames", json!({})), ("completedTasks", json!([])),
        ("focus", json!("")), ("recordingTracks", json!(false)), ("hasVideo", json!(false)),
    ] { object.entry(key).or_insert(default); }
    let known_fields = object.iter().filter(|(key, _)| MUTABLE_META_FIELDS.contains(&key.as_str()))
        .map(|(key, value)| (key.clone(), value.clone())).collect();
    validate_patch(&known_fields)?;
    Ok(meta)
}

/// Ignore an individual damaged entry without making the entire library unusable.
pub fn list_meetings(root: &Path) -> Result<Vec<Value>> {
    private_directory(root)?;
    let library = root.join("meetings");
    private_directory(&library)?;
    let mut result = Vec::new();
    for entry in fs::read_dir(library)? {
        let Ok(entry) = entry else { continue };
        let Some(id) = entry.file_name().to_str().map(str::to_owned) else { continue };
        if !valid_id(&id) { continue; }
        let Ok(kind) = entry.file_type() else { continue };
        if !kind.is_dir() || kind.is_symlink() { continue; }
        if let Ok(meta) = regular_json_limited(&entry.path().join("meta.json"), 1_048_576).and_then(|meta| compatible_meta(meta, &id)) {
            result.push(meta);
        }
    }
    result.sort_by(|left, right| {
        right["createdAt"].as_f64().unwrap_or_default()
            .total_cmp(&left["createdAt"].as_f64().unwrap_or_default())
    });
    Ok(result)
}

/// Copy through an already opened ordinary file. Metadata is committed only
/// after the complete private source has been flushed to disk.
pub fn import_meeting(root: &Path, source: &Path, focus: &str) -> Result<Value> {
    let source = source.canonicalize().context("Не удалось открыть исходную запись")?;
    let extension = source.extension().and_then(|value| value.to_str()).unwrap_or("").to_ascii_lowercase();
    ensure!(ALLOWED_EXTENSIONS.contains(&extension.as_str()), "Добавьте поддерживаемый аудио- или видеофайл");
    let mut input = File::open(&source)?;
    ensure!(input.metadata()?.is_file(), "Исходная запись должна быть обычным файлом");
    let id = Uuid::new_v4().to_string();
    let directory = meeting_directory(root, &id)?;
    // Refuse an existing destination, even in the unlikely event of an ID
    // collision; cleanup below must only remove a directory this import owns.
    DirBuilder::new().mode(0o700).create(&directory)?;
    let result = (|| -> Result<Value> {
        let filename = format!("source.{extension}");
        let mut output = OpenOptions::new().write(true).create_new(true).mode(0o600).open(directory.join(&filename))?;
        std::io::copy(&mut input, &mut output)?;
        output.sync_all()?;
        let title = source.file_stem().and_then(|value| value.to_str()).unwrap_or("Встреча");
        let meta = json!({
            "id": id, "title": title, "createdAt": Utc::now().timestamp_millis() as f64 / 1000.0,
            "source": filename, "status": "imported", "duration": 0,
            "speakerNames": {}, "completedTasks": [], "focus": focus,
            "recordingTracks": false, "hasVideo": false
        });
        atomic_json(&directory.join("meta.json"), &meta)?;
        Ok(meta)
    })();
    if result.is_err() { let _ = fs::remove_dir_all(&directory); }
    result
}

/// File locks serialize all read/modify/write operations across worker processes.
/// Requires Rust 1.89+ (the standard-library file locking API).
pub(crate) fn meeting_lock(directory: &Path) -> Result<File> {
    let path = directory.join(".posle-storage.lock");
    if let Ok(info) = fs::symlink_metadata(&path) {
        ensure!(info.is_file() && !info.file_type().is_symlink(), "Некорректный файл блокировки");
    }
    let file = OpenOptions::new().read(true).write(true).create(true).truncate(false)
        .mode(0o600).custom_flags(libc::O_NOFOLLOW).open(path)?;
    file.lock().context("Не удалось заблокировать данные встречи")?;
    Ok(file)
}

fn validate_patch(patch: &Map<String, Value>) -> Result<()> {
    for (key, value) in patch {
        let valid = match key.as_str() {
            "title" => value.as_str().is_some_and(|text| !text.trim().is_empty()),
            "focus" => value.is_string(),
            "meetingPurpose" => value.is_null() || value.as_str().is_some_and(|text| text.chars().count() <= 300),
            "generateCards" => value.is_null() || value.is_boolean(),
            "status" => value.as_str().is_some_and(|status| ["imported", "recording", "processing", "transcribed", "ready"].contains(&status)),
            "duration" => value.as_f64().is_some_and(|duration| duration.is_finite() && duration >= 0.0),
            "speakerNames" => value.as_object().is_some_and(|names| names.values().all(Value::is_string)),
            "completedTasks" => value.as_array().is_some_and(|tasks| tasks.iter().all(Value::is_string)),
            "recordingTracks" | "hasVideo" => value.is_boolean(),
            "error" => value.is_null() || value.is_string(),
            _ => bail!("Поле метаданных нельзя изменять: {key}"),
        };
        ensure!(valid, "Некорректное значение поля метаданных: {key}");
    }
    Ok(())
}

/// Patch only user-editable/state fields, preserving unknown metadata fields.
pub fn update_meta(root: &Path, id: &str, patch: &Value) -> Result<Value> {
    let patch = patch.as_object().context("Обновление метаданных должно быть объектом")?;
    validate_patch(patch)?;
    let directory = meeting_directory(root, id)?;
    let _lock = meeting_lock(&directory)?;
    let mut meta = compatible_meta(regular_json(&directory.join("meta.json"))?, id)?;
    let object = meta.as_object_mut().unwrap();
    object.extend(patch.iter().map(|(key, value)| (key.clone(), value.clone())));
    atomic_json(&directory.join("meta.json"), &meta)?;
    Ok(meta)
}

/// Rename only the title the editor opened, under the shared meeting lock.
/// Other metadata, including worker updates and unknown fields, stays intact.
pub fn rename_meeting(root: &Path, id: &str, title: &str, expected_title: &str) -> Result<Value> {
    let title = title.trim();
    ensure!(!title.is_empty(), "Введите название встречи.");
    ensure!(title.chars().count() <= 500, "Название слишком длинное. Максимум — 500 символов.");
    ensure!(!title.chars().any(char::is_control), "Название должно быть в одну строку.");
    let directory = meeting_directory(root, id)?;
    let _lock = meeting_lock(&directory)?;
    let mut meta = compatible_meta(regular_json(&directory.join("meta.json"))?, id)?;
    ensure!(meta["title"].as_str() == Some(expected_title),
        "Название изменено в другом окне. Ваш вариант остался в поле.");
    meta["title"] = json!(title);
    atomic_json(&directory.join("meta.json"), &meta)?;
    Ok(meta)
}

/// Save only a user's overview edit against the summary they actually opened.
/// The meeting lock covers the comparison and commit, never model inference.
pub fn save_summary_overview(root: &Path, id: &str, text: &str, expected_overview: &str, expected_generated_at: f64) -> Result<Value> {
    let text = text.trim();
    ensure!(!text.is_empty(), "Краткий конспект не должен быть пустым.");
    ensure!(expected_generated_at.is_finite(), "Некорректная дата исходного конспекта.");
    const MAX_SUMMARY: u64 = 8 * 1_048_576;
    ensure!(text.len() as u64 <= MAX_SUMMARY, "Краткий конспект слишком большой.");
    let directory = meeting_directory(root, id)?;
    let _lock = meeting_lock(&directory)?;
    let path = directory.join("summary.json");
    let info = fs::symlink_metadata(&path).context("Конспект недоступен. Откройте его заново.")?;
    ensure!(info.is_file() && !info.file_type().is_symlink() && info.len() <= MAX_SUMMARY, "Некорректный файл конспекта.");
    let mut file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(&path)?;
    let mut bytes = Vec::new(); Read::by_ref(&mut file).take(MAX_SUMMARY + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 <= MAX_SUMMARY, "Файл конспекта слишком большой.");
    let mut summary: Value = serde_json::from_slice(&bytes).context("Не удалось прочитать конспект. Исходный файл сохранён.")?;
    let object = summary.as_object_mut().context("Конспект должен содержать объект.")?;
    ensure!(object.get("overview").and_then(Value::as_str) == Some(expected_overview)
        && object.get("generatedAt").and_then(Value::as_f64) == Some(expected_generated_at),
        "Конспект изменился. Откройте правку заново, чтобы сохранить актуальную версию.");
    object.insert("overview".into(), json!(text));
    object.insert("overviewClaims".into(), json!([]));
    object.insert("manuallyEdited".into(), json!(true));
    object.insert("overviewManuallyEdited".into(), json!(true));
    object.insert("overviewStale".into(), json!(false));
    ensure!(serde_json::to_vec(&summary)?.len() as u64 <= MAX_SUMMARY, "Файл конспекта слишком большой.");
    atomic_json(&path, &summary)?;
    Ok(summary)
}

fn parse_time(value: &Value, field: &str) -> Result<DateTime<Utc>> {
    let text = value.as_str().with_context(|| format!("Нет даты {field} в истории карточки"))?;
    DateTime::parse_from_rfc3339(text).map(|date| date.with_timezone(&Utc))
        .with_context(|| format!("Некорректная дата {field} в истории карточки"))
}

pub(crate) fn schedule(previous: Option<&Value>, rating: u8, now: DateTime<Utc>) -> Result<(Value, Value)> {
    ensure!((1..=4).contains(&rating), "Оценка карточки должна быть от 1 до 4");
    let previous_card = previous.map(|state| state.get("card").context("В истории карточки нет состояния FSRS")).transpose()?;
    let memory = match previous_card {
        Some(card) => {
            let stability = card["stability"].as_f64().context("В истории карточки нет stability")? as f32;
            let difficulty = card["difficulty"].as_f64().context("В истории карточки нет difficulty")? as f32;
            ensure!(stability.is_finite() && stability > 0.0 && difficulty.is_finite() && (1.0..=10.0).contains(&difficulty), "Повреждено состояние FSRS карточки");
            Some(MemoryState { stability, difficulty })
        }
        None => None,
    };
    let elapsed_days = if let Some(card) = previous_card {
        now.signed_duration_since(parse_time(&card["last_review"], "last_review")?).num_days().clamp(0, u32::MAX as i64) as u32
    } else { 0 };
    let next = FSRS::default().next_states(memory, RETENTION, elapsed_days)?;
    let next = match rating { 1 => next.again, 2 => next.hard, 3 => next.good, 4 => next.easy, _ => unreachable!() };
    let old_state = previous_card.and_then(|card| card["state"].as_u64()).unwrap_or(1);
    ensure!((1..=3).contains(&old_state), "Некорректное состояние обучения карточки");
    let old_step = previous_card.and_then(|card| card["step"].as_u64()).unwrap_or(0);
    let review_interval = Duration::days(next.interval.round().clamp(1.0, 36500.0) as i64);
    // Standard 1m/10m learning and 10m relearning steps, compatible with the
    // previous Python scheduler. Mathematical memory updates remain in fsrs-rs.
    let (state, step, interval) = match (old_state, rating) {
        (1, 1) => (1, Some(0), Duration::minutes(1)),
        (1, 2) if old_step == 0 => (1, Some(0), Duration::seconds(330)),
        (1, 2) if old_step == 1 => (1, Some(1), Duration::minutes(10)),
        (1, 3) if old_step == 0 => (1, Some(1), Duration::minutes(10)),
        (2, 1) | (3, 1) => (3, Some(0), Duration::minutes(10)),
        (3, 2) if old_step == 0 => (3, Some(0), Duration::minutes(15)),
        _ => (2, None, review_interval),
    };
    let date = now.to_rfc3339_opts(SecondsFormat::Millis, true);
    let due = (now + interval).to_rfc3339_opts(SecondsFormat::Millis, true);
    let card_id = previous_card.and_then(|card| card.get("card_id")).cloned()
        .unwrap_or_else(|| json!((Uuid::new_v4().as_u128() as u64) & i64::MAX as u64));
    let count = previous.map(|state| state["count"].as_u64().context("Нет счётчика повторений")).transpose()?.unwrap_or(0)
        .checked_add(1).context("Слишком большой счётчик повторений")?;
    let value = json!({
        "card": {"card_id": card_id, "state": state, "step": step,
                 "stability": next.memory.stability, "difficulty": next.memory.difficulty,
                 "due": due, "last_review": date},
        "due": due, "count": count, "lastRating": rating,
        "scheduler": SCHEDULER, "desiredRetention": RETENTION
    });
    let log = json!({"card_id": card_id, "rating": rating, "review_datetime": date, "review_duration": null});
    Ok((value, log))
}

/// Complete an interrupted two-file review transaction idempotently. The journal
/// is written before either durable output and removed after both are committed.
pub(crate) fn recover_review(directory: &Path) -> Result<()> {
    let path = directory.join("review-pending.json");
    if !path.exists() { return Ok(()); }
    let pending = regular_json(&path)?;
    let review_id = pending["entry"]["reviewID"].as_str().context("Повреждён журнал повторения")?;
    ensure!(pending["states"].is_object(), "Повреждено состояние журнала повторения");
    let log_path = directory.join("review-log.jsonl");
    let mut present = false;
    if log_path.exists() {
        let info = fs::symlink_metadata(&log_path)?;
        ensure!(info.is_file() && !info.file_type().is_symlink(), "Некорректный журнал повторений");
        let log = OpenOptions::new().read(true).write(true).custom_flags(libc::O_NOFOLLOW).open(&log_path)?;
        let mut reader = BufReader::new(log);
        let mut offset = 0;
        let mut line = Vec::new();
        loop {
            line.clear();
            if reader.read_until(b'\n', &mut line)? == 0 { break; }
            if let Ok(entry) = serde_json::from_slice::<Value>(&line) {
                if entry["reviewID"].as_str() == Some(review_id) { present = true; }
            } else if line.last() != Some(&b'\n') {
                // Only an uncommitted partial tail can be discarded. Keep all
                // previously completed entries, including legacy Python logs.
                reader.get_ref().set_len(offset)?;
                reader.get_ref().sync_all()?;
                break;
            }
            offset += line.len() as u64;
        }
    }
    if !present {
        let mut file = OpenOptions::new().read(true).create(true).append(true)
            .mode(0o600).custom_flags(libc::O_NOFOLLOW).open(&log_path)?;
        // Keep ordinary JSONL free from blank lines, while isolating a partial
        // final line if the previous process died during an append.
        if file.metadata()?.len() > 0 {
            file.seek(SeekFrom::End(-1))?;
            let mut last = [0];
            file.read_exact(&mut last)?;
            if last[0] != b'\n' { file.write_all(b"\n")?; }
        }
        serde_json::to_writer(&mut file, &pending["entry"])?;
        file.write_all(b"\n")?;
        file.sync_all()?;
    }
    atomic_json(&directory.join("review-state.json"), &pending["states"])?;
    if let Some(undo) = pending.get("undo") {
        atomic_json(&directory.join("cards-review-undo.json"), undo)?;
    }
    // The transaction is committed. A failed journal cleanup must not report a
    // failed rating and invite the user to accidentally submit it twice.
    let _ = fs::remove_file(path);
    Ok(())
}

/// Rate an existing summary card with Again=1, Hard=2, Good=3, Easy=4.
/// Old Python FSRS memory/step fields migrate in place without resetting history.
pub fn review(root: &Path, id: &str, card_id: &str, rating: u8) -> Result<Value> {
    review_at(root, id, card_id, rating, Utc::now())
}

fn review_at(root: &Path, id: &str, card_id: &str, rating: u8, now: DateTime<Utc>) -> Result<Value> {
    ensure!((1..=4).contains(&rating), "Оценка карточки должна быть от 1 до 4");
    let directory = meeting_directory(root, id)?;
    let _lock = meeting_lock(&directory)?;
    recover_review(&directory)?;
    let summary = regular_json(&directory.join("summary.json"))?;
    ensure!(summary["cards"].as_array().is_some_and(|cards| cards.iter().any(|card| card["id"].as_str() == Some(card_id))), "Карточка не найдена");
    let state_path = directory.join("review-state.json");
    let mut states = if state_path.exists() { regular_json(&state_path)? } else { json!({}) };
    let object = states.as_object_mut().context("История повторений должна быть объектом")?;
    let (state, log) = schedule(object.get(card_id), rating, now)?;
    object.insert(card_id.to_owned(), state.clone());
    let pending = json!({"states": states, "entry": {"cardID": card_id,
        "reviewID": Uuid::new_v4().to_string(), "scheduler": SCHEDULER, "review": log}});
    atomic_json(&directory.join("review-pending.json"), &pending)?;
    recover_review(&directory)?;
    Ok(state)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    struct TestDirectory(PathBuf);
    impl TestDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("posle-storage-test-{}", Uuid::new_v4()));
            private_directory(&path).unwrap();
            Self(path)
        }
        fn meeting(&self) -> Value {
            let source = self.0.join("Встреча.mp3");
            fs::write(&source, b"test source").unwrap();
            import_meeting(&self.0.join("data"), &source, "Сроки и решения").unwrap()
        }
    }
    impl Drop for TestDirectory { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }

    #[test]
    fn import_is_private_and_metadata_is_swift_compatible() {
        let temp = TestDirectory::new();
        let meta = temp.meeting();
        let root = temp.0.join("data");
        let directory = meeting_directory(&root, meta["id"].as_str().unwrap()).unwrap();
        assert_eq!(fs::read(directory.join("source.mp3")).unwrap(), b"test source");
        assert_eq!(fs::metadata(directory.join("source.mp3")).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(fs::metadata(directory.join("meta.json")).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(meta["title"], "Встреча");
        assert_eq!(list_meetings(&root).unwrap(), vec![meta]);
    }

    #[test]
    fn traversal_and_symlink_meetings_are_rejected() {
        let temp = TestDirectory::new();
        assert!(meeting_directory(&temp.0, "../elsewhere").is_err());
        assert!(meeting_directory(&temp.0, "a/b").is_err());
        let external = temp.0.join("external");
        private_directory(&external).unwrap();
        private_directory(&temp.0.join("meetings")).unwrap();
        symlink(&external, temp.0.join("meetings/linked")).unwrap();
        assert!(meeting_directory(&temp.0, "linked").is_err());
    }

    #[test]
    fn atomic_json_replaces_content_and_cleans_temporary_file() {
        let temp = TestDirectory::new();
        let path = temp.0.join("state.json");
        atomic_json(&path, &json!({"old": true})).unwrap();
        atomic_json(&path, &json!({"new": [1, 2, 3]})).unwrap();
        assert_eq!(regular_json(&path).unwrap(), json!({"new": [1, 2, 3]}));
        assert_eq!(fs::read_dir(&temp.0).unwrap().count(), 1);
    }

    #[test]
    fn metadata_patch_cannot_replace_identity_or_source() {
        let temp = TestDirectory::new();
        let mut meta = temp.meeting();
        let root = temp.0.join("data");
        let id = meta["id"].as_str().unwrap().to_owned();
        let directory = meeting_directory(&root, &id).unwrap();
        meta["futureMetadata"] = json!({"preserve": true});
        atomic_json(&directory.join("meta.json"), &meta).unwrap();
        assert!(update_meta(&root, &id, &json!({"source": "../../private", "title": "Changed"})).is_err());
        assert!(update_meta(&root, &id, &json!({"id": "changed"})).is_err());
        assert!(update_meta(&root, &id, &json!({"createdAt": 0})).is_err());
        let changed = update_meta(&root, &id, &json!({"speakerNames": {"speaker_0": "Мария"}, "error": null})).unwrap();
        assert_eq!(changed["title"], meta["title"]);
        assert_eq!(changed["speakerNames"]["speaker_0"], "Мария");
        assert_eq!(changed["futureMetadata"], json!({"preserve": true}));
    }

    #[test]
    fn meeting_rename_is_trimmed_and_preserves_latest_worker_fields() {
        let temp = TestDirectory::new(); let meta = temp.meeting(); let root = temp.0.join("data");
        let id = meta["id"].as_str().unwrap();
        let old_title = meta["title"].as_str().unwrap();
        let directory = meeting_directory(&root, id).unwrap();
        let mut worker = meta.clone(); worker["duration"] = json!(72.5);
        worker["status"] = json!("ready"); worker["futureField"] = json!({"keep":true});
        atomic_json(&directory.join("meta.json"), &worker).unwrap();
        let renamed = rename_meeting(&root, id, "  Английский — урок 2  ", old_title).unwrap();
        assert_eq!(renamed["title"], "Английский — урок 2");
        worker["title"] = json!("Английский — урок 2"); assert_eq!(renamed, worker);
        assert_eq!(regular_json(&directory.join("meta.json")).unwrap(), worker);
        let stale = rename_meeting(&root, id, "My stale name", old_title);
        assert!(stale.is_err()); assert_eq!(regular_json(&directory.join("meta.json")).unwrap(), worker);
        for invalid in [" ".to_owned(), "line\nbreak".to_owned(), "x".repeat(501)] {
            assert!(rename_meeting(&root, id, &invalid, "Английский — урок 2").is_err());
            assert_eq!(regular_json(&directory.join("meta.json")).unwrap(), worker);
        }
    }

    #[test]
    fn meeting_rename_rechecks_title_after_waiting_for_shared_lock() {
        let temp = TestDirectory::new(); let meta = temp.meeting(); let root = temp.0.join("data");
        let id = meta["id"].as_str().unwrap().to_owned(); let expected = meta["title"].as_str().unwrap().to_owned();
        let directory = meeting_directory(&root, &id).unwrap(); let lock = meeting_lock(&directory).unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::channel(); let (tx, rx) = std::sync::mpsc::channel();
        let thread = std::thread::spawn(move || {
            started_tx.send(()).unwrap(); tx.send(rename_meeting(&root, &id, "Stale editor", &expected)).unwrap();
        });
        started_rx.recv().unwrap();
        let early = rx.recv_timeout(std::time::Duration::from_millis(250));
        let waited = matches!(early, Err(std::sync::mpsc::RecvTimeoutError::Timeout));
        let mut latest = meta; latest["title"] = json!("Other editor"); latest["duration"] = json!(45);
        atomic_json(&directory.join("meta.json"), &latest).unwrap(); drop(lock);
        let result = match early { Ok(value) => value, Err(_) => rx.recv_timeout(std::time::Duration::from_secs(3)).unwrap() };
        thread.join().unwrap(); assert!(waited); assert!(result.is_err());
        assert_eq!(regular_json(&directory.join("meta.json")).unwrap(), latest);
    }

    #[test]
    fn meeting_purpose_is_an_optional_user_editable_metadata_field() {
        let temp = TestDirectory::new(); let meta = temp.meeting(); let root = temp.0.join("data");
        let id = meta["id"].as_str().unwrap();
        let purpose = "Синк с руководителем о прогрессе и следующих шагах";
        let updated = update_meta(&root, id, &json!({"meetingPurpose":purpose})).unwrap();
        assert_eq!(updated["meetingPurpose"],purpose);
        assert_eq!(list_meetings(&root).unwrap()[0]["meetingPurpose"],purpose);
        assert!(update_meta(&root,id,&json!({"meetingPurpose":12})).is_err());
        assert!(update_meta(&root,id,&json!({"meetingPurpose":"x".repeat(301)})).is_err());
        assert_eq!(update_meta(&root,id,&json!({"meetingPurpose":null})).unwrap()["meetingPurpose"],Value::Null);
    }

    #[test]
    fn card_generation_is_optional_user_metadata_and_never_inferred_from_existing_cards() {
        let temp=TestDirectory::new(); let meta=temp.meeting(); let root=temp.0.join("data");
        let id=meta["id"].as_str().unwrap();
        assert!(list_meetings(&root).unwrap()[0]["generateCards"].is_null());
        for flag in [json!(true),json!(false),Value::Null] {
            let updated=update_meta(&root,id,&json!({"generateCards":flag})).unwrap();
            assert_eq!(updated["generateCards"],flag);
            assert_eq!(list_meetings(&root).unwrap()[0]["generateCards"],flag);
            assert_eq!(updated["source"],meta["source"]);
        }
        assert!(update_meta(&root,id,&json!({"generateCards":"true"})).is_err());
        assert!(update_meta(&root,id,&json!({"generateCards":1})).is_err());
    }
    #[test]
    fn overview_cas_preserves_cards_evidence_unknown_fields_and_review_history() {
        let temp = TestDirectory::new(); let meta = temp.meeting(); let root = temp.0.join("data");
        let id = meta["id"].as_str().unwrap(); let directory = meeting_directory(&root, id).unwrap();
        let original = json!({"overview":"Исходный конспект", "generatedAt":1234.5,
            "overviewClaims":[{"text":"Исходный конспект","segmentIDs":[0]}],
            "items":[{"kind":"action","text":"Проверить договор","segmentIDs":[0]}],
            "cards":[{"id":"card-1","front":"Check the contract"}], "futureSummary":{"keep":[1,2,3]}});
        atomic_json(&directory.join("summary.json"), &original).unwrap();
        let review = b"review history must remain unchanged";
        fs::write(directory.join("review-state.json"), review).unwrap();
        let result = save_summary_overview(&root, id, "  Моя правка.  ", "Исходный конспект", 1234.5).unwrap();
        assert_eq!(result["overview"], "Моя правка."); assert_eq!(result["overviewClaims"], json!([]));
        for field in ["generatedAt", "items", "cards", "futureSummary"] { assert_eq!(result[field], original[field]); }
        assert_eq!(regular_json(&directory.join("summary.json")).unwrap(), result);
        assert_eq!(fs::read(directory.join("review-state.json")).unwrap(), review);
        let committed = fs::read(directory.join("summary.json")).unwrap();
        for (text, overview, generated_at) in [("Новая", "Исходный конспект", 1234.5), ("Новая", "Моя правка.", 1235.0),
            (" \n\t", "Моя правка.", 1234.5), ("Новая", "Моя правка.", f64::NAN), ("Новая", "Моя правка.", f64::INFINITY)] {
            assert!(save_summary_overview(&root, id, text, overview, generated_at).is_err());
            assert_eq!(fs::read(directory.join("summary.json")).unwrap(), committed);
        }
    }

    #[test]
    fn overview_cas_allows_one_concurrent_editor_and_preserves_the_winner() {
        let temp = TestDirectory::new(); let meta = temp.meeting(); let root = temp.0.join("data");
        let id = meta["id"].as_str().unwrap().to_owned(); let directory = meeting_directory(&root, &id).unwrap();
        atomic_json(&directory.join("summary.json"), &json!({"overview":"Общий оригинал","generatedAt":1,"cards":[{"id":"keep"}]})).unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2)); let mut threads = Vec::new();
        for text in ["Правка первая", "Правка вторая"] {
            let root = root.clone(); let id = id.clone(); let barrier = barrier.clone();
            threads.push(std::thread::spawn(move || { barrier.wait(); save_summary_overview(&root, &id, text, "Общий оригинал", 1.0) }));
        }
        let results = threads.into_iter().map(|thread| thread.join().unwrap()).collect::<Vec<_>>();
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        let winner = results.into_iter().find_map(Result::ok).unwrap();
        assert_eq!(regular_json(&directory.join("summary.json")).unwrap(), winner);
        assert_eq!(winner["cards"], json!([{"id":"keep"}]));
    }

    #[test]
    fn overview_cas_waits_for_summary_generation_then_rechecks_the_latest_source() {
        let temp = TestDirectory::new(); let meta = temp.meeting(); let root = temp.0.join("data");
        let id = meta["id"].as_str().unwrap().to_owned(); let directory = meeting_directory(&root, &id).unwrap();
        atomic_json(&directory.join("summary.json"), &json!({"overview":"Конспект","generatedAt":1})).unwrap();
        let lock = meeting_lock(&directory).unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::channel(); let (tx, rx) = std::sync::mpsc::channel();
        let thread = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            tx.send(save_summary_overview(&root, &id, "Старая правка", "Конспект", 1.0)).unwrap();
        });
        started_rx.recv().unwrap();
        let early = rx.recv_timeout(std::time::Duration::from_millis(250));
        let waited = matches!(early, Err(std::sync::mpsc::RecvTimeoutError::Timeout));
        let regenerated = json!({"overview":"Конспект","generatedAt":2,"cards":[{"id":"new"}],"futureField":true});
        atomic_json(&directory.join("summary.json"), &regenerated).unwrap(); drop(lock);
        let result = match early { Ok(value) => value, Err(_) => rx.recv_timeout(std::time::Duration::from_secs(3)).unwrap() };
        thread.join().unwrap();
        assert!(waited); assert!(result.is_err());
        assert_eq!(regular_json(&directory.join("summary.json")).unwrap(), regenerated);
    }

    #[test]
    fn one_corrupt_entry_does_not_break_library_listing() {
        let temp = TestDirectory::new();
        let valid = temp.meeting();
        let root = temp.0.join("data");
        let directory = meeting_directory(&root, "corrupt").unwrap();
        let mut corrupt = valid.clone();
        corrupt["id"] = json!("corrupt");
        corrupt["duration"] = json!("not a number");
        atomic_json(&directory.join("meta.json"), &corrupt).unwrap();
        assert_eq!(list_meetings(&root).unwrap(), vec![valid]);
    }

    #[test]
    fn all_ratings_use_official_fsrs_memory_and_learning_steps() {
        let now = DateTime::parse_from_rfc3339("2026-10-25T12:00:00Z").unwrap().with_timezone(&Utc);
        let expected = FSRS::default().next_states(None, RETENTION, 0).unwrap();
        for (rating, memory, seconds) in [
            (1, expected.again.memory, 60), (2, expected.hard.memory, 330),
            (3, expected.good.memory, 600), (4, expected.easy.memory, 8 * 86400),
        ] {
            let (state, _) = schedule(None, rating, now).unwrap();
            assert!((state["card"]["stability"].as_f64().unwrap() - memory.stability as f64).abs() < 1e-5);
            assert!((state["card"]["difficulty"].as_f64().unwrap() - memory.difficulty as f64).abs() < 1e-5);
            assert_eq!((parse_time(&state["due"], "due").unwrap() - now).num_seconds(), seconds);
            assert_eq!(state["count"], 1);
            assert_eq!(state["lastRating"], rating);
        }
        assert!(schedule(None, 0, now).is_err());
        assert!(schedule(None, 5, now).is_err());
    }

    #[test]
    fn python_card_state_migrates_without_resetting_memory_or_count() {
        let now = DateTime::parse_from_rfc3339("2026-10-25T12:00:00Z").unwrap().with_timezone(&Utc);
        let previous = json!({"card": {"card_id": 123, "state": 2, "step": null,
            "stability": 7.0, "difficulty": 5.0, "due": "2026-10-25T12:00:00+00:00",
            "last_review": "2026-10-18T12:00:00+00:00"}, "due": "2026-10-25T12:00:00+00:00", "count": 6, "lastRating": 3});
        let expected = FSRS::default().next_states(Some(MemoryState { stability: 7.0, difficulty: 5.0 }), RETENTION, 7).unwrap();
        let (state, _) = schedule(Some(&previous), 3, now).unwrap();
        assert_eq!(state["count"], 7);
        assert_eq!(state["card"]["card_id"], 123);
        assert!((state["card"]["stability"].as_f64().unwrap() - expected.good.memory.stability as f64).abs() < 1e-5);
        assert_eq!(state["card"]["state"], 2);
        assert!(state["card"]["step"].is_null());
        assert!(parse_time(&state["due"], "due").unwrap() > now + Duration::days(1));
    }

    #[test]
    fn reviews_are_durable_and_missing_cards_cannot_create_history() {
        let temp = TestDirectory::new();
        let meta = temp.meeting();
        let root = temp.0.join("data");
        let id = meta["id"].as_str().unwrap();
        let directory = meeting_directory(&root, id).unwrap();
        atomic_json(&directory.join("summary.json"), &json!({"cards": [{"id": "phrase-1"}]})).unwrap();
        assert!(review(&root, id, "missing", 3).is_err());
        assert!(!directory.join("review-state.json").exists());
        let first = review(&root, id, "phrase-1", 1).unwrap();
        let second = review(&root, id, "phrase-1", 3).unwrap();
        assert_eq!(first["count"], 1);
        assert_eq!(second["count"], 2);
        assert_eq!(regular_json(&directory.join("review-state.json")).unwrap()["phrase-1"], second);
        let logs = fs::read_to_string(directory.join("review-log.jsonl")).unwrap();
        assert_eq!(logs.lines().filter(|line| !line.is_empty()).count(), 2);
        assert!(!directory.join("review-pending.json").exists());
    }

    #[test]
    fn interrupted_review_journal_recovers_once() {
        let temp = TestDirectory::new();
        let directory = temp.0.join("meeting");
        private_directory(&directory).unwrap();
        let pending = json!({"states": {"card-1": {"count": 1}},
            "entry": {"cardID": "card-1", "reviewID": "transaction-1", "review": {"rating": 3}}});
        atomic_json(&directory.join("review-pending.json"), &pending).unwrap();
        fs::write(directory.join("review-log.jsonl"), b"{\"reviewID\":\"transaction-1\"").unwrap();
        recover_review(&directory).unwrap();
        // Simulate an interruption after outputs committed but before unlink.
        atomic_json(&directory.join("review-pending.json"), &pending).unwrap();
        recover_review(&directory).unwrap();
        let logs = fs::read_to_string(directory.join("review-log.jsonl")).unwrap();
        assert_eq!(logs.lines().filter(|line| !line.is_empty()).count(), 1);
        assert!(logs.lines().all(|line| serde_json::from_str::<Value>(line).is_ok()));
        assert_eq!(regular_json(&directory.join("review-state.json")).unwrap()["card-1"]["count"], 1);
    }
}
