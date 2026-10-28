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
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "get_workspace",
            "get_meeting",
            "save_note",
            "save_folder",
            "search_library",
        ]),
    ))
    .expect("Tauri build configuration");
}
