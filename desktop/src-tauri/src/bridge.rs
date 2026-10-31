//! Typed, bounded IPC to the canonical library. The webview never supplies a
//! process, command-line argument, root directory, filename or engine operation.
use crate::models::*;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc, Arc,
    },
    thread,
    time::{Duration, Instant},
};

const MAX_INPUT: usize = 256 * 1024;
const MAX_OUTPUT: usize = 8 * 1_048_576;
const MAX_STDERR: usize = 64 * 1024;
const TIMEOUT: Duration = Duration::from_secs(12);
const IMPORT_TIMEOUT: Duration = Duration::from_secs(30 * 60);
const MAX_PARALLEL: usize = 4;

#[derive(Clone)]
pub struct LibraryBridge {
    engine: Engine,
    root: PathBuf,
    running: Arc<AtomicUsize>,
}
#[derive(Clone)]
struct Engine {
    path: PathBuf,
    digest: Option<String>,
}
impl LibraryBridge {
    pub(crate) fn data_root(&self) -> PathBuf {
        self.root.clone()
    }
    pub fn bundled(resource_dir: &Path, default_data_dir: &Path) -> Result<Self, HostError> {
        let root =
            development_override("AFTER_DATA_DIR").unwrap_or_else(|| default_data_dir.into());
        prepare_root(&root)?;
        let engine = match development_override("AFTER_ENGINE_PATH") {
            Some(path) => Engine { path, digest: None },
            None => Engine {
                path: resource_dir.join("engine").join(env!("AFTER_ENGINE_NAME")),
                digest: Some(env!("AFTER_ENGINE_SHA256").into()),
            },
        };
        Ok(Self {
            engine,
            root,
            running: Arc::new(AtomicUsize::new(0)),
        })
    }

    /// Explicit fixture construction is available only in debug builds. Neither
    /// this constructor nor environment path overrides exist in release builds.
    #[cfg(debug_assertions)]
    pub fn for_development(engine: PathBuf, root: PathBuf) -> Result<Self, HostError> {
        prepare_root(&root)?;
        let bridge = Self {
            engine: Engine {
                path: engine,
                digest: None,
            },
            root,
            running: Arc::new(AtomicUsize::new(0)),
        };
        bridge.engine.verify()?;
        Ok(bridge)
    }

    pub fn workspace(&self) -> Result<Workspace, HostError> {
        let mut workspace: Workspace = self.call("get_workspace", json!({})).map_err(|error| {
            crate::platform::report_error(&error);
            error
        })?;
        workspace.capabilities.import = true;
        workspace.capabilities.recording = crate::capture::Recorder::available();
        Ok(workspace)
    }
    pub fn meeting(&self, id: String) -> Result<MeetingDetail, HostError> {
        validate_id(&id)?;
        self.call("get_meeting", json!({"meetingId":id}))
    }
    pub fn save_note(&self, input: SaveNoteInput) -> Result<Note, HostError> {
        input.validate()?;
        self.call("save_note", json!({"input":input}))
    }
    /// Only host-selected files or host-owned recordings may cross this boundary.
    /// The renderer cannot supply a path.
    pub(crate) fn import_meeting(
        &self,
        source: &Path,
        title: Option<&str>,
    ) -> Result<Meeting, HostError> {
        if !source.is_absolute() {
            return Err(HostError::invalid());
        }
        let path = source.to_str().ok_or_else(HostError::invalid)?;
        self.call_with_timeout(
            "import_meeting",
            json!({"sourcePath": path, "focus": "", "title": title}),
            IMPORT_TIMEOUT,
        )
    }
    pub(crate) fn media_chunk(
        &self,
        id: &str,
        offset: u64,
        length: u32,
    ) -> Result<MediaChunk, HostError> {
        validate_id(id)?;
        if length == 0 || length > 1_048_576 || offset > 9_007_199_254_740_991 {
            return Err(HostError::invalid());
        }
        self.call(
            "read_media_chunk",
            json!({"meetingId":id, "offset":offset, "length":length}),
        )
    }
    pub fn feature_operation(&self, operation: &str, arguments: Value) -> Result<Value, HostError> {
        let allowed = [
            "list_tasks",
            "get_task",
            "create_task",
            "update_task",
            "list_cards",
            "save_card",
            "delete_card",
            "suspend_card",
            "preview_card_review",
            "review_card",
            "undo_card_review",
        ];
        let command = allowed
            .iter()
            .copied()
            .find(|value| *value == operation)
            .ok_or_else(HostError::invalid)?;
        if !arguments.is_object() {
            return Err(HostError::invalid());
        }
        self.call(command, arguments)
    }
    pub fn save_folder(&self, input: SaveFolderInput) -> Result<Folder, HostError> {
        input.validate()?;
        self.call("save_folder", json!({"input":input}))
    }
    pub fn search(
        &self,
        query: String,
        folder_id: Option<String>,
    ) -> Result<SearchResults, HostError> {
        validate_query(&query, folder_id.as_deref())?;
        self.call(
            "search_library",
            json!({"query":query,"folderId":folder_id,"limit":40}),
        )
    }
    fn call<T: DeserializeOwned>(
        &self,
        command: &'static str,
        arguments: Value,
    ) -> Result<T, HostError> {
        self.call_with_timeout(command, arguments, TIMEOUT)
    }
    fn call_with_timeout<T: DeserializeOwned>(
        &self,
        command: &'static str,
        arguments: Value,
        timeout: Duration,
    ) -> Result<T, HostError> {
        let count = self.running.fetch_add(1, Ordering::AcqRel);
        let _permit = Permit(&self.running);
        if count >= MAX_PARALLEL {
            return Err(HostError::new(
                "busy",
                "The library is busy. Try again in a moment.",
            ));
        }
        self.engine.verify()?;
        let bytes = serde_json::to_vec(&json!({"command":command,"arguments":arguments}))
            .map_err(|_| HostError::invalid())?;
        if bytes.len() > MAX_INPUT {
            return Err(HostError::invalid());
        }
        let output = execute(&self.engine.path, &self.root, bytes, timeout)?;
        decode(&output)
    }
}
struct Permit<'a>(&'a AtomicUsize);
impl Drop for Permit<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}
fn development_override(name: &str) -> Option<PathBuf> {
    #[cfg(debug_assertions)]
    {
        std::env::var_os(name).map(PathBuf::from)
    }
    #[cfg(not(debug_assertions))]
    {
        let _ = name;
        None
    }
}
fn is_link_or_reparse(metadata: &fs::Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        return metadata.file_attributes() & 0x400 != 0; // FILE_ATTRIBUTE_REPARSE_POINT
    }
    #[cfg(not(windows))]
    {
        false
    }
}
fn ordinary_ancestors(path: &Path) -> Result<(), HostError> {
    #[cfg(windows)]
    {
        for ancestor in path.ancestors() {
            match fs::symlink_metadata(ancestor) {
                Ok(metadata) if metadata.is_dir() && !is_link_or_reparse(&metadata) => (),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                _ => {
                    return Err(HostError::new(
                        "invalid_configuration",
                        "The desktop location cannot contain links or reparse points.",
                    ))
                }
            }
        }
    }
    #[cfg(not(windows))]
    let _ = path;
    Ok(())
}
fn prepare_root(root: &Path) -> Result<(), HostError> {
    if !root.is_absolute() {
        return Err(HostError::new(
            "invalid_configuration",
            "The desktop data location must be absolute.",
        ));
    }
    ordinary_ancestors(root)?;
    if let Ok(meta) = fs::symlink_metadata(root) {
        if !meta.is_dir() || is_link_or_reparse(&meta) {
            return Err(HostError::new(
                "invalid_configuration",
                "The desktop data location must be a regular directory.",
            ));
        }
    }
    fs::create_dir_all(root).map_err(|_| {
        HostError::new(
            "storage_unavailable",
            "The desktop data directory could not be created.",
        )
    })?;
    ordinary_ancestors(root)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(root, fs::Permissions::from_mode(0o700)).map_err(|_| {
            HostError::new(
                "storage_unavailable",
                "The desktop data directory could not be secured.",
            )
        })?;
    }
    Ok(())
}
impl Engine {
    fn verify(&self) -> Result<(), HostError> {
        let unavailable = || {
            HostError::new(
                "engine_unavailable",
                "The library engine is not installed for this desktop build.",
            )
        };
        if !self.path.is_absolute() || self.digest.as_ref().is_some_and(|hash| hash.is_empty()) {
            return Err(unavailable());
        }
        ordinary_ancestors(self.path.parent().ok_or_else(unavailable)?)
            .map_err(|_| unavailable())?;
        let metadata = fs::symlink_metadata(&self.path).map_err(|_| unavailable())?;
        if !metadata.is_file() || is_link_or_reparse(&metadata) {
            return Err(unavailable());
        }
        if let Some(expected) = &self.digest {
            #[cfg(windows)]
            let mut file = {
                use std::os::windows::fs::OpenOptionsExt;
                fs::OpenOptions::new()
                    .read(true)
                    .custom_flags(0x00200000)
                    .open(&self.path)
                    .map_err(|_| unavailable())?
            };
            #[cfg(not(windows))]
            let mut file = File::open(&self.path).map_err(|_| unavailable())?;
            let opened = file.metadata().map_err(|_| unavailable())?;
            if !opened.is_file() || is_link_or_reparse(&opened) {
                return Err(unavailable());
            }
            let mut hash = Sha256::new();
            let mut buf = [0u8; 64 * 1024];
            loop {
                let count = file.read(&mut buf).map_err(|_| unavailable())?;
                if count == 0 {
                    break;
                }
                hash.update(&buf[..count]);
            }
            if format!("{:x}", hash.finalize()) != *expected {
                return Err(HostError::new(
                    "engine_integrity",
                    "The library engine failed its integrity check. Reinstall this desktop build.",
                ));
            }
        }
        Ok(())
    }
}

fn decode<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, HostError> {
    // Booleans are intentionally decoded separately: internally tagged Serde
    // enums accept strings, whereas the transport uses a JSON boolean.
    let value: Value = serde_json::from_slice(bytes).map_err(|_| protocol_error())?;
    match value.get("ok").and_then(Value::as_bool) {
        Some(true) => {
            serde_json::from_value(value.get("result").cloned().ok_or_else(protocol_error)?)
                .map_err(|_| protocol_error())
        }
        Some(false) => {
            let error: HostError =
                serde_json::from_value(value.get("error").cloned().ok_or_else(protocol_error)?)
                    .map_err(|_| protocol_error())?;
            let allowed = [
                "invalid_request",
                "unsupported_command",
                "not_found",
                "conflict",
                "duplicate_name",
                "library_error",
                "content_too_large",
                "unsupported_platform",
                "import_failed",
            ];
            if !allowed.contains(&error.code.as_str())
                || error.message.len() > 1024
                || error.message.contains('\0')
            {
                return Err(protocol_error());
            }
            Err(error)
        }
        None => Err(protocol_error()),
    }
}
fn protocol_error() -> HostError {
    HostError::new(
        "invalid_response",
        "The library engine returned an invalid response.",
    )
}
fn process_error() -> HostError {
    HostError::new(
        "engine_failure",
        "The library operation could not be completed. Your changes remain in the editor.",
    )
}

enum PipeEvent {
    Stdout(Result<Vec<u8>, HostError>),
    Stderr(Result<Vec<u8>, HostError>),
    Input(Result<(), HostError>),
}
fn read_bounded(mut stream: impl Read, max: usize) -> Result<Vec<u8>, HostError> {
    let mut bytes = Vec::new();
    stream
        .by_ref()
        .take((max + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| process_error())?;
    if bytes.len() > max {
        return Err(HostError::new(
            "content_too_large",
            "The library response exceeded the desktop limit.",
        ));
    }
    Ok(bytes)
}
fn execute(
    engine: &Path,
    root: &Path,
    input: Vec<u8>,
    timeout: Duration,
) -> Result<Vec<u8>, HostError> {
    let mut command = Command::new(engine);
    command
        .args(["desktop-bridge", "--root"])
        .arg(root)
        .current_dir(root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env_clear();
    // No loader, provider or application configuration is inherited by the
    // metadata-only subprocess. Windows needs these OS locations to load DLLs.
    for name in ["SystemRoot", "WINDIR", "TMP", "TEMP", "LANG", "LC_ALL"] {
        if let Some(value) = std::env::var_os(name) {
            command.env(name, value);
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    let mut child = command.spawn().map_err(|_| process_error())?;
    let (sender, receiver) = mpsc::channel();
    let mut stdin = child.stdin.take().ok_or_else(process_error)?;
    let stdout = child.stdout.take().ok_or_else(process_error)?;
    let stderr = child.stderr.take().ok_or_else(process_error)?;
    let tx = sender.clone();
    thread::spawn(move || {
        let result = stdin.write_all(&input).map_err(|_| process_error());
        drop(stdin);
        let _ = tx.send(PipeEvent::Input(result));
    });
    let tx = sender.clone();
    thread::spawn(move || {
        let _ = tx.send(PipeEvent::Stdout(read_bounded(stdout, MAX_OUTPUT)));
    });
    thread::spawn(move || {
        let _ = sender.send(PipeEvent::Stderr(read_bounded(stderr, MAX_STDERR)));
    });
    let deadline = Instant::now() + timeout;
    let mut output = None;
    let mut stderr_done = false;
    let mut stdin_done = false;
    let mut exited = false;
    let result = loop {
        while let Ok(event) = receiver.try_recv() {
            match event {
                PipeEvent::Stdout(Ok(bytes)) => output = Some(bytes),
                PipeEvent::Stderr(Ok(_)) => stderr_done = true,
                PipeEvent::Input(Ok(())) => stdin_done = true,
                PipeEvent::Stdout(Err(error))
                | PipeEvent::Stderr(Err(error))
                | PipeEvent::Input(Err(error)) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(error);
                }
            }
        }
        if !exited {
            match child.try_wait() {
                Ok(Some(status)) if status.success() => exited = true,
                Ok(Some(_)) | Err(_) => break Err(process_error()),
                Ok(None) => (),
            }
        }
        if exited && stderr_done && stdin_done && output.is_some() {
            break Ok(output.take().unwrap());
        }
        if Instant::now() >= deadline {
            break Err(HostError::new(
                "engine_timeout",
                "The library operation took too long. Try again.",
            ));
        }
        thread::sleep(Duration::from_millis(5));
    };
    if result.is_err() {
        let _ = child.kill();
    }
    let _ = child.wait();
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn transport_rejects_truncated_or_wrong_envelopes() {
        for input in [
            b"{}".as_slice(),
            b"{\"ok\":true}",
            b"{\"ok\":\"true\",\"result\":{}}",
            b"{\"ok\":false,\"error\":{\"code\":\"raw\",\"message\":\"path\"}}",
        ] {
            assert_eq!(decode::<Value>(input).unwrap_err().code, "invalid_response");
        }
        let conflict = decode::<Value>(
            br#"{"ok":false,"error":{"code":"conflict","message":"Reload before saving."}}"#,
        )
        .unwrap_err();
        assert_eq!(conflict.code, "conflict");
        assert_eq!(
            decode::<Value>(br#"{"ok":true,"result":{"id":"yes"}}"#).unwrap()["id"],
            "yes"
        );
    }
    #[test]
    fn response_limit_is_checked_at_the_boundary() {
        assert_eq!(
            read_bounded(Cursor::new(b"12345"), 4).unwrap_err().code,
            "content_too_large"
        );
        assert_eq!(read_bounded(Cursor::new(b"1234"), 4).unwrap(), b"1234");
    }
    #[test]
    fn absent_and_changed_engines_cannot_run() {
        let temp = tempfile::tempdir().unwrap();
        let missing = Engine {
            path: temp.path().join("missing"),
            digest: None,
        };
        assert_eq!(missing.verify().unwrap_err().code, "engine_unavailable");
        let file = temp.path().join("engine");
        fs::write(&file, b"one").unwrap();
        let trusted = Engine {
            path: file.clone(),
            digest: Some(format!("{:x}", Sha256::digest(b"one"))),
        };
        assert!(trusted.verify().is_ok());
        fs::write(&file, b"two").unwrap();
        assert_eq!(trusted.verify().unwrap_err().code, "engine_integrity");
    }
    #[cfg(unix)]
    #[test]
    fn symlinks_and_nonabsolute_fixture_roots_are_refused() {
        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("engine");
        fs::write(&file, b"one").unwrap();
        let link = temp.path().join("link");
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert_eq!(
            Engine {
                path: link,
                digest: None
            }
            .verify()
            .unwrap_err()
            .code,
            "engine_unavailable"
        );
        assert!(prepare_root(Path::new("relative")).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn subprocess_timeout_and_failed_exit_are_sanitized() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let process = temp.path().join("process");
        fs::write(&process, "#!/bin/sh\nexec /bin/sleep 1\n").unwrap();
        fs::set_permissions(&process, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(
            execute(
                &process,
                temp.path(),
                b"{}".to_vec(),
                Duration::from_millis(30)
            )
            .unwrap_err()
            .code,
            "engine_timeout"
        );
        fs::write(
            &process,
            "#!/bin/sh\necho private-account-path >&2\nexit 4\n",
        )
        .unwrap();
        assert_eq!(
            execute(
                &process,
                temp.path(),
                b"{}".to_vec(),
                Duration::from_secs(2)
            )
            .unwrap_err()
            .code,
            "engine_failure"
        );
    }
}
