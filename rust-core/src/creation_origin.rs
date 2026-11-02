//! Immutable creation provenance. Unknown future strings remain round-trippable
//! so editing a record never destroys metadata written by a newer client.
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
