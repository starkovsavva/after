//! Compatibility entry point for the durable queue used by native clients.
//! SQLite and filesystem access live in infrastructure; scheduling policy is shared.
pub use crate::domain::jobs::Job;
use anyhow::Result;
use serde_json::Value;
use std::path::Path;

pub fn dispatch(root: &Path, value: &Value) -> Result<Value> {
    crate::infrastructure::job_queue::dispatch(root, value)
}
