//! Explicit native boundary for the desktop migration. The React client is
//! portable; that alone does not make the existing process/filesystem adapters
//! portable. Packaging can share these target names without guessing suffixes.
use serde_json::{json, Value};

pub fn engine_executable(os: &str) -> Option<&'static str> {
    match os {
        "macos" | "linux" => Some("posle-engine"),
        "windows" => Some("posle-engine.exe"),
        _ => None,
    }
}

pub fn manifest() -> Value {
    json!({
        "os":std::env::consts::OS,
        "arch":std::env::consts::ARCH,
        "engineExecutable":engine_executable(std::env::consts::OS),
        "libraryBackend":"existing-rust-core",
        "nativeAdapters":{
            "recording":"not_connected",
            "calendar":"not_connected",
            "credentials":"not_connected",
            "speech":"not_connected"
        },
        "portability":{
            "macos":"development",
            "linux":"not_verified",
            "windows":"requires_filesystem_and_process_adapters"
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_asset_names_are_explicit_without_claiming_engine_support() {
        assert_eq!(engine_executable("macos"), Some("posle-engine"));
        assert_eq!(engine_executable("linux"), Some("posle-engine"));
        assert_eq!(engine_executable("windows"), Some("posle-engine.exe"));
        assert_eq!(engine_executable("other"), None);
        assert_eq!(
            manifest()["portability"]["windows"],
            "requires_filesystem_and_process_adapters"
        );
        assert_eq!(manifest()["nativeAdapters"]["recording"], "not_connected");
    }
}
