//! Grant-free queue state and pagination shared by native job kinds.
use serde::{Deserialize, Serialize};

/// Public pagination key contains no file grant or receipt capability.
#[derive(Clone, Serialize, Deserialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HistoryCursor {
    pub created_at: f64,
    pub id: String,
}
impl HistoryCursor {
    pub fn valid(&self) -> bool {
        self.created_at.is_finite()
            && self.id.len() == 36
            && uuid::Uuid::parse_str(&self.id).is_ok()
    }
    pub fn follows(&self, previous: &Self) -> bool {
        self.created_at < previous.created_at
            || (self.created_at == previous.created_at && self.id < previous.id)
    }
}

#[derive(Clone, Copy, Serialize, Deserialize, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
    Interrupted,
    Blocked,
}
