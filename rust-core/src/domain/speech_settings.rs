//! Minimal local-speech selection. App/integration credentials never belong to
//! a durable transcription job; unrelated settings remain in their own stores.
use anyhow::{ensure, Result};
use serde_json::{json, Value};

pub(crate) fn local_snapshot(settings: &Value) -> Result<Value> {
    ensure!(
        settings["speechMode"].as_str() == Some("local"),
        "Select local speech explicitly"
    );
    ensure!(
        settings["diarization"].as_bool() == Some(false),
        "This executor requires diarization=false"
    );
    let path = settings["asrModelPath"]
        .as_str()
        .filter(|path| !path.trim().is_empty())
        .ok_or_else(|| anyhow::anyhow!("Select an explicit local ASR model"))?;
    let mut frozen = json!({"speechMode":"local", "diarization":false, "asrModelPath":path.trim()});
    if let Some(format) = settings.get("asrModelFormat") {
        ensure!(
            matches!(format.as_str(), Some("auto" | "onnx" | "mlx")),
            "Unsupported ASR model format"
        );
        frozen["asrModelFormat"] = format.clone();
    }
    if let Some(model) = settings.get("speechLocalModel") {
        ensure!(
            model.as_str().is_some_and(|name| !name.trim().is_empty()),
            "Invalid local speech model"
        );
        frozen["speechLocalModel"] = model.clone();
    }
    Ok(frozen)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn freezes_only_explicit_local_selection_and_never_copies_other_settings() {
        let input = json!({"speechMode":"local","diarization":false,"asrModelPath":" /selected/model ",
            "asrModelFormat":"onnx","speechLocalModel":"parakeet-v3","speechApiKey":"private-fixture",
            "aiApiKey":"private-fixture","integration":{"token":"private-fixture"}});
        let result = local_snapshot(&input).unwrap();
        assert_eq!(
            result,
            json!({"speechMode":"local","diarization":false,"asrModelPath":"/selected/model",
            "asrModelFormat":"onnx","speechLocalModel":"parakeet-v3"})
        );
        assert!(!result.to_string().contains("private-fixture"));
    }
    #[test]
    fn missing_or_unsupported_selection_never_falls_back() {
        let base =
            json!({"speechMode":"local","diarization":false,"asrModelPath":"/selected/model"});
        for (key, value) in [
            ("speechMode", json!("cloud")),
            ("speechMode", Value::Null),
            ("diarization", json!(true)),
            ("diarization", Value::Null),
            ("asrModelPath", json!(" ")),
            ("asrModelPath", Value::Null),
            ("asrModelFormat", json!("unknown")),
            ("speechLocalModel", json!(false)),
        ] {
            let mut input = base.clone();
            input[key] = value;
            assert!(local_snapshot(&input).is_err(), "{key}");
        }
    }
}
