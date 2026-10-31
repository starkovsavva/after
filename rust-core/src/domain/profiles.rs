//! Pure folder/profile validation and deterministic legacy normalization.
use super::workspace::{CapturedNote, Folder, NotesWorkspace};
use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
pub(crate) const MAX_FOLDERS: usize = 1_000;
pub(crate) const FEATURES: &[&str] = &["cards", "tasks", "calendar", "assistant", "semanticSearch"];
pub(crate) fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
}
pub(crate) fn bounded(value: &str, max: usize) -> Result<()> {
    ensure!(
        value.len() <= max && !value.contains('\0'),
        "Некорректное или слишком длинное поле профиля папки"
    );
    Ok(())
}
pub(crate) fn one_of(value: &str, allowed: &[&str]) -> Result<()> {
    ensure!(
        allowed.contains(&value),
        "Неизвестное значение настройки папки"
    );
    Ok(())
}
pub(crate) fn endpoint(value: &str, local: bool) -> Result<()> {
    if value.is_empty() {
        return Ok(());
    }
    let url = url::Url::parse(value).context("Некорректный адрес модели в папке")?;
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
            "cloudReasoning" => super::config::validate_reasoning(text),
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
pub(crate) fn bumped(revision: u64) -> Result<u64> {
    revision
        .checked_add(1)
        .context("Слишком большая ревизия папки")
}
pub(crate) fn legacy_id(name: &str) -> String {
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
