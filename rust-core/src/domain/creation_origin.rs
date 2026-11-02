//! Immutable creation provenance. Unknown future strings remain round-trippable
//! so editing a record never destroys metadata written by a newer client.
use serde_json::Value;
use std::collections::BTreeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CreationOrigin {
    Manual,
    Ai,
    Imported,
    Unknown,
    Future(String),
}

impl Serialize for CreationOrigin {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(match self {
            Self::Manual => "manual",
            Self::Ai => "ai",
            Self::Imported => "imported",
            Self::Unknown => "unknown",
            Self::Future(value) => value,
        })
    }
}

impl<'de> Deserialize<'de> for CreationOrigin {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(match String::deserialize(deserializer)?.as_str() {
            "manual" => Self::Manual,
            "ai" => Self::Ai,
            "imported" => Self::Imported,
            "unknown" => Self::Unknown,
            value => Self::Future(value.to_owned()),
        })
    }
}

/// Every writer, including raw workspace operations and undo, retains the
/// original provenance. Missing legacy values and future strings are metadata
/// too; neither editing nor adding AI content classifies an old record.
pub(crate) fn preserve_note_creation_origins(previous: &Value, value: &mut Value) {
    let origins = previous["notes"].as_array().into_iter().flatten()
        .filter_map(|note| note["id"].as_str().map(|id| (id, note.get("creationOrigin"))))
        .collect::<BTreeMap<_, _>>();
    for note in value["notes"].as_array_mut().into_iter().flatten() {
        let Some(origin) = note["id"].as_str().and_then(|id| origins.get(id)) else { continue; };
        let Some(object) = note.as_object_mut() else { continue; };
        match origin {
            Some(origin) => { object.insert("creationOrigin".into(), (*origin).clone()); }
            None => { object.remove("creationOrigin"); }
        }
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_and_future_origins_round_trip_without_reclassification() {
        for value in ["manual", "ai", "imported", "unknown", "future-provenance"] {
            let origin: CreationOrigin = serde_json::from_value(serde_json::json!(value)).unwrap();
            assert_eq!(serde_json::to_value(origin).unwrap(), value);
        }
        assert_eq!(
            serde_json::from_value::<CreationOrigin>(serde_json::json!("future-provenance")).unwrap(),
            CreationOrigin::Future("future-provenance".into())
        );
        assert!(serde_json::from_value::<CreationOrigin>(serde_json::json!(7)).is_err());
    }
}
