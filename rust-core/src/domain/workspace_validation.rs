//! Pure aggregate validation; values do not depend on validators.
use super::workspace::{CapturedNote, NotesWorkspace};
use anyhow::{ensure, Context, Result};
pub(crate) const MAX_TEXT: usize = 100_000;
const MAX_NOTES: usize = 10_000;
pub(crate) fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
pub(crate) fn bounded(value: &str, max: usize, label: &str) -> Result<()> {
    ensure!(
        value.len() <= max && !value.contains('\0'),
        "Слишком длинное или некорректное поле: {label}"
    );
    Ok(())
}
pub(crate) fn validate_note(note: &CapturedNote) -> Result<()> {
    ensure!(valid_id(&note.id), "Некорректный ID заметки");
    ensure!(
        ["note", "important", "question", "task"].contains(&note.kind.as_str()),
        "Неизвестный тип заметки"
    );
    bounded(&note.text, MAX_TEXT, "текст")?;
    bounded(&note.owner, 512, "ответственный")?;
    bounded(&note.due, 512, "срок")?;
    ensure!(
        note.created_at.is_finite()
            && note.created_at >= 0.0
            && note.updated_at.is_finite()
            && note.updated_at >= 0.0,
        "Некорректная дата заметки"
    );
    if let Some(id) = &note.meeting_id {
        ensure!(valid_id(id), "Некорректный ID встречи");
    }
    if let Some(time) = note.timestamp {
        ensure!(
            note.meeting_id.is_some() && time.is_finite() && (0.0..=604_800.0).contains(&time),
            "Некорректный таймкод заметки"
        );
    }
    bounded(&note.title, 1024, "название")?;
    bounded(&note.folder, 256, "папка")?;
    bounded(&note.content_rtf, 2_000_000, "форматирование")?;
    ensure!(
        note.tags.len() <= 30,
        "В заметке можно сохранить до 30 тегов"
    );
    for tag in &note.tags {
        bounded(tag, 128, "тег")?;
    }
    if let Some(time) = note.trashed_at {
        ensure!(
            time.is_finite() && time >= 0.0,
            "Некорректная дата удаления"
        );
    }
    bounded(&note.source_url, 8192, "источник")?;
    if !note.source_url.is_empty() {
        let url = url::Url::parse(&note.source_url)
            .context("Источник должен быть HTTP- или HTTPS-ссылкой")?;
        ensure!(
            ["http", "https"].contains(&url.scheme())
                && url.host_str().is_some()
                && url.username().is_empty()
                && url.password().is_none(),
            "Источник должен быть HTTP- или HTTPS-ссылкой без пароля"
        );
    }
    ensure!(
        note.attachments.len() <= 12,
        "В одной заметке можно сохранить до 12 вложений"
    );
    let mut attachment_ids = std::collections::HashSet::new();
    for attachment in &note.attachments {
        ensure!(
            valid_id(&attachment.id) && attachment_ids.insert(&attachment.id),
            "Некорректный или повторный ID вложения"
        );
        bounded(&attachment.name, 512, "имя вложения")?;
        bounded(&attachment.extracted_text, MAX_TEXT, "распознанный текст")?;
        let expected = format!("notes/attachments/{}.", attachment.id);
        ensure!(
            attachment.relative_path.starts_with(&expected)
                && attachment.relative_path.split('/').count() == 3
                && attachment.relative_path[expected.len()..]
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric()),
            "Некорректный путь вложения"
        );
        let extension = attachment
            .relative_path
            .rsplit_once('.')
            .map(|(_, extension)| extension)
            .unwrap_or("");
        ensure!(
            attachment_type(extension) == Some(attachment.content_type.as_str()),
            "Некорректный тип вложения"
        );
    }
    ensure!(
        note.history.len() <= 1000 && note.subtasks.len() <= 200,
        "Слишком много дополнений или подзадач"
    );
    for entry in &note.history {
        ensure!(
            entry["text"]
                .as_str()
                .is_some_and(|text| text.len() <= MAX_TEXT)
                && entry["id"].as_str().is_some_and(valid_id)
                && entry["createdAt"]
                    .as_f64()
                    .is_some_and(|t| t.is_finite() && t >= 0.0),
            "Некорректная история задачи"
        );
    }
    let mut subtask_ids = std::collections::HashSet::new();
    for entry in &note.subtasks {
        ensure!(
            subtask_ids.insert(entry["id"].as_str()),
            "Повторный ID подзадачи"
        );
        ensure!(
            entry["text"]
                .as_str()
                .is_some_and(|text| !text.trim().is_empty() && text.len() <= 10_000)
                && entry["id"].as_str().is_some_and(valid_id)
                && entry["completed"].as_bool().is_some(),
            "Некорректная подзадача"
        );
    }
    if let Some(origin) = &note.task_origin {
        ensure!(
            note.kind == "task"
                && origin["meetingID"].as_str().is_some_and(valid_id)
                && origin["itemSignature"]
                    .as_str()
                    .is_some_and(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())),
            "Некорректный источник задачи"
        );
    }
    if let Some(expansion) = &note.expansion {
        ensure!(
            expansion.is_object() && serde_json::to_vec(expansion)?.len() <= 200_000,
            "Некорректное дополнение заметки"
        );
    }
    Ok(())
}
pub(crate) fn validate_workspace(data: &NotesWorkspace) -> Result<()> {
    super::task_validation::validate_workspace(data)?;
    super::profiles::validate_workspace(data)?;
    ensure!(
        data.notes.len() <= MAX_NOTES
            && data.templates.len() <= 100
            && data.contexts.len() <= MAX_NOTES,
        "Слишком много заметок или шаблонов"
    );
    ensure!(
        data.voice_plans.len() <= 100 && data.voice_operations.len() <= 500,
        "Слишком много голосовых операций"
    );
    let mut ids = std::collections::HashSet::new();
    for note in &data.notes {
        validate_note(note)?;
        ensure!(ids.insert(&note.id), "Повторный ID заметки");
    }
    let mut ids = std::collections::HashSet::new();
    for template in &data.templates {
        ensure!(
            valid_id(&template.id) && ids.insert(&template.id) && !template.name.trim().is_empty(),
            "Некорректный шаблон"
        );
        bounded(&template.name, 256, "имя шаблона")?;
        bounded(&template.body, MAX_TEXT, "шаблон")?;
        bounded(&template.focus, 10_000, "фокус")?;
    }
    let mut ids = std::collections::HashSet::new();
    for context in &data.contexts {
        ensure!(
            valid_id(&context.meeting_id) && ids.insert(&context.meeting_id),
            "Некорректный контекст встречи"
        );
        bounded(&context.project, 512, "проект")?;
        bounded(&context.person, 512, "собеседник")?;
        if let Some(id) = &context.template_id {
            ensure!(valid_id(id), "Некорректный ID шаблона");
        }
    }
    Ok(())
}
pub(crate) fn attachment_type(extension: &str) -> Option<&'static str> {
    match extension {
        "png" => Some("image/png"),
        "jpg" | "jpeg" => Some("image/jpeg"),
        "heic" => Some("image/heic"),
        "gif" => Some("image/gif"),
        "tif" | "tiff" => Some("image/tiff"),
        "webp" => Some("image/webp"),
        "pdf" => Some("application/pdf"),
        "txt" | "md" => Some("text/plain"),
        _ => None,
    }
}
