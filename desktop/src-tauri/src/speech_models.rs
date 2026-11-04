//! Grant-free selection DTOs. Candidate metadata is not model readiness.
use crate::models::HostError;
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SelectionStatus {
    pub revision: String,
    pub local: bool,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelCandidate {
    pub generation: String,
    pub model_id: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelConfiguration {
    pub selection: SelectionStatus,
    #[serde(deserialize_with = "required_candidate")]
    pub candidate: Option<ModelCandidate>,
}
fn required_candidate<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<ModelCandidate>, D::Error> {
    Option::<ModelCandidate>::deserialize(deserializer)
}
pub(crate) fn revision_valid(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub(crate) fn generation_valid(value: &str) -> bool {
    uuid::Uuid::parse_str(value)
        .is_ok_and(|id| id.get_version_num() == 4 && id.to_string() == value)
}
pub(crate) fn invalid() -> HostError {
    HostError::new(
        "invalid_response",
        "Speech model configuration is unavailable.",
    )
}
impl SelectionStatus {
    pub(crate) fn validate(&self) -> Result<(), HostError> {
        if revision_valid(&self.revision) {
            Ok(())
        } else {
            Err(invalid())
        }
    }
}
impl ModelConfiguration {
    pub(crate) fn validate(&self) -> Result<(), HostError> {
        self.selection.validate()?;
        if self.candidate.as_ref().is_some_and(|candidate| {
            !generation_valid(&candidate.generation)
                || crate::models::validate_id(&candidate.model_id).is_err()
        }) {
            return Err(invalid());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn candidate_dtos_accept_only_bounded_opaque_identities() {
        let valid = json!({"selection":{"revision":"a".repeat(64),"local":false},"candidate":{"generation":"11111111-1111-4111-8111-111111111111","modelId":"parakeet-v3-int8"}});
        serde_json::from_value::<ModelConfiguration>(valid.clone())
            .unwrap()
            .validate()
            .unwrap();
        let mut invalid = valid.clone();
        invalid["candidate"]["generation"] = json!("../private");
        assert!(serde_json::from_value::<ModelConfiguration>(invalid)
            .unwrap()
            .validate()
            .is_err());
        let mut private = valid;
        private["candidate"]["directory"] = json!("/private/model");
        assert!(serde_json::from_value::<ModelConfiguration>(private).is_err());
        assert!(!revision_valid(&"z".repeat(64)));
        assert!(serde_json::from_value::<ModelConfiguration>(
            json!({"selection":{"revision":"a".repeat(64),"local":false}})
        )
        .is_err());
    }
}
