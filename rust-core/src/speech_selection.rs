//! Native selection facade. Only opaque revisions/generation IDs are public;
//! neither private settings nor model paths are renderer response fields.
use crate::{
    application::speech_selection::{self, SelectionPort},
    infrastructure::speech_selection::Selection,
};
use anyhow::Result;
use serde::Serialize;
use std::path::Path;
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectionStatus {
    pub revision: String,
    pub local: bool,
}
pub fn status(root: &Path) -> Result<SelectionStatus> {
    let settings = Selection::new(root)?.settings()?;
    Ok(SelectionStatus {
        revision: settings.revision,
        local: settings.value["speechMode"].as_str() == Some("local"),
    })
}
pub fn select(root: &Path, generation: &str, expected_revision: &str) -> Result<SelectionStatus> {
    speech_selection::validate(generation, expected_revision)?;
    let selection = Selection::new(root)?;
    let revision = speech_selection::select(&selection, generation, expected_revision)?;
    Ok(SelectionStatus {
        revision,
        local: true,
    })
}
