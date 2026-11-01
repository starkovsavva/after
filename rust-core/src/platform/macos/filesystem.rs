use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// Best-effort APFS cloning keeps destination metadata separate from the source.
/// The caller still verifies bytes and publishes its private destination, or
/// removes a partial destination and performs the checked streamed-copy fallback.
pub(crate) fn clone_model(source: &Path, destination: &Path) -> bool {
    let (Ok(source), Ok(destination)) = (
        CString::new(source.as_os_str().as_bytes()),
        CString::new(destination.as_os_str().as_bytes()),
    ) else {
        return false;
    };
    unsafe { libc::clonefile(source.as_ptr(), destination.as_ptr(), 0) == 0 }
}
