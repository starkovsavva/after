//! Typed identities for future knowledge sources. No new source is exposed to
//! external agents by introducing these types.
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum SourceKind {
    Note, Meeting, Transcript, Summary, Card, Task, TaskEvent, TaskArtifact, Calendar, Code,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SourceRef {
    #[serde(rename = "libraryID")]
    pub library_id: String,
    pub kind: SourceKind,
    #[serde(rename = "objectID")]
    pub object_id: String,
    #[serde(rename = "subID", default)]
    pub sub_id: Option<String>,
}

fn identifier(value: &str) -> bool {
    !value.is_empty() && value.len() <= 512 &&
        !value.chars().any(|c| c.is_control())
}
fn fingerprint(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

impl SourceRef {
    pub fn validate(&self) -> Result<()> {
        ensure!(Uuid::parse_str(&self.library_id).is_ok(), "Некорректный идентификатор библиотеки");
        ensure!(identifier(&self.object_id), "Некорректный идентификатор источника");
        ensure!(self.sub_id.as_ref().is_none_or(|s| identifier(s)), "Некорректный идентификатор фрагмента");
        if self.kind == SourceKind::Note {
            ensure!(self.sub_id.is_none() && self.object_id.len() <= 128 &&
                self.object_id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'),
                "Некорректная ссылка на заметку");
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SourceVersion {
    #[serde(rename = "ref")]
    pub source: SourceRef,
    pub entity_revision: Option<u64>,
    pub content_fingerprint: String,
    pub policy_revision: u64,
}
impl SourceVersion {
    pub fn validate(&self) -> Result<()> {
        self.source.validate()?;
        ensure!(fingerprint(&self.content_fingerprint), "Некорректный отпечаток источника");
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct EvidenceAnchor {
    #[serde(rename = "ref")]
    pub source: SourceRef,
    pub content_fingerprint: String,
    #[serde(rename = "spanID")]
    pub span_id: String,
    pub quote_hash: String,
    #[serde(rename = "startUTF8", default)]
    pub start_utf8: Option<u64>,
    #[serde(rename = "endUTF8", default)]
    pub end_utf8: Option<u64>,
    pub prefix_hash: Option<String>,
    pub suffix_hash: Option<String>,
}
impl EvidenceAnchor {
    pub fn validate(&self) -> Result<()> {
        self.source.validate()?;
        ensure!(identifier(&self.span_id) && fingerprint(&self.content_fingerprint) &&
            fingerprint(&self.quote_hash), "Некорректная цитата");
        ensure!(self.prefix_hash.as_ref().is_none_or(|v| fingerprint(v)) &&
            self.suffix_hash.as_ref().is_none_or(|v| fingerprint(v)), "Некорректный контекст цитаты");
        ensure!(match (self.start_utf8, self.end_utf8) {
            (None, None) => true,
            (Some(start), Some(end)) => start < end,
            _ => false,
        }, "Некорректные границы цитаты");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn identities_are_closed_and_note_ids_are_not_paths() {
        let library = Uuid::new_v4().to_string();
        let mut v = json!({"libraryID": library, "kind":"note", "objectID":"Note_42"});
        let r: SourceRef = serde_json::from_value(v.clone()).unwrap();
        assert!(r.validate().is_ok());
        v["objectID"] = json!("../secrets");
        assert!(serde_json::from_value::<SourceRef>(v.clone()).unwrap().validate().is_err());
        v["kind"] = json!("unrecognized");
        assert!(serde_json::from_value::<SourceRef>(v).is_err());
    }
}
