//! Stable library folders and inherited processing profiles. A folder is a
//! logical membership, never a filesystem path or a new credential grant.
use crate::notes::{CapturedNote, MeetingContext, NotesWorkspace};
use anyhow::{bail, ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::Path;

const MAX_FOLDERS: usize = 1_000;
const FEATURES: &[&str] = &["cards", "tasks", "calendar", "assistant", "semanticSearch"];
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Folder {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub revision: u64,
    #[serde(default = "empty_object")]
    pub overrides: Value,
}
fn empty_object() -> Value {
    json!({})
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileSnapshot {
    #[serde(rename = "folderID")]
    pub folder_id: Option<String>,
    pub folder_name: Option<String>,
    pub fingerprint: String,
    pub overrides: Value,
    pub generate_cards: bool,
    #[serde(default)]
    pub features: crate::ai::AppFeatures,
}
fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
}
fn bounded(value: &str, max: usize) -> Result<()> {
    ensure!(
        value.len() <= max && !value.contains('\0'),
        "Некорректное или слишком длинное поле профиля папки"
    );
    Ok(())
}
fn one_of(value: &str, allowed: &[&str]) -> Result<()> {
    ensure!(
        allowed.contains(&value),
        "Неизвестное значение настройки папки"
    );
    Ok(())
}
fn endpoint(value: &str, local: bool) -> Result<()> {
    if value.is_empty() {
        return Ok(());
    }
    let url = reqwest::Url::parse(value).context("Некорректный адрес модели в папке")?;
    let host = url.host_str().context("Укажите адрес модели")?;
    let loopback = matches!(host, "localhost" | "127.0.0.1" | "[::1]" | "::1");
    let authority = value
        .split_once("://")
        .map(|(_, rest)| rest.split(['/', '?', '#']).next().unwrap_or(""))
        .unwrap_or("");
    ensure!(
        !authority.contains('@')
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none(),
        "Адрес модели не должен содержать ключ, логин, параметры или фрагмент"
    );
    if local {
        ensure!(
            loopback && matches!(url.scheme(), "http" | "https"),
            "Локальная модель должна работать на этом Mac"
        );
    } else {
        ensure!(
            url.scheme() == "https" || (url.scheme() == "http" && loopback),
            "Для облачного API нужен HTTPS"
        );
    }
    Ok(())
}
pub(crate) fn validate_overrides(value: &Value) -> Result<()> {
    let object = value
        .as_object()
        .context("Настройки папки должны быть объектом")?;
    for (key, value) in object {
        ensure!(
            [
                "features",
                "mode",
                "localProvider",
                "localEndpoint",
                "localModel",
                "cloudProvider",
                "cloudEndpoint",
                "cloudModel",
                "cloudAPI",
                "cloudOutput",
                "cloudReasoning",
                "chatGPTAccountID",
                "language",
                "focus",
                "summaryUserContext",
                "generateCards"
            ]
            .contains(&key.as_str()),
            "Неизвестное поле профиля папки: {key}"
        );
        if value.is_null() {
            continue;
        }
        if key == "features" {
            for (feature, enabled) in value
                .as_object()
                .context("Возможности папки должны быть объектом")?
            {
                ensure!(
                    FEATURES.contains(&feature.as_str())
                        && (enabled.is_boolean() || enabled.is_null()),
                    "Неизвестная возможность или неверное значение в папке"
                );
            }
            continue;
        }
        if key == "generateCards" {
            ensure!(
                value.is_boolean(),
                "Создание карточек должно быть включено или выключено"
            );
            continue;
        }
        let text = value
            .as_str()
            .context("Настройка папки должна быть строкой")?;
        bounded(
            text,
            match key.as_str() {
                "focus" => 10_000,
                "summaryUserContext" => 8_000,
                "localEndpoint" | "cloudEndpoint" => 8_192,
                _ => 512,
            },
        )?;
        if !["focus", "summaryUserContext"].contains(&key.as_str()) {
            ensure!(
                !text.chars().any(char::is_control),
                "Уберите управляющие символы из настройки папки"
            );
        }
        match key.as_str() {
            "mode" => one_of(text, &["local", "cloud"]),
            "localProvider" => one_of(text, &["managed", "ollama", "lmstudio"]),
            "cloudProvider" => one_of(
                text,
                &["openai", "chatgpt", "openrouter", "polza", "custom"],
            ),
            "cloudAPI" => one_of(text, &["responses", "chat"]),
            "cloudOutput" => one_of(text, &["schema", "json", "prompt"]),
            "cloudReasoning" => crate::chatgpt::validate_reasoning(text),
            "language" => one_of(text, &["ru", "en"]),
            "localEndpoint" => endpoint(text, true),
            "cloudEndpoint" => endpoint(text, false),
            "localModel" | "cloudModel" => {
                ensure!(!text.trim().is_empty(), "Укажите имя модели");
                Ok(())
            }
            _ => Ok(()),
        }?;
    }
    Ok(())
}
pub(crate) fn validate_workspace(workspace: &NotesWorkspace) -> Result<()> {
    ensure!(
        workspace.folders.len() <= MAX_FOLDERS,
        "Слишком много папок"
    );
    let mut ids = HashSet::new();
    let mut names = HashSet::new();
    for folder in &workspace.folders {
        ensure!(
            valid_id(&folder.id) && ids.insert(folder.id.as_str()),
            "Некорректный или повторный ID папки"
        );
        bounded(&folder.name, 256)?;
        ensure!(
            !folder.name.trim().is_empty() && names.insert(folder.name.as_str()),
            "Папка с таким названием уже есть"
        );
        validate_overrides(&folder.overrides)?;
    }
    for id in workspace
        .notes
        .iter()
        .filter_map(|n| n.folder_id.as_deref())
        .chain(
            workspace
                .contexts
                .iter()
                .filter_map(|c| c.folder_id.as_deref()),
        )
    {
        ensure!(ids.contains(id), "Папка не найдена. Обновите библиотеку.");
    }
    Ok(())
}
fn bumped(revision: u64) -> Result<u64> {
    revision
        .checked_add(1)
        .context("Слишком большая ревизия папки")
}
fn legacy_id(name: &str) -> String {
    format!(
        "legacy-{}",
        &format!("{:x}", Sha256::digest(name.as_bytes()))[..24]
    )
}
/// Run only when the canonical payload predates folders. Names are retained
/// verbatim; meeting membership is deliberately not guessed from its notes.
pub(crate) fn migrate_legacy(value: &mut Value) -> Result<bool> {
    if value.get("folders").is_some() {
        return Ok(false);
    }
    let mut folders = std::collections::BTreeMap::new();
    if let Some(notes) = value["notes"].as_array_mut() {
        for note in notes {
            let Some(name) = note["folder"]
                .as_str()
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned)
            else {
                continue;
            };
            bounded(&name, 256)?;
            let id = legacy_id(&name);
            folders
                .entry(name.clone())
                .or_insert_with(|| json!({"id":id,"name":name,"revision":1,"overrides":{}}));
            note["folderID"] = json!(id);
        }
    }
    value["folders"] = Value::Array(folders.into_values().collect());
    Ok(true)
}
pub(crate) fn normalize_note_folder(
    workspace: &mut NotesWorkspace,
    note: &mut CapturedNote,
) -> Result<()> {
    if let Some(id) = &note.folder_id {
        let folder = workspace
            .folders
            .iter()
            .find(|f| &f.id == id)
            .context("Папка удалена. Выберите другую папку.")?;
        note.folder = folder.name.clone();
        return Ok(());
    }
    if note.folder.trim().is_empty() {
        note.folder.clear();
        return Ok(());
    }
    if let Some(folder) = workspace.folders.iter().find(|f| f.name == note.folder) {
        note.folder_id = Some(folder.id.clone());
        return Ok(());
    }
    bounded(&note.folder, 256)?;
    ensure!(workspace.folders.len() < MAX_FOLDERS, "Слишком много папок");
    let id = legacy_id(&note.folder);
    ensure!(
        !workspace.folders.iter().any(|f| f.id == id),
        "Идентификатор папки уже существует"
    );
    workspace.folders.push(Folder {
        id: id.clone(),
        name: note.folder.clone(),
        revision: 1,
        overrides: json!({}),
    });
    note.folder_id = Some(id);
    Ok(())
}
pub fn save(root: &Path, mut folder: Folder) -> Result<Folder> {
    folder.name = folder.name.trim().to_owned();
    ensure!(valid_id(&folder.id), "Некорректный ID папки");
    let dir = crate::notes::directory(root)?;
    let _lock = crate::notes::lock(&dir)?;
    let mut data = crate::notes::load(&dir)?;
    if let Some(index) = data.folders.iter().position(|f| f.id == folder.id) {
        ensure!(
            data.folders[index].revision == folder.revision,
            "Папка уже изменилась. Обновите данные; ваши настройки сохранены в редакторе."
        );
        folder.revision = bumped(folder.revision)?;
        for note in &mut data.notes {
            if note.folder_id.as_deref() == Some(&folder.id) && note.folder != folder.name {
                note.folder = folder.name.clone();
                note.revision = bumped(note.revision)?;
                note.updated_at = chrono::Utc::now().timestamp_millis() as f64 / 1000.0;
            }
        }
        data.folders[index] = folder.clone();
    } else {
        ensure!(folder.revision == 0, "Папка уже удалена. Обновите данные.");
        folder.revision = 1;
        data.folders.push(folder.clone());
    }
    crate::notes::persist(&dir, &data)?;
    Ok(folder)
}
pub fn delete(root: &Path, id: &str, revision: u64) -> Result<Value> {
    let dir = crate::notes::directory(root)?;
    let _lock = crate::notes::lock(&dir)?;
    let mut data = crate::notes::load(&dir)?;
    let index = data
        .folders
        .iter()
        .position(|f| f.id == id)
        .context("Папка уже удалена")?;
    ensure!(
        data.folders[index].revision == revision,
        "Папка изменилась. Обновите данные перед удалением."
    );
    let mut notes = 0;
    let mut meetings = 0;
    for note in &mut data.notes {
        if note.folder_id.as_deref() == Some(id) {
            note.folder_id = None;
            note.folder.clear();
            note.revision = bumped(note.revision)?;
            note.updated_at = chrono::Utc::now().timestamp_millis() as f64 / 1000.0;
            notes += 1;
        }
    }
    for context in &mut data.contexts {
        if context.folder_id.as_deref() == Some(id) {
            context.folder_id = None;
            context.revision = bumped(context.revision)?;
            meetings += 1;
        }
    }
    data.folders.remove(index);
    crate::notes::persist(&dir, &data)?;
    Ok(json!({"deleted":true,"unlinkedNotes":notes,"unlinkedMeetings":meetings}))
}
pub fn assign_meeting(
    root: &Path,
    meeting_id: &str,
    folder_id: Option<&str>,
    revision: u64,
) -> Result<MeetingContext> {
    let dir = crate::notes::directory(root)?;
    let _lock = crate::notes::lock(&dir)?;
    let mut data = crate::notes::load(&dir)?;
    let directory = crate::storage::meeting_directory(root, meeting_id)?;
    let meta = crate::storage::regular_json(&directory.join("meta.json"))?;
    ensure!(
        meta["id"].as_str() == Some(meeting_id),
        "Встреча не найдена"
    );
    if let Some(id) = folder_id {
        ensure!(data.folders.iter().any(|f| f.id == id), "Папка не найдена");
    }
    let context = if let Some(index) = data
        .contexts
        .iter()
        .position(|c| c.meeting_id == meeting_id)
    {
        let current = &mut data.contexts[index];
        ensure!(
            current.revision == revision,
            "Контекст встречи изменился. Обновите данные."
        );
        current.folder_id = folder_id.map(str::to_owned);
        current.revision = bumped(current.revision)?;
        current.clone()
    } else {
        ensure!(
            revision == 0,
            "Контекст встречи изменился. Обновите данные."
        );
        let context = MeetingContext {
            meeting_id: meeting_id.into(),
            project: String::new(),
            person: String::new(),
            template_id: None,
            folder_id: folder_id.map(str::to_owned),
            revision: 1,
        };
        data.contexts.push(context.clone());
        context
    };
    crate::notes::persist(&dir, &data)?;
    Ok(context)
}
pub fn folder_id_for_meeting<'a>(
    workspace: &'a NotesWorkspace,
    meeting_id: &str,
) -> Option<&'a str> {
    workspace
        .contexts
        .iter()
        .find(|c| c.meeting_id == meeting_id)
        .and_then(|c| c.folder_id.as_deref())
}
pub fn folder_id_for_note<'a>(workspace: &'a NotesWorkspace, note_id: &str) -> Option<&'a str> {
    let note = workspace.notes.iter().find(|n| n.id == note_id)?;
    note.folder_id.as_deref().or_else(|| {
        note.meeting_id
            .as_deref()
            .and_then(|id| folder_id_for_meeting(workspace, id))
    })
}
pub fn workspace_snapshot(root: &Path) -> Result<NotesWorkspace> {
    serde_json::from_value(crate::workspace_repository::read_committed(root)?)
        .context("Не удалось прочитать профили папок")
}
pub fn resolve(
    root: &Path,
    meeting_id: Option<&str>,
    folder_id: Option<&str>,
) -> Result<ProfileSnapshot> {
    let data = workspace_snapshot(root)?;
    if let Some(id) = meeting_id {
        ensure!(valid_id(id), "Некорректный ID встречи");
    }
    // Existing object membership is authoritative, including "no folder".
    // A stale sidebar selection must never override a meeting's profile.
    let id = match meeting_id {
        Some(id) => folder_id_for_meeting(&data, id),
        None => folder_id,
    };
    let folder = id
        .map(|id| {
            data.folders
                .iter()
                .find(|f| f.id == id)
                .context("Папка удалена. Обновите данные.")
        })
        .transpose()?;
    let overrides = folder
        .map(|f| f.overrides.clone())
        .unwrap_or_else(empty_object);
    let path = root.join("settings.json");
    let mut effective = if path.exists() {
        crate::storage::regular_json(&path)?
    } else {
        json!({})
    };
    apply_overrides(&mut effective, &overrides)?;
    // Normalize absent fields through the same defaults used by inference.
    // First saving unrelated UI preferences must not invalidate a queued job.
    let effective: crate::ai::Settings = serde_json::from_value(effective)?;
    let features = effective.features.clone();
    let effective = serde_json::to_value(effective)?;
    let fingerprint = format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(
            &json!({"folderID":id,"revision":folder.map(|f|f.revision),"overrides":overrides,"effectiveSettings":effective})
        )?)
    );
    Ok(ProfileSnapshot {
        folder_id: id.map(str::to_owned),
        folder_name: folder.map(|f| f.name.clone()),
        fingerprint,
        generate_cards: overrides["generateCards"].as_bool().unwrap_or(false),
        features,
        overrides,
    })
}
/// Sparse merge. Null means inherit; credentials never enter folder profiles.
pub fn apply_overrides(settings: &mut Value, overrides: &Value) -> Result<()> {
    validate_overrides(overrides)?;
    let object = settings
        .as_object_mut()
        .context("Настройки приложения должны быть объектом")?;
    for (key, value) in overrides.as_object().unwrap() {
        if value.is_null() || key == "generateCards" {
            continue;
        }
        if key == "features" {
            let current = object.entry("features").or_insert_with(empty_object);
            if !current.is_object() {
                bail!("Некорректные возможности приложения");
            }
            for (name, enabled) in value.as_object().unwrap() {
                if !enabled.is_null() {
                    current[name] = enabled.clone();
                }
            }
        } else {
            object.insert(key.clone(), value.clone());
        }
    }
    Ok(())
}
pub fn profile_settings(
    root: &Path,
    meeting_id: Option<&str>,
    folder_id: Option<&str>,
) -> Result<Value> {
    let path = root.join("settings.json");
    let mut settings = if path.exists() {
        crate::storage::regular_json(&path)?
    } else {
        json!({})
    };
    apply_overrides(
        &mut settings,
        &resolve(root, meeting_id, folder_id)?.overrides,
    )?;
    Ok(settings)
}
pub fn available_features(root: &Path) -> Result<crate::ai::AppFeatures> {
    let path = root.join("settings.json");
    let settings = if path.exists() {
        crate::storage::regular_json(&path)?
    } else {
        json!({})
    };
    let mut enabled: crate::ai::AppFeatures = serde_json::from_value(
        settings
            .get("features")
            .cloned()
            .unwrap_or_else(empty_object),
    )?;
    for folder in workspace_snapshot(root)?.folders {
        let mut candidate = settings.clone();
        apply_overrides(&mut candidate, &folder.overrides)?;
        let f: crate::ai::AppFeatures = serde_json::from_value(
            candidate
                .get("features")
                .cloned()
                .unwrap_or_else(empty_object),
        )?;
        enabled.cards |= f.cards;
        enabled.tasks |= f.tasks;
        enabled.calendar |= f.calendar;
        enabled.assistant |= f.assistant;
        enabled.semantic_search |= f.semantic_search;
    }
    Ok(enabled)
}
pub fn dispatch(root: &Path, input: &Value) -> Result<Value> {
    let string = |key: &str| {
        input[key]
            .as_str()
            .with_context(|| format!("Нет поля {key}"))
    };
    let revision = || {
        input["revision"]
            .as_u64()
            .context("Нет ревизии папки или контекста")
    };
    match input["command"].as_str().unwrap_or("") {
        "folder-save" => Ok(serde_json::to_value(save(
            root,
            serde_json::from_value(input["folder"].clone())?,
        )?)?),
        "folder-delete" => delete(root, string("id")?, revision()?),
        "folder-assign-meeting" => {
            ensure!(
                input.get("folderID").is_some()
                    && (input["folderID"].is_null() || input["folderID"].is_string()),
                "Укажите папку или null"
            );
            Ok(serde_json::to_value(assign_meeting(
                root,
                string("meetingID")?,
                input["folderID"].as_str(),
                revision()?,
            )?)?)
        }
        "profile-resolve" => {
            for key in ["meetingID", "folderID"] {
                ensure!(
                    input.get(key).is_none_or(|v| v.is_null() || v.is_string()),
                    "Некорректная область профиля"
                );
            }
            Ok(serde_json::to_value(resolve(
                root,
                input["meetingID"].as_str(),
                input["folderID"].as_str(),
            )?)?)
        }
        _ => bail!("Неизвестная команда папки"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn folder(id: &str, name: &str, overrides: Value) -> Folder {
        Folder {
            id: id.into(),
            name: name.into(),
            revision: 0,
            overrides,
        }
    }
    fn meeting(root: &Path, id: &str) {
        let path = crate::storage::meeting_directory(root, id).unwrap();
        crate::storage::atomic_json(
            &path.join("meta.json"),
            &json!({"id":id,"title":"Рабочая встреча","createdAt":1,"source":"recording.wav"}),
        )
        .unwrap();
    }
    fn note(root: &Path, text: &str, folder_id: Option<&str>) -> CapturedNote {
        crate::notes::save_note(root,serde_json::from_value(json!({"id":uuid::Uuid::new_v4().to_string(),"text":text,"folderID":folder_id,"createdAt":0,"updatedAt":0})).unwrap()).unwrap()
    }
    #[test]
    fn profiles_inherit_sparse_values_and_preserve_global_settings() {
        let root = tempfile::tempdir().unwrap();
        let global = json!({"mode":"local","language":"ru","features":{"cards":false,"tasks":true},"futureSetting":{"safe":true}});
        crate::storage::atomic_json(&root.path().join("settings.json"), &global).unwrap();
        let saved=save(root.path(),folder("english","Английский",json!({"features":{"cards":true,"tasks":false,"calendar":null},"language":"en","focus":null,"generateCards":true}))).unwrap();
        let profile = resolve(root.path(), None, Some(&saved.id)).unwrap();
        assert!(profile.generate_cards);
        assert!(profile.features.cards);
        assert!(!profile.features.tasks);
        let effective = profile_settings(root.path(), None, Some(&saved.id)).unwrap();
        assert_eq!(effective["features"], json!({"cards":true,"tasks":false}));
        assert_eq!(effective["language"], "en");
        assert_eq!(effective["futureSetting"], global["futureSetting"]);
        assert_eq!(
            crate::storage::regular_json(&root.path().join("settings.json")).unwrap(),
            global
        );
        let available = available_features(root.path()).unwrap();
        assert!(available.cards && available.tasks);
        assert!(!resolve(root.path(), None, None).unwrap().generate_cards);
    }
    #[test]
    fn folder_rename_and_delete_use_cas_and_preserve_content() {
        let root = tempfile::tempdir().unwrap();
        meeting(root.path(), "meeting");
        let mut saved = save(
            root.path(),
            folder("english", "Английский", json!({"generateCards":true})),
        )
        .unwrap();
        let note = note(root.path(), "Нужный текст", Some(&saved.id));
        let context = assign_meeting(root.path(), "meeting", Some(&saved.id), 0).unwrap();
        assert!(assign_meeting(root.path(), "meeting", None, 0).is_err());
        saved.name = "English".into();
        let renamed = save(root.path(), saved.clone()).unwrap();
        assert!(save(root.path(), saved.clone()).is_err());
        let current = crate::notes::load_note_snapshot(root.path(), &note.id).unwrap();
        assert_eq!(current.folder, "English");
        assert!(current.revision > note.revision);
        assert!(delete(root.path(), &saved.id, saved.revision).is_err());
        let result = delete(root.path(), &saved.id, renamed.revision).unwrap();
        assert_eq!(result["unlinkedNotes"], 1);
        assert_eq!(result["unlinkedMeetings"], 1);
        let current = crate::notes::load_note_snapshot(root.path(), &note.id).unwrap();
        assert_eq!(current.text, "Нужный текст");
        assert!(current.folder_id.is_none() && current.folder.is_empty());
        let data = crate::notes::list(root.path()).unwrap();
        let current = data
            .contexts
            .iter()
            .find(|c| c.meeting_id == "meeting")
            .unwrap();
        assert!(current.folder_id.is_none() && current.revision > context.revision);
        assert!(crate::notes::save_note(root.path(), note).is_err());
        assert!(resolve(root.path(), None, Some(&renamed.id)).is_err());
    }
    #[test]
    fn legacy_folder_migration_is_stable_and_does_not_guess_meeting_membership() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("notes/workspace.json");
        crate::storage::atomic_json(&path,&json!({"notes":[{"id":"one","text":"Слова","folder":"Английский","meetingID":"call","createdAt":0,"updatedAt":0},{"id":"two","text":"Дела","folder":"Работа","meetingID":"call","createdAt":0,"updatedAt":0}],"templates":[],"contexts":[{"meetingID":"call","project":"Работа","person":"Лид","revision":1}],"future":{"kept":true}})).unwrap();
        let first = crate::notes::list(root.path()).unwrap();
        assert_eq!(first.folders.len(), 2);
        assert!(first.notes.iter().all(|n| n.folder_id.is_some()));
        assert!(first.contexts[0].folder_id.is_none());
        let snapshot = crate::workspace_repository::snapshot(root.path()).unwrap();
        let again = crate::notes::list(root.path()).unwrap();
        assert_eq!(first.notes[0].folder_id, again.notes[0].folder_id);
        assert_eq!(
            snapshot.revision,
            crate::workspace_repository::snapshot(root.path())
                .unwrap()
                .revision
        );
        assert_eq!(snapshot.value["future"]["kept"], true);
        let id = first.notes[0].folder_id.as_deref().unwrap();
        let f = first.folders.iter().find(|f| f.id == id).unwrap();
        delete(root.path(), id, f.revision).unwrap();
        assert_eq!(crate::notes::list(root.path()).unwrap().folders.len(), 1);
    }
    #[test]
    fn invalid_profiles_and_secrets_never_commit() {
        let root = tempfile::tempdir().unwrap();
        for overrides in [
            json!({"apiKey":"secret"}),
            json!({"features":{"cards":"yes"}}),
            json!({"features":{"apiKey":true}}),
            json!({"localEndpoint":"https://remote.example/v1"}),
            json!({"cloudEndpoint":"https://secret@example.com/v1"}),
            json!({"cloudEndpoint":"https://example.com/v1?key=secret"}),
            json!({"mode":"unknown"}),
            json!({"cloudProvider":"not-supported"}),
            json!({"language":"unknown"}),
            json!({"generateCards":"true"}),
        ] {
            assert!(save(root.path(), folder("bad", "Bad", overrides)).is_err());
            assert!(crate::notes::list(root.path()).unwrap().folders.is_empty());
        }
        assert!(note_invalid(root.path(), "missing").is_err());
    }
    fn note_invalid(root: &Path, id: &str) -> Result<CapturedNote> {
        crate::notes::save_note(
            root,
            serde_json::from_value(
                json!({"id":"note","folderID":id,"text":"Draft","createdAt":0,"updatedAt":0}),
            )?,
        )
    }
    #[test]
    fn profile_fingerprint_changes_on_inherited_settings_but_not_ui_preferences() {
        let root = tempfile::tempdir().unwrap();
        save(
            root.path(),
            folder("work", "Работа", json!({"focus":"Решения"})),
        )
        .unwrap();
        crate::storage::atomic_json(
            &root.path().join("settings.json"),
            &json!({"mode":"local","localModel":"first","theme":"dark"}),
        )
        .unwrap();
        let first = resolve(root.path(), None, Some("work"))
            .unwrap()
            .fingerprint;
        crate::storage::atomic_json(
            &root.path().join("settings.json"),
            &json!({"mode":"local","localModel":"first","theme":"light"}),
        )
        .unwrap();
        assert_eq!(
            resolve(root.path(), None, Some("work"))
                .unwrap()
                .fingerprint,
            first
        );
        crate::storage::atomic_json(
            &root.path().join("settings.json"),
            &json!({"mode":"local","localModel":"second","theme":"light"}),
        )
        .unwrap();
        assert_ne!(
            resolve(root.path(), None, Some("work"))
                .unwrap()
                .fingerprint,
            first
        );
    }
    #[test]
    fn policy_reads_committed_sqlite_while_workspace_lock_is_held() {
        let root = tempfile::tempdir().unwrap();
        save(
            root.path(),
            folder("english", "Английский", json!({"features":{"cards":true}})),
        )
        .unwrap();
        let dir = crate::notes::directory(root.path()).unwrap();
        let _lock = crate::notes::lock(&dir).unwrap();
        assert!(available_features(root.path()).unwrap().cards);
        assert_eq!(
            resolve(root.path(), None, Some("english"))
                .unwrap()
                .folder_name
                .as_deref(),
            Some("Английский")
        );
    }
    #[test]
    fn first_policy_read_does_not_create_a_library() {
        let root = tempfile::tempdir().unwrap();
        assert!(!available_features(root.path()).unwrap().cards);
        assert!(std::fs::read_dir(root.path()).unwrap().next().is_none());
    }
    #[test]
    fn future_folder_fields_survive_a_known_profile_edit() {
        let root = tempfile::tempdir().unwrap();
        let mut saved = save(root.path(), folder("english", "Английский", json!({}))).unwrap();
        let snapshot = crate::workspace_repository::snapshot(root.path()).unwrap();
        let mut value = snapshot.value;
        value["folders"][0]["future"] = json!({"kept":true});
        crate::workspace_repository::compare_and_save(root.path(), snapshot.revision, &value)
            .unwrap();
        saved.overrides = json!({"language":"en"});
        save(root.path(), saved).unwrap();
        assert_eq!(
            crate::workspace_repository::snapshot(root.path())
                .unwrap()
                .value["folders"][0]["future"]["kept"],
            true
        );
    }
    #[test]
    fn omitted_defaults_and_explicit_defaults_have_the_same_fingerprint() {
        let root = tempfile::tempdir().unwrap();
        let first = resolve(root.path(), None, None).unwrap().fingerprint;
        let mut settings = serde_json::to_value(crate::ai::Settings::default()).unwrap();
        settings["theme"] = json!("dark");
        crate::storage::atomic_json(&root.path().join("settings.json"), &settings).unwrap();
        assert_eq!(resolve(root.path(), None, None).unwrap().fingerprint, first);
    }
    #[test]
    fn selected_sidebar_folder_never_overrides_existing_meeting_membership() {
        let root = tempfile::tempdir().unwrap();
        meeting(root.path(), "work-call");
        meeting(root.path(), "base-call");
        save(
            root.path(),
            folder("english", "Английский", json!({"language":"en"})),
        )
        .unwrap();
        save(
            root.path(),
            folder("work", "Работа", json!({"language":"ru"})),
        )
        .unwrap();
        assign_meeting(root.path(), "work-call", Some("work"), 0).unwrap();
        assert_eq!(
            resolve(root.path(), Some("work-call"), Some("english"))
                .unwrap()
                .folder_id
                .as_deref(),
            Some("work")
        );
        assert_eq!(
            resolve(root.path(), Some("base-call"), Some("english"))
                .unwrap()
                .folder_id,
            None
        );
    }
}
