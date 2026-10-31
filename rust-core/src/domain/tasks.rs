//! Task workspace values shared across transports and repositories.
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct TaskIntegration {
    pub enabled: bool,
    pub revision: u64,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct AgentAccess {
    pub enabled: bool,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskClaim {
    pub id: String,
    pub agent_id: String,
    pub claimed_at: f64,
    pub context_version: String,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct TaskMaterial {
    pub id: String,
    pub kind: String,
    pub title: String,
    #[serde(rename = "noteID")]
    pub note_id: Option<String>,
    #[serde(rename = "meetingID")]
    pub meeting_id: Option<String>,
    #[serde(rename = "segmentIDs")]
    pub segment_ids: Vec<u64>,
    #[serde(rename = "attachmentID")]
    pub attachment_id: Option<String>,
    pub path: Option<String>,
    pub url: Option<String>,
    pub shared: bool,
    pub created_at: f64,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct TaskArtifact {
    pub id: String,
    pub title: String,
    pub kind: String,
    pub text: String,
    pub url: Option<String>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskEvent {
    pub id: String,
    pub kind: String,
    pub text: String,
    pub actor: String,
    pub created_at: f64,
    #[serde(default)]
    pub artifacts: Vec<TaskArtifact>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<Value>,
    #[serde(default, rename = "claimID", skip_serializing_if = "Option::is_none")]
    pub claim_id: Option<String>,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct TaskRecord {
    #[serde(rename = "noteID")]
    pub note_id: String,
    pub status: String,
    pub source: String,
    #[serde(rename = "externalURL")]
    pub external_url: String,
    pub project: String,
    pub materials: Vec<TaskMaterial>,
    pub history: Vec<TaskEvent>,
    pub agent_access: AgentAccess,
    pub claim: Option<TaskClaim>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskMaterialView {
    #[serde(flatten)]
    pub material: TaskMaterial,
    pub text: Option<String>,
    pub available: bool,
    pub note_revision: Option<u64>,
    pub source_fingerprint: Option<String>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskDetails {
    pub id: String,
    pub title: String,
    pub text: String,
    pub status: String,
    pub completed: bool,
    pub owner: String,
    pub due: String,
    pub source: String,
    #[serde(rename = "externalURL")]
    pub external_url: String,
    pub project: String,
    pub revision: u64,
    pub created_at: f64,
    pub updated_at: f64,
    #[serde(rename = "virtual")]
    pub virtual_task: bool,
    #[serde(rename = "meetingID")]
    pub meeting_id: Option<String>,
    pub source_fingerprint: String,
    pub materials: Vec<TaskMaterialView>,
    pub history: Vec<TaskEvent>,
    pub material_count: usize,
    pub history_count: usize,
    pub agent_access: AgentAccess,
    pub claim: Option<TaskClaim>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskContext {
    pub task: TaskDetails,
    pub materials: Vec<TaskMaterialView>,
    pub context_version: String,
    pub generated_at: f64,
    pub truncated: bool,
}
