//! Closed metadata operations, independent of the leased speech executor.
use super::*;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Select {
    generation: String,
    expected_revision: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Empty {}
pub(super) fn dispatch(root: &Path, command: &str, arguments: Value) -> Result<Value> {
    #[cfg(unix)]
    match command {
        "get_speech_model_configuration" => {
            let _: Empty = parse(arguments)?;
            Ok(
                serde_json::to_value(domain(crate::speech_selection::configuration(root))?)
                    .map_err(|_| BridgeError::library())?,
            )
        }
        "select_managed_speech_model" => {
            let args: Select = parse(arguments)?;
            crate::application::speech_selection::validate(
                &args.generation,
                &args.expected_revision,
            )
            .map_err(|_| BridgeError::invalid())?;
            Ok(serde_json::to_value(domain(crate::speech_selection::select(
                root,
                &args.generation,
                &args.expected_revision,
            ))?)
            .map_err(|_| BridgeError::library())?)
        }
        _ => Err(BridgeError::invalid()),
    }
    #[cfg(not(unix))]
    {
        let _ = (root, command, arguments);
        Err(BridgeError {
            code: "unsupported_platform",
            message: "Managed speech selection is unavailable on this platform.",
        })
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    fn call(root: &Path, command: &str, arguments: Value) -> Value {
        crate::desktop::handle_bytes(root, &serde_json::to_vec(&json!({"command":command,"arguments":arguments})).unwrap())
    }
    #[test]
    fn candidate_metadata_is_not_a_model_grant_and_private_settings_stay_private() {
        let root = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
        let generation = Uuid::new_v4().to_string();
        let scope = root.path().join("runtime/asr-models/parakeet-v3-int8");
        crate::platform_fs::private_directory(&scope).unwrap();
        let directory = scope
            .join(&generation)
            .join("sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8");
        let receipt = json!({"schemaVersion":1,"modelId":"parakeet-v3-int8","generation":generation,"directory":directory,"version":"parakeet-tdt-0.6b-v3-int8"});
        storage::atomic_json(&scope.join("active.json"), &receipt).unwrap();
        let settings =
            json!({"speechMode":"cloud","apiKey":"private-model-fixture","future":{"keep":true}});
        storage::atomic_json(&root.path().join("settings.json"), &settings).unwrap();
        let view = call(root.path(), "get_speech_model_configuration", json!({}));
        assert_eq!(view["ok"], true);
        assert_eq!(view["result"]["candidate"]["generation"], generation);
        assert!(!view.to_string().contains("private-model-fixture"));
        assert!(!view.to_string().contains("directory"));
        assert_eq!(view["result"]["candidate"].as_object().unwrap().len(), 2);
        let selected = call(
            root.path(),
            "select_managed_speech_model",
            json!({"generation":generation,"expectedRevision":view["result"]["selection"]["revision"]}),
        );
        assert_eq!(selected["error"]["code"], "library_error");
        assert_eq!(
            storage::regular_json(&root.path().join("settings.json")).unwrap(),
            settings
        );
        storage::atomic_json(&root.path().join("settings.json"), &json!({"changed":true})).unwrap();
        let stale = call(
            root.path(),
            "select_managed_speech_model",
            json!({"generation":generation,"expectedRevision":view["result"]["selection"]["revision"]}),
        );
        assert_eq!(stale["error"]["code"], "conflict");
        assert_eq!(
            call(
                root.path(),
                "get_speech_model_configuration",
                json!({"path":"/private"})
            )["error"]["code"],
            "invalid_request"
        );
        storage::atomic_json(
            &scope.join("active.json"),
            &json!({"private":"do-not-echo"}),
        )
        .unwrap();
        let invalid = call(root.path(), "get_speech_model_configuration", json!({}));
        assert_eq!(invalid["error"]["code"], "library_error");
        assert!(!invalid.to_string().contains("do-not-echo"));
    }
}
