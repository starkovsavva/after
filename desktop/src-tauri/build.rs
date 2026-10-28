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
            format!("{:x}", Sha256::digest(bytes))
        }
        Ok(_) => panic!("Staged engine must be a regular file"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => panic!("Cannot inspect staged engine: {error}"),
    };
    println!("cargo:rustc-env=AFTER_ENGINE_NAME={name}");
    println!("cargo:rustc-env=AFTER_ENGINE_SHA256={digest}");
    let attributes =
        tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
            "get_workspace",
            "get_meeting",
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
