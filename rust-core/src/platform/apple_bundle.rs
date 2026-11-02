//! Apple bundle layout compatibility; no lifecycle or processing policy.
use std::path::{Path, PathBuf};
/// Resolve the outer application from either its compatibility CLI executable
/// or one of its nested helper applications. Helper resources belong to the
/// enclosing product, rather than the helper's own Contents directory.
pub fn application_contents(executable: &Path) -> Option<&Path> {
    let contents = executable
        .parent()
        .filter(|path| path.file_name().is_some_and(|name| name == "MacOS"))?
        .parent()
        .filter(|path| path.file_name().is_some_and(|name| name == "Contents"))?;
    let package = contents
        .parent()
        .filter(|path| path.extension().is_some_and(|name| name == "app"))?;
    if let Some(outer) = package
        .parent()
        .filter(|path| path.file_name().is_some_and(|name| name == "Helpers"))
        .and_then(Path::parent)
        .filter(|path| path.file_name().is_some_and(|name| name == "Contents"))
        .filter(|path| {
            path.parent()
                .is_some_and(|parent| parent.extension().is_some_and(|name| name == "app"))
        })
    {
        return Some(outer);
    }
    Some(contents)
}

/// Production uses a separately branded native helper inside the app. The
/// ordinary engine binary supports the same private entry point for developers.
pub(crate) fn native_host_path(engine: &Path) -> PathBuf {
    application_contents(engine)
        .map(|contents| {
            let directory = contents.join("Helpers/После Распознавание.app/Contents/MacOS");
            let current = directory.join("After Speech");
            let legacy = directory.join("После Речь");
            // A process from an earlier version may still see the old bundle
            // while an update is being applied. Never prefer the legacy file
            // when the current helper is present.
            if !current.is_file() && legacy.is_file() {
                legacy
            } else {
                current
            }
        })
        .unwrap_or_else(|| engine.to_owned())
}
