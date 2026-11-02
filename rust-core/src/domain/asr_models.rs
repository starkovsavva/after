//! Native deployment receipt. This is not a renderer grant or ASR-ready capability.
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledAsrModel {
    pub schema_version: u32,
    pub model_id: String,
    pub generation: String,
    pub directory: String,
    pub version: String,
}
