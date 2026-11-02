//! macOS CPython composition, venv binding and descriptor-based dynamic loading.
//! Complete file verification is shared through the Unix runtime-tree adapter.
use crate::infrastructure::runtime_tree::{absolute, open, relative, Layout, Policy, Tree, ERROR};
#[cfg(test)]
use crate::infrastructure::runtime_tree::{secure, ExpectedFile, ExpectedLink};
use crate::infrastructure::runtime_venv::VenvBinding;
use anyhow::{bail, Context, Result};
#[cfg(test)]
use sha2::{Digest, Sha256};
use std::ffi::{CStr, CString};
use std::fs::{self, File};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
pub const VERIFY_MODE: &str = "--posle-verify-python-runtime";
const LAYOUT: Layout<'static> = Layout {
    required_files: &[
        "bin/python3.12",
        "lib/libpython3.12.dylib",
        "lib/python3.12/encodings/__init__.py",
    ],
    library: Some("lib/libpython3.12.dylib"),
};
fn verify_tree(base: &Path, policy: &Policy) -> Result<Tree> {
    Tree::verify(base, policy, LAYOUT)
}
fn policy() -> Result<&'static Policy> {
    static POLICY: OnceLock<std::result::Result<Policy, String>> = OnceLock::new();
    match POLICY.get_or_init(|| {
        serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../backend/python-runtime.json"
        )))
        .map_err(|_| ERROR.to_owned())
    }) {
        Ok(policy) => Ok(policy),
        Err(_) => bail!(ERROR),
    }
}
pub struct VerifiedRuntime {
    pub interpreter: PathBuf,
    pub real: PathBuf,
    pub base: PathBuf,
    pub venv: PathBuf,
    pub library: PathBuf,
    tree: Option<Tree>,
    venv_binding: Option<VenvBinding>,
    fixture_library: Option<File>,
    version: String,
}
impl VerifiedRuntime {
    pub fn recheck(&self) -> Result<()> {
        if let Some(tree) = &self.tree {
            tree.recheck()?;
        }
        if let Some(binding) = &self.venv_binding {
            binding.recheck()?;
        }
        Ok(())
    }
    fn library_file(&self) -> Result<&File> {
        self.tree
            .as_ref()
            .and_then(|tree| tree.library.as_ref())
            .or(self.fixture_library.as_ref())
            .context(ERROR)
    }
    /// Load the exact vnode whose bytes were verified, not a pathname that can
    /// be atomically replaced after verification. CPython's pinned macOS image
    /// depends only on system libraries, so no @loader_path dependency is lost.
    pub fn loader_path(&self) -> Result<CString> {
        self.recheck()?;
        CString::new(format!("/dev/fd/{}", self.library_file()?.as_raw_fd())).context(ERROR)
    }
    pub fn require_version(&self, actual: &[u8]) -> Result<()> {
        let version = actual
            .split(|b| b.is_ascii_whitespace())
            .next()
            .unwrap_or_default();
        if self.tree.is_some() {
            if version != self.version.as_bytes() {
                bail!(ERROR);
            }
        } else if !version.starts_with(b"3.12.") {
            bail!(ERROR);
        }
        Ok(())
    }
    /// Compatibility binding after dlopen, not a replacement for pre-load hashes.
    pub unsafe fn require_image(&self, symbol: *const libc::c_void) -> Result<()> {
        let mut info: libc::Dl_info = std::mem::zeroed();
        if libc::dladdr(symbol, &mut info) == 0 || info.dli_fname.is_null() {
            bail!(ERROR);
        }
        let loaded = Path::new(std::ffi::OsStr::from_bytes(
            CStr::from_ptr(info.dli_fname).to_bytes(),
        ));
        let loaded = fs::metadata(loaded).context(ERROR)?;
        let expected = self.library_file()?.metadata().context(ERROR)?;
        if loaded.dev() != expected.dev() || loaded.ino() != expected.ino() {
            bail!(ERROR);
        }
        Ok(())
    }
}
/// Used by setup before any downloaded Python executable is run. A staging
/// directory is allowed here, but the complete compiled policy is always used.
pub fn verify_distribution(base: &Path) -> Result<()> {
    verify_tree(base, policy()?)?.recheck()
}

fn canonical_root(root: &Path) -> Result<PathBuf> {
    absolute(root)?;
    let _root = open(root, true)?;
    fs::canonicalize(root).context(ERROR)
}
fn venv(root: &Path, interpreter: &Path) -> Result<PathBuf> {
    absolute(interpreter)?;
    let expected = root.join("runtime/venv/bin/python");
    let lexical = interpreter.parent().context(ERROR)?;
    // Canonicalize only the parent after no-follow checks on the owned dirs.
    for path in [
        root.join("runtime"),
        root.join("runtime/venv"),
        root.join("runtime/venv/bin"),
    ] {
        let _dir = open(&path, true)?;
    }
    if fs::canonicalize(lexical).context(ERROR)? != expected.parent().unwrap()
        || interpreter.file_name() != expected.file_name()
    {
        bail!(ERROR);
    }
    let cfg = open(&root.join("runtime/venv/pyvenv.cfg"), false)?;
    let info = cfg.metadata().context(ERROR)?;
    if info.len() > 16 * 1024 {
        bail!(ERROR);
    }
    Ok(root.join("runtime/venv"))
}
#[cfg(debug_assertions)]
fn fixture(root: &Path) -> bool {
    std::env::var_os("POSLE_UNVERIFIED_PYTHON_RUNTIME_FOR_TESTS").as_deref()
        == Some(std::ffi::OsStr::new("1"))
        && root
            .strip_prefix("/private/tmp")
            .ok()
            .and_then(|p| p.components().next())
            .is_some_and(|p| p.as_os_str().to_string_lossy().starts_with("posle-"))
}
#[cfg(not(debug_assertions))]
fn fixture(_: &Path) -> bool {
    false
}

pub fn validate(root: &Path, interpreter: &Path) -> Result<VerifiedRuntime> {
    let root = canonical_root(root)?;
    let venv = venv(&root, interpreter)?;
    if fixture(&root) {
        let real = fs::canonicalize(interpreter).context(ERROR)?;
        let base = real
            .parent()
            .filter(|p| p.file_name() == Some(std::ffi::OsStr::new("bin")))
            .and_then(Path::parent)
            .context(ERROR)?
            .to_owned();
        if real.file_name() != Some(std::ffi::OsStr::new("python3.12")) {
            bail!(ERROR);
        }
        let library = base.join("lib/libpython3.12.dylib");
        if !real.is_file() || !library.is_file() {
            bail!(ERROR);
        }
        let fixture_library = Some(File::open(&library).context(ERROR)?);
        return Ok(VerifiedRuntime {
            interpreter: interpreter.to_owned(),
            real,
            base,
            venv,
            library,
            tree: None,
            venv_binding: None,
            fixture_library,
            version: String::new(),
        });
    }
    validate_pinned(&root, interpreter, venv, policy()?)
}
fn validate_pinned(
    root: &Path,
    interpreter: &Path,
    venv: PathBuf,
    policy: &Policy,
) -> Result<VerifiedRuntime> {
    let _python = open(&root.join("runtime/python"), true)?;
    let base = root
        .join("runtime/python")
        .join(relative(&policy.directory)?);
    let tree = verify_tree(&base, policy)?;
    let real = base.join("bin/python3.12");
    if fs::canonicalize(interpreter).context(ERROR)? != real || !real.is_file() {
        bail!(ERROR);
    }
    let venv_binding = VenvBinding::verify(&venv, &base, &policy.version)?;
    let library = base.join("lib/libpython3.12.dylib");
    if tree.library.is_none() {
        bail!(ERROR);
    }
    let runtime = VerifiedRuntime {
        interpreter: interpreter.to_owned(),
        real,
        base,
        venv,
        library,
        tree: Some(tree),
        venv_binding: Some(venv_binding),
        fixture_library: None,
        version: policy.version.clone(),
    };
    runtime.recheck()?;
    Ok(runtime)
}
/// The helper receives its interpreter before the script arguments. Derive the
/// one permitted root from that fixed layout, not from an untrusted script flag.
pub fn validate_interpreter(interpreter: &Path) -> Result<VerifiedRuntime> {
    let root = interpreter
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .and_then(Path::parent)
        .context(ERROR)?;
    validate(root, interpreter)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};

    fn bytes(path: &str, body: &[u8]) -> ExpectedFile {
        ExpectedFile {
            path: path.into(),
            size: body.len() as u64,
            sha256: format!("{:x}", Sha256::digest(body)),
        }
    }
    fn distribution(base: &Path) -> Policy {
        let files = vec![
            bytes("bin/python3.12", b"synthetic interpreter"),
            bytes("lib/libpython3.12.dylib", b"synthetic library"),
            bytes("lib/python3.12/encodings/__init__.py", b"synthetic source"),
            bytes(
                "lib/python3.12/lib-dynload/example.so",
                b"synthetic native extension",
            ),
        ];
        for file in &files {
            let path = base.join(&file.path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            let content: &[u8] = match file.path.as_str() {
                "bin/python3.12" => b"synthetic interpreter",
                "lib/libpython3.12.dylib" => b"synthetic library",
                "lib/python3.12/encodings/__init__.py" => b"synthetic source",
                _ => b"synthetic native extension",
            };
            fs::write(path, content).unwrap();
        }
        fs::create_dir_all(base.join("empty")).unwrap();
        symlink("python3.12", base.join("bin/python3")).unwrap();
        Policy {
            version: "3.12.16".into(),
            directory: "pinned-python".into(),
            files,
            links: vec![ExpectedLink {
                path: "bin/python3".into(),
                target: "python3.12".into(),
            }],
            directories: vec!["empty".into()],
        }
    }
    #[test]
    fn verifies_full_policy_and_keeps_library_open_until_load() {
        let tmp = tempfile::tempdir().unwrap();
        let policy = distribution(tmp.path());
        let tree = verify_tree(tmp.path(), &policy).unwrap();
        assert!(tree.library.is_some());
        assert_ne!(
            unsafe { libc::fcntl(tree.library.as_ref().unwrap().as_raw_fd(), libc::F_GETFD) }
                & libc::FD_CLOEXEC,
            0
        );
        tree.recheck().unwrap();
        assert_eq!(tree.files.len(), 4);
        assert!(tree.directories.contains(Path::new("empty")));
    }
    #[test]
    fn loader_descriptor_keeps_verified_bytes_after_pathname_replacement() {
        let tmp = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(tmp.path()).unwrap();
        let (policy, interpreter, base) = installed(&root);
        let verified = validate_pinned(
            &root,
            &interpreter,
            venv(&root, &interpreter).unwrap(),
            &policy,
        )
        .unwrap();
        let loader = verified.loader_path().unwrap();
        let original = base.join("lib/libpython3.12.dylib");
        fs::rename(&original, base.join("lib/renamed-original")).unwrap();
        fs::write(&original, b"untrusted replacement").unwrap();
        assert_eq!(
            fs::read(Path::new(std::ffi::OsStr::from_bytes(loader.as_bytes()))).unwrap(),
            b"synthetic library"
        );
        assert!(verified.recheck().is_err());
    }

    #[test]
    fn rejects_changes_to_library_python_source_and_nested_native_extensions() {
        for file in [
            "lib/libpython3.12.dylib",
            "lib/python3.12/encodings/__init__.py",
            "lib/python3.12/lib-dynload/example.so",
        ] {
            let tmp = tempfile::tempdir().unwrap();
            let policy = distribution(tmp.path());
            let tree = verify_tree(tmp.path(), &policy).unwrap();
            let path = tmp.path().join(file);
            let mut data = fs::read(&path).unwrap();
            data[0] ^= 1;
            fs::write(path, data).unwrap();
            assert!(
                verify_tree(tmp.path(), &policy).is_err(),
                "Changed bytes passed: {file}"
            );
            assert!(tree.recheck().is_err(), "Changed metadata passed: {file}");
        }
    }
    #[test]
    fn rejects_unknown_code_files_and_runtime_side_manifests() {
        for name in ["injected.py", "lib/injected.dylib", "python-runtime.json"] {
            let tmp = tempfile::tempdir().unwrap();
            let policy = distribution(tmp.path());
            fs::write(
                tmp.path().join(name),
                b"not part of trusted compiled policy",
            )
            .unwrap();
            assert!(verify_tree(tmp.path(), &policy).is_err());
        }
    }
    #[test]
    fn rejects_missing_inventory_entries_and_file_symlink_substitution() {
        let tmp = tempfile::tempdir().unwrap();
        let policy = distribution(tmp.path());
        let library = tmp.path().join("lib/libpython3.12.dylib");
        fs::remove_file(&library).unwrap();
        assert!(verify_tree(tmp.path(), &policy).is_err());
        let outside = tempfile::NamedTempFile::new().unwrap();
        fs::write(outside.path(), b"synthetic library").unwrap();
        symlink(outside.path(), &library).unwrap();
        assert!(verify_tree(tmp.path(), &policy).is_err());
    }
    #[test]
    fn rejects_link_changes_directory_links_and_declared_escapes() {
        let tmp = tempfile::tempdir().unwrap();
        let mut policy = distribution(tmp.path());
        fs::remove_file(tmp.path().join("bin/python3")).unwrap();
        symlink("other", tmp.path().join("bin/python3")).unwrap();
        assert!(verify_tree(tmp.path(), &policy).is_err());
        let outside = tempfile::tempdir().unwrap();
        fs::remove_dir(tmp.path().join("empty")).unwrap();
        symlink(outside.path(), tmp.path().join("empty")).unwrap();
        assert!(verify_tree(tmp.path(), &policy).is_err());
        fs::remove_file(tmp.path().join("empty")).unwrap();
        fs::create_dir(tmp.path().join("empty")).unwrap();
        fs::remove_file(tmp.path().join("bin/python3")).unwrap();
        policy.links[0].target = outside.path().to_string_lossy().into_owned();
        symlink(outside.path(), tmp.path().join("bin/python3")).unwrap();
        assert!(verify_tree(tmp.path(), &policy).is_err());
    }
    #[test]
    fn rejects_group_world_writable_files_and_directories_before_loading() {
        for (name, mode) in [("lib/libpython3.12.dylib", 0o666), ("lib", 0o777)] {
            let tmp = tempfile::tempdir().unwrap();
            let policy = distribution(tmp.path());
            fs::set_permissions(tmp.path().join(name), fs::Permissions::from_mode(mode)).unwrap();
            assert!(verify_tree(tmp.path(), &policy).is_err());
        }
        let tmp = tempfile::tempdir().unwrap();
        let policy = distribution(tmp.path());
        let tree = verify_tree(tmp.path(), &policy).unwrap();
        fs::set_permissions(tmp.path().join("lib"), fs::Permissions::from_mode(0o777)).unwrap();
        assert!(tree.recheck().is_err());
    }
    #[test]
    fn rejects_foreign_owned_files_when_not_running_as_root() {
        let info = fs::metadata("/bin/sh").unwrap();
        if info.uid() != unsafe { libc::geteuid() } {
            assert!(secure(&info).is_err());
        }
    }
    #[test]
    fn venv_configuration_cannot_redirect_the_verified_python_runtime() {
        for content in [
            "home = /tmp\ninclude-system-site-packages = false\nversion = 3.12.16\n",
            "home = /tmp\ninclude-system-site-packages = true\nversion = 3.12.16\n",
        ] {
            let tmp = tempfile::tempdir().unwrap();
            let root = fs::canonicalize(tmp.path()).unwrap();
            let (policy, interpreter, _) = installed(&root);
            fs::write(root.join("runtime/venv/pyvenv.cfg"), content).unwrap();
            assert!(validate_pinned(
                &root,
                &interpreter,
                venv(&root, &interpreter).unwrap(),
                &policy
            )
            .is_err());
        }
        let tmp = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(tmp.path()).unwrap();
        let (policy, interpreter, _) = installed(&root);
        let verified = validate_pinned(
            &root,
            &interpreter,
            venv(&root, &interpreter).unwrap(),
            &policy,
        )
        .unwrap();
        fs::write(root.join("runtime/venv/pyvenv.cfg"), "home = /tmp").unwrap();
        assert!(verified.recheck().is_err());
    }
    fn installed(root: &Path) -> (Policy, PathBuf, PathBuf) {
        let base = root.join("runtime/python/pinned-python");
        let policy = distribution(&base);
        let venv = root.join("runtime/venv");
        fs::create_dir_all(venv.join("bin")).unwrap();
        fs::write(
            venv.join("pyvenv.cfg"),
            format!(
                "home = {}\ninclude-system-site-packages = false\nversion = 3.12.16\n",
                base.join("bin").display()
            ),
        )
        .unwrap();
        symlink(base.join("bin/python3.12"), venv.join("bin/python3.12")).unwrap();
        symlink("python3.12", venv.join("bin/python3")).unwrap();
        symlink("python3", venv.join("bin/python")).unwrap();
        (policy, venv.join("bin/python"), base)
    }
    #[test]
    fn permits_normal_internal_venv_aliases_but_never_external_interpreters() {
        let tmp = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(tmp.path()).unwrap();
        let (policy, interpreter, base) = installed(&root);
        let venv = venv(&root, &interpreter).unwrap();
        let verified = validate_pinned(&root, &interpreter, venv.clone(), &policy).unwrap();
        assert_eq!(verified.real, base.join("bin/python3.12"));
        verified.recheck().unwrap();
        let outside = tempfile::tempdir().unwrap();
        distribution(outside.path());
        fs::remove_file(&interpreter).unwrap();
        symlink(outside.path().join("bin/python3.12"), &interpreter).unwrap();
        assert!(validate_pinned(&root, &interpreter, venv, &policy).is_err());
    }
    #[test]
    fn exact_loaded_version_is_compatibility_check_not_the_trust_root() {
        let tmp = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(tmp.path()).unwrap();
        let (policy, interpreter, _) = installed(&root);
        let verified = validate_pinned(
            &root,
            &interpreter,
            venv(&root, &interpreter).unwrap(),
            &policy,
        )
        .unwrap();
        assert!(verified
            .require_version(b"3.12.16 (standalone build)")
            .is_ok());
        for version in [b"3.12.15" as &[u8], b"3.12.160", b"3.13.1", b""] {
            assert!(verified.require_version(version).is_err());
        }
    }
    #[test]
    fn rejects_relative_parent_and_invalid_policy_paths() {
        for path in ["relative", "/tmp/../tmp/runtime"] {
            assert!(absolute(Path::new(path)).is_err());
        }
        for path in ["", "../libpython", "/tmp/libpython", "lib/../library"] {
            assert!(relative(path).is_err());
        }
        let tmp = tempfile::tempdir().unwrap();
        let mut policy = distribution(tmp.path());
        policy.files[0].path = "../outside".into();
        assert!(verify_tree(tmp.path(), &policy).is_err());
    }
}
