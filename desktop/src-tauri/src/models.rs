use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HostError {
    pub code: String,
    pub message: String,
}
impl HostError {
    pub(crate) fn new(code: &str, message: &str) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
    pub(crate) fn invalid() -> Self {
        Self::new("invalid_request", "The request contains an invalid value.")
    }
}
impl std::fmt::Display for HostError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}
impl std::error::Error for HostError {}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Folder {
    pub id: String,
    pub name: String,
    pub revision: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Meeting {
    pub id: String,
    pub title: String,
    pub started_at: Option<f64>,
    pub duration_seconds: Option<f64>,
    pub folder_id: Option<String>,
    pub has_transcript: bool,
    pub has_summary: bool,
    #[serde(default)]
    pub has_media: bool,
    #[serde(default)]
    pub media_kind: Option<String>,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MediaChunk {
    pub meeting_id: String,
    pub offset: u64,
    pub total_bytes: u64,
    pub content_type: String,
    pub data_base64: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    pub id: String,
    pub title: String,
    pub text: String,
    pub folder_id: Option<String>,
    pub meeting_id: Option<String>,
    pub revision: u64,
    pub updated_at: f64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    pub library: bool,
    #[serde(default)]
    pub import: bool,
    pub recording: bool,
    pub calendar: bool,
    pub assistant: bool,
    pub cards: bool,
    pub tasks: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
    pub folders: Vec<Folder>,
    pub meetings: Vec<Meeting>,
    pub notes: Vec<Note>,
    pub capabilities: Capabilities,
    pub platform: serde_json::Value,
    pub truncated: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranscriptSegment {
    pub start: f64,
    pub end: Option<f64>,
    pub speaker: Option<String>,
    pub text: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MeetingDetail {
    pub meeting: Meeting,
    pub transcript: Vec<TranscriptSegment>,
    pub summary: Option<String>,
    pub notes: Vec<Note>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub excerpt: String,
    pub meeting_id: Option<String>,
    pub note_id: Option<String>,
    pub start: Option<f64>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResults {
    pub hits: Vec<SearchHit>,
    pub total: usize,
    pub truncated: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SaveNoteInput {
    pub id: Option<String>,
    pub title: String,
    pub text: String,
    #[serde(
        default,
        deserialize_with = "reference_field",
        skip_serializing_if = "Option::is_none"
    )]
    pub folder_id: Option<Option<String>>,
    #[serde(
        default,
        deserialize_with = "reference_field",
        skip_serializing_if = "Option::is_none"
    )]
    pub meeting_id: Option<Option<String>>,
    pub expected_revision: Option<u64>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SaveFolderInput {
    pub id: Option<String>,
    pub name: String,
    pub expected_revision: Option<u64>,
}

// Missing is an editor patch which preserves the current relationship; JSON
// null explicitly unlinks it. A plain Option<String> would collapse both and
// silently unlink a meeting or folder when an older/partial editor saves.
fn reference_field<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<Option<String>>, D::Error> {
    Option::<String>::deserialize(deserializer).map(Some)
}

pub(crate) fn validate_id(value: &str) -> Result<(), HostError> {
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err(HostError::invalid());
    }
    Ok(())
}
fn validate_text(value: &str, limit: usize) -> Result<(), HostError> {
    if value.len() > limit || value.contains('\0') {
        return Err(HostError::invalid());
    }
    Ok(())
}
fn validate_edit(id: Option<&str>, revision: Option<u64>) -> Result<(), HostError> {
    match (id, revision) {
        (Some(id), Some(revision)) if revision > 0 => validate_id(id),
        (None, None) => Ok(()),
        _ => Err(HostError::invalid()),
    }
}
impl SaveNoteInput {
    pub(crate) fn validate(&self) -> Result<(), HostError> {
        validate_edit(self.id.as_deref(), self.expected_revision)?;
        validate_text(&self.title, 1024)?;
        validate_text(&self.text, 100_000)?;
        if let Some(Some(id)) = &self.folder_id {
            validate_id(id)?;
        }
        if let Some(Some(id)) = &self.meeting_id {
            validate_id(id)?;
        }
        Ok(())
    }
}
impl SaveFolderInput {
    pub(crate) fn validate(&self) -> Result<(), HostError> {
        validate_edit(self.id.as_deref(), self.expected_revision)?;
        validate_text(&self.name, 256)?;
        if self.name.trim().is_empty() {
            return Err(HostError::invalid());
        }
        Ok(())
    }
}
pub(crate) fn validate_query(query: &str, folder_id: Option<&str>) -> Result<(), HostError> {
    validate_text(query, 512)?;
    if query.trim().is_empty() {
        return Err(HostError::invalid());
    }
    if let Some(id) = folder_id {
        validate_id(id)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn edits_require_a_revision_and_paths_are_not_identifiers() {
        for id in ["../meeting", "/tmp/data", "a/b", "a\\b", "", "a\0b"] {
            assert!(validate_id(id).is_err());
        }
        assert!(validate_id("meeting_A-10").is_ok());
        let mut note: SaveNoteInput =
            serde_json::from_value(json!({"title":"Draft", "text":"Keep me", "id":"existing"}))
                .unwrap();
        assert!(note.validate().is_err());
        note.expected_revision = Some(7);
        assert!(note.validate().is_ok());
        note.text.push('\0');
        assert!(note.validate().is_err());
        assert!(serde_json::from_value::<SaveNoteInput>(
            json!({"title":"Draft","text":"Keep", "root":"/tmp"})
        )
        .is_err());
    }
    #[test]
    fn omitted_references_are_preserved_while_null_explicitly_unlinks() {
        let absent: SaveNoteInput =
            serde_json::from_value(json!({"title":"Keep", "text":"Text"})).unwrap();
        let unlink: SaveNoteInput = serde_json::from_value(
            json!({"title":"Keep", "text":"Text", "folderId":null,"meetingId":null}),
        )
        .unwrap();
        assert_eq!(absent.folder_id, None);
        assert_eq!(absent.meeting_id, None);
        assert_eq!(unlink.folder_id, Some(None));
        assert_eq!(unlink.meeting_id, Some(None));
        let absent_json = serde_json::to_value(absent).unwrap();
        assert!(absent_json.get("folderId").is_none());
        assert!(absent_json.get("meetingId").is_none());
        let unlink_json = serde_json::to_value(unlink).unwrap();
        assert_eq!(unlink_json.get("folderId"), Some(&serde_json::Value::Null));
        assert_eq!(unlink_json.get("meetingId"), Some(&serde_json::Value::Null));
        let assignment: SaveNoteInput =
            serde_json::from_value(json!({"title":"Keep", "text":"Text", "folderId":"folder-id"}))
                .unwrap();
        assert_eq!(assignment.folder_id, Some(Some("folder-id".into())));
        assert!(assignment.validate().is_ok());
    }
    #[test]
    fn bounds_are_utf8_bytes_and_empty_search_is_rejected() {
        assert!(validate_query("", None).is_err());
        assert!(validate_query(" English ", Some("folder-id")).is_ok());
        assert!(validate_query(&"я".repeat(257), None).is_err());
        let folder = SaveFolderInput {
            id: None,
            name: " ".into(),
            expected_revision: None,
        };
        assert!(folder.validate().is_err());
    }
}
