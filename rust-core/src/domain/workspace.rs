//! Workspace values and validation. No storage, process, UI or operating-system I/O.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

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
pub(crate) fn empty_object() -> Value {
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
    pub features: crate::domain::config::AppFeatures,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NoteAttachment {
    pub id: String,
    pub name: String,
    pub relative_path: String,
    pub content_type: String,
    #[serde(default)]
    pub extracted_text: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CapturedNote {
    pub id: String,
    #[serde(default)]
    pub text: String,
    #[serde(default = "note_kind")]
    pub kind: String,
    #[serde(default, rename = "meetingID", alias = "meetingId")]
    pub meeting_id: Option<String>,
    #[serde(default)]
    pub timestamp: Option<f64>,
    pub created_at: f64,
    pub updated_at: f64,
    #[serde(default)]
    pub revision: u64,
    #[serde(default, rename = "sourceURL", alias = "sourceUrl")]
    pub source_url: String,
    #[serde(default)]
    pub owner: String,
    #[serde(default)]
    pub due: String,
    #[serde(default)]
    pub completed: bool,
    #[serde(default)]
    pub title: String,
    #[serde(default, rename = "contentRTF", alias = "contentRtf")]
    pub content_rtf: String,
    #[serde(default)]
    pub folder: String,
    #[serde(default, rename = "folderID", alias = "folderId")]
    pub folder_id: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub trashed_at: Option<f64>,
    #[serde(default)]
    pub attachments: Vec<NoteAttachment>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expansion: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_origin: Option<Value>,
    #[serde(default)]
    pub history: Vec<Value>,
    #[serde(default)]
    pub subtasks: Vec<Value>,
}
fn note_kind() -> String {
    "note".into()
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteTemplate {
    pub id: String,
    pub name: String,
    pub body: String,
    #[serde(default)]
    pub focus: String,
    #[serde(default)]
    pub revision: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeetingContext {
    #[serde(rename = "meetingID", alias = "meetingId")]
    pub meeting_id: String,
    #[serde(default)]
    pub project: String,
    #[serde(default)]
    pub person: String,
    #[serde(default, rename = "templateID", alias = "templateId")]
    pub template_id: Option<String>,
    #[serde(default, rename = "folderID", alias = "folderId")]
    pub folder_id: Option<String>,
    #[serde(default)]
    pub revision: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotesWorkspace {
    #[serde(default)]
    pub folders: Vec<Folder>,
    #[serde(default)]
    pub notes: Vec<CapturedNote>,
    #[serde(default)]
    pub templates: Vec<NoteTemplate>,
    #[serde(default)]
    pub contexts: Vec<MeetingContext>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub voice_plans: Vec<Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub voice_operations: Vec<Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub task_workspaces: Vec<super::tasks::TaskRecord>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub task_plans: Vec<Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub task_operations: Vec<Value>,
    #[serde(default)]
    pub task_integration: super::tasks::TaskIntegration,
}
pub(crate) fn defaults() -> NotesWorkspace {
    let templates = [
        ("purchases", "Закупки", "Цель встречи\n\nВопросы\n• Цена и скидки\n• Минимальная партия\n• Доставка\n• Оплата\n\nДоговорённости\n\nЧто уточнить", "Точные цены, валюты, скидки, объёмы, сроки доставки и оплаты. Отдельно — условия и открытые вопросы."),
        ("interview", "Собеседование", "Роль и контекст\n\nМои вопросы\n\nСильные ответы\n\nПробелы и что повторить\n\nСледующие шаги", "Вопросы собеседования, ответы, пробелы в знаниях и темы для повторения. Не додумывай оценки кандидата."),
        ("one-on-one", "Один на один", "Как дела\n\nЧто получилось\n\nЧто мешает\n\nОбратная связь\n\nДоговорённости", "Обратная связь, препятствия, ожидания и договорённости. Отделяй мнение от подтверждённых фактов."),
        ("english", "Английский", "Тема разговора\n\nНовые фразы\n\nЧто было трудно сказать\n\nОшибки и исправления\n\nЧто повторить", "Полезные английские фразы с контекстом, переводом и исправлениями, только если они подтверждены записью."),
    ].into_iter().map(|(id,name,body,focus)| NoteTemplate { id:id.into(),name:name.into(),body:body.into(),focus:focus.into(),revision:1 }).collect();
    NotesWorkspace {
        folders: vec![],
        notes: vec![],
        templates,
        contexts: vec![],
        voice_plans: vec![],
        voice_operations: vec![],
        task_workspaces: vec![],
        task_plans: vec![],
        task_operations: vec![],
        task_integration: Default::default(),
    }
}
pub(crate) fn task_signature(item: &Value) -> String {
    format!(
        "{:x}",
        Sha256::digest(
            serde_json::to_vec(&json!([item["text"], item["segmentIDs"]])).expect("JSON value")
        )
    )
}

#[cfg(test)]
mod tests {
    use super::super::workspace_validation::{validate_note, validate_workspace};
    use super::*;
    fn note() -> CapturedNote {
        serde_json::from_value(json!({"id":"n1","text":"Original", "createdAt":0,"updatedAt":0}))
            .unwrap()
    }
    #[test]
    fn legacy_aliases_round_trip_to_canonical_workspace_names() {
        let mut workspace = defaults();
        let mut value = serde_json::to_value(note()).unwrap();
        value["meetingId"] = json!("m1");
        value.as_object_mut().unwrap().remove("meetingID");
        value["contentRtf"] = json!("legacy-rich-text");
        value.as_object_mut().unwrap().remove("contentRTF");
        workspace.notes.push(serde_json::from_value(value).unwrap());
        validate_workspace(&workspace).unwrap();
        let persisted = serde_json::to_value(&workspace).unwrap();
        assert_eq!(persisted["notes"][0]["meetingID"], "m1");
        assert_eq!(persisted["notes"][0]["contentRTF"], "legacy-rich-text");
        assert!(persisted["notes"][0].get("meetingId").is_none());
        let reopened: NotesWorkspace = serde_json::from_value(persisted.clone()).unwrap();
        assert_eq!(serde_json::to_value(reopened).unwrap(), persisted);
    }
    #[test]
    fn dangling_membership_is_rejected_without_mutating_the_workspace() {
        let mut workspace = defaults();
        let mut draft = note();
        draft.folder_id = Some("missing-folder".into());
        workspace.notes.push(draft);
        let original = serde_json::to_value(&workspace).unwrap();
        assert!(validate_workspace(&workspace).is_err());
        assert_eq!(serde_json::to_value(&workspace).unwrap(), original);
    }
    #[test]
    fn serialized_attachment_paths_are_platform_independent() {
        let mut draft = note();
        draft.attachments.push(NoteAttachment {
            id: "a1".into(),
            name: "image.png".into(),
            relative_path: "notes/attachments/a1.png".into(),
            content_type: "image/png".into(),
            extracted_text: String::new(),
        });
        validate_note(&draft).unwrap();
        for path in [
            "notes/attachments/a1.png/extra",
            "notes/attachments/a1../outside.png",
            "notes/attachments/a1.\\outside.png",
            "notes/attachments/a1.pdf",
        ] {
            draft.attachments[0].relative_path = path.into();
            assert!(
                validate_note(&draft).is_err(),
                "Accepted unsafe or mismatched attachment: {path}"
            );
        }
    }
    #[test]
    fn task_material_contract_is_validated_without_loading_a_repository() {
        let mut workspace = defaults();
        workspace
            .task_workspaces
            .push(super::super::tasks::TaskRecord {
                note_id: "n1".into(),
                status: "todo".into(),
                source: "local".into(),
                ..Default::default()
            });
        validate_workspace(&workspace).unwrap();
        workspace.task_workspaces[0].source = "unrecognised-provider".into();
        assert!(validate_workspace(&workspace).is_err());
    }
}
