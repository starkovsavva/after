#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("--check-linux-smoke")) {
        // Release must refuse before creating a window or resolving its normal
        // library: AFTER_DATA_DIR overrides are deliberately debug-only.
        if !cfg!(all(debug_assertions, target_os = "linux")) {
            eprintln!("Linux smoke requires a debug build");
            std::process::exit(2);
        }
        let root = std::env::var_os("AFTER_DATA_DIR").map(std::path::PathBuf::from);
        let valid = root.as_ref().is_some_and(|root| {
            root.is_absolute()
                && !root.exists()
                && root.file_name() == Some(std::ffi::OsStr::new("library"))
                && root.parent().is_some_and(|parent| {
                    parent.file_name().is_some_and(|name| {
                        name.to_string_lossy().starts_with("after-linux-smoke-")
                    }) && std::fs::symlink_metadata(parent)
                        .is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink())
                        && parent
                            .canonicalize()
                            .ok()
                            .zip(std::env::temp_dir().canonicalize().ok())
                            .is_some_and(|(parent, temp)| parent.parent() == Some(temp.as_path()))
                })
        });
        if !valid {
            eprintln!("Linux smoke requires a fresh owned temporary fixture");
            std::process::exit(2);
        }
    }
    after_desktop::run();
}
