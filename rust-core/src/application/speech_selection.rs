//! Explicit managed-model selection, independent of filesystem/model adapters.
use anyhow::{ensure, Result};
use serde_json::{json, Value};
pub(crate) struct Settings {
    pub value: Value,
    pub revision: String,
}
pub(crate) trait SelectionPort {
    type Guard;
    fn settings(&self) -> Result<Settings>;
    fn model(&self, generation: &str) -> Result<(String, Self::Guard)>;
    fn commit(&self, expected: &str, value: &Value, guard: &Self::Guard) -> Result<String>;
}
pub(crate) fn validate(generation: &str, expected: &str) -> Result<()> {
    let id = uuid::Uuid::parse_str(generation)?;
    ensure!(
        id.get_version_num() == 4 && id.to_string() == generation,
        "Invalid model generation"
    );
    ensure!(
        expected.len() == 64
            && expected
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "Invalid settings revision"
    );
    Ok(())
}
pub(crate) fn select(
    port: &impl SelectionPort,
    generation: &str,
    expected: &str,
) -> Result<String> {
    validate(generation, expected)?;
    let mut settings = port.settings()?;
    ensure!(
        settings.revision == expected,
        crate::domain::config::SettingsConflict
    );
    let (path, guard) = port.model(generation)?;
    let object = settings
        .value
        .as_object_mut()
        .ok_or_else(|| anyhow::anyhow!("Settings must be an object"))?;
    for (key, value) in [
        ("speechMode", json!("local")),
        ("speechLocalModel", json!("parakeet-v3")),
        ("asrModelPath", json!(path)),
        ("asrModelFormat", json!("onnx")),
        ("diarization", json!(false)),
    ] {
        object.insert(key.into(), value);
    }
    port.commit(expected, &settings.value, &guard)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};
    struct Port {
        settings: RefCell<Value>,
        revision: RefCell<String>,
        model_calls: Cell<u32>,
    }
    impl SelectionPort for Port {
        type Guard = ();
        fn settings(&self) -> Result<Settings> {
            Ok(Settings {
                value: self.settings.borrow().clone(),
                revision: self.revision.borrow().clone(),
            })
        }
        fn model(&self, _: &str) -> Result<(String, ())> {
            self.model_calls.set(self.model_calls.get() + 1);
            Ok(("/verified/managed/model".into(), ()))
        }
        fn commit(&self, expected: &str, value: &Value, _: &()) -> Result<String> {
            ensure!(*self.revision.borrow() == expected);
            *self.settings.borrow_mut() = value.clone();
            *self.revision.borrow_mut() = "b".repeat(64);
            Ok("b".repeat(64))
        }
    }
    fn port() -> Port {
        Port {
            settings: RefCell::new(
                json!({"speechMode":"cloud","speechLocalModel":"whisper-small","diarization":true,"credential":"private-fixture","future":{"preserve":true},"language":"ru"}),
            ),
            revision: RefCell::new("a".repeat(64)),
            model_calls: Cell::new(0),
        }
    }
    #[test]
    fn explicit_selection_updates_only_speech_fields_and_preserves_private_extensions() {
        let port = port();
        let generation = uuid::Uuid::new_v4().to_string();
        assert_eq!(
            select(&port, &generation, &"a".repeat(64)).unwrap(),
            "b".repeat(64)
        );
        let value = port.settings.borrow();
        assert_eq!(value["credential"], "private-fixture");
        assert_eq!(value["future"], json!({"preserve":true}));
        assert_eq!(value["language"], "ru");
        assert_eq!(value["speechMode"], "local");
        assert_eq!(value["asrModelPath"], "/verified/managed/model");
        assert_eq!(value["asrModelFormat"], "onnx");
        assert_eq!(value["speechLocalModel"], "parakeet-v3");
        assert_eq!(value["diarization"], false);
    }
    #[test]
    fn stale_or_invalid_requests_do_not_verify_a_model_or_change_settings() {
        let port = port();
        let original = port.settings.borrow().clone();
        let generation = uuid::Uuid::new_v4().to_string();
        for (id, revision) in [
            ("../outside".to_string(), "a".repeat(64)),
            (generation.clone(), "z".repeat(64)),
            (generation, "c".repeat(64)),
        ] {
            assert!(select(&port, &id, &revision).is_err());
        }
        assert_eq!(port.model_calls.get(), 0);
        assert_eq!(*port.settings.borrow(), original);
    }
}
