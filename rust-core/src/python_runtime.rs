//! Trusted CPython distribution policy, compiled into both native entry points.
//! This verifies CPython itself. Third-party venv packages remain a separate
//! dependency-installation trust boundary; their local RECORD is not a trust root.
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{CStr, CString};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{Read, Seek};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use std::sync::OnceLock;

pub const VERIFY_MODE: &str = "--posle-verify-python-runtime";
const ERROR: &str = "Целостность компонентов Python не подтверждена. Переустановите компоненты распознавания в настройках.";

#[derive(Deserialize)]
struct Policy {
    version: String,
    directory: String,
    files: Vec<ExpectedFile>,
    links: Vec<ExpectedLink>,
    #[serde(default)]
    directories: Vec<String>,
}
#[derive(Deserialize)]
struct ExpectedFile {
    path: String,
    sha256: String,
    size: u64,
}
#[derive(Deserialize)]
struct ExpectedLink {
    path: String,
    target: String,
}
fn policy() -> Result<&'static Policy> {
    static POLICY: OnceLock<std::result::Result<Policy, String>> = OnceLock::new();
    match POLICY.get_or_init(|| {
        serde_json::from_str(include_str!("../../backend/python-runtime.json"))
            .map_err(|_| ERROR.to_owned())
    }) {
        Ok(policy) => Ok(policy),
        Err(_) => bail!(ERROR),
    }
}
fn relative(path: &str) -> Result<&Path> {
    let path = Path::new(path);
    if path.as_os_str().is_empty()
        || path
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
    {
        bail!(ERROR);
    }
    Ok(path)
}
fn absolute(path: &Path) -> Result<()> {
    if !path.is_absolute() || path.components().any(|c| matches!(c, Component::ParentDir)) {
        bail!(ERROR);
    }
    Ok(())
}
fn secure(info: &Metadata) -> Result<()> {
    if info.uid() != unsafe { libc::geteuid() } || info.mode() & 0o022 != 0 {
        bail!(ERROR);
    }
    Ok(())
}
fn open(path: &Path, directory: bool) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(
            libc::O_NOFOLLOW | libc::O_NONBLOCK | if directory { libc::O_DIRECTORY } else { 0 },
        )
        .open(path)
        .context(ERROR)?;
    let info = file.metadata().context(ERROR)?;
    secure(&info)?;
    if directory != info.is_dir() || (!directory && !info.is_file()) {
        bail!(ERROR);
    }
    Ok(file)
}
fn child(parent: &File, name: &std::ffi::OsStr, directory: bool) -> Result<File> {
    let name = CString::new(name.as_bytes()).context(ERROR)?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY
                | libc::O_CLOEXEC
                | libc::O_NOFOLLOW
                | libc::O_NONBLOCK
                | if directory { libc::O_DIRECTORY } else { 0 },
        )
    };
    if fd < 0 {
        bail!(ERROR);
    }
    let file = unsafe { File::from_raw_fd(fd) };
    let info = file.metadata().context(ERROR)?;
    secure(&info)?;
    if directory != info.is_dir() || (!directory && !info.is_file()) {
        bail!(ERROR);
    }
    Ok(file)
}
#[derive(PartialEq, Eq)]
struct Stamp {
    device: u64,
    inode: u64,
    size: u64,
    modified: (i64, i64),
    changed: (i64, i64),
    mode: u32,
    uid: u32,
}
fn stamp(info: &Metadata) -> Stamp {
    Stamp {
        device: info.dev(),
        inode: info.ino(),
        size: info.len(),
        modified: (info.mtime(), info.mtime_nsec()),
        changed: (info.ctime(), info.ctime_nsec()),
        mode: info.mode(),
        uid: info.uid(),
    }
}
fn hash_file(mut file: &File, expected: &ExpectedFile) -> Result<Stamp> {
    let before = file.metadata().context(ERROR)?;
    secure(&before)?;
    if !before.is_file() || before.len() != expected.size {
        bail!(ERROR);
    }
    let mut hash = Sha256::new();
    let copied = std::io::copy(
        &mut Read::by_ref(&mut file).take(expected.size + 1),
        &mut hash,
    )
    .context(ERROR)?;
    let after = file.metadata().context(ERROR)?;
    if copied != expected.size
        || stamp(&before) != stamp(&after)
        || format!("{:x}", hash.finalize()) != expected.sha256
    {
        bail!(ERROR);
    }
    // /dev/fd duplicates the held descriptor on macOS. Leave its read offset
    // at the start rather than at EOF after hashing.
    file.rewind().context(ERROR)?;
    Ok(stamp(&after))
}
/// Enumerate via the held directory descriptor, not a re-opened path. Symlink
/// entries are inspected separately and never traversed by this walk.
fn names(directory: &File) -> Result<Vec<std::ffi::OsString>> {
    let duplicate = unsafe { libc::fcntl(directory.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
    if duplicate < 0 {
        bail!(ERROR);
    }
    let stream = unsafe { libc::fdopendir(duplicate) };
    if stream.is_null() {
        unsafe {
            libc::close(duplicate);
        }
        bail!(ERROR);
    }
    struct Stream(*mut libc::DIR);
    impl Drop for Stream {
        fn drop(&mut self) {
            unsafe {
                libc::closedir(self.0);
            }
        }
    }
    let stream = Stream(stream);
    let mut result = Vec::new();
    loop {
        let entry = unsafe { libc::readdir(stream.0) };
        if entry.is_null() {
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if name != b"." && name != b".." {
            result.push(std::ffi::OsStr::from_bytes(name).to_owned());
        }
    }
    Ok(result)
}
struct Tree {
    base: PathBuf,
    directory: File,
    files: BTreeMap<PathBuf, Stamp>,
    links: BTreeMap<PathBuf, PathBuf>,
    directories: BTreeSet<PathBuf>,
    directory_stamps: BTreeMap<PathBuf, Stamp>,
    library: Option<File>,
}
impl Tree {
    fn verify(base: &Path, policy: &Policy) -> Result<Self> {
        absolute(base)?;
        // Reject a linked final directory; /tmp's system alias in an ancestor
        // is normalized before the descriptor-based traversal begins.
        let directory = open(base, true)?;
        let base = fs::canonicalize(base).context(ERROR)?;
        let mut tree = Self {
            base,
            directory,
            files: BTreeMap::new(),
            links: BTreeMap::new(),
            directories: BTreeSet::new(),
            directory_stamps: BTreeMap::new(),
            library: None,
        };
        tree.directory_stamps.insert(
            PathBuf::new(),
            stamp(&tree.directory.metadata().context(ERROR)?),
        );
        let mut expected_files = BTreeMap::new();
        let mut expected_links = BTreeMap::new();
        let mut expected_dirs = BTreeSet::new();
        for item in &policy.files {
            let path = relative(&item.path)?.to_owned();
            if item.sha256.len() != 64
                || !item.sha256.bytes().all(|b| b.is_ascii_hexdigit())
                || item.size == u64::MAX
                || expected_files.insert(path.clone(), item).is_some()
            {
                bail!(ERROR);
            }
            for parent in path
                .ancestors()
                .skip(1)
                .filter(|p| !p.as_os_str().is_empty())
            {
                expected_dirs.insert(parent.to_owned());
            }
        }
        for item in &policy.links {
            let path = relative(&item.path)?.to_owned();
            if Path::new(&item.target).is_absolute()
                || item.target.is_empty()
                || expected_links
                    .insert(path.clone(), PathBuf::from(&item.target))
                    .is_some()
            {
                bail!(ERROR);
            }
            for parent in path
                .ancestors()
                .skip(1)
                .filter(|p| !p.as_os_str().is_empty())
            {
                expected_dirs.insert(parent.to_owned());
            }
        }
        for path in &policy.directories {
            expected_dirs.insert(relative(path)?.to_owned());
        }
        if expected_files
            .keys()
            .any(|p| expected_links.contains_key(p) || expected_dirs.contains(p))
            || expected_links.keys().any(|p| expected_dirs.contains(p))
        {
            bail!(ERROR);
        }
        if !expected_files.contains_key(Path::new("bin/python3.12"))
            || !expected_files.contains_key(Path::new("lib/libpython3.12.dylib"))
            || !expected_files.contains_key(Path::new("lib/python3.12/encodings/__init__.py"))
        {
            bail!(ERROR);
        }
        let dir = tree.directory.try_clone().context(ERROR)?;
        tree.walk(
            &dir,
            Path::new(""),
            &expected_files,
            &expected_links,
            &expected_dirs,
        )?;
        if tree.files.len() != expected_files.len()
            || tree.links != expected_links
            || tree.directories != expected_dirs
        {
            bail!(ERROR);
        }
        // Every declared alias must resolve inside this verified distribution.
        for path in tree.links.keys() {
            let target = fs::canonicalize(tree.base.join(path)).context(ERROR)?;
            if !target.starts_with(&tree.base) || (!target.is_dir() && !target.is_file()) {
                bail!(ERROR);
            }
        }
        Ok(tree)
    }
    fn walk(
        &mut self,
        directory: &File,
        prefix: &Path,
        files: &BTreeMap<PathBuf, &ExpectedFile>,
        links: &BTreeMap<PathBuf, PathBuf>,
        dirs: &BTreeSet<PathBuf>,
    ) -> Result<()> {
        for name in names(directory)? {
            let path = prefix.join(&name);
            if dirs.contains(&path) {
                let next = child(directory, &name, true)?;
                self.directory_stamps
                    .insert(path.clone(), stamp(&next.metadata().context(ERROR)?));
                self.directories.insert(path.clone());
                self.walk(&next, &path, files, links, dirs)?;
            } else if let Some(expected) = files.get(&path) {
                let file = child(directory, &name, false)?;
                self.files.insert(path.clone(), hash_file(&file, expected)?);
                if path == Path::new("lib/libpython3.12.dylib") {
                    self.library = Some(file);
                }
            } else if let Some(target) = links.get(&path) {
                let name = CString::new(name.as_bytes()).context(ERROR)?;
                let mut info: libc::stat = unsafe { std::mem::zeroed() };
                if unsafe {
                    libc::fstatat(
                        directory.as_raw_fd(),
                        name.as_ptr(),
                        &mut info,
                        libc::AT_SYMLINK_NOFOLLOW,
                    )
                } != 0
                    || info.st_uid != unsafe { libc::geteuid() }
                    || info.st_mode & libc::S_IFMT != libc::S_IFLNK
                {
                    bail!(ERROR);
                }
                let mut bytes = vec![0u8; 4096];
                let size = unsafe {
                    libc::readlinkat(
                        directory.as_raw_fd(),
                        name.as_ptr(),
                        bytes.as_mut_ptr().cast(),
                        bytes.len(),
                    )
                };
                if size < 0 || size as usize == bytes.len() {
                    bail!(ERROR);
                }
                bytes.truncate(size as usize);
                if bytes != target.as_os_str().as_bytes() {
                    bail!(ERROR);
                }
                self.links.insert(path, target.clone());
            } else {
                bail!(ERROR);
            }
        }
        Ok(())
    }
    fn recheck(&self) -> Result<()> {
        if stamp(&self.directory.metadata().context(ERROR)?)
            != stamp(&fs::symlink_metadata(&self.base).context(ERROR)?)
        {
            bail!(ERROR);
        }
        for (path, expected) in &self.directory_stamps {
            if stamp(&fs::symlink_metadata(self.base.join(path)).context(ERROR)?) != *expected {
                bail!(ERROR);
            }
        }
        for (path, expected) in &self.files {
            if stamp(&fs::symlink_metadata(self.base.join(path)).context(ERROR)?) != *expected {
                bail!(ERROR);
            }
        }
        for (path, target) in &self.links {
            if fs::read_link(self.base.join(path)).context(ERROR)? != *target {
                bail!(ERROR);
            }
        }
        Ok(())
    }
}

pub struct VerifiedRuntime {
    pub interpreter: PathBuf,
    pub real: PathBuf,
    pub base: PathBuf,
    pub venv: PathBuf,
    pub library: PathBuf,
    tree: Option<Tree>,
    config: Option<(File, Stamp)>,
    fixture_library: Option<File>,
    version: String,
}
impl VerifiedRuntime {
    pub fn recheck(&self) -> Result<()> {
        if let Some(tree) = &self.tree {
            tree.recheck()?;
        }
        if let Some((file, expected)) = &self.config {
            if stamp(&file.metadata().context(ERROR)?) != *expected
                || stamp(&fs::symlink_metadata(self.venv.join("pyvenv.cfg")).context(ERROR)?)
                    != *expected
            {
                bail!(ERROR);
            }
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
    Tree::verify(base, policy()?)?.recheck()
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
            config: None,
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
    let tree = Tree::verify(&base, policy)?;
    let real = base.join("bin/python3.12");
    if fs::canonicalize(interpreter).context(ERROR)? != real || !real.is_file() {
        bail!(ERROR);
    }
    // Only ordinary venv aliases are accepted, never directory links or an
    // interpreter redirected outside the pinned distribution.
    let mut link = venv.join("bin/python");
    let mut complete = false;
    for _ in 0..4 {
        if fs::canonicalize(&link).context(ERROR)? != real {
            bail!(ERROR);
        }
        let info = fs::symlink_metadata(&link).context(ERROR)?;
        if info.file_type().is_symlink() {
            if info.uid() != unsafe { libc::geteuid() } {
                bail!(ERROR);
            }
            let target = fs::read_link(&link).context(ERROR)?;
            let next = if target.is_absolute() {
                target
            } else {
                link.parent().context(ERROR)?.join(target)
            };
            if next == real {
                complete = true;
                break;
            }
            if ![
                venv.join("bin/python"),
                venv.join("bin/python3"),
                venv.join("bin/python3.12"),
            ]
            .contains(&next)
            {
                bail!(ERROR);
            }
            link = next;
        } else {
            bail!(ERROR);
        }
    }
    if !complete {
        bail!(ERROR);
    }
    let library = base.join("lib/libpython3.12.dylib");
    if tree.library.is_none() {
        bail!(ERROR);
    }
    let mut config_file = open(&venv.join("pyvenv.cfg"), false)?;
    let config_stamp = stamp(&config_file.metadata().context(ERROR)?);
    let mut text = String::new();
    Read::by_ref(&mut config_file)
        .take(16 * 1024 + 1)
        .read_to_string(&mut text)
        .context(ERROR)?;
    if text.len() > 16 * 1024 {
        bail!(ERROR);
    }
    let mut values = BTreeMap::new();
    for line in text.lines() {
        if let Some((key, value)) = line.split_once('=') {
            if values
                .insert(key.trim().to_lowercase(), value.trim())
                .is_some()
            {
                bail!(ERROR);
            }
        }
    }
    if values.get("include-system-site-packages") != Some(&"false")
        || values.get("version").copied() != Some(policy.version.as_str())
        || values
            .get("home")
            .map(Path::new)
            .and_then(|path| fs::canonicalize(path).ok())
            != Some(base.join("bin"))
    {
        bail!(ERROR);
    }
    let runtime = VerifiedRuntime {
        interpreter: interpreter.to_owned(),
        real,
        base,
        venv,
        library,
        tree: Some(tree),
        config: Some((config_file, config_stamp)),
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
        let tree = Tree::verify(tmp.path(), &policy).unwrap();
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
            let tree = Tree::verify(tmp.path(), &policy).unwrap();
            let path = tmp.path().join(file);
            let mut data = fs::read(&path).unwrap();
            data[0] ^= 1;
            fs::write(path, data).unwrap();
            assert!(
                Tree::verify(tmp.path(), &policy).is_err(),
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
            assert!(Tree::verify(tmp.path(), &policy).is_err());
        }
    }
    #[test]
    fn rejects_missing_inventory_entries_and_file_symlink_substitution() {
        let tmp = tempfile::tempdir().unwrap();
        let policy = distribution(tmp.path());
        let library = tmp.path().join("lib/libpython3.12.dylib");
        fs::remove_file(&library).unwrap();
        assert!(Tree::verify(tmp.path(), &policy).is_err());
        let outside = tempfile::NamedTempFile::new().unwrap();
        fs::write(outside.path(), b"synthetic library").unwrap();
        symlink(outside.path(), &library).unwrap();
        assert!(Tree::verify(tmp.path(), &policy).is_err());
    }
    #[test]
    fn rejects_link_changes_directory_links_and_declared_escapes() {
        let tmp = tempfile::tempdir().unwrap();
        let mut policy = distribution(tmp.path());
        fs::remove_file(tmp.path().join("bin/python3")).unwrap();
        symlink("other", tmp.path().join("bin/python3")).unwrap();
        assert!(Tree::verify(tmp.path(), &policy).is_err());
        let outside = tempfile::tempdir().unwrap();
        fs::remove_dir(tmp.path().join("empty")).unwrap();
        symlink(outside.path(), tmp.path().join("empty")).unwrap();
        assert!(Tree::verify(tmp.path(), &policy).is_err());
        fs::remove_file(tmp.path().join("empty")).unwrap();
        fs::create_dir(tmp.path().join("empty")).unwrap();
        fs::remove_file(tmp.path().join("bin/python3")).unwrap();
        policy.links[0].target = outside.path().to_string_lossy().into_owned();
        symlink(outside.path(), tmp.path().join("bin/python3")).unwrap();
        assert!(Tree::verify(tmp.path(), &policy).is_err());
    }
    #[test]
    fn rejects_group_world_writable_files_and_directories_before_loading() {
        for (name, mode) in [("lib/libpython3.12.dylib", 0o666), ("lib", 0o777)] {
            let tmp = tempfile::tempdir().unwrap();
            let policy = distribution(tmp.path());
            fs::set_permissions(tmp.path().join(name), fs::Permissions::from_mode(mode)).unwrap();
            assert!(Tree::verify(tmp.path(), &policy).is_err());
        }
        let tmp = tempfile::tempdir().unwrap();
        let policy = distribution(tmp.path());
        let tree = Tree::verify(tmp.path(), &policy).unwrap();
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
        assert!(Tree::verify(tmp.path(), &policy).is_err());
    }
}
