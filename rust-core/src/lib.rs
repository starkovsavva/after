pub mod python_runtime;
pub mod ai;
pub mod chatgpt;
pub mod models;
pub mod storage;
pub mod notes;
pub mod workspace_repository;
pub mod cards;
pub mod voice;
pub mod task_workspace;
pub mod mcp;
pub mod search;
pub mod semantic;
pub mod code_index;
pub mod tracker_sync;
pub mod knowledge;
pub mod worker;
pub mod jobs;
pub mod corrections;

use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::{Component, Path, PathBuf};

/// Keep all UI persistence in Rust. Paths are relative to the application's
/// private data directory and restricted to known JSON files.
fn data_path(root: &Path, relative: &str) -> Result<PathBuf> {
    let relative = Path::new(relative);
    if relative.components().any(|p| !matches!(p, Component::Normal(_))) {
        bail!("Недопустимый путь библиотеки");
    }
    let allowed = ["settings.json", "overview-drafts.json", "voice-draft.json", "capture-drafts.json", "meta.json", "transcript.json", "summary.json", "examples.json", "review-state.json"];
    let name = relative.file_name().and_then(|s| s.to_str()).context("Нет имени файла")?;
    if !allowed.contains(&name) { bail!("Этот файл не относится к библиотеке"); }
    let components: Vec<_> = relative.components().collect();
    if ["settings.json", "overview-drafts.json", "voice-draft.json", "capture-drafts.json"].contains(&name) {
        if components.len() != 1 { bail!("Недопустимый путь настроек"); }
    } else {
        if components.len() != 3 || components[0].as_os_str() != "meetings" { bail!("Недопустимый путь встречи"); }
        storage::meeting_directory(root, components[1].as_os_str().to_str().context("Неверный ID")?)?;
    }
    Ok(root.join(relative))
}

pub fn request(value: &Value) -> Result<Value> {
    let root = PathBuf::from(value["root"].as_str().context("Нужна папка данных приложения")?);
    if !root.is_absolute() { bail!("Папка данных должна иметь абсолютный путь"); }
    match value["command"].as_str().context("Нет команды ядра")? {
        command if command.starts_with("tracker-") => tracker_sync::request(&root,command,value),
        command if command.starts_with("semantic-") => semantic::dispatch(&root,value),
        command if command.starts_with("code-index-") => code_index::dispatch(&root,value),
        command if ["notes-list", "note-save", "note-delete", "note-trash", "note-restore", "context-save", "template-save", "template-delete", "note-attach", "attachment-path", "attachment-remove", "attachment-text", "notes-search", "notes-tasks", "notes-task-complete", "notes-brief", "note-search-validate", "note-expansion-validate", "note-expansion-valid"].contains(&command) => notes::dispatch(&root, value),
        "voice-plan" | "voice-inspect" | "voice-choose" | "voice-apply" | "voice-undo" | "voice-recover" | "task-update" | "task-materialize" | "task-append" => voice::dispatch(&root, value),
        command if command.starts_with("task-") => task_workspace::dispatch(&root, value),
        "cards-import" | "cards-import-preview" | "cards-library" | "card-save" | "card-delete" | "card-suspend" | "cards-review" | "cards-review-preview" | "cards-review-undo" => cards::dispatch(&root,value),
        command if command.starts_with("job-") => jobs::dispatch(&root, value),
        "meeting-content-snapshot" | "transcript-segment-save" | "summary-item-save" => corrections::dispatch(&root, value),
        "list" => Ok(json!({"meetings": storage::list_meetings(&root)?})),
        "knowledge-search" => knowledge::lookup(&root, value),
        "knowledge-validate-source" => knowledge::validate_source(&root, value),
        "search-validate" => search::validate(&root, value["meetingID"].as_str().context("Нет ID встречи")?, value["sourceFingerprint"].as_str().unwrap_or("")),
        "search" => search::search(&root, value["query"].as_str().unwrap_or(""), value["scope"].as_str().unwrap_or("all"), value["limit"].as_u64().unwrap_or(60).min(100) as usize),
        "read" => {
            let path = data_path(&root, value["path"].as_str().context("Нет пути")?)?;
            if !path.exists() { return Ok(Value::Null); }
            let info = std::fs::symlink_metadata(&path)?;
            if !info.is_file() || info.file_type().is_symlink() { bail!("Ожидается обычный файл библиотеки"); }
            Ok(serde_json::from_slice(&std::fs::read(path)?)?)
        }
        "write" => {
            let path = data_path(&root, value["path"].as_str().context("Нет пути")?)?;
            let data = value.get("value").context("Нет данных")?;
            if path.file_name().and_then(|s| s.to_str()) == Some("settings.json") {
                if ["apiKey", "api_key", "key", "token"].iter().any(|k| data.get(k).is_some()) {
                    bail!("Секреты должны храниться в Связке ключей macOS");
                }
            }
            storage::atomic_json(&path, data)?;
            Ok(json!({"saved": true}))
        }
        "import" => storage::import_meeting(&root, Path::new(value["source"].as_str().context("Нет файла")?),
                                            value["focus"].as_str().unwrap_or("")),
        "summary-overview-save" => storage::save_summary_overview(&root,
            value["meetingID"].as_str().context("Нет ID встречи")?,
            value["text"].as_str().context("Нет текста конспекта")?,
            value["expectedOverview"].as_str().context("Нет исходного конспекта")?,
            value["expectedGeneratedAt"].as_f64().context("Нет даты исходного конспекта")?),
        "update" => storage::update_meta(&root, value["id"].as_str().context("Нет ID")?, value.get("patch").context("Нет изменений")?),
        _ => Err(anyhow!("Неизвестная команда ядра")),
    }
}

/// C ABI contains JSON only: Swift never shares Rust layout, pointers to models,
/// async runtimes or Rust-owned memory beyond this allocated response string.
#[no_mangle]
pub unsafe extern "C" fn posle_request(input: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| -> Result<Value> {
        if input.is_null() { bail!("Пустой запрос"); }
        let data = CStr::from_ptr(input).to_str().context("Ожидается UTF-8")?;
        request(&serde_json::from_str(data)?)
    });
    let envelope = match result {
        Ok(Ok(value)) => json!({"ok": true, "value": value}),
        Ok(Err(error)) => json!({"ok": false, "error": error.to_string()}),
        Err(_) => json!({"ok": false, "error": "Ядро не смогло обработать запрос. Данные сохранены."}),
    };
    CString::new(envelope.to_string()).expect("JSON escapes NUL").into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn posle_free_string(value: *mut c_char) {
    if !value.is_null() { drop(CString::from_raw(value)); }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn overview_drafts_are_private_root_files() {
        let directory = tempfile::tempdir().unwrap();
        let draft = json!({"meeting-1": {"text": "Моя правка", "original": "Конспект", "generatedAt": 1}});
        request(&json!({"root": directory.path(), "command": "write", "path": "overview-drafts.json", "value": draft})).unwrap();
        assert_eq!(request(&json!({"root": directory.path(), "command": "read", "path": "overview-drafts.json"})).unwrap(), draft);
        assert!(request(&json!({"root": directory.path(), "command": "write", "path": "meetings/meeting-1/overview-drafts.json", "value": draft})).is_err());
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(directory.path().join("overview-drafts.json")).unwrap().permissions().mode() & 0o777, 0o600);
    }

    #[test]
    fn overview_save_domain_request_returns_latest_summary_and_requires_cas_fields() {
        let directory = tempfile::tempdir().unwrap();
        let meeting = storage::meeting_directory(directory.path(), "synthetic").unwrap();
        let path = meeting.join("summary.json");
        storage::atomic_json(&path, &json!({"overview":"Old","generatedAt":1,"cards":[],"future":true})).unwrap();
        let mut input = json!({"root":directory.path(),"command":"summary-overview-save","meetingID":"synthetic",
            "text":"Edited", "expectedOverview":"Old", "expectedGeneratedAt":1});
        let result = request(&input).unwrap();
        assert_eq!(result, json!({"overview":"Edited","overviewClaims":[],"generatedAt":1,"cards":[],"future":true,"manuallyEdited":true,"overviewManuallyEdited":true,"overviewStale":false}));
        let committed = std::fs::read(&path).unwrap();
        input.as_object_mut().unwrap().remove("expectedGeneratedAt");
        assert!(request(&input).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), committed);
    }

    #[test]
    fn library_paths_cannot_escape_or_write_secrets() {
        let dir = tempfile::tempdir().unwrap();
        for path in ["../outside.json", "/tmp/meta.json", "meetings/../meta.json", "arbitrary.json"] {
            assert!(data_path(dir.path(), path).is_err());
        }
        let request = json!({"root":dir.path(),"command":"write","path":"settings.json","value":{"apiKey":"secret"}});
        assert!(super::request(&request).is_err());
        assert!(!dir.path().join("settings.json").exists());
    }
    #[test]
    fn ffi_round_trip_and_free() {
        let directory = tempfile::tempdir().unwrap();
        let input = CString::new(json!({"root":directory.path(),"command":"read","path":"settings.json"}).to_string()).unwrap();
        unsafe {
            let output = posle_request(input.as_ptr());
            let value: Value = serde_json::from_str(CStr::from_ptr(output).to_str().unwrap()).unwrap();
            assert_eq!(value["ok"], true);
            assert!(value["value"].is_null());
            posle_free_string(output);
        }
    }
}

pub mod embedded_speech;
