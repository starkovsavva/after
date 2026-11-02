//! Portable capture lifecycle/recovery through an injected device backend. Files
//! stay in the private library until an exact canonical import receipt exists.
use serde::Serialize;
use crate::{capture_audio as wav, capture_backend::{CaptureBackend, CaptureCapabilities, CaptureControl, CaptureMode, CaptureRequest}};
use std::{
    fs,
    path::PathBuf,
    sync::{mpsc, Arc, Mutex},
    thread::{self, JoinHandle},
    time::Instant,
};
#[path = "capture/guard.rs"]
mod guard;


#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingStatus {
    pub session_id: Option<String>,
    pub phase: String,
    pub mode: Option<String>,
    pub elapsed_ms: u64,
    pub warning: Option<String>,
}
impl RecordingStatus {
    fn idle() -> Self {
        Self {
            session_id: None,
            phase: "idle".into(),
            mode: None,
            elapsed_ms: 0,
            warning: None,
        }
    }
}
struct Session {
    stop: mpsc::Sender<()>,
    worker: JoinHandle<()>,
    path: PathBuf,
    guard: guard::Guard,
}
struct Shared {
    status: RecordingStatus,
    started: Option<Instant>,
}
struct SessionControl {
    state: Arc<Mutex<Shared>>,
    identity: String,
    ready: Option<mpsc::SyncSender<Result<(),String>>>,
    stop: mpsc::Receiver<()>,
}
impl CaptureControl for SessionControl {
    fn started(&mut self) -> Result<(),String> {
        let ready=self.ready.take().ok_or("The capture backend reported readiness twice.")?;
        let mut state=self.state.lock().unwrap_or_else(|error|error.into_inner());
        if state.status.session_id.as_deref()!=Some(&self.identity) { return Err("The capture session changed.".into()); }
        state.started=Some(Instant::now()); state.status.phase="recording".into();
        // A caller may have timed out and already requested stop. Keep cleanup
        // in the backend even when that caller no longer receives readiness.
        let _=ready.send(Ok(()));
        Ok(())
    }
    fn wait_for_stop(&self, timeout:std::time::Duration) -> bool {
        !matches!(self.stop.recv_timeout(timeout),Err(mpsc::RecvTimeoutError::Timeout))
    }
}
impl SessionControl {
    fn finish(&mut self, result:Result<(),String>) {
        let result=if self.ready.is_some() && result.is_ok() { Err("The capture backend stopped before reporting readiness.".into()) } else { result };
        let mut state=self.state.lock().unwrap_or_else(|error|error.into_inner());
        if state.status.session_id.as_deref()==Some(&self.identity) {
            if let Some(started)=state.started { state.status.elapsed_ms=started.elapsed().as_millis().min(u64::MAX as u128) as u64; }
            state.status.phase=if result.is_ok() { "stopped" } else { "interrupted" }.into();
            state.status.warning=result.as_ref().err().cloned();
        }
        if let Some(ready)=self.ready.take() { let _=ready.send(result); }
    }
}
pub struct CompletedRecording {
    pub path: PathBuf,
    pub status: RecordingStatus,
    _guard: guard::Guard,
    _file: Option<std::fs::File>,
}
impl CompletedRecording {
    pub fn session_id(&self) -> Result<&str, String> {
        self.status.session_id.as_deref().filter(|id|valid_session_id(id))
            .ok_or_else(|| "Invalid recording identity.".into())
    }
    pub fn finalize(&mut self) -> Result<(), String> {
        let dir=self.path.parent().ok_or("Invalid recording path.")?;
        if imported(dir)? { return Err("This recording was already saved to the library.".into()); }
        if self._file.is_none() {
            let mut file=guard::open_source(&self.path,true).map_err(|_| "The recording is unavailable or unsafe.")?;
            wav::repair(&mut file).map_err(|_| "The recording cannot be recovered as WAV; its original file was kept.")?;
            self._file=Some(file);
        }
        Ok(())
    }
    pub fn mark_imported(&self) -> Result<(), String> {
        mark_imported(self.path.parent().ok_or("Invalid recording path.")?)
    }
}
impl crate::recording_import::CapturedRecording for CompletedRecording {
    fn session_id(&self) -> Result<&str,crate::models::HostError> {
        self.session_id().map_err(|_|crate::models::HostError::invalid())
    }
    fn source(&self) -> &std::path::Path { &self.path }
    fn finalize(&mut self) -> Result<(),crate::models::HostError> {
        self.finalize().map_err(|_|crate::models::HostError::new("recording_error","The captured audio could not be finalized. It remains available for recovery."))
    }
    fn acknowledge(&self) -> Result<(),crate::models::HostError> {
        self.mark_imported().map_err(|_|crate::models::HostError::new("recording_error","The saved recording could not be acknowledged."))
    }
}
fn imported(dir: &std::path::Path) -> Result<bool,String> {
    let path=dir.join("imported");
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind()==std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err("Cannot inspect recording receipt marker.".into()),
        Ok(_) => {
            let file=guard::open_source(&path,false).map_err(|_| "Recording receipt marker is unsafe.")?;
            if file.metadata().map_err(|_| "Cannot inspect recording receipt marker.")?.len()!=0 {
                return Err("Recording receipt marker is invalid.".into());
            }
            Ok(true)
        }
    }
}
fn mark_imported(dir: &std::path::Path) -> Result<(),String> {
    if imported(dir)? { return Ok(()); }
    fs::OpenOptions::new().write(true).create_new(true).open(dir.join("imported"))
        .and_then(|file|file.sync_all()).map_err(|_| "The recording was imported but could not be marked as saved.")?;
    Ok(())
}

pub struct Recorder {
    root: PathBuf,
    backend: Arc<dyn CaptureBackend>,
    startup_timeout: std::time::Duration,
    state: Arc<Mutex<Shared>>,
    session: Mutex<Option<Session>>,
}
impl Recorder {
    pub fn capabilities(&self) -> CaptureCapabilities { self.backend.capabilities() }

    pub fn new(root: PathBuf, backend: Arc<dyn CaptureBackend>) -> Self {
        Self {
            root,
            backend,
            startup_timeout: std::time::Duration::from_secs(10),
            state: Arc::new(Mutex::new(Shared {
                status: RecordingStatus::idle(),
                started: None,
            })),
            session: Mutex::new(None),
        }
    }
    pub fn status(&self) -> RecordingStatus {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let mut status = state.status.clone();
        if status.phase == "recording" {
            if let Some(t) = state.started {
                status.elapsed_ms = t.elapsed().as_millis().min(u64::MAX as u128) as u64;
            }
        }
        status
    }
    pub fn start(&self, mode: String) -> Result<RecordingStatus, String> {
        let mode = CaptureMode::parse(&mode)?;
        if !self.backend.capabilities().supports(mode) {
            return Err("The capture backend does not support this recording mode.".into());
        }
        let mut slot = self
            .session
            .lock()
            .map_err(|_| "Recording state is unavailable.")?;
        if slot.is_some() {
            return Err("A recording is already active or awaiting saving.".into());
        }
        let session_id = uuid::Uuid::new_v4().to_string();
        let (dir, guard) = guard::create(&self.root, &session_id)
            .map_err(|_| "Cannot create a protected recording folder.")?;
        let path = dir.join("source.wav");
        let (stop_tx, stop_rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let state = Arc::clone(&self.state);
        let path_for_thread = path.clone();
        let backend = self.backend.clone();
        let identity = session_id.clone();
        {
            let mut s = state.lock().unwrap_or_else(|e| e.into_inner());
            s.status = RecordingStatus {
                session_id: Some(session_id),
                phase: "starting".into(),
                mode: Some(mode.as_str().into()),
                elapsed_ms: 0,
                warning: None,
            };
            s.started = None;
        }
        let worker = thread::Builder::new()
            .name("after-audio-capture".into())
            .spawn(move || {
                let mut control=SessionControl { state, identity, ready:Some(ready_tx), stop:stop_rx };
                let result=backend.record(CaptureRequest { destination:&path_for_thread,mode }, &mut control);
                control.finish(result);
            })
            .map_err(|_| {
                let mut s = self.state.lock().unwrap_or_else(|e| e.into_inner());
                s.status = RecordingStatus::idle();
                s.started = None;
                "Cannot start the audio recording thread."
            })?;
        let expected_path = path.clone();
        *slot = Some(Session {
            stop: stop_tx,
            worker,
            path,
            guard,
        });
        drop(slot);
        match ready_rx.recv_timeout(self.startup_timeout) {
            Ok(Ok(())) => Ok(self.status()),
            Ok(Err(error)) => {
                if let Ok(mut slot) = self.session.lock() {
                    if slot
                        .as_ref()
                        .is_some_and(|session| session.path == expected_path)
                    {
                        let session = slot.take().unwrap();
                        let _ = session.stop.send(());
                        let _ = session.worker.join();
                        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
                        state.status = RecordingStatus::idle();
                        state.started = None;
                    }
                }
                Err(error)
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                if let Ok(mut slot) = self.session.lock() {
                    if slot
                        .as_ref()
                        .is_some_and(|session| session.path == expected_path)
                    {
                        let session = slot.take().unwrap();
                        let _ = session.stop.send(());
                        let _ = session.worker.join();
                        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
                        state.status = RecordingStatus::idle();
                        state.started = None;
                    }
                }
                Err("The audio thread stopped before recording started. Any captured audio remains available for recovery.".into())
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if let Ok(slot) = self.session.lock() {
                    if let Some(session) = slot.as_ref().filter(|s| s.path == expected_path) {
                        let _ = session.stop.send(());
                        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
                        state.status.warning = Some("Starting audio took too long; cancellation was requested. Stop the session to finalize any captured audio.".into());
                        return Ok(state.status.clone());
                    }
                }
                Ok(self.status())
            }
        }
    }
    /// List only validated, unsaved sessions. No filesystem path crosses IPC.
    pub fn recoverable(&self) -> Result<Vec<RecoverableRecording>, String> {
        let captures = self.root.join("captures");
        if !captures.exists() {
            return Ok(Vec::new());
        }
        let _captures =
            guard::pin(&captures).map_err(|_| "Cannot inspect the protected recovery folder.")?;
        // Hold the session lock through enumeration so a concurrent start
        // cannot make its file appear as a recoverable stopped recording.
        let session = self
            .session
            .lock()
            .map_err(|_| "Recording state unavailable.")?;
        let current = session
            .as_ref()
            .and_then(|value| value.path.parent())
            .and_then(|dir| dir.file_name())
            .and_then(|id| id.to_str());
        let mut result = Vec::new();
        for entry in fs::read_dir(&captures).map_err(|_| "Cannot inspect recordings.")? {
            let entry = entry.map_err(|_| "Cannot inspect recordings.")?;
            let id = match entry.file_name().into_string() {
                Ok(v) if valid_session_id(&v) => v,
                _ => continue,
            };
            if current == Some(id.as_str()) {
                continue;
            }
            let dir = entry.path();
            let _guard = match guard::pin_session(&dir) {
                Ok(v) => v,
                Err(_) => continue,
            };
            if imported(&dir)? {
                continue;
            }
            let file = match guard::open_source(&dir.join("source.wav"), false) {
                Ok(v) => v,
                Err(_) => continue,
            };
            let bytes = file.metadata().map(|m| m.len()).unwrap_or(0);
            if bytes > 44 {
                result.push(RecoverableRecording {
                    session_id: id,
                    bytes,
                });
            }
        }
        result.sort_by(|a, b| a.session_id.cmp(&b.session_id));
        Ok(result)
    }
    pub fn pending(&self, session_id: String) -> Result<CompletedRecording, String> {
        if !valid_session_id(&session_id) {
            return Err("Invalid recording identifier.".into());
        }
        if self
            .session
            .lock()
            .map_err(|_| "Recording state unavailable.")?
            .is_some()
            && self.status().session_id.as_deref() == Some(&session_id)
        {
            return Err("Stop this recording before recovering it.".into());
        }
        let dir = self.root.join("captures").join(&session_id);
        let guard = guard::pin_session(&dir).map_err(|_| "The recording is unavailable or unsafe.")?;
        let path = dir.join("source.wav");
        let status = RecordingStatus {
            session_id: Some(session_id),
            phase: "recovered".into(),
            mode: None,
            elapsed_ms: 0,
            warning: Some("Recovered after an interrupted recording or import.".into()),
        };
        Ok(CompletedRecording {
            path,
            status,
            _guard: guard,
            _file: None,
        })
    }
    #[cfg(test)]
    pub fn recover(&self, session_id: String) -> Result<CompletedRecording, String> {
        let mut completed=self.pending(session_id)?;
        completed.finalize()?;
        Ok(completed)
    }
    #[cfg(test)]
    pub fn mark_imported(&self, session_id: &str) -> Result<(), String> {
        if !valid_session_id(session_id) {
            return Err("Invalid recording identifier.".into());
        }
        let dir = self.root.join("captures").join(session_id);
        let _guard = guard::pin(&dir).map_err(|_| "The recording is unavailable or unsafe.")?;
        mark_imported(&dir)
    }
    pub fn stop(&self) -> Result<CompletedRecording, String> {
        let mut slot = self
            .session
            .lock()
            .map_err(|_| "Recording state is unavailable.")?;
        let session = slot.take().ok_or("No recording is active.")?;
        let _ = session.stop.send(());
        let panicked = session.worker.join().is_err();
        // Publish idle only once capture is actually stopped, while the session
        // lock still prevents a concurrent new start from having its state reset.
        let completed_status = {
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            let mut status = state.status.clone();
            if panicked {
                status.phase = "interrupted".into();
                status.warning = Some("The recording process stopped unexpectedly; the available audio was recovered.".into());
            }
            state.status = RecordingStatus::idle();
            state.started = None;
            status
        };
        drop(slot);
        let mut file = guard::open_source(&session.path, true).map_err(|_| {
            "No captured audio file is available. The session remains in the recovery folder."
        })?;
        // A write or worker failure can leave a checkpoint header shorter than
        // the captured PCM. Repair before importing; if this fails, keep the
        // original available for a later recovery attempt.
        wav::repair(&mut file).map_err(|_| "The captured audio could not be finalized; the original remains available for recovery.")?;
        Ok(CompletedRecording {
            path: session.path,
            status: completed_status,
            _guard: session.guard,
            _file: Some(file),
        })
    }
}
impl Drop for Recorder {
    fn drop(&mut self) {
        if let Ok(slot) = self.session.get_mut() {
            if let Some(session) = slot.take() {
                let _ = session.stop.send(());
                let _ = session.worker.join();
            }
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecoverableRecording {
    pub session_id: String,
    pub bytes: u64,
}
fn valid_session_id(id: &str) -> bool {
    uuid::Uuid::parse_str(id).is_ok_and(|v| v.to_string() == id)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Clone, Copy)]
    enum Behavior { Normal, NoReady, PanicBeforeReady, DuplicateReady }
    struct Synthetic {
        behavior:Behavior,
        stopped: Arc<std::sync::atomic::AtomicBool>,
        init: Option<Mutex<mpsc::Receiver<()>>>,
    }
    impl CaptureBackend for Synthetic {
        fn capabilities(&self)->CaptureCapabilities { CaptureCapabilities::MICROPHONE }
        fn record(&self, request:CaptureRequest<'_>,control:&mut dyn CaptureControl)->Result<(),String> {
            if let Some(init)=&self.init { init.lock().unwrap().recv_timeout(std::time::Duration::from_secs(2)).map_err(|_|"Synthetic init timeout")?; }
            assert_eq!(request.mode,CaptureMode::Microphone);
            let mut wav=wav::Wav::create(request.destination).map_err(|error|error.to_string())?;
            wav.write(&[0.25;100]).map_err(|error|error.to_string())?;
            if matches!(self.behavior,Behavior::PanicBeforeReady) { panic!("Synthetic capture panic"); }
            if matches!(self.behavior,Behavior::NoReady) { return Ok(()); }
            control.started()?;
            if matches!(self.behavior,Behavior::DuplicateReady) { control.started()?; }
            while !control.wait_for_stop(std::time::Duration::from_millis(10)) {}
            wav.finish().map_err(|error|error.to_string())?;
            self.stopped.store(true,std::sync::atomic::Ordering::Release);
            Ok(())
        }
    }
    fn synthetic(behavior:Behavior)->Arc<Synthetic> {
        Arc::new(Synthetic { behavior,stopped:Arc::new(std::sync::atomic::AtomicBool::new(false)),init:None })
    }
    #[test]
    fn injected_backend_owns_devices_and_common_lifecycle_stops_and_retains_audio() {
        let root=tempfile::tempdir().unwrap();let backend=synthetic(Behavior::Normal);
        let recorder=Recorder::new(root.path().canonicalize().unwrap(),backend.clone());
        let started=recorder.start("microphone".into()).unwrap();
        assert_eq!(started.phase,"recording");assert_eq!(started.mode.as_deref(),Some("microphone"));
        assert!(recorder.start("microphone".into()).is_err());
        let completed=recorder.stop().unwrap();
        assert!(backend.stopped.load(std::sync::atomic::Ordering::Acquire));
        assert_eq!(completed.status.phase,"stopped");assert_eq!(fs::metadata(&completed.path).unwrap().len(),244);
        assert_eq!(recorder.status().phase,"idle");
        assert!(recorder.recoverable().unwrap().is_empty());
        drop(completed);assert_eq!(recorder.recoverable().unwrap().len(),1);
    }
    #[test]
    fn unsupported_modes_fail_before_creating_capture_directories() {
        let root=tempfile::tempdir().unwrap();let recorder=Recorder::new(root.path().canonicalize().unwrap(),synthetic(Behavior::Normal));
        assert!(recorder.start("microphone_and_system".into()).is_err());
        assert!(recorder.start("arbitrary".into()).is_err());
        assert!(!root.path().join("captures").exists());
        let recorder=Recorder::new(root.path().canonicalize().unwrap(),Arc::new(crate::capture_platform::UnavailableCapture));
        assert!(recorder.start("microphone".into()).is_err());
        assert!(!root.path().join("captures").exists());
    }
    #[test]
    fn missing_readiness_or_panic_releases_admission_and_preserves_partial_audio() {
        for behavior in [Behavior::NoReady,Behavior::PanicBeforeReady] {
            let root=tempfile::tempdir().unwrap();let recorder=Recorder::new(root.path().canonicalize().unwrap(),synthetic(behavior));
            assert!(recorder.start("microphone".into()).is_err());
            assert_eq!(recorder.status().phase,"idle");
            let pending=recorder.recoverable().unwrap();assert_eq!(pending.len(),1);
            let completed=recorder.recover(pending[0].session_id.clone()).unwrap();
            assert_eq!(fs::metadata(completed.path.clone()).unwrap().len(),244);
        }
    }
    #[test]
    fn duplicate_readiness_interrupts_instead_of_resetting_the_capture_clock() {
        let root=tempfile::tempdir().unwrap();let recorder=Recorder::new(root.path().canonicalize().unwrap(),synthetic(Behavior::DuplicateReady));
        recorder.start("microphone".into()).unwrap();
        let completed=recorder.stop().unwrap();
        assert_eq!(completed.status.phase,"interrupted");
        assert!(completed.status.warning.unwrap().contains("readiness twice"));
    }
    #[test]
    fn startup_timeout_keeps_ownership_until_late_backend_cleanup_is_joined() {
        let root=tempfile::tempdir().unwrap();let (release,init)=mpsc::channel();
        let backend=Arc::new(Synthetic { behavior:Behavior::Normal,stopped:Arc::new(std::sync::atomic::AtomicBool::new(false)),init:Some(Mutex::new(init)) });
        let mut recorder=Recorder::new(root.path().canonicalize().unwrap(),backend.clone());
        recorder.startup_timeout=std::time::Duration::from_millis(10);
        let status=recorder.start("microphone".into()).unwrap();
        assert_eq!(status.phase,"starting");assert!(status.warning.is_some());
        assert!(recorder.recoverable().unwrap().is_empty());
        release.send(()).unwrap();
        let completed=recorder.stop().unwrap();
        assert!(backend.stopped.load(std::sync::atomic::Ordering::Acquire));
        assert_eq!(recorder.status().phase,"idle");assert!(completed.path.is_file());
    }
    #[test]
    fn interrupted_recording_can_be_recovered_then_marked_imported() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let recorder = Recorder::new(root.clone(), Arc::new(crate::capture_platform::UnavailableCapture));
        let id = uuid::Uuid::new_v4().to_string();
        let (session, guard) = guard::create(&root, &id).unwrap();
        let mut wav = wav::Wav::create(&session.join("source.wav")).unwrap();
        wav.write(&vec![0.25; 100]).unwrap(); // Simulated crash before checkpoint.
        drop(wav);
        drop(guard);
        assert_eq!(recorder.recoverable().unwrap()[0].session_id, id);
        assert!(recorder.recover("../../evil".into()).is_err());
        let recovered = recorder.recover(id.clone()).unwrap();
        let bytes = std::fs::read(&recovered.path).unwrap();
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 200);
        recorder.mark_imported(&id).unwrap();
        drop(recovered);
        assert!(recorder.recoverable().unwrap().is_empty());
        assert!(session.join("source.wav").is_file());
    }
    #[test]
    fn active_session_does_not_appear_in_recovery() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let recorder = Recorder::new(root.clone(), Arc::new(crate::capture_platform::UnavailableCapture));
        let id = uuid::Uuid::new_v4().to_string();
        let (session, guard) = guard::create(&root, &id).unwrap();
        let mut wav = wav::Wav::create(&session.join("source.wav")).unwrap();
        wav.write(&[0.25; 64]).unwrap();
        drop(wav);
        let (tx, rx) = mpsc::channel();
        let worker = thread::spawn(move || {
            let _ = rx.recv();
        });
        *recorder.session.lock().unwrap() = Some(Session {
            stop: tx,
            worker,
            path: session.join("source.wav"),
            guard,
        });
        recorder.state.lock().unwrap().status = RecordingStatus {
            session_id: Some(id),
            phase: "recording".into(),
            mode: None,
            elapsed_ms: 0,
            warning: None,
        };
        assert!(recorder.recoverable().unwrap().is_empty());
        let stopped = recorder.stop().unwrap();
        assert!(stopped.status.session_id.is_some());
        assert_eq!(recorder.status().phase, "idle");
        assert!(recorder.status().session_id.is_none());
        drop(stopped);
        assert_eq!(recorder.recoverable().unwrap().len(), 1);
    }
    #[test]
    fn panicked_capture_is_repaired_and_reported_interrupted() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let recorder = Recorder::new(root.clone(), Arc::new(crate::capture_platform::UnavailableCapture));
        let id = uuid::Uuid::new_v4().to_string();
        let (session, guard) = guard::create(&root, &id).unwrap();
        let path = session.join("source.wav");
        let mut wav = wav::Wav::create(&path).unwrap();
        wav.write(&[0.25; 100]).unwrap();
        drop(wav);
        let (tx, _rx) = mpsc::channel();
        let worker = thread::spawn(|| panic!("synthetic capture failure"));
        *recorder.session.lock().unwrap() = Some(Session {
            stop: tx,
            worker,
            path,
            guard,
        });
        recorder.state.lock().unwrap().status = RecordingStatus {
            session_id: Some(id),
            phase: "recording".into(),
            mode: None,
            elapsed_ms: 0,
            warning: None,
        };
        let completed = recorder.stop().unwrap();
        assert_eq!(completed.status.phase, "interrupted");
        assert_eq!(recorder.status().phase, "idle");
        let bytes = std::fs::read(&completed.path).unwrap();
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 200);
        drop(completed);
        assert_eq!(recorder.recoverable().unwrap().len(), 1);
    }
    #[test]
    fn recovery_rejects_hard_linked_source() {
        let root = tempfile::tempdir().unwrap();
        let canonical = root.path().canonicalize().unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let (session, guard) = guard::create(&canonical, &id).unwrap();
        let original = root.path().join("other.wav");
        std::fs::write(&original, [0u8; 64]).unwrap();
        std::fs::hard_link(&original, session.join("source.wav")).unwrap();
        drop(guard);
        let recorder = Recorder::new(canonical, Arc::new(crate::capture_platform::UnavailableCapture));
        assert!(recorder.recover(id).is_err());
        assert!(recorder.recoverable().unwrap().is_empty());
        assert_eq!(std::fs::read(original).unwrap(), [0u8; 64]);
    }
    #[cfg(unix)]
    #[test]
    fn recovery_never_follows_session_symlinks() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::create_dir(root.path().join("captures")).unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        symlink(outside.path(), root.path().join("captures").join(&id)).unwrap();
        let recorder = Recorder::new(root.path().canonicalize().unwrap(), Arc::new(crate::capture_platform::UnavailableCapture));
        assert!(recorder.recover(id).is_err());
        assert!(recorder.recoverable().unwrap().is_empty());
    }
}
