use sha2::{Digest, Sha256};
use std::{env, fs, path::PathBuf};

fn main() {
    let target = env::var("TARGET").expect("Cargo target");
    let suffix = if target.contains("windows") {
        ".exe"
    } else {
        ""
    };
    let name = format!("posle-engine-{target}{suffix}");
    let path = PathBuf::from("binaries").join(&name);
    println!("cargo:rerun-if-changed={}", path.display());
    let digest = match fs::symlink_metadata(&path) {
        Ok(meta) if meta.is_file() && !meta.file_type().is_symlink() => {
            let bytes = fs::read(&path).expect("Read staged engine");
            assert!(!bytes.is_empty(), "Staged engine must not be empty");
            if target.contains("windows") {
                verify_windows_engine(&bytes, &target);
            }
            format!("{:x}", Sha256::digest(bytes))
        }
        Ok(_) => panic!("Staged engine must be a regular file"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            assert!(env::var("PROFILE").as_deref() != Ok("release"),
                "A release preview requires the staged canonical engine for {target}; run scripts/stage-desktop-engine.py first");
            String::new()
        }
        Err(error) => panic!("Cannot inspect staged engine: {error}"),
    };
    println!("cargo:rustc-env=AFTER_ENGINE_NAME={name}");
    println!("cargo:rustc-env=AFTER_ENGINE_SHA256={digest}");
    speech_backend();
    let attributes =
        tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
            "get_workspace",
            "get_speech_model_configuration",
            "select_managed_speech_model",
            "transcription_status",
            "start_transcription",
            "resume_transcription",
            "cancel_transcription",
            "speech_check_status",
            "start_speech_check",
            "cancel_speech_check",
            "get_meeting",
            "choose_and_import",
            "import_status",
            "cancel_import",
            "import_history",
            "resume_import",
            "cancel_queued_import",
            "start_recording",
            "recording_status",
            "stop_recording",
            "recoverable_recordings",
            "recover_recording",
            "feature_operation",
            "save_note",
            "save_folder",
            "search_library",
        ]));
    let attributes = with_windows_test_manifest(attributes, &target);
    tauri_build::try_build(attributes).expect("Tauri build configuration");
}

fn with_windows_test_manifest(
    attributes: tauri_build::Attributes,
    target: &str,
) -> tauri_build::Attributes {
    if !target.ends_with("-windows-msvc") {
        return attributes;
    }
    // Tauri 2.7.4 links its resource manifest into application binaries only.
    // The lib unit-test harness then loads legacy ComCtl32 and fails before
    // Rust's test runner starts (STATUS_ENTRYPOINT_NOT_FOUND). Apply the same
    // canonical manifest to every linked artifact, including unit/integration
    // tests. Keep Common Controls v6 enabled and avoid embedding it twice in
    // the application .res. Maintainer workaround:
    // https://github.com/tauri-apps/tauri/issues/13419
    let manifest =
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("Cargo manifest directory"))
            .join("windows-app-manifest.xml");
    println!("cargo:rerun-if-changed={}", manifest.display());
    println!("cargo:rustc-link-arg=/MANIFEST:EMBED");
    println!("cargo:rustc-link-arg=/MANIFESTINPUT:{}", manifest.display());
    // Do not silently ship an artifact whose manifest was skipped by the linker.
    println!("cargo:rustc-link-arg=/WX");
    attributes.windows_attributes(tauri_build::WindowsAttributes::new_without_app_manifest())
}

// Fail before bundling a Mac/ELF resource or a wrong-architecture Windows engine.
fn verify_windows_engine(bytes: &[u8], target: &str) {
    assert!(
        bytes.len() >= 64 && &bytes[..2] == b"MZ",
        "The staged Windows engine must be a PE executable"
    );
    let offset = u32::from_le_bytes(bytes[60..64].try_into().unwrap()) as usize;
    let header = bytes
        .get(offset..offset.saturating_add(24))
        .expect("Truncated PE header");
    assert!(&header[..4] == b"PE\0\0", "Invalid Windows PE signature");
    let machine = u16::from_le_bytes(header[4..6].try_into().unwrap());
    let expected = if target.starts_with("x86_64-") {
        0x8664
    } else if target.starts_with("aarch64-") {
        0xaa64
    } else {
        panic!("Unsupported Windows preview target: {target}")
    };
    assert_eq!(
        machine, expected,
        "The staged engine has the wrong Windows architecture"
    );
    let characteristics = u16::from_le_bytes(header[22..24].try_into().unwrap());
    assert!(
        characteristics & 2 != 0 && characteristics & 0x2000 == 0,
        "The staged engine must be an executable, not a DLL"
    );
}

// Pin app-owned Python source from this checkout, never from an untrusted runtime
// manifest. A stale/partial stage cannot silently change the bundled backend.
fn speech_backend() {
    let source = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("../../backend");
    let catalog = source.join("desktop-speech-files.json");
    println!("cargo:rerun-if-changed={}", catalog.display());
    let names: Vec<String> =
        serde_json::from_slice(&fs::read(catalog).expect("Read speech catalog"))
            .expect("Speech catalog array");
    assert!(
        !names.is_empty() && names.len() <= 32,
        "Invalid speech catalog"
    );
    let unique: std::collections::BTreeSet<_> = names.iter().collect();
    assert_eq!(unique.len(), names.len(), "Duplicate speech module");
    let stage = PathBuf::from("binaries/speech-backend");
    println!("cargo:rerun-if-changed={}", stage.display());
    let staged = match fs::symlink_metadata(&stage) {
        Ok(meta) => {
            assert!(
                meta.is_dir() && !meta.file_type().is_symlink(),
                "Speech stage must be an ordinary directory"
            );
            true
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            assert!(
                env::var("PROFILE").as_deref() != Ok("release"),
                "Release requires scripts/stage-desktop-engine.py to stage speech resources"
            );
            false
        }
        Err(error) => panic!("Cannot inspect speech stage: {error}"),
    };
    let mut inventory = Vec::new();
    for name in &names {
        assert!(
            name.ends_with(".py")
                && name
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b == b'_' || b == b'.'),
            "Invalid speech module name"
        );
        let original = source.join(name);
        println!("cargo:rerun-if-changed={}", original.display());
        let metadata = fs::symlink_metadata(&original).expect("Speech source metadata");
        assert!(
            metadata.is_file() && !metadata.file_type().is_symlink(),
            "Speech source must be ordinary"
        );
        let bytes = fs::read(original).expect("Read speech source");
        assert!(
            !bytes.is_empty() && bytes.len() <= 1024 * 1024,
            "Invalid speech source size"
        );
        if staged {
            let path = stage.join(name);
            let metadata = fs::symlink_metadata(&path)
                .expect("Speech stage is incomplete; rerun scripts/stage-desktop-engine.py");
            assert!(
                metadata.is_file() && !metadata.file_type().is_symlink(),
                "Speech stage contains an alias"
            );
            assert_eq!(
                fs::read(path).expect("Read speech stage"),
                bytes,
                "Speech stage is stale; rerun scripts/stage-desktop-engine.py"
            );
        }
        inventory.push(serde_json::json!({"name":name,"size":bytes.len(),"sha256":format!("{:x}",Sha256::digest(&bytes))}));
    }
    if staged {
        let actual: std::collections::BTreeSet<_> = fs::read_dir(&stage)
            .unwrap()
            .map(|entry| {
                entry
                    .unwrap()
                    .file_name()
                    .into_string()
                    .expect("UTF-8 speech module")
            })
            .collect();
        assert_eq!(
            actual,
            names.into_iter().collect(),
            "Unexpected speech stage content; rerun scripts/stage-desktop-engine.py"
        );
    }
    println!(
        "cargo:rustc-env=AFTER_SPEECH_BACKEND_INVENTORY={}",
        serde_json::to_string(&inventory).unwrap()
    );
}
