//! User-authored notes, attachments and meeting preparation. Canonical SQLite
//! snapshots are changed under a process-wide file lock. Per-entity revisions
//! prevent a quick-capture panel from silently overwriting a newer editor save.
use anyhow::{bail, ensure, Context, Result};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::Read;
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use uuid::Uuid;

const MAX_ATTACHMENT: u64 = 25 * 1_048_576;
const MAX_TEXT: usize = 100_000;
const MAX_NOTES: usize = 10_000;
const CONFLICT: &str = "Заметка уже изменена в другом окне. Обновите данные; ваш текст остаётся в редакторе.";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NoteAttachment {
    pub id: String, pub name: String, pub relative_path: String,
    pub content_type: String, #[serde(default)] pub extracted_text: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CapturedNote {
    pub id: String, #[serde(default)] pub text: String,
    #[serde(default = "note_kind")] pub kind: String,
    #[serde(default, rename = "meetingID", alias = "meetingId")] pub meeting_id: Option<String>,
    #[serde(default)] pub timestamp: Option<f64>,
    pub created_at: f64, pub updated_at: f64,
    #[serde(default)] pub revision: u64,
    #[serde(default, rename = "sourceURL", alias = "sourceUrl")] pub source_url: String,
    #[serde(default)] pub owner: String, #[serde(default)] pub due: String,
    #[serde(default)] pub completed: bool,
    #[serde(default)] pub title: String,
    #[serde(default, rename="contentRTF", alias="contentRtf")] pub content_rtf: String,
    #[serde(default)] pub folder: String,
    #[serde(default, rename="folderID", alias="folderId")] pub folder_id: Option<String>,
    #[serde(default)] pub tags: Vec<String>,
    #[serde(default)] pub pinned: bool,
    #[serde(default)] pub trashed_at: Option<f64>,
    #[serde(default)] pub attachments: Vec<NoteAttachment>,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub expansion: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub task_origin: Option<Value>,
    #[serde(default)] pub history: Vec<Value>,
    #[serde(default)] pub subtasks: Vec<Value>,
}
fn note_kind() -> String { "note".into() }
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteTemplate {
    pub id: String, pub name: String, pub body: String,
    #[serde(default)] pub focus: String, #[serde(default)] pub revision: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeetingContext {
    #[serde(rename = "meetingID", alias = "meetingId")] pub meeting_id: String, #[serde(default)] pub project: String,
    #[serde(default)] pub person: String, #[serde(default, rename = "templateID", alias = "templateId")] pub template_id: Option<String>,
    #[serde(default, rename="folderID", alias="folderId")] pub folder_id: Option<String>,
    #[serde(default)] pub revision: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotesWorkspace {
    #[serde(default)] pub folders: Vec<crate::folders::Folder>,
    #[serde(default)] pub notes: Vec<CapturedNote>,
    #[serde(default)] pub templates: Vec<NoteTemplate>,
    #[serde(default)] pub contexts: Vec<MeetingContext>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")] pub voice_plans: Vec<Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")] pub voice_operations: Vec<Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")] pub task_workspaces: Vec<crate::task_workspace::TaskRecord>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")] pub task_plans: Vec<Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")] pub task_operations: Vec<Value>,
    #[serde(default)] pub task_integration: crate::task_workspace::TaskIntegration,
}
pub(crate) fn defaults() -> NotesWorkspace {
    let templates = [
        ("purchases", "Закупки", "Цель встречи\n\nВопросы\n• Цена и скидки\n• Минимальная партия\n• Доставка\n• Оплата\n\nДоговорённости\n\nЧто уточнить", "Точные цены, валюты, скидки, объёмы, сроки доставки и оплаты. Отдельно — условия и открытые вопросы."),
        ("interview", "Собеседование", "Роль и контекст\n\nМои вопросы\n\nСильные ответы\n\nПробелы и что повторить\n\nСледующие шаги", "Вопросы собеседования, ответы, пробелы в знаниях и темы для повторения. Не додумывай оценки кандидата."),
        ("one-on-one", "Один на один", "Как дела\n\nЧто получилось\n\nЧто мешает\n\nОбратная связь\n\nДоговорённости", "Обратная связь, препятствия, ожидания и договорённости. Отделяй мнение от подтверждённых фактов."),
        ("english", "Английский", "Тема разговора\n\nНовые фразы\n\nЧто было трудно сказать\n\nОшибки и исправления\n\nЧто повторить", "Полезные английские фразы с контекстом, переводом и исправлениями, только если они подтверждены записью."),
    ].into_iter().map(|(id,name,body,focus)| NoteTemplate { id:id.into(),name:name.into(),body:body.into(),focus:focus.into(),revision:1 }).collect();
    NotesWorkspace { folders:vec![],notes:vec![],templates,contexts:vec![],voice_plans:vec![],voice_operations:vec![],task_workspaces:vec![],task_plans:vec![],task_operations:vec![],task_integration:Default::default() }
}
fn valid_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128 && value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
#[cfg(unix)]
fn private_directory(path: &Path) -> Result<()> {
    if let Ok(info) = fs::symlink_metadata(path) {
        ensure!(info.is_dir() && !info.file_type().is_symlink(), "Папка заметок не должна быть ссылкой");
    }
    DirBuilder::new().recursive(true).mode(0o700).create(path)?;
    let info = fs::symlink_metadata(path)?;
    ensure!(info.is_dir() && !info.file_type().is_symlink(), "Некорректная папка заметок");
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}
#[cfg(windows)]
fn private_directory(path: &Path) -> Result<()> { crate::platform_fs::private_directory(path) }
pub(crate) fn directory(root: &Path) -> Result<PathBuf> {
    ensure!(root.is_absolute(), "Папка данных должна иметь абсолютный путь");
    private_directory(root)?;
    let directory = root.join("notes"); private_directory(&directory)?;
    Ok(directory)
}
fn regular(path: &Path, max: u64) -> Result<File> {
    let info = fs::symlink_metadata(path)?;
    ensure!(info.is_file() && !info.file_type().is_symlink() && info.len() <= max, "Ожидался обычный файл допустимого размера");
    let file = crate::platform_fs::open_read(path)?;
    ensure!(file.metadata()?.is_file() && file.metadata()?.len() <= max, "Файл слишком большой");
    Ok(file)
}
pub(crate) fn lock(directory: &Path) -> Result<File> {
    let path = directory.join(".workspace.lock");
    if let Ok(info) = fs::symlink_metadata(&path) { ensure!(info.is_file() && !info.file_type().is_symlink(), "Некорректная блокировка заметок"); }
    let file = crate::platform_fs::open_private(&path,false)?;
    crate::platform_fs::secure_file(&file)?;
    file.lock().context("Не удалось заблокировать заметки")?;
    Ok(file)
}
pub(crate) fn load(directory: &Path) -> Result<NotesWorkspace> {
    crate::corrections::recover_notes_transaction(directory)?;
    let snapshot = crate::workspace_repository::load_locked(directory)?;
    serde_json::from_value(snapshot.value).context("Не удалось прочитать заметки. База сохранена.")
}
pub(crate) fn persist(directory: &Path, data: &NotesWorkspace) -> Result<()> {
    validate_workspace(data)?;
    crate::workspace_repository::persist_locked(directory, data)?;
    Ok(())
}
fn bounded(value: &str, max: usize, label: &str) -> Result<()> {
    ensure!(value.len() <= max && !value.contains('\0'), "Слишком длинное или некорректное поле: {label}"); Ok(())
}
fn validate_note(note: &CapturedNote) -> Result<()> {
    ensure!(valid_id(&note.id), "Некорректный ID заметки");
    ensure!(["note","important","question","task"].contains(&note.kind.as_str()), "Неизвестный тип заметки");
    bounded(&note.text,MAX_TEXT,"текст")?; bounded(&note.owner,512,"ответственный")?; bounded(&note.due,512,"срок")?;
    ensure!(note.created_at.is_finite() && note.created_at >= 0.0 && note.updated_at.is_finite() && note.updated_at >= 0.0, "Некорректная дата заметки");
    if let Some(id) = &note.meeting_id { ensure!(valid_id(id), "Некорректный ID встречи"); }
    if let Some(time) = note.timestamp { ensure!(note.meeting_id.is_some() && time.is_finite() && (0.0..=604_800.0).contains(&time), "Некорректный таймкод заметки"); }
    bounded(&note.title,1024,"название")?; bounded(&note.folder,256,"папка")?;
    bounded(&note.content_rtf,2_000_000,"форматирование")?;
    ensure!(note.tags.len() <= 30,"В заметке можно сохранить до 30 тегов");
    for tag in &note.tags { bounded(tag,128,"тег")?; }
    if let Some(time)=note.trashed_at { ensure!(time.is_finite() && time >= 0.0,"Некорректная дата удаления"); }
    bounded(&note.source_url,8192,"источник")?;
    if !note.source_url.is_empty() {
        let url = reqwest::Url::parse(&note.source_url).context("Источник должен быть HTTP- или HTTPS-ссылкой")?;
        ensure!(["http","https"].contains(&url.scheme()) && url.host_str().is_some() && url.username().is_empty() && url.password().is_none(), "Источник должен быть HTTP- или HTTPS-ссылкой без пароля");
    }
    ensure!(note.attachments.len() <= 12,"В одной заметке можно сохранить до 12 вложений");
    let mut attachment_ids = std::collections::HashSet::new();
    for attachment in &note.attachments {
        ensure!(valid_id(&attachment.id) && attachment_ids.insert(&attachment.id), "Некорректный или повторный ID вложения");
        bounded(&attachment.name,512,"имя вложения")?; bounded(&attachment.extracted_text,MAX_TEXT,"распознанный текст")?;
        let expected = format!("notes/attachments/{}.",attachment.id);
        ensure!(attachment.relative_path.starts_with(&expected) && Path::new(&attachment.relative_path).components().count() == 3 && attachment.relative_path[expected.len()..].bytes().all(|b|b.is_ascii_alphanumeric()), "Некорректный путь вложения");
        let extension=Path::new(&attachment.relative_path).extension().and_then(|s|s.to_str()).unwrap_or("");
        ensure!(attachment_type(extension)==Some(attachment.content_type.as_str()),"Некорректный тип вложения");
    }
    ensure!(note.history.len() <= 1000 && note.subtasks.len() <= 200, "Слишком много дополнений или подзадач");
    for entry in &note.history { ensure!(entry["text"].as_str().is_some_and(|text|text.len() <= MAX_TEXT) && entry["id"].as_str().is_some_and(valid_id) && entry["createdAt"].as_f64().is_some_and(|t|t.is_finite()&&t>=0.0), "Некорректная история задачи"); }
    let mut subtask_ids=std::collections::HashSet::new();
    for entry in &note.subtasks { ensure!(subtask_ids.insert(entry["id"].as_str()),"Повторный ID подзадачи"); ensure!(entry["text"].as_str().is_some_and(|text|!text.trim().is_empty()&&text.len()<=10_000) && entry["id"].as_str().is_some_and(valid_id) && entry["completed"].as_bool().is_some(), "Некорректная подзадача"); }
    if let Some(origin)=&note.task_origin { ensure!(note.kind=="task" && origin["meetingID"].as_str().is_some_and(valid_id) && origin["itemSignature"].as_str().is_some_and(|s|s.len()==64&&s.bytes().all(|b|b.is_ascii_hexdigit())), "Некорректный источник задачи"); }
    if let Some(expansion) = &note.expansion { ensure!(expansion.is_object() && serde_json::to_vec(expansion)?.len() <= 200_000, "Некорректное дополнение заметки"); }
    Ok(())
}
pub(crate) fn validate_workspace(data: &NotesWorkspace) -> Result<()> {
    crate::task_workspace::validate_workspace(data)?;
    crate::folders::validate_workspace(data)?;
    ensure!(data.notes.len() <= MAX_NOTES && data.templates.len() <= 100 && data.contexts.len() <= MAX_NOTES,"Слишком много заметок или шаблонов");
    ensure!(data.voice_plans.len() <= 100 && data.voice_operations.len() <= 500, "Слишком много голосовых операций");
    let mut ids = std::collections::HashSet::new();
    for note in &data.notes { validate_note(note)?; ensure!(ids.insert(&note.id),"Повторный ID заметки"); }
    let mut ids = std::collections::HashSet::new();
    for template in &data.templates {
        ensure!(valid_id(&template.id) && ids.insert(&template.id) && !template.name.trim().is_empty(),"Некорректный шаблон");
        bounded(&template.name,256,"имя шаблона")?; bounded(&template.body,MAX_TEXT,"шаблон")?; bounded(&template.focus,10_000,"фокус")?;
    }
    let mut ids = std::collections::HashSet::new();
    for context in &data.contexts {
        ensure!(valid_id(&context.meeting_id) && ids.insert(&context.meeting_id),"Некорректный контекст встречи");
        bounded(&context.project,512,"проект")?; bounded(&context.person,512,"собеседник")?;
        if let Some(id) = &context.template_id { ensure!(valid_id(id),"Некорректный ID шаблона"); }
    }
    Ok(())
}
fn ensure_meeting(root: &Path, id: Option<&str>) -> Result<()> {
    if let Some(id) = id {
        let path = crate::storage::meeting_directory(root,id)?;
        let mut bytes=Vec::new(); regular(&path.join("meta.json"),1_048_576)?.take(1_048_577).read_to_end(&mut bytes)?;
        let meta:Value=serde_json::from_slice(&bytes)?;
        ensure!(meta["id"].as_str() == Some(id), "Встреча не найдена");
    }
    Ok(())
}
fn now() -> f64 { Utc::now().timestamp_millis() as f64 / 1000.0 }
fn bumped(revision: u64) -> Result<u64> { revision.checked_add(1).context("Слишком большая ревизия заметки") }
fn expected<'a>(data: &'a mut NotesWorkspace,id: &str,revision: u64) -> Result<&'a mut CapturedNote> {
    let note = data.notes.iter_mut().find(|n|n.id == id).context("Заметка уже удалена. Ваш текст остаётся в редакторе.")?;
    ensure!(note.revision == revision, CONFLICT); Ok(note)
}
pub fn list(root: &Path) -> Result<NotesWorkspace> {
    let dir = directory(root)?; let _lock=lock(&dir)?; load(&dir)
}
pub fn save_note(root: &Path,mut note: CapturedNote) -> Result<CapturedNote> {
    validate_note(&note)?;
    let dir=directory(root)?; let _lock=lock(&dir)?; let mut data=load(&dir)?;
    crate::folders::normalize_note_folder(&mut data,&mut note)?;
    if let Some(index)=data.notes.iter().position(|n|n.id == note.id) {
        let old=&data.notes[index]; ensure!(old.revision == note.revision, CONFLICT);
        ensure!(old.trashed_at == note.trashed_at,"Состояние Корзины изменилось. Обновите заметку.");
        // Provenance and append history belong to the operation journal. Older
        // editors which do not encode these fields must preserve them too.
        note.task_origin=old.task_origin.clone(); note.history=old.history.clone();
        // Plain-text edits made by older editor surfaces must not retain stale rich content.
        if old.text != note.text && old.content_rtf == note.content_rtf { note.content_rtf.clear(); }
        // Trashing a meeting must not make the user's independent note
        // read-only or erase its historical timestamp/link. Validate only a
        // newly introduced target; retaining an old ID reads no meeting files.
        if old.meeting_id != note.meeting_id { ensure_meeting(root,note.meeting_id.as_deref())?; }
        ensure!(old.attachments == note.attachments, "Вложения изменились. Обновите заметку перед сохранением.");
        ensure!(old.expansion.is_some() || note.expansion.is_none(), "Дополнение ИИ сохраняется отдельной командой");
        // Treat the client copy as a presence flag only: Swift can encode 1.0
        // as 1. The authoritative grounded object is never replaced by note-save.
        if note.expansion.is_some() { note.expansion=old.expansion.clone(); }
        if old.text != note.text || old.meeting_id != note.meeting_id || old.timestamp != note.timestamp { note.expansion=None; }
        note.created_at=old.created_at; note.revision=bumped(old.revision)?; note.updated_at=now();
        data.notes[index]=note.clone();
    } else {
        ensure!(note.revision == 0, CONFLICT);
        ensure_meeting(root,note.meeting_id.as_deref())?;
        ensure!(note.attachments.is_empty() && note.expansion.is_none(), "Создайте заметку перед добавлением вложений");
        note.created_at=now(); note.updated_at=note.created_at; note.revision=1; data.notes.push(note.clone());
    }
    persist(&dir,&data)?; Ok(note)
}
pub fn trash_note(root:&Path,id:&str,revision:u64,restore:bool) -> Result<CapturedNote> {
    let dir=directory(root)?; let _lock=lock(&dir)?; let mut data=load(&dir)?;
    let note=expected(&mut data,id,revision)?;
    if restore {
        ensure!(note.trashed_at.is_some_and(|deleted| deleted <= now() && now()-deleted < crate::storage::TRASH_RETENTION_SECONDS), "Срок восстановления заметки истёк");
    }
    note.trashed_at=if restore { None } else { note.trashed_at.or_else(||Some(now())) };
    note.revision=bumped(note.revision)?; note.updated_at=now();
    let result=note.clone(); persist(&dir,&data)?; Ok(result)
}
pub(crate) fn is_task_tombstone(note: &CapturedNote) -> bool {
    note.task_origin.as_ref().is_some_and(|origin| origin["sourceText"] == "")
        && note.trashed_at.is_some_and(|deleted| now()-deleted >= crate::storage::TRASH_RETENTION_SECONDS)
        && note.text.is_empty() && note.title.is_empty() && note.attachments.is_empty()
}
pub fn delete_note(root:&Path,id:&str,revision:u64) -> Result<Value> {
    let dir=directory(root)?; let _lock=lock(&dir)?; let mut data=load(&dir)?;
    let current=expected(&mut data,id,revision)?;
    if is_task_tombstone(current) { return Ok(json!({"deleted":true})); }
    let attachments=current.attachments.clone();
    if let Some(note)=data.notes.iter_mut().find(|note|note.id==id && note.task_origin.is_some()) {
        // Keep only a source tombstone: otherwise the unchanged summary would
        // re-create a deleted task after retention cleanup.
        let origin=note.task_origin.as_ref().unwrap();
        note.task_origin=Some(json!({"meetingID":origin["meetingID"],"itemSignature":origin["itemSignature"],"sourceText":"","segmentIDs":[],"summaryTaskID":""}));
        note.text.clear(); note.title.clear(); note.content_rtf.clear(); note.owner.clear(); note.due.clear();
        note.source_url.clear(); note.tags.clear(); note.attachments.clear(); note.history.clear(); note.subtasks.clear(); note.expansion=None;
        note.trashed_at=Some(now()-crate::storage::TRASH_RETENTION_SECONDS-1.0); note.revision=bumped(note.revision)?; note.updated_at=now();
    } else { data.notes.retain(|note|note.id != id); }
    persist(&dir,&data)?;
    for attachment in attachments { let _=remove_owned_attachment(root,&attachment); }
    Ok(json!({"deleted":true}))
}
pub fn save_context(root:&Path,mut context:MeetingContext) -> Result<MeetingContext> {
    let dir=directory(root)?; let _lock=lock(&dir)?; let mut data=load(&dir)?;
    ensure_meeting(root,Some(&context.meeting_id))?;
    if let Some(id)=&context.template_id { ensure!(data.templates.iter().any(|t|&t.id == id),"Шаблон не найден"); }
    if let Some(index)=data.contexts.iter().position(|c|c.meeting_id == context.meeting_id) {
        ensure!(data.contexts[index].revision == context.revision,"Контекст уже изменён. Обновите данные.");
        context.revision=bumped(context.revision)?; data.contexts[index]=context.clone();
    } else { ensure!(context.revision == 0,"Контекст уже изменён. Обновите данные."); context.revision=1; data.contexts.push(context.clone()); }
    persist(&dir,&data)?; Ok(context)
}
pub fn save_template(root:&Path,mut template:NoteTemplate) -> Result<NoteTemplate> {
    let dir=directory(root)?; let _lock=lock(&dir)?; let mut data=load(&dir)?;
    if let Some(index)=data.templates.iter().position(|t|t.id == template.id) {
        ensure!(data.templates[index].revision == template.revision,"Шаблон уже изменён. Обновите данные.");
        template.revision=bumped(template.revision)?; data.templates[index]=template.clone();
    } else { ensure!(template.revision == 0,"Шаблон уже изменён. Обновите данные."); template.revision=1; data.templates.push(template.clone()); }
    persist(&dir,&data)?; Ok(template)
}
pub fn delete_template(root:&Path,id:&str,revision:u64) -> Result<Value> {
    let dir=directory(root)?; let _lock=lock(&dir)?; let mut data=load(&dir)?;
    let template=data.templates.iter().find(|t|t.id == id).context("Шаблон уже удалён")?;
    ensure!(template.revision == revision,"Шаблон уже изменён. Обновите данные.");
    data.templates.retain(|t|t.id != id);
    for context in &mut data.contexts { if context.template_id.as_deref()==Some(id) { context.template_id=None; context.revision=bumped(context.revision)?; } }
    persist(&dir,&data)?; Ok(json!({"deleted":true}))
}
fn attachment_folder(root:&Path) -> Result<PathBuf> {
    let dir=directory(root)?.join("attachments"); private_directory(&dir)?; Ok(dir)
}
fn attachment_type(extension:&str) -> Option<&'static str> {
    match extension {
        "png"=>Some("image/png"),"jpg"|"jpeg"=>Some("image/jpeg"),"heic"=>Some("image/heic"),
        "gif"=>Some("image/gif"),"tif"|"tiff"=>Some("image/tiff"),"webp"=>Some("image/webp"),
        "pdf"=>Some("application/pdf"),"txt"|"md"=>Some("text/plain"),_=>None,
    }
}
fn attachment_file(root:&Path,attachment:&NoteAttachment) -> Result<PathBuf> {
    let folder=attachment_folder(root)?;
    let filename=Path::new(&attachment.relative_path).file_name().context("Некорректное вложение")?;
    let expected=format!("notes/attachments/{}",filename.to_string_lossy());
    ensure!(attachment.relative_path==expected,"Некорректное вложение");
    Ok(folder.join(filename))
}
fn remove_owned_attachment(root:&Path,attachment:&NoteAttachment) -> Result<()> {
    let path=attachment_file(root,attachment)?;
    let info=fs::symlink_metadata(&path)?;
    ensure!(info.is_file() && !info.file_type().is_symlink(),"Некорректное вложение");
    fs::remove_file(path)?; Ok(())
}
pub fn attach(root:&Path,id:&str,revision:u64,source:&Path) -> Result<CapturedNote> {
    // Only user-selected supported documents are copied; no hard links or
    // original-path references can let later app writes change the original.
    ensure!(source.is_absolute(),"Выберите файл вложения");
    let source=source.canonicalize().context("Не удалось открыть вложение")?;
    let extension=source.extension().and_then(|s|s.to_str()).unwrap_or("").to_ascii_lowercase();
    let content_type=attachment_type(&extension).context("Добавьте изображение, PDF или текстовый файл")?;
    let mut input=regular(&source,MAX_ATTACHMENT)?;
    let name=source.file_name().and_then(|s|s.to_str()).context("Некорректное имя вложения")?.to_owned();
    bounded(&name,512,"имя вложения")?;
    let dir=directory(root)?; let _lock=lock(&dir)?; let mut data=load(&dir)?;
    ensure!(expected(&mut data,id,revision)?.attachments.len()<12,"В одной заметке можно сохранить до 12 вложений");
    let attachment_id=Uuid::new_v4().to_string(); let filename=format!("{attachment_id}.{extension}");
    let destination=attachment_folder(root)?.join(&filename);
    let mut output=crate::platform_fs::open_private(&destination,true)?;
    let result=(|| -> Result<CapturedNote> {
        let copied=std::io::copy(&mut (&mut input).take(MAX_ATTACHMENT+1),&mut output)?;
        ensure!(copied<=MAX_ATTACHMENT,"Вложение должно быть не больше 25 МБ"); output.sync_all()?;
        let mut extracted_text=String::new();
        if content_type=="text/plain" {
            let mut bytes=Vec::new(); regular(&destination,MAX_ATTACHMENT)?.take(MAX_TEXT as u64+1).read_to_end(&mut bytes)?;
            if bytes.len()<=MAX_TEXT { extracted_text=String::from_utf8(bytes).context("Текстовый файл должен быть в UTF-8")?; bounded(&extracted_text,MAX_TEXT,"текст вложения")?; }
        }
        let note=expected(&mut data,id,revision)?;
        note.attachments.push(NoteAttachment{id:attachment_id,name,relative_path:format!("notes/attachments/{filename}"),content_type:content_type.into(),extracted_text});
        note.expansion=None; note.revision=bumped(note.revision)?; note.updated_at=now(); let result=note.clone();
        persist(&dir,&data)?; Ok(result)
    })();
    if result.is_err() { let _=fs::remove_file(&destination); }
    result
}
pub fn attachment_path(root:&Path,id:&str,attachment_id:&str) -> Result<Value> {
    let dir=directory(root)?; let _lock=lock(&dir)?; let data=load(&dir)?;
    let attachment=data.notes.iter().find(|n|n.id==id).and_then(|n|n.attachments.iter().find(|a|a.id==attachment_id)).context("Вложение не найдено")?;
    let path=attachment_file(root,attachment)?; regular(&path,MAX_ATTACHMENT)?;
    Ok(json!({"path":path}))
}
pub fn remove_attachment(root:&Path,id:&str,revision:u64,attachment_id:&str) -> Result<CapturedNote> {
    let dir=directory(root)?; let _lock=lock(&dir)?; let mut data=load(&dir)?;
    let note=expected(&mut data,id,revision)?;
    let attachment=note.attachments.iter().find(|a|a.id==attachment_id).context("Вложение уже удалено")?.clone();
    note.attachments.retain(|a|a.id!=attachment_id); note.expansion=None; note.revision=bumped(note.revision)?; note.updated_at=now();
    let result=note.clone(); persist(&dir,&data)?; let _=remove_owned_attachment(root,&attachment); Ok(result)
}
pub fn attachment_text(root:&Path,id:&str,revision:u64,attachment_id:&str,text:&str) -> Result<CapturedNote> {
    bounded(text,MAX_TEXT,"распознанный текст")?;
    let dir=directory(root)?; let _lock=lock(&dir)?; let mut data=load(&dir)?;
    let note=expected(&mut data,id,revision)?;
    let attachment=note.attachments.iter_mut().find(|a|a.id==attachment_id).context("Вложение уже удалено")?;
    regular(&attachment_file(root,attachment)?,MAX_ATTACHMENT)?; attachment.extracted_text=text.into();
    note.expansion=None; note.revision=bumped(note.revision)?; note.updated_at=now(); let result=note.clone(); persist(&dir,&data)?; Ok(result)
}
pub fn search(root:&Path,query:&str,scope:&str,meeting_id:Option<&str>) -> Result<Value> {
    ensure!(["all","tasks"].contains(&scope),"Неизвестная область заметок");
    let data=list(root)?;
    let mut notes=Vec::new();
    let matcher=crate::search::QueryMatcher::new(query)?;
    for note in data.notes {
        if note.trashed_at.is_some() { continue; }
        if scope=="tasks" && note.kind!="task" { continue; }
        if meeting_id.is_some_and(|id|note.meeting_id.as_deref()!=Some(id)) { continue; }
        let body=format!("{} {} {} {} {} {} {} {}",note.title,note.folder,note.tags.join(" "),note.text,note.owner,note.due,note.source_url,note.attachments.iter().map(|a|format!("{} {}",a.name,a.extracted_text)).collect::<Vec<_>>().join(" "));
        if matcher.matches(&body) { notes.push(note); }
    }
    notes.sort_by(|a,b|b.updated_at.total_cmp(&a.updated_at));
    Ok(json!({"notes":notes}))
}
pub fn dispatch(root:&Path,value:&Value) -> Result<Value> {
    let string=|key:&str|value[key].as_str().with_context(||format!("Нет поля {key}"));
    let revision=||value["revision"].as_u64().context("Нет ревизии заметки");
    match value["command"].as_str().unwrap_or("") {
        "notes-list"=>{let data=list(root)?;Ok(json!({"notes":data.notes,"templates":data.templates,"contexts":data.contexts,"folders":data.folders}))},
        "note-save"=>Ok(serde_json::to_value(save_note(root,serde_json::from_value(value["note"].clone())?)?)?),
        "note-delete"=>delete_note(root,string("id")?,revision()?),
        "note-trash"|"note-restore"=>Ok(serde_json::to_value(trash_note(root,string("id")?,revision()?,value["command"]=="note-restore")?)?),
        "context-save"=>Ok(serde_json::to_value(save_context(root,serde_json::from_value(value["context"].clone())?)?)?),
        "template-save"=>Ok(serde_json::to_value(save_template(root,serde_json::from_value(value["template"].clone())?)?)?),
        "template-delete"=>delete_template(root,string("id")?,revision()?),
        "note-attach"=>Ok(serde_json::to_value(attach(root,string("noteID")?,revision()?,Path::new(string("path")?))?)?),
        "attachment-path"=>attachment_path(root,string("noteID")?,string("attachmentID")?),
        "attachment-remove"=>Ok(serde_json::to_value(remove_attachment(root,string("noteID")?,revision()?,string("attachmentID")?)?)?),
        "attachment-text"=>Ok(serde_json::to_value(attachment_text(root,string("noteID")?,revision()?,string("attachmentID")?,string("text")?)?)?),
        "notes-tasks"=>tasks(root),
        "notes-task-complete"=>complete_task_checked(root,string("meetingID")?,value["itemIndex"].as_u64().context("Нет номера задачи")? as usize,string("text")?,value["completed"].as_bool().context("Нет статуса задачи")?,value.get("expectedSegmentIDs")),
        "notes-brief"=>brief(root,string("meetingID")?),
        "note-expansion-validate"|"note-expansion-valid"=>Ok(json!({"valid":expansion_valid(root,string("noteID")?)?})),
        "notes-search"=>search(root,value["query"].as_str().unwrap_or(""),value["scope"].as_str().unwrap_or("all"),value["meetingID"].as_str()),
        "note-search-validate"=>Ok(json!({"valid":list(root)?.notes.iter().any(|n|n.trashed_at.is_none() && n.id==value["noteID"].as_str().unwrap_or("") && n.revision==value["revision"].as_u64().unwrap_or(0))})),
        _=>bail!("Неизвестная команда заметок"),
    }
}

pub fn load_note_snapshot(root:&Path,id:&str) -> Result<CapturedNote> {
    ensure!(valid_id(id),"Некорректный ID заметки");
    list(root)?.notes.into_iter().find(|note|note.id==id && note.trashed_at.is_none()).context("Заметка не найдена")
}
fn transcript_snapshot(root:&Path,meeting_id:&str) -> Result<(Value,String)> {
    ensure_meeting(root,Some(meeting_id))?;
    let path=crate::storage::meeting_directory(root,meeting_id)?.join("transcript.json");
    let mut bytes=Vec::new(); regular(&path,64*1_048_576)?.take(64*1_048_576+1).read_to_end(&mut bytes)?;
    ensure!(bytes.len()<=64*1_048_576,"Транскрипт слишком большой");
    let fingerprint=format!("{:x}",Sha256::digest(&bytes));
    Ok((serde_json::from_slice(&bytes)?,fingerprint))
}
fn validate_expansion(expansion:&Value,transcript:&Value,fingerprint:&str) -> Result<()> {
    ensure!(expansion["sourceFingerprint"].as_str()==Some(fingerprint),"Транскрипт изменился. Повторите дополнение заметки.");
    let segments=transcript["segments"].as_array().context("Нет реплик транскрипта")?;
    let mut ids=std::collections::HashSet::new();
    for segment in segments {
        let id=segment["id"].as_u64().context("Некорректный ID реплики")?;
        ensure!(ids.insert(id),"Повторный ID реплики");
    }
    let statements=expansion["statements"].as_array().context("Нет утверждений дополнения")?;
    ensure!(statements.len()<=40,"Слишком много утверждений дополнения");
    for statement in statements {
        let text=statement["text"].as_str().context("Нет текста утверждения")?;
        ensure!(!text.trim().is_empty(),"Пустое утверждение"); bounded(text,6000,"утверждение")?;
        let refs=statement["segmentIDs"].as_array().context("Нет ссылок на реплики")?;
        ensure!(!refs.is_empty() && refs.len()<=100 && refs.iter().all(|id|id.as_u64().is_some_and(|id|ids.contains(&id))),"Дополнение ссылается на отсутствующую реплику");
    }
    for field in ["openQuestions","warnings"] {
        let values=expansion[field].as_array().with_context(||format!("Нет поля {field}"))?;
        ensure!(values.len()<=40,"Слишком много вопросов или предупреждений");
        for value in values { bounded(value.as_str().context("Ожидался текст")?,6000,field)?; }
    }
    for field in ["provider","model"] { bounded(expansion[field].as_str().context("Нет модели дополнения")?,512,field)?; }
    ensure!(expansion["generatedAt"].as_f64().is_some_and(|date|date.is_finite()&&date>=0.0),"Некорректная дата дополнения");
    Ok(())
}
pub fn save_expansion_checked(root:&Path,id:&str,revision:u64,expected_transcript_fingerprint:&str,expansion:Value) -> Result<CapturedNote> {
    ensure!(serde_json::to_vec(&expansion)?.len()<=200_000,"Слишком большое дополнение заметки");
    let dir=directory(root)?; let _lock=lock(&dir)?; let mut data=load(&dir)?;
    let note=expected(&mut data,id,revision)?;
    let meeting_id=note.meeting_id.as_deref().context("Привяжите заметку к встрече перед дополнением")?;
    // Serialize the source check and note commit with transcription publication.
    let meeting_dir=crate::storage::meeting_directory(root,meeting_id)?;
    let _source_lock=crate::storage::meeting_lock(&meeting_dir)?;
    let (transcript,current)=transcript_snapshot(root,meeting_id)?;
    ensure!(current==expected_transcript_fingerprint,"Транскрипт изменился. Повторите дополнение заметки.");
    validate_expansion(&expansion,&transcript,&current)?;
    note.expansion=Some(expansion); note.revision=bumped(note.revision)?; note.updated_at=now();
    let result=note.clone(); persist(&dir,&data)?; Ok(result)
}
pub fn expansion_valid(root:&Path,id:&str) -> Result<bool> {
    let note=load_note_snapshot(root,id)?;
    let (Some(expansion),Some(meeting_id))=(&note.expansion,note.meeting_id.as_deref()) else { return Ok(false); };
    let Ok((transcript,fingerprint))=transcript_snapshot(root,meeting_id) else { return Ok(false); };
    Ok(validate_expansion(expansion,&transcript,&fingerprint).is_ok())
}
/// Adapt manual notes to the existing search shape. Navigation validates note
/// revision rather than a meeting fingerprint, including notes in the inbox.
pub fn search_hits(root:&Path,query:&str) -> Result<Vec<Value>> {
    let result=search(root,query,"all",None)?;
    let meetings=crate::storage::list_meetings(root)?;
    let mut hits=Vec::new();
    for raw in result["notes"].as_array().context("Нет результатов заметок")? {
        let note:CapturedNote=serde_json::from_value(raw.clone())?;
        let title=if let Some(id)=note.meeting_id.as_deref() { meetings.iter().find(|m|m["id"].as_str()==Some(id)).and_then(|m|m["title"].as_str()).unwrap_or("Встреча недоступна") } else { "Входящие заметки" };
        let content=format!("{} {} {} {} {} {} {} {}",note.title,note.folder,note.tags.join(" "),note.text,note.owner,note.due,note.source_url,note.attachments.iter().map(|a|format!("{} {}",a.name,a.extracted_text)).collect::<Vec<_>>().join(" "));
        let snippet=crate::search::query_excerpt(&content,query)?;
        hits.push(json!({"id":format!("manual:{}",note.id),"meetingID":note.meeting_id.clone().unwrap_or_default(),"meetingTitle":title,
            "createdAt":note.created_at,"kind":"manual","noteKind":note.kind,"text":note.text,"snippet":snippet,"segmentIDs":[],"itemIndex":null,"cardID":null,
            "start":note.timestamp,"sourceFingerprint":format!("note:{}",note.revision),"noteID":note.id,"noteRevision":note.revision}));
    }
    Ok(hits)
}
pub(crate) fn task_signature(item:&Value) -> String {
    format!("{:x}",Sha256::digest(serde_json::to_vec(&json!([item["text"],item["segmentIDs"]])).expect("JSON value")))
}
pub fn tasks(root:&Path) -> Result<Value> {
    let workspace=list(root)?; let meetings=crate::storage::list_meetings(root)?;
    let mut tasks=Vec::new();
    for note in workspace.notes.iter().filter(|n|n.kind=="task" && n.trashed_at.is_none()) {
        let meeting=meetings.iter().find(|m|m["id"].as_str()==note.meeting_id.as_deref());
        tasks.push(json!({"id":format!("manual:{}",note.id),"meetingID":note.meeting_id,"title":meeting.and_then(|m|m["title"].as_str()).unwrap_or("Входящие заметки"),
            "text":note.text,"owner":note.owner,"due":note.due,"completed":note.completed,"segmentIDs":note.task_origin.as_ref().map(|origin|origin["segmentIDs"].clone()).unwrap_or_else(||json!([])),"itemIndex":null,"noteID":note.id,"noteRevision":note.revision,"timestamp":note.timestamp,"taskTitle":note.title,"history":note.history,"subtasks":note.subtasks,"taskOrigin":note.task_origin}));
    }
    for meeting in &meetings {
        let id=meeting["id"].as_str().context("Нет ID встречи")?;
        let dir=crate::storage::meeting_directory(root,id)?;
        let Ok(mut file)=regular(&dir.join("summary.json"),8*1_048_576) else { continue; };
        let mut bytes=Vec::new(); (&mut file).take(8*1_048_576+1).read_to_end(&mut bytes)?;
        let Ok(summary)=serde_json::from_slice::<Value>(&bytes) else { continue; };
        let Some(items)=summary["items"].as_array() else { continue; };
        let mut source_ids=std::collections::HashSet::new();
        for (index,item) in items.iter().take(10_000).enumerate().filter(|(_,item)|item["kind"]=="action") {
            let Some(text)=item["text"].as_str().filter(|text|text.len()<=MAX_TEXT) else { continue; };
            let refs=item["segmentIDs"].as_array().map(|ids|ids.iter().filter_map(Value::as_u64).collect::<Vec<_>>()).unwrap_or_default();
            let signature=task_signature(item);
            if !source_ids.insert(signature.clone()) { continue; }
            if workspace.notes.iter().any(|note|note.task_origin.as_ref().is_some_and(|origin|origin["meetingID"]==id && origin["itemSignature"]==signature)) { continue; }
            let insight_id=format!("action-{}-{text}",refs.iter().map(ToString::to_string).collect::<Vec<_>>().join("-"));
            let completed=meeting["completedTasks"].as_array().is_some_and(|ids|ids.iter().any(|id|id.as_str()==Some(&insight_id)));
            tasks.push(json!({"id":format!("summary:{id}:{signature}"),"meetingID":id,"title":meeting["title"],"text":text,
                "owner":item["owner"].as_str().unwrap_or(""),"due":item["due"].as_str().unwrap_or(""),"completed":completed,
                "segmentIDs":refs,"itemIndex":index,"noteID":null,"noteRevision":null,"timestamp":null}));
        }
    }
    Ok(json!({"tasks":tasks}))
}
pub fn brief(root:&Path,meeting_id:&str) -> Result<Value> {
    ensure_meeting(root,Some(meeting_id))?;
    let data=list(root)?;
    let Some(context)=data.contexts.iter().find(|c|c.meeting_id==meeting_id) else { return Ok(json!({"meetingIDs":[]})); };
    let normalized=|text:&str|text.trim().to_lowercase();
    let project=normalized(&context.project); let person=normalized(&context.person);
    let meetings=crate::storage::list_meetings(root)?;
    let ids=data.contexts.iter().filter(|c|c.meeting_id!=meeting_id && ((!project.is_empty() && normalized(&c.project)==project) || (!person.is_empty() && normalized(&c.person)==person)))
        .filter(|c|meetings.iter().any(|m|m["id"].as_str()==Some(&c.meeting_id))).map(|c|c.meeting_id.clone()).collect::<Vec<_>>();
    Ok(json!({"meetingIDs":ids}))
}

/// Summary task completion shares storage's meeting lock, so it cannot erase
/// speaker renames or another simultaneous completion from a different window.
pub fn complete_task(root:&Path,meeting_id:&str,item_index:usize,text:&str,completed:bool) -> Result<Value> {
    complete_task_checked(root,meeting_id,item_index,text,completed,None)
}
fn complete_task_checked(root:&Path,meeting_id:&str,item_index:usize,text:&str,completed:bool,expected_segment_ids:Option<&Value>) -> Result<Value> {
    ensure_meeting(root,Some(meeting_id))?;
    // Keep the established workspace → meeting lock order used by grounded
    // note expansion. Validate the source before mutating a canonical task.
    let notes_dir=directory(root)?;let _notes_lock=lock(&notes_dir)?;let mut workspace=load(&notes_dir)?;
    let dir=crate::storage::meeting_directory(root,meeting_id)?;
    let lock_path=dir.join(".posle-storage.lock");
    if let Ok(info)=fs::symlink_metadata(&lock_path) { ensure!(info.is_file() && !info.file_type().is_symlink(),"Некорректная блокировка встречи"); }
    let lock=crate::platform_fs::open_private(&lock_path,false)?;
    lock.lock()?;
    let read=|name:&str,max:u64|->Result<Value> {
        let mut bytes=Vec::new(); regular(&dir.join(name),max)?.take(max+1).read_to_end(&mut bytes)?;
        ensure!(bytes.len() as u64<=max,"Слишком большой файл встречи"); Ok(serde_json::from_slice(&bytes)?)
    };
    let mut meta=read("meta.json",1_048_576)?;
    let summary=read("summary.json",8*1_048_576)?;
    let item=summary["items"].as_array().and_then(|items|items.get(item_index)).context("Задача больше не существует")?;
    ensure!(item["kind"]=="action" && item["text"].as_str()==Some(text),"Задача изменилась. Обновите список.");
    let refs=item["segmentIDs"].as_array().context("Некорректные ссылки задачи")?.iter().map(|id|id.as_u64().context("Некорректный ID реплики")).collect::<Result<Vec<_>>>()?;
    if let Some(expected)=expected_segment_ids { ensure!(*expected==json!(refs),"Исходные реплики задачи изменились. Обновите конспект."); }
    let signature=task_signature(item);
    if let Some(note)=workspace.notes.iter_mut().find(|note|note.trashed_at.is_none()&&note.task_origin.as_ref().is_some_and(|origin|origin["meetingID"]==meeting_id&&origin["itemSignature"]==signature)) {
        if note.completed!=completed {note.completed=completed;note.revision=bumped(note.revision)?;note.updated_at=now();note.history.push(json!({"id":Uuid::new_v4().to_string(),"operationID":Uuid::new_v4().to_string(),"text":if completed{"Задача выполнена"}else{"Задача снова открыта"},"createdAt":now()}));}
        let note=note.clone();persist(&notes_dir,&workspace)?;return Ok(json!({"saved":true,"note":note}));
    }
    let insight_id=format!("action-{}-{text}",refs.iter().map(ToString::to_string).collect::<Vec<_>>().join("-"));
    let object=meta.as_object_mut().context("Некорректные метаданные встречи")?;
    ensure!(object.get("id").and_then(Value::as_str)==Some(meeting_id),"Некорректный ID встречи");
    let tasks=object.entry("completedTasks").or_insert_with(||json!([])).as_array_mut().context("Некорректные статусы задач")?;
    tasks.retain(|id|id.as_str()!=Some(&insight_id));
    if completed { tasks.push(json!(insight_id)); }
    crate::storage::atomic_json(&dir.join("meta.json"),&meta)?;
    Ok(json!({"saved":true}))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink,MetadataExt};
    fn note(text:&str) -> CapturedNote { serde_json::from_value(json!({"id":Uuid::new_v4().to_string(),"text":text,"createdAt":0.0,"updatedAt":0.0})).unwrap() }
    fn meeting(root:&Path,id:&str) -> PathBuf {
        let dir=crate::storage::meeting_directory(root,id).unwrap();
        crate::storage::atomic_json(&dir.join("meta.json"),&json!({"id":id,"title":"Пилот","source":"source.mp3","createdAt":1.0,"speakerNames":{"speaker_1":"Анна"},"completedTasks":[]})).unwrap();
        crate::storage::atomic_json(&dir.join("transcript.json"),&json!({"segments":[{"id":1,"start":0.0,"end":5.0,"text":"Цена 15 процентов"}]})).unwrap(); dir
    }
    fn expansion(root:&Path,id:&str) -> Value {
        let (_,fingerprint)=transcript_snapshot(root,id).unwrap();
        json!({"statements":[{"text":"Цена 15 процентов","segmentIDs":[1]}],"openQuestions":["Срок доставки?"],"generatedAt":1.0,"provider":"test","model":"test","warnings":[],"sourceFingerprint":fingerprint})
    }
    #[test] fn ffi_swift_acronyms_and_legacy_aliases_round_trip() {
        let root=tempfile::tempdir().unwrap(); meeting(root.path(),"one");
        let request=json!({"root":root.path(),"command":"note-save","note":{"id":"swift-note","text":"Источник","kind":"note","meetingID":"one","timestamp":0.0,"createdAt":0.0,"updatedAt":0.0,"revision":0,"sourceURL":"https://example.org/price","owner":"","due":"","completed":false,"attachments":[]}});
        let result=crate::request(&request).unwrap(); assert_eq!(result["meetingID"],"one"); assert_eq!(result["sourceURL"],"https://example.org/price"); assert!(result.get("meetingId").is_none());
        let context=crate::request(&json!({"root":root.path(),"command":"context-save","context":{"meetingID":"one","project":"Пилот","person":"Анна","templateID":"purchases","revision":0}})).unwrap();
        assert_eq!(context["meetingID"],"one"); assert_eq!(context["templateID"],"purchases");
        let legacy:CapturedNote=serde_json::from_value(json!({"id":"legacy","text":"old","meetingId":"one","createdAt":0.0,"updatedAt":0.0,"sourceUrl":"https://example.org"})).unwrap(); assert_eq!(legacy.meeting_id.as_deref(),Some("one"));
    }
    #[test] fn notes_cas_preserves_newer_edits_and_private_storage() {
        let root=tempfile::tempdir().unwrap();
        assert_eq!(list(root.path()).unwrap().templates.len(),4);
        let original=save_note(root.path(),note("Первая мысль")).unwrap();
        assert_eq!(original.revision,1);
        let mut updated=original.clone(); updated.text="Новый текст".into();
        let updated=save_note(root.path(),updated).unwrap();
        assert_eq!(updated.revision,2); assert_eq!(updated.created_at,original.created_at);
        assert!(save_note(root.path(),original.clone()).is_err());
        assert!(delete_note(root.path(),&original.id,original.revision).is_err());
        assert_eq!(list(root.path()).unwrap().notes[0].text,"Новый текст");
        assert_eq!(fs::metadata(root.path().join("notes/workspace.json")).unwrap().permissions().mode()&0o777,0o600);
        assert_eq!(fs::metadata(root.path().join("notes")).unwrap().permissions().mode()&0o777,0o700);
    }
    #[test] fn orphaned_notes_remain_editable_without_losing_original_link_or_timestamp() {
        let root=tempfile::tempdir().unwrap(); let dir=meeting(root.path(),"one");
        let mut draft=note("Проверить договор"); draft.kind="task".into(); draft.meeting_id=Some("one".into()); draft.timestamp=Some(0.0);
        let original=save_note(root.path(),draft).unwrap(); fs::remove_dir_all(dir).unwrap();
        let mut edited=original.clone(); edited.text="Проверить и выслать договор".into(); edited.completed=true;
        let saved=save_note(root.path(),edited).unwrap(); assert_eq!(saved.meeting_id.as_deref(),Some("one")); assert_eq!(saved.timestamp,Some(0.0)); assert!(saved.completed); assert_eq!(saved.created_at,original.created_at);
        let mut unrelated=note("Новая заметка"); unrelated.meeting_id=Some("one".into()); assert!(save_note(root.path(),unrelated).is_err());
        let mut bad_relink=saved.clone(); bad_relink.meeting_id=Some("missing".into()); assert!(save_note(root.path(),bad_relink).is_err());
        let mut detached=saved; detached.meeting_id=None; detached.timestamp=None; assert!(save_note(root.path(),detached).unwrap().meeting_id.is_none());
    }
    #[test] fn concurrent_panels_cannot_erase_each_other() {
        let root=tempfile::tempdir().unwrap(); let saved=save_note(root.path(),note("Общий оригинал")).unwrap();
        let mut threads=vec![];
        for i in 0..6 { let root=root.path().to_owned(); let mut draft=saved.clone(); draft.text=format!("Правка {i}"); threads.push(std::thread::spawn(move||save_note(&root,draft))); }
        let won=threads.into_iter().map(|thread|thread.join().unwrap()).filter(Result::is_ok).count();
        assert_eq!(won,1); assert_eq!(list(root.path()).unwrap().notes[0].revision,2);
        let mut threads=vec![];
        for i in 0..6 { let root=root.path().to_owned(); threads.push(std::thread::spawn(move||save_note(&root,note(&format!("Отдельная {i}"))).unwrap())); }
        for thread in threads { thread.join().unwrap(); } assert_eq!(list(root.path()).unwrap().notes.len(),7);
    }
    #[test] fn attachments_are_owned_copies_and_require_current_revision() {
        let root=tempfile::tempdir().unwrap(); let source=tempfile::tempdir().unwrap(); let path=source.path().join("Цены.txt"); fs::write(&path,"Скидка 15% завтра").unwrap();
        let original=save_note(root.path(),note("Прайс")).unwrap();
        let attached=attach(root.path(),&original.id,original.revision,&path).unwrap();
        assert_eq!(attached.attachments[0].extracted_text,"Скидка 15% завтра");
        let copied=root.path().join(&attached.attachments[0].relative_path);
        assert_ne!(fs::metadata(&path).unwrap().ino(),fs::metadata(&copied).unwrap().ino());
        assert_eq!(fs::metadata(&copied).unwrap().permissions().mode()&0o777,0o600);
        assert!(attach(root.path(),&original.id,original.revision,&path).is_err());
        let mut forged=attached.clone(); forged.attachments[0].relative_path="/tmp/secret.txt".into(); assert!(save_note(root.path(),forged).is_err());
        let cleaned=remove_attachment(root.path(),&attached.id,attached.revision,&attached.attachments[0].id).unwrap();
        assert!(cleaned.attachments.is_empty()); assert!(!copied.exists()); assert_eq!(fs::read_to_string(path).unwrap(),"Скидка 15% завтра");
    }
    #[test] fn symlinked_workspace_lock_and_attachments_never_touch_targets() {
        for name in ["workspace.json",".workspace.lock"] {
            let root=tempfile::tempdir().unwrap(); let outside=tempfile::tempdir().unwrap(); fs::write(outside.path().join("keep"),b"untouched").unwrap();
            private_directory(&root.path().join("notes")).unwrap(); symlink(outside.path().join("keep"),root.path().join("notes").join(name)).unwrap();
            assert!(save_note(root.path(),note("Запрещено")).is_err()); assert_eq!(fs::read(outside.path().join("keep")).unwrap(),b"untouched");
        }
        let root=tempfile::tempdir().unwrap(); let outside=tempfile::tempdir().unwrap(); symlink(outside.path(),root.path().join("notes")).unwrap(); assert!(list(root.path()).is_err());
        let root=tempfile::tempdir().unwrap(); let original=save_note(root.path(),note("Файл")).unwrap(); let source=outside.path().join("text.txt"); fs::write(&source,"private").unwrap();
        symlink(outside.path(),root.path().join("notes/attachments")).unwrap(); assert!(attach(root.path(),&original.id,original.revision,&source).is_err());
        assert_eq!(fs::read_to_string(source).unwrap(),"private");
    }
    #[test] fn bad_or_oversized_json_cannot_be_overwritten() {
        let root=tempfile::tempdir().unwrap(); directory(root.path()).unwrap(); let path=root.path().join("notes/workspace.json"); fs::write(&path,b"{broken").unwrap();
        assert!(save_note(root.path(),note("Новая")).is_err()); assert_eq!(fs::read(&path).unwrap(),b"{broken");
        File::create(&path).unwrap().set_len(crate::workspace_repository::MAX_WORKSPACE+1).unwrap(); assert!(list(root.path()).is_err());
        let root=tempfile::tempdir().unwrap(); let mut draft=note("x"); draft.text="x".repeat(MAX_TEXT+1); assert!(save_note(root.path(),draft).is_err());
        let mut draft=note("x"); draft.source_url="javascript:alert(1)".into(); assert!(save_note(root.path(),draft).is_err());
        let mut draft=note("x"); draft.timestamp=Some(0.0); assert!(save_note(root.path(),draft).is_err());
    }
    #[test] fn grounded_expansions_require_current_note_and_transcript() {
        let root=tempfile::tempdir().unwrap(); let dir=meeting(root.path(),"one"); let mut draft=note("Скидка? доставка?"); draft.meeting_id=Some("one".into()); draft.timestamp=Some(0.0);
        let saved=save_note(root.path(),draft).unwrap(); let generated=expansion(root.path(),"one"); let fingerprint=generated["sourceFingerprint"].as_str().unwrap().to_owned();
        let expanded=save_expansion_checked(root.path(),&saved.id,saved.revision,&fingerprint,generated.clone()).unwrap();
        assert_eq!(expanded.text,saved.text); assert!(expansion_valid(root.path(),&saved.id).unwrap());
        let mut from_swift=expanded.clone(); from_swift.expansion.as_mut().unwrap()["generatedAt"]=json!(1);
        from_swift.expansion.as_mut().unwrap()["statements"][0]["text"]=json!("Untrusted client replacement");
        let saved_copy=save_note(root.path(),from_swift).unwrap();
        assert_eq!(saved_copy.expansion,expanded.expansion);
        let expanded=saved_copy;
        assert!(save_expansion_checked(root.path(),&saved.id,saved.revision,&fingerprint,generated.clone()).is_err());
        let mut invalid=generated.clone(); invalid["statements"][0]["segmentIDs"]=json!([999]); assert!(save_expansion_checked(root.path(),&saved.id,expanded.revision,&fingerprint,invalid).is_err());
        crate::storage::atomic_json(&dir.join("transcript.json"),&json!({"segments":[{"id":1,"text":"Цена изменилась"}]})).unwrap();
        assert!(!expansion_valid(root.path(),&saved.id).unwrap()); assert!(save_expansion_checked(root.path(),&saved.id,expanded.revision,&fingerprint,generated).is_err());
        let mut edited=expanded.clone(); edited.text="Моя ручная правка".into(); assert!(save_note(root.path(),edited).unwrap().expansion.is_none());
    }
    #[test] fn grounded_expansion_waits_for_transcript_publication_and_rechecks_source() {
        let root=tempfile::tempdir().unwrap(); let dir=meeting(root.path(),"one");
        let mut draft=note("Какая цена?"); draft.meeting_id=Some("one".into());
        let saved=save_note(root.path(),draft).unwrap(); let generated=expansion(root.path(),"one");
        let fingerprint=generated["sourceFingerprint"].as_str().unwrap().to_owned();
        let lock=crate::storage::meeting_lock(&dir).unwrap();
        let (started_tx,started_rx)=std::sync::mpsc::channel();
        let (finished_tx,finished_rx)=std::sync::mpsc::channel();
        let thread_root=root.path().to_owned(); let id=saved.id.clone(); let revision=saved.revision;
        let thread=std::thread::spawn(move|| {
            started_tx.send(()).unwrap();
            finished_tx.send(save_expansion_checked(&thread_root,&id,revision,&fingerprint,generated)).unwrap();
        });
        started_rx.recv().unwrap();
        let early=finished_rx.recv_timeout(std::time::Duration::from_millis(250));
        let waited=matches!(early,Err(std::sync::mpsc::RecvTimeoutError::Timeout));
        crate::storage::atomic_json(&dir.join("transcript.json"),&json!({"segments":[{"id":1,"start":0.0,"end":5.0,"text":"Цена теперь 20 процентов"}]})).unwrap();
        drop(lock);
        let result=match early { Ok(value)=>value,Err(_)=>finished_rx.recv_timeout(std::time::Duration::from_secs(3)).unwrap() };
        thread.join().unwrap();
        assert!(waited,"grounded note was published while the source writer held its lock");
        assert!(result.is_err());
        let current=load_note_snapshot(root.path(),&saved.id).unwrap();
        assert_eq!(current.revision,saved.revision); assert!(current.expansion.is_none());
    }
    #[test] fn context_and_template_revisions_preserve_meeting_data() {
        let root=tempfile::tempdir().unwrap(); let dir=meeting(root.path(),"one"); let original=fs::read(dir.join("meta.json")).unwrap();
        let context=save_context(root.path(),MeetingContext{meeting_id:"one".into(),project:"Ремонт".into(),person:"Анна".into(),template_id:Some("purchases".into()),folder_id:None,revision:0}).unwrap();
        assert!(save_context(root.path(),MeetingContext{revision:0,..context.clone()}).is_err());
        let builtin=list(root.path()).unwrap().templates[0].clone(); delete_template(root.path(),&builtin.id,builtin.revision).unwrap();
        assert!(list(root.path()).unwrap().contexts[0].template_id.is_none()); assert_eq!(fs::read(dir.join("meta.json")).unwrap(),original);
        let template=save_template(root.path(),NoteTemplate{id:"custom".into(),name:"Мой".into(),body:"Вопросы".into(),focus:"Цифры".into(),revision:0}).unwrap();
        assert!(save_template(root.path(),NoteTemplate{revision:0,..template}).is_err());
    }
    #[test] fn global_search_matches_notes_and_ocr_but_never_settings() {
        let root=tempfile::tempdir().unwrap(); let source=tempfile::tempdir().unwrap(); let path=source.path().join("scan.png"); fs::write(&path,b"fake synthetic image").unwrap();
        let saved=save_note(root.path(),note("Бюджеты running migrations")).unwrap(); let saved=attach(root.path(),&saved.id,saved.revision,&path).unwrap();
        let saved=attachment_text(root.path(),&saved.id,saved.revision,&saved.attachments[0].id,"Отчёты 2026").unwrap();
        crate::storage::atomic_json(&root.path().join("settings.json"),&json!({"secret":"neverindex"})).unwrap();
        for query in ["БЮДЖЕТ","run","migrating","отчет","2026"] { let result=crate::search::search(root.path(),query,"notes",60).unwrap(); assert_eq!(result["total"],1,"{query}"); assert_eq!(result["hits"][0]["noteID"],saved.id); }
        assert_eq!(crate::search::search(root.path(),"neverindex","all",60).unwrap()["total"],0);
        let long=save_note(root.path(),note(&format!("{} контрольныйМаркер", "начало ".repeat(100)))).unwrap();
        let hit=crate::search::search(root.path(),"контрольныймаркер","notes",60).unwrap();
        assert!(hit["hits"][0]["snippet"].as_str().unwrap().contains("контрольныйМаркер"));
        delete_note(root.path(),&long.id,long.revision).unwrap();
        delete_note(root.path(),&saved.id,saved.revision).unwrap(); assert_eq!(crate::search::search(root.path(),"2026","all",60).unwrap()["total"],0);
    }
    #[test] fn tasks_use_summary_and_manual_completion_without_overwriting_metadata() {
        let root=tempfile::tempdir().unwrap(); let dir=meeting(root.path(),"one");
        crate::storage::atomic_json(&dir.join("summary.json"),&json!({"items":[{"kind":"action","text":"Выслать договор","owner":"Анна","due":"Завтра","segmentIDs":[1]}]})).unwrap();
        let mut manual=note("Моя задача"); manual.kind="task".into(); save_note(root.path(),manual).unwrap();
        assert_eq!(tasks(root.path()).unwrap()["tasks"].as_array().unwrap().len(),2);
        complete_task(root.path(),"one",0,"Выслать договор",true).unwrap();
        let tasks=tasks(root.path()).unwrap(); assert_eq!(tasks["tasks"][1]["completed"],true);
        let meta:Value=serde_json::from_slice(&fs::read(dir.join("meta.json")).unwrap()).unwrap(); assert_eq!(meta["speakerNames"]["speaker_1"],"Анна");
        assert!(complete_task(root.path(),"one",0,"Старый текст",false).is_err());
    }
    #[test] fn preparation_links_existing_project_or_person_and_skips_deleted_meetings() {
        let root=tempfile::tempdir().unwrap(); for id in ["one","two","three"] { meeting(root.path(),id); }
        for (id,project,person) in [("one","Ремонт","Анна"),("two"," ремонт ","Борис"),("three","Другое","АННА")] {
            save_context(root.path(),MeetingContext{meeting_id:id.into(),project:project.into(),person:person.into(),template_id:None,folder_id:None,revision:0}).unwrap();
        }
        assert_eq!(brief(root.path(),"one").unwrap()["meetingIDs"],json!(["two","three"]));
        fs::remove_dir_all(root.path().join("meetings/two")).unwrap(); assert_eq!(brief(root.path(),"one").unwrap()["meetingIDs"],json!(["three"]));
    }
}
