pub(crate) mod application;
pub(crate) mod infrastructure;
pub mod domain;
pub mod platform_fs;
mod ai_config;
pub mod desktop;
mod desktop_import;
mod desktop_queue;
mod desktop_queue_executor;
pub mod desktop_queue_service;
mod desktop_media;
pub mod desktop_platform;
mod platform;
#[cfg(target_os = "macos")]
pub use platform::embedded_speech;
#[cfg(any(target_os = "macos", target_os = "linux"))]
pub use platform::python_runtime;
#[cfg(target_os = "macos")]
use platform::managed_embedding_transport;
#[cfg(unix)]
pub mod media;
#[cfg(unix)]
pub mod ai;
pub mod chatgpt;
#[cfg(unix)]
pub mod models;
pub mod storage;
pub mod notes;
pub mod creation_origin;
pub mod folders;
pub mod workspace_repository;
pub mod cards;
#[cfg(unix)]
pub mod trash;
#[cfg(unix)]
pub mod voice;
pub mod task_workspace;
#[cfg(unix)]
pub mod mcp;
pub mod search;
#[cfg(unix)]
pub mod semantic;
#[cfg(unix)]
pub mod code_index;
#[cfg(unix)]
pub mod tracker_sync;
#[cfg(unix)]
pub mod knowledge;
#[cfg(unix)]
pub mod worker;
pub mod jobs;
pub mod desktop_worker;
pub mod corrections;
#[cfg(unix)]
pub mod source_snapshot;

#[cfg(unix)]
pub mod scoped_share;
#[cfg(unix)]
pub mod managed_embeddings;
#[cfg(unix)]
pub mod knowledge_rebuild_ai;
pub mod knowledge_contract;
pub(crate) mod knowledge_meetings;
mod knowledge_vectors;
mod source_cleanup;
#[cfg(all(test, unix))]
mod meeting_incarnation;
#[allow(dead_code)]
mod knowledge_mixed_inventory;
#[cfg(unix)]
pub mod assistant_find;
#[cfg(unix)]
pub mod assistant_note_find;
#[cfg(unix)]
#[allow(dead_code)]
mod scoped_agent;

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
    let allowed = ["settings.json", "sidebar-state.json", "language-state.json", "overview-drafts.json", "voice-draft.json", "capture-drafts.json", "material-filters.json", "meta.json", "transcript.json", "summary.json", "examples.json", "review-state.json"];
    let name = relative.file_name().and_then(|s| s.to_str()).context("Нет имени файла")?;
    if !allowed.contains(&name) { bail!("Этот файл не относится к библиотеке"); }
    let components: Vec<_> = relative.components().collect();
    if ["settings.json", "sidebar-state.json", "language-state.json", "overview-drafts.json", "voice-draft.json", "capture-drafts.json", "material-filters.json"].contains(&name) {
        if components.len() != 1 { bail!("Недопустимый путь настроек"); }
    } else {
        if components.len() != 3 || components[0].as_os_str() != "meetings" { bail!("Недопустимый путь встречи"); }
        storage::meeting_directory(root, components[1].as_os_str().to_str().context("Неверный ID")?)?;
    }
    Ok(root.join(relative))
}

#[cfg(unix)]
pub fn request(value: &Value) -> Result<Value> {
    let root = PathBuf::from(value["root"].as_str().context("Нужна папка данных приложения")?);
    if !root.is_absolute() { bail!("Папка данных должна иметь абсолютный путь"); }
    match value["command"].as_str().context("Нет команды ядра")? {
        command if command.starts_with("folder-") || command == "profile-resolve" => folders::dispatch(&root,value),
        command if command.starts_with("trash-") => trash::dispatch(&root,value),
        command if command.starts_with("agent-share-") => scoped_share::dispatch(&root,value),
        command if command.starts_with("tracker-") => tracker_sync::request(&root,command,value),
        command if command.starts_with("semantic-") => semantic::dispatch(&root,value),
        command if command.starts_with("code-index-") => code_index::dispatch(&root,value),
        "note-save-from-summary" => {
            let note: notes::CapturedNote = serde_json::from_value(value["note"].clone())?;
            if note.kind != "note" || note.meeting_id.is_none() || note.revision != 0 {
                bail!("Для копии конспекта нужна новая заметка со встречей");
            }
            let origin = summary_copy_origin(&root, &note);
            Ok(serde_json::to_value(notes::save_note_with_origin(&root, note, origin)?)?)
        }
        command if ["notes-list", "note-save", "note-save-copy", "note-delete", "note-trash", "note-restore", "context-save", "template-save", "template-delete", "note-attach", "attachment-path", "attachment-remove", "attachment-text", "notes-search", "notes-tasks", "notes-task-complete", "notes-brief", "note-search-validate", "note-expansion-validate", "note-expansion-valid"].contains(&command) => notes::dispatch(&root, value),
        "voice-plan" | "voice-inspect" | "voice-choose" | "voice-apply" | "voice-undo" | "voice-recover" | "task-update" | "task-materialize" | "task-append" => voice::dispatch(&root, value),
        command if command.starts_with("task-") => task_workspace::dispatch(&root, value),
        "card-trash-list" | "card-restore" | "card-trash-purge" | "cards-batch-apply" | "cards-batch-undo" | "cards-batch-recover" | "cards-import" | "cards-import-preview" | "cards-library" | "card-save" | "card-delete" | "card-suspend" | "cards-review" | "cards-review-preview" | "cards-review-undo" => cards::dispatch(&root,value),
        command if command.starts_with("job-") => jobs::dispatch(&root, value),
        "meeting-content-snapshot" | "transcript-segment-save" | "summary-item-save" => corrections::dispatch(&root, value),
        "source-snapshot" => source_snapshot::snapshot(&root, value),
        "list" => Ok(json!({"meetings": storage::list_meetings(&root)?})),
        "kb-rebuild-generate" => knowledge_rebuild_ai::generate(&root,value),
        command if command.starts_with("kb-") => workspace_repository::knowledge_dispatch(&root,value),
        "assistant-find" | "assistant-find-validate" | "assistant-find-validate-list" => assistant_find::dispatch(&root,value),
        "assistant-note-find" | "assistant-note-validate" => assistant_note_find::dispatch(&root,value),
        "knowledge-meeting-suggestions" => knowledge_meetings::suggestions(&root,value),
        "knowledge-meeting-validate" => knowledge_meetings::validate_for_note(&root,value),
        "knowledge-search" => knowledge::lookup(&root, value),
        "knowledge-validate-source" => knowledge::validate_source(&root, value),
        "search-validate" => search::validate(&root, value["meetingID"].as_str().context("Нет ID встречи")?, value["sourceFingerprint"].as_str().unwrap_or("")),
        "search" => search::search(&root, value["query"].as_str().unwrap_or(""), value["scope"].as_str().unwrap_or("all"), value["limit"].as_u64().unwrap_or(60).min(100) as usize),
        "read" => {
            let path = data_path(&root, value["path"].as_str().context("Нет пути")?)?;
            if !path.exists() { return Ok(Value::Null); }
            let info = std::fs::symlink_metadata(&path)?;
            if !info.is_file() || info.file_type().is_symlink() { bail!("Ожидается обычный файл библиотеки"); }
            if path.file_name().and_then(|s| s.to_str()) == Some("material-filters.json") && info.len() > 65_536 {
                bail!("Файл фильтров слишком большой");
            }
            Ok(serde_json::from_slice(&std::fs::read(path)?)?)
        }
        "write" => {
            let path = data_path(&root, value["path"].as_str().context("Нет пути")?)?;
            let data = value.get("value").context("Нет данных")?;
            if path.file_name().and_then(|s| s.to_str()) == Some("material-filters.json") &&
                (!data.is_object() || serde_json::to_vec(data)?.len() > 65_536) {
                bail!("Некорректные настройки фильтров");
            }
            if path.file_name().and_then(|s| s.to_str()) == Some("settings.json") {
                if ["apiKey", "api_key", "key", "token"].iter().any(|k| data.get(k).is_some()) {
                    bail!("Секреты должны храниться в Связке ключей macOS");
                }
            }
            if path.file_name().and_then(|s| s.to_str()) == Some("summary.json") {
                cards::write_compatible_summary(&path, data)?;
            } else {
                storage::atomic_json(&path, data)?;
            }
            Ok(json!({"saved": true}))
        }
        "import" => storage::import_meeting(&root, Path::new(value["source"].as_str().context("Нет файла")?),
                                            value["focus"].as_str().unwrap_or("")),
        "summary-overview-save" => storage::save_summary_overview(&root,
            value["meetingID"].as_str().context("Нет ID встречи")?,
            value["text"].as_str().context("Нет текста конспекта")?,
            value["expectedOverview"].as_str().context("Нет исходного конспекта")?,
            value["expectedGeneratedAt"].as_f64().context("Нет даты исходного конспекта")?),
        "meeting-rename" => storage::rename_meeting(&root,
            value["meetingID"].as_str().context("Нет ID встречи")?,
            value["title"].as_str().context("Нет названия встречи")?,
            value["expectedTitle"].as_str().context("Нет исходного названия встречи")?),
        "update" => storage::update_meta(&root, value["id"].as_str().context("Нет ID")?, value.get("patch").context("Нет изменений")?),
        _ => Err(anyhow!("Неизвестная команда ядра")),
    }
}

/// The Windows preview exposes only the bounded desktop protocol. Native
/// processing and credentials are intentionally unavailable on this platform.
#[cfg(windows)]
pub fn request(_value: &Value) -> Result<Value> {
    bail!("Unsupported Windows preview command. Use the typed desktop bridge.")
}

#[cfg(unix)]
/// A meeting association or writable recovery draft does not prove authorship.
/// A draft inherits AI provenance only from the current generated baseline.
fn summary_copy_origin(root: &Path, note: &notes::CapturedNote) -> creation_origin::CreationOrigin {
    use creation_origin::CreationOrigin;
    let Some(id) = note.meeting_id.as_deref() else { return CreationOrigin::Unknown; };
    let read = |path: PathBuf| {
        std::fs::symlink_metadata(&path).ok().filter(|info| info.is_file() && !info.file_type().is_symlink() && info.len() <= 8 * 1_048_576)
            .and_then(|_| storage::regular_json(&path).ok())
    };
    let Some(summary) = storage::meeting_directory(root, id).ok().and_then(|directory| read(directory.join("summary.json"))) else {
        return CreationOrigin::Unknown;
    };
    if !summary["provider"].as_str().is_some_and(|s| !s.is_empty() && s != "manual" && s != "import") {
        return CreationOrigin::Unknown;
    }
    let Some(overview) = summary["overview"].as_str() else { return CreationOrigin::Unknown; };
    if overview == note.text.as_str() { return CreationOrigin::Ai; }
    let Some(generated_at) = summary["generatedAt"].as_f64().filter(|n| n.is_finite() && *n >= 0.0) else {
        return CreationOrigin::Unknown;
    };
    if let Some(drafts) = read(root.join("overview-drafts.json")) {
        let draft = &drafts[id];
        if draft["text"].as_str() == Some(note.text.as_str()) &&
            draft["original"].as_str() == Some(overview) &&
            draft["generatedAt"].as_f64() == Some(generated_at) {
            return CreationOrigin::Ai;
        }
    }
    CreationOrigin::Unknown
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

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[test]
    fn summary_note_origin_rejects_forged_drafts_and_imported_or_manual_baselines() {
        let root = tempfile::tempdir().unwrap();
        let meeting = storage::meeting_directory(root.path(), "source").unwrap();
        storage::atomic_json(&meeting.join("meta.json"), &json!({"id":"source","title":"Source","createdAt":1,"status":"ready"})).unwrap();
        let save = |id: &str, text: &str| request(&json!({"root":root.path(),"command":"note-save-from-summary","note":{"id":id,"text":text,"meetingID":"source","createdAt":1,"updatedAt":1}})).unwrap();
        assert_eq!(save("unknown", "Arbitrary manual text")["creationOrigin"], "unknown");
        let draft = json!({"source":{"text":"Recovered edit","original":"Baseline text","generatedAt":1}});
        request(&json!({"root":root.path(),"command":"write","path":"overview-drafts.json","value":draft})).unwrap();
        let recovered = save("forged-draft", "Recovered edit");
        assert_eq!(recovered["creationOrigin"], "unknown");
        assert_eq!(recovered["text"], "Recovered edit");
        for provider in ["import", "manual", ""] {
            storage::atomic_json(&meeting.join("summary.json"), &json!({"overview":"Baseline text","provider":provider,"generatedAt":1,"cards":[]})).unwrap();
            assert_eq!(save(&format!("direct-{}", if provider.is_empty() {"missing"} else {provider}), "Baseline text")["creationOrigin"], "unknown");
            let saved = save(&format!("draft-{}", if provider.is_empty() {"missing"} else {provider}), "Recovered edit");
            assert_eq!(saved["creationOrigin"], "unknown");
            assert_eq!(saved["text"], "Recovered edit");
        }
        assert_eq!(storage::regular_json(&root.path().join("overview-drafts.json")).unwrap(), draft);
    }
    #[test]
    fn summary_note_origin_accepts_only_current_generated_content_or_matching_draft_baseline() {
        let root = tempfile::tempdir().unwrap();
        let meeting = storage::meeting_directory(root.path(), "source").unwrap();
        storage::atomic_json(&meeting.join("meta.json"), &json!({"id":"source","title":"Source","createdAt":1,"status":"ready"})).unwrap();
        let save = |id: &str, text: &str| request(&json!({"root":root.path(),"command":"note-save-from-summary","note":{"id":id,"text":text,"meetingID":"source","createdAt":1,"updatedAt":1}})).unwrap();
        storage::atomic_json(&meeting.join("summary.json"), &json!({"overview":"Generated text","provider":"fixture","generatedAt":1,"cards":[]})).unwrap();
        assert_eq!(save("generated", "Generated text")["creationOrigin"], "ai");
        assert_eq!(save("different", "Unrelated text")["creationOrigin"], "unknown");
        storage::atomic_json(&root.path().join("overview-drafts.json"), &json!({"source":{"text":"Recovered edit","original":"Generated text","generatedAt":1}})).unwrap();
        let mut recovered = save("recovered", "Recovered edit");
        assert_eq!(recovered["creationOrigin"], "ai");
        recovered["text"] = json!("Human edits"); recovered["creationOrigin"] = json!("manual");
        let saved = request(&json!({"root":root.path(),"command":"note-save","note":recovered})).unwrap();
        assert_eq!(saved["creationOrigin"], "ai");
        for (id, draft) in [
            ("draft-without-original", json!({"text":"Recovered edit","generatedAt":1})),
            ("draft-wrong-generation", json!({"text":"Recovered edit","original":"Generated text","generatedAt":2})),
            ("draft-without-generation", json!({"text":"Recovered edit","original":"Generated text"})),
        ] {
            storage::atomic_json(&root.path().join("overview-drafts.json"), &json!({"source":draft})).unwrap();
            assert_eq!(save(id, "Recovered edit")["creationOrigin"], "unknown");
        }
        storage::atomic_json(&root.path().join("overview-drafts.json"), &json!({"source":{"text":"Recovered edit","original":"Generated text","generatedAt":1}})).unwrap();
        for (id, overview, generated_at) in [
            ("changed-baseline", json!("Different source text"), json!(1)),
            ("changed-generation", json!("Generated text"), json!(2)),
            ("missing-generation", json!("Generated text"), Value::Null),
            ("invalid-generation", json!("Generated text"), json!(-1)),
        ] {
            storage::atomic_json(&meeting.join("summary.json"), &json!({"overview":overview,"provider":"fixture","generatedAt":generated_at,"cards":[]})).unwrap();
            let recovered = save(id, "Recovered edit");
            assert_eq!(recovered["creationOrigin"], "unknown");
            assert_eq!(recovered["text"], "Recovered edit");
        }
        std::fs::remove_file(meeting.join("summary.json")).unwrap();
        let recovered = save("missing-baseline", "Recovered edit");
        assert_eq!(recovered["creationOrigin"], "unknown");
        assert_eq!(recovered["text"], "Recovered edit");
    }
    #[test]
    fn sidebar_layout_state_is_private_and_root_only() {
        let directory = tempfile::tempdir().unwrap();
        let state = json!({"foldersExpanded": false});
        request(&json!({"root":directory.path(),"command":"write","path":"sidebar-state.json","value":state})).unwrap();
        assert_eq!(request(&json!({"root":directory.path(),"command":"read","path":"sidebar-state.json"})).unwrap(), state);
        assert!(request(&json!({"root":directory.path(),"command":"write","path":"meetings/demo/sidebar-state.json","value":state})).is_err());
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(directory.path().join("sidebar-state.json")).unwrap().permissions().mode() & 0o777, 0o600);
        let outside = tempfile::tempdir().unwrap();
        std::fs::remove_file(directory.path().join("sidebar-state.json")).unwrap();
        let target = outside.path().join("outside.json");
        std::fs::write(&target, b"unchanged").unwrap();
        std::os::unix::fs::symlink(&target, directory.path().join("sidebar-state.json")).unwrap();
        assert!(request(&json!({"root":directory.path(),"command":"read","path":"sidebar-state.json"})).is_err());
        request(&json!({"root":directory.path(),"command":"write","path":"sidebar-state.json","value":state})).unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"unchanged");
        assert!(!std::fs::symlink_metadata(directory.path().join("sidebar-state.json")).unwrap().file_type().is_symlink());
    }

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

#[cfg(unix)]
pub mod asr_model;

#[cfg(unix)]
pub mod speech_job;

#[cfg(unix)]
mod desktop_speech_queue;
#[cfg(unix)]
mod desktop_speech_checks;
#[cfg(unix)]
pub mod desktop_speech_service;
