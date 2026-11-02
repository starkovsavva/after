//! Descriptor-based Unix verification of a complete trusted runtime inventory.
//! This adapter never selects a distribution, executes code, or trusts a local manifest.
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
pub(crate) const ERROR: &str = "Целостность компонентов Python не подтверждена. Переустановите компоненты распознавания в настройках.";
#[derive(Clone, Copy)]
pub(crate) struct Layout<'a> {
    pub required_files: &'a [&'a str],
    pub library: &'a str,
}
#[derive(Deserialize)]
pub(crate) struct Policy {
    pub(crate) version: String,
    pub(crate) directory: String,
    pub(crate) files: Vec<ExpectedFile>,
    pub(crate) links: Vec<ExpectedLink>,
    #[serde(default)]
    pub(crate) directories: Vec<String>,
}
#[derive(Deserialize)]
pub(crate) struct ExpectedFile {
    pub(crate) path: String,
    pub(crate) sha256: String,
    pub(crate) size: u64,
}
#[derive(Deserialize)]
pub(crate) struct ExpectedLink {
    pub(crate) path: String,
    pub(crate) target: String,
}
pub(crate) fn relative(path: &str) -> Result<&Path> {
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
pub(crate) fn absolute(path: &Path) -> Result<()> {
    if !path.is_absolute() || path.components().any(|c| matches!(c, Component::ParentDir)) {
        bail!(ERROR);
    }
    Ok(())
}
pub(crate) fn secure(info: &Metadata) -> Result<()> {
    if info.uid() != unsafe { libc::geteuid() } || info.mode() & 0o022 != 0 {
        bail!(ERROR);
    }
    Ok(())
}
pub(crate) fn open(path: &Path, directory: bool) -> Result<File> {
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
pub(crate) struct Stamp {
    device: u64,
    inode: u64,
    size: u64,
    modified: (i64, i64),
    changed: (i64, i64),
    mode: u32,
    uid: u32,
}
pub(crate) fn stamp(info: &Metadata) -> Stamp {
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
pub(crate) struct Tree {
    base: PathBuf,
    directory: File,
    pub(crate) files: BTreeMap<PathBuf, Stamp>,
    links: BTreeMap<PathBuf, PathBuf>,
    pub(crate) directories: BTreeSet<PathBuf>,
    directory_stamps: BTreeMap<PathBuf, Stamp>,
    pub(crate) library: Option<File>,
}
impl Tree {
    pub(crate) fn verify(base: &Path, policy: &Policy, layout: Layout<'_>) -> Result<Self> {
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
        if layout.required_files.is_empty()
            || !layout.required_files.contains(&layout.library)
            || layout
                .required_files
                .iter()
                .any(|path| !expected_files.contains_key(Path::new(path)))
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
            layout.library,
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
        library: &str,
    ) -> Result<()> {
        for name in names(directory)? {
            let path = prefix.join(&name);
            if dirs.contains(&path) {
                let next = child(directory, &name, true)?;
                self.directory_stamps
                    .insert(path.clone(), stamp(&next.metadata().context(ERROR)?));
                self.directories.insert(path.clone());
                self.walk(&next, &path, files, links, dirs, library)?;
            } else if let Some(expected) = files.get(&path) {
                let file = child(directory, &name, false)?;
                self.files.insert(path.clone(), hash_file(&file, expected)?);
                if path == Path::new(library) {
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
    pub(crate) fn recheck(&self) -> Result<()> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};
    const LAYOUT: Layout<'static> = Layout {
        required_files: &[
            "bin/python3.12",
            "lib/libpython3.12.so.1.0",
            "lib/python3.12/encodings/__init__.py",
        ],
        library: "lib/libpython3.12.so.1.0",
    };
    fn verify_tree(base: &Path, policy: &Policy) -> Result<Tree> {
        Tree::verify(base, policy, LAYOUT)
    }
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
            bytes("lib/libpython3.12.so.1.0", b"synthetic library"),
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
                "lib/libpython3.12.so.1.0" => b"synthetic library",
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
    fn caller_layout_must_bind_a_declared_library_and_required_bootstrap_files() {
        let tmp = tempfile::tempdir().unwrap();
        let mut policy = distribution(tmp.path());
        for layout in [
            Layout {
                required_files: &[],
                library: LAYOUT.library,
            },
            Layout {
                required_files: &["bin/python3.12"],
                library: LAYOUT.library,
            },
            Layout {
                required_files: &["not-in-inventory"],
                library: "not-in-inventory",
            },
        ] {
            assert!(Tree::verify(tmp.path(), &policy, layout).is_err());
        }
        // Removing a required file from both disk and inventory still fails;
        // an internally consistent inventory cannot choose a weaker layout.
        let required = "lib/python3.12/encodings/__init__.py";
        fs::remove_file(tmp.path().join(required)).unwrap();
        policy.files.retain(|file| file.path != required);
        assert!(verify_tree(tmp.path(), &policy).is_err());
    }
    #[test]
    fn rejects_changes_to_library_python_source_and_nested_native_extensions() {
        for file in [
            "lib/libpython3.12.so.1.0",
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
        for name in ["injected.py", "lib/injected.so", "python-runtime.json"] {
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
        let library = tmp.path().join("lib/libpython3.12.so.1.0");
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
        for (name, mode) in [("lib/libpython3.12.so.1.0", 0o666), ("lib", 0o777)] {
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

// Exercise the existing macOS composition's synthetic venv/descriptor contracts
// on Linux too. This module neither loads libpython nor invokes a macOS SDK;
// native dlopen/ABI behavior still requires the macOS verification profile.
#[cfg(all(test, target_os = "linux"))]
#[path = "../platform/macos/python_runtime.rs"]
mod macos_composition_contracts;
