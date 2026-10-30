//! Narrow, versioned desktop transport over the existing Rust domain. The host
//! supplies the private root; the webview supplies IDs and editor fields only.
//! No arbitrary command, path, settings, attachment or provider access is exposed.
use crate::{folders, notes, storage};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::path::{Component, Path};
use uuid::Uuid;
mod features;

pub const MAX_REQUEST_BYTES: usize = 256 * 1024;
pub const MAX_RESPONSE_BYTES: usize = 8 * 1024 * 1024;
const MAX_ENTITIES: usize = 10_000;
type Result<T> = std::result::Result<T, BridgeError>;

#[derive(Debug)]
struct BridgeError {
    code: &'static str,
    message: &'static str,
}
impl BridgeError {
    fn invalid() -> Self {
        Self {
            code: "invalid_request",
            message: "The request is invalid or exceeds the supported limit.",
        }
    }
    fn missing() -> Self {
        Self {
            code: "not_found",
            message: "This item is no longer available. Refresh the library.",
        }
    }
    fn conflict() -> Self {
        Self {code:"conflict",message:"This item changed in another window. Refresh the library; your draft has been preserved."}
    }
    fn library() -> Self {
        Self {
            code: "library_error",
            message:
                "The library could not be read or saved. Your existing data has been preserved.",
        }
    }
    fn large() -> Self {
        Self {code:"content_too_large",message:"This library or meeting exceeds the desktop preview limit. Open it in the native app."}
    }
}
fn domain<T>(value: anyhow::Result<T>) -> Result<T> {
    value.map_err(|error| {
        // Never serialize the underlying error: it can contain local paths,
        // source content or settings. Match only known canonical CAS failures.
        let message = error.to_string();
        if message.contains("Заметка уже изменена")
            || message.contains("Папка уже изменилась")
            || message.contains("Состояние Корзины изменилось")
            || message.contains("Задача или её контекст изменились")
            || message.contains("Карточка изменилась")
            || message.contains("Карточка уже изменена")
            || message.contains("История повторений изменилась")
            || message.contains("Повторение уже изменено")
        {
            BridgeError::conflict()
        } else if message.contains("Папка с таким названием уже есть") {
            BridgeError {
                code: "duplicate_name",
                message: "A folder with this name already exists.",
            }
        } else {
            BridgeError::library()
        }
    })
}
fn identifier(id: &str) -> Result<()> {
    if !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
    {
        Ok(())
    } else {
        Err(BridgeError::invalid())
    }
}
fn optional_id(id: Option<&str>) -> Result<()> {
    id.map(identifier).transpose().map(|_| ())
}
fn bounded(text: &str, limit: usize) -> Result<()> {
    if text.len() <= limit && !text.contains('\0') {
        Ok(())
    } else {
        Err(BridgeError::invalid())
    }
}
fn parse<T: serde::de::DeserializeOwned>(value: Value) -> Result<T> {
    serde_json::from_value(value).map_err(|_| BridgeError::invalid())
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    command: String,
    #[serde(default = "empty_object")]
    arguments: Value,
}
fn empty_object() -> Value {
    json!({})
}
#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceArguments {
    folder_id: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MediaArguments { meeting_id: String, offset: u64, length: u32 }
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ImportArguments { source_path: String, #[serde(default)] focus: String, title: Option<String> }
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MeetingArguments {
    meeting_id: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SaveArguments<T> {
    input: T,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FolderInput {
    id: Option<String>,
    name: String,
    expected_revision: Option<u64>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NoteInput {
    id: Option<String>,
    title: String,
    text: String,
    #[serde(default, deserialize_with = "reference")]
    folder_id: Reference,
    #[serde(default, deserialize_with = "reference")]
    meeting_id: Reference,
    expected_revision: Option<u64>,
}
#[derive(Default)]
enum Reference {
    #[default]
    Unchanged,
    Value(Option<String>),
}
fn reference<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Reference, D::Error> {
    Option::<String>::deserialize(deserializer).map(Reference::Value)
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SearchArguments {
    query: String,
    folder_id: Option<String>,
    limit: Option<usize>,
}

fn checked_workspace(root: &Path, folder_id: Option<&str>) -> Result<notes::NotesWorkspace> {
    optional_id(folder_id)?;
    let workspace = domain(notes::list(root))?;
    if workspace.notes.len() > MAX_ENTITIES || workspace.folders.len() > 1_000 {
        return Err(BridgeError::large());
    }
    if folder_id.is_some_and(|id| !workspace.folders.iter().any(|f| f.id == id)) {
        return Err(BridgeError::missing());
    }
    Ok(workspace)
}
fn note_dto(note: &notes::CapturedNote, workspace: &notes::NotesWorkspace) -> Value {
    json!({"id":note.id,"title":note.title,"text":note.text,
        "folderId":folders::folder_id_for_note(workspace,&note.id),"meetingId":note.meeting_id,
        "revision":note.revision,"updatedAt":note.updated_at})
}
fn folder_dto(folder: &folders::Folder) -> Value {
    json!({"id":folder.id,"name":folder.name,"revision":folder.revision})
}
fn ordinary_content(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|info| {
        info.is_file() && !info.file_type().is_symlink() && info.len() <= 32 * 1_048_576
    })
}
fn meeting_dto(root: &Path, meta: &Value, workspace: &notes::NotesWorkspace) -> Result<Value> {
    let id = meta["id"].as_str().ok_or_else(BridgeError::library)?;
    let directory = domain(storage::meeting_directory(root, id))?;
    let media_kind = crate::desktop_media::kind(root, id);
    Ok(
        json!({"id":id,"title":meta["title"],"startedAt":meta["createdAt"],
        "hasMedia":media_kind.is_some(),"mediaKind":media_kind,
        "durationSeconds":meta["duration"],"folderId":folders::folder_id_for_meeting(workspace,id),
        "hasTranscript":ordinary_content(&directory.join("transcript.json")),
        "hasSummary":ordinary_content(&directory.join("summary.json"))}),
    )
}
fn snapshot(root: &Path, args: WorkspaceArguments) -> Result<Value> {
    let workspace = checked_workspace(root, args.folder_id.as_deref())?;
    let metadata = domain(storage::list_meetings(root))?;
    if metadata.len() > MAX_ENTITIES {
        return Err(BridgeError::large());
    }
    let meetings = metadata
        .iter()
        .filter(|meta| meta["libraryKind"] != "cards")
        .filter(|meta| {
            args.folder_id.as_deref().is_none_or(|id| {
                folders::folder_id_for_meeting(&workspace, meta["id"].as_str().unwrap_or(""))
                    == Some(id)
            })
        })
        .map(|meta| meeting_dto(root, meta, &workspace))
        .collect::<Result<Vec<_>>>()?;
    let captured = workspace
        .notes
        .iter()
        .filter(|note| note.trashed_at.is_none() && note.kind != "task")
        .filter(|note| {
            args.folder_id
                .as_deref()
                .is_none_or(|id| folders::folder_id_for_note(&workspace, &note.id) == Some(id))
        })
        .map(|note| note_dto(note, &workspace))
        .collect::<Vec<_>>();
    Ok(
        json!({"folders":workspace.folders.iter().map(folder_dto).collect::<Vec<_>>(),"meetings":meetings,"notes":captured,
        "capabilities":{"library":true,"recording":false,"calendar":false,"assistant":false,"cards":false,"tasks":false},
        "platform":crate::desktop_platform::manifest(),"truncated":false}),
    )
}
fn import_meeting(root: &Path, args: ImportArguments) -> Result<Value> {
    bounded(&args.source_path, 32760)?;
    bounded(&args.focus, 4096)?;
    if let Some(title) = &args.title { bounded(title, 2000)?; }
    let source = Path::new(&args.source_path);
    if !source.is_absolute() { return Err(BridgeError::invalid()); }
    let meta = crate::desktop_import::import(root, source, &args.focus, args.title.as_deref()).map_err(|_| BridgeError {
        code: "import_failed", message: "Could not import this file. The original was preserved. Check the format, available disk space and file access."
    })?;
    let media_kind = meta["id"].as_str().and_then(|id| crate::desktop_media::kind(root, id));
    Ok(json!({"id":meta["id"],"title":meta["title"],"startedAt":meta["createdAt"],"durationSeconds":0,
        "folderId":null,"hasTranscript":false,"hasSummary":false,"hasMedia":media_kind.is_some(),"mediaKind":media_kind}))
}
fn meeting(root: &Path, args: MeetingArguments) -> Result<Value> {
    identifier(&args.meeting_id)?;
    let workspace = checked_workspace(root, None)?;
    let meta = domain(storage::list_meetings(root))?
        .into_iter()
        .find(|meta| {
            meta["id"].as_str() == Some(&args.meeting_id) && meta["libraryKind"] != "cards"
        })
        .ok_or_else(BridgeError::missing)?;
    // The existing correction boundary reads only named ordinary files with
    // O_NOFOLLOW, locks them, and bounds each JSON document to 32 MiB.
    let content = domain(crate::corrections::dispatch(
        root,
        &json!({"command":"meeting-content-snapshot","meetingID":args.meeting_id}),
    ))?;
    let mut transcript = Vec::new();
    if let Some(segments) = content["transcript"]["segments"].as_array() {
        if segments.len() > 100_000 {
            return Err(BridgeError::large());
        }
        for segment in segments {
            let Some(start) = segment["start"]
                .as_f64()
                .filter(|start| start.is_finite() && *start >= 0.0)
            else {
                continue;
            };
            let Some(text) = segment["text"].as_str() else {
                continue;
            };
            let end = segment["end"]
                .as_f64()
                .filter(|end| end.is_finite() && *end >= start);
            let speaker = segment["speaker"]
                .as_str()
                .map(|id| meta["speakerNames"][id].as_str().unwrap_or(id));
            transcript.push(json!({"start":start,"end":end,"speaker":speaker,"text":text}));
        }
    }
    let notes = workspace
        .notes
        .iter()
        .filter(|note| {
            note.trashed_at.is_none()
                && note.kind != "task"
                && note.meeting_id.as_deref() == Some(&args.meeting_id)
        })
        .map(|note| note_dto(note, &workspace))
        .collect::<Vec<_>>();
    Ok(
        json!({"meeting":meeting_dto(root,&meta,&workspace)?,"transcript":transcript,
        "summary":content["summary"]["overview"].as_str(),"notes":notes}),
    )
}
fn revision_for_existing(id: Option<&str>, expected: Option<u64>) -> Result<()> {
    optional_id(id)?;
    if (id.is_some() && expected.is_none())
        || (id.is_none() && expected.is_some_and(|revision| revision != 0))
    {
        return Err(BridgeError::invalid());
    }
    Ok(())
}
fn save_folder(root: &Path, input: FolderInput) -> Result<Value> {
    revision_for_existing(input.id.as_deref(), input.expected_revision)?;
    let name = input.name.trim();
    bounded(name, 256)?;
    if name.is_empty() {
        return Err(BridgeError::invalid());
    }
    let workspace = checked_workspace(root, None)?;
    let mut folder = if let Some(id) = input.id {
        workspace
            .folders
            .iter()
            .find(|folder| folder.id == id)
            .cloned()
            .ok_or_else(BridgeError::missing)?
    } else {
        folders::Folder {
            id: Uuid::new_v4().to_string(),
            name: String::new(),
            revision: 0,
            overrides: json!({}),
        }
    };
    if folder.revision != input.expected_revision.unwrap_or(0) {
        return Err(BridgeError::conflict());
    }
    // Hidden model/profile overrides never round-trip through a partial editor.
    folder.name = name.into();
    Ok(folder_dto(&domain(folders::save(root, folder))?))
}
fn save_note(root: &Path, input: NoteInput) -> Result<Value> {
    revision_for_existing(input.id.as_deref(), input.expected_revision)?;
    bounded(&input.title, 1024)?;
    bounded(&input.text, 100_000)?;
    if let Reference::Value(id) = &input.folder_id {
        optional_id(id.as_deref())?;
    }
    if let Reference::Value(id) = &input.meeting_id {
        optional_id(id.as_deref())?;
    }
    let workspace = checked_workspace(root, None)?;
    let mut note = if let Some(id) = input.id {
        workspace
            .notes
            .iter()
            .find(|note| note.id == id && note.trashed_at.is_none() && note.kind != "task")
            .cloned()
            .ok_or_else(BridgeError::missing)?
    } else {
        parse::<notes::CapturedNote>(
            json!({"id":Uuid::new_v4().to_string(),"text":"","createdAt":0,"updatedAt":0}),
        )?
    };
    if note.revision != input.expected_revision.unwrap_or(0) {
        return Err(BridgeError::conflict());
    }
    note.title = input.title;
    note.text = input.text;
    if let Reference::Value(folder_id) = input.folder_id {
        if folder_id
            .as_deref()
            .is_some_and(|id| !workspace.folders.iter().any(|folder| folder.id == id))
        {
            return Err(BridgeError::missing());
        }
        note.folder_id = folder_id;
        note.folder = String::new();
    }
    if let Reference::Value(meeting_id) = input.meeting_id {
        if note.meeting_id != meeting_id {
            note.timestamp = None;
        }
        note.meeting_id = meeting_id;
    }
    let saved = domain(notes::save_note(root, note))?;
    // Resolve effective folder from the same committed domain, including an
    // inherited meeting folder. No unrelated fields are exposed or replaced.
    let latest = checked_workspace(root, None)?;
    Ok(note_dto(&saved, &latest))
}
fn search(root: &Path, args: SearchArguments) -> Result<Value> {
    bounded(&args.query, 2048)?;
    optional_id(args.folder_id.as_deref())?;
    if args.query.chars().count() > 512 || args.limit.is_some_and(|limit| limit == 0 || limit > 100)
    {
        return Err(BridgeError::invalid());
    }
    checked_workspace(root, args.folder_id.as_deref())?;
    let results = domain(crate::search::search_library(
        root,
        &args.query,
        args.folder_id.as_deref(),
        args.limit.unwrap_or(40),
    ))?;
    let hits=results["hits"].as_array().ok_or_else(BridgeError::library)?.iter().filter_map(|hit| {
        let kind=match hit["kind"].as_str()? { "title"=>"meeting","transcript"=>"transcript","overview"|"item"=>"summary","manual"=>"note",_=>return None };
        Some(json!({"id":hit["id"],"kind":kind,"title":hit["meetingTitle"],"excerpt":hit["snippet"],
            "meetingId":hit["meetingID"].as_str().filter(|id|!id.is_empty()),"noteId":hit["noteID"],"start":hit["start"]}))
    }).collect::<Vec<_>>();
    Ok(json!({"hits":hits,"total":results["total"],"truncated":results["truncated"]}))
}
fn dispatch(root: &Path, request: Value) -> Result<Value> {
    if !root.is_absolute()
        || root
            .components()
            .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
    {
        return Err(BridgeError::invalid());
    }
    let request: Request = parse(request)?;
    #[cfg(windows)]
    let _root_guard=crate::platform_fs::private_directory(root)
        .and_then(|_|crate::platform_fs::pin_directory(root)).map_err(|_|BridgeError::library())?;
    match request.command.as_str() {
        "import_meeting" => import_meeting(root, parse(request.arguments)?),
        "read_media_chunk" => {
            let args: MediaArguments = parse(request.arguments)?;
            identifier(&args.meeting_id)?;
            if args.length == 0 || args.length > crate::desktop_media::MAX_CHUNK || args.offset > 9_007_199_254_740_991 { return Err(BridgeError::invalid()); }
            domain(crate::desktop_media::read(root, &args.meeting_id, args.offset, args.length))
        },
        "get_workspace" => snapshot(root, parse(request.arguments)?),
        "get_meeting" => meeting(root, parse(request.arguments)?),
        "save_folder" => save_folder(
            root,
            parse::<SaveArguments<FolderInput>>(request.arguments)?.input,
        ),
        "save_note" => save_note(
            root,
            parse::<SaveArguments<NoteInput>>(request.arguments)?.input,
        ),
        "search_library" => search(root, parse(request.arguments)?),
        "list_tasks" | "get_task" | "create_task" | "update_task"
        | "list_cards" | "save_card" | "delete_card" | "suspend_card"
        | "preview_card_review" | "review_card" | "undo_card_review" =>
            features::dispatch(root, &request.command, request.arguments),
        _ => Err(BridgeError {
            code: "unsupported_command",
            message: "This desktop command is not supported.",
        }),
    }
}
fn envelope(result: Result<Value>) -> Value {
    match result {
        Ok(value) => json!({"ok":true,"result":value}),
        Err(error) => json!({"ok":false,"error":{"code":error.code,"message":error.message}}),
    }
}
/// One request per isolated helper process. Both directions are bounded; errors
/// are stable DTOs and never include the underlying library or provider error.
pub fn handle_bytes(root: &Path, input: &[u8]) -> Value {
    let outcome = std::panic::catch_unwind(|| {
        if input.len() > MAX_REQUEST_BYTES {
            return Err(BridgeError::invalid());
        }
        let request = serde_json::from_slice(input).map_err(|_| BridgeError::invalid())?;
        let value = dispatch(root, request)?;
        if serde_json::to_vec(&value)
            .map_err(|_| BridgeError::library())?
            .len()
            > MAX_RESPONSE_BYTES - 64
        {
            return Err(BridgeError::large());
        }
        Ok(value)
    })
    .unwrap_or_else(|_| Err(BridgeError::library()));
    envelope(outcome)
}
pub fn run_stdio(root: &Path, reader: impl Read, mut writer: impl Write) -> std::io::Result<()> {
    let mut bytes = Vec::new();
    let result = match reader
        .take((MAX_REQUEST_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
    {
        Ok(_) => handle_bytes(root, &bytes),
        Err(_) => envelope(Err(BridgeError::invalid())),
    };
    serde_json::to_writer(&mut writer, &result)?;
    writer.write_all(b"\n")?;
    writer.flush()
}

#[cfg(test)]
mod tests;
