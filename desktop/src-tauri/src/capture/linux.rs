//! Local PulseAudio/PipeWire-Pulse microphone adapter. All dispatch is nonblocking;
//! device selection and stream cleanup stay on the recorder's worker thread.
use crate::{
    capture_audio::{Wav, RATE},
    capture_backend::{
        CaptureBackend, CaptureCapabilities, CaptureControl, CaptureMode, CaptureRequest,
    },
};
use libpulse_binding as pulse;
use pulse::{
    callbacks::ListResult,
    context::{Context, State as ContextState},
    mainloop::standard::{IterateResult, Mainloop},
    operation::{Operation, State as OperationState},
    sample::{Format, Spec},
    stream::{PeekResult, State as StreamState, Stream},
};
use std::{
    cell::{Cell, RefCell},
    env, fs,
    os::unix::fs::{FileTypeExt, MetadataExt},
    path::{Component, Path, PathBuf},
    rc::Rc,
    time::{Duration, Instant},
};

const TICK: Duration = Duration::from_millis(10);
const MAX_PACKET: usize = 256 * 1024;
#[derive(Debug)]
enum Error {
    Stopped,
    Failed(&'static str),
}
type Result<T> = std::result::Result<T, Error>;
fn fail(message: &'static str) -> Error {
    Error::Failed(message)
}
fn message(error: Error) -> String {
    match error {
        Error::Stopped => "Microphone initialization was cancelled.".into(),
        Error::Failed(value) => value.into(),
    }
}

pub(crate) struct LinuxMicrophone {
    server: Option<PathBuf>,
}
impl LinuxMicrophone {
    pub fn new() -> Self {
        Self {
            server: socket_path(
                env::var_os("PULSE_SERVER").as_deref(),
                env::var_os("XDG_RUNTIME_DIR").as_deref(),
            ),
        }
    }
}
fn socket_path(
    server: Option<&std::ffi::OsStr>,
    runtime: Option<&std::ffi::OsStr>,
) -> Option<PathBuf> {
    let path = if let Some(server) = server {
        PathBuf::from(server.to_str()?.strip_prefix("unix:")?)
    } else {
        PathBuf::from(runtime?).join("pulse/native")
    };
    if !path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, Component::ParentDir | Component::CurDir))
        || path.to_str()?.contains('\0')
    {
        return None;
    }
    Some(path)
}
fn local_socket(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .is_ok_and(|info| info.file_type().is_socket() && info.uid() == unsafe { libc::geteuid() })
}
impl CaptureBackend for LinuxMicrophone {
    fn capabilities(&self) -> CaptureCapabilities {
        if self.server.as_deref().is_some_and(local_socket) {
            CaptureCapabilities::MICROPHONE
        } else {
            CaptureCapabilities::NONE
        }
    }
    fn record(
        &self,
        request: CaptureRequest<'_>,
        control: &mut dyn CaptureControl,
    ) -> std::result::Result<(), String> {
        if request.mode != CaptureMode::Microphone {
            return Err("Linux system-audio capture is not available yet.".into());
        }
        let server = self
            .server
            .as_deref()
            .filter(|path| local_socket(path))
            .ok_or("A local PulseAudio or PipeWire Pulse server is required.")?;
        record(server, request.destination, control).map_err(message)
    }
}
#[derive(Clone, Debug, PartialEq)]
struct Source {
    name: String,
    index: u32,
    monitor: bool,
}
impl Source {
    fn microphone(&self) -> Result<()> {
        if self.name.is_empty() || self.monitor {
            return Err(fail(
                "Select a microphone input instead of a system-audio monitor.",
            ));
        }
        Ok(())
    }
}
struct Client {
    // Drop/disconnect the stream before the context and the mainloop API.
    stream: Option<Stream>,
    context: Context,
    mainloop: Mainloop,
}
impl Drop for Client {
    fn drop(&mut self) {
        if let Some(stream) = &mut self.stream {
            let _ = stream.disconnect();
        }
        self.context.disconnect();
    }
}
impl Client {
    fn new(server: &Path) -> Result<Self> {
        let mainloop =
            Mainloop::new().ok_or_else(|| fail("Cannot initialize the microphone event loop."))?;
        let context = Context::new(&mainloop, "After microphone")
            .ok_or_else(|| fail("Cannot initialize the audio connection."))?;
        let mut client = Self {
            stream: None,
            context,
            mainloop,
        };
        let address = format!(
            "unix:{}",
            server
                .to_str()
                .ok_or_else(|| fail("Invalid local audio socket."))?
        );
        client
            .context
            .connect(Some(&address), pulse::context::FlagSet::NOAUTOSPAWN, None)
            .map_err(|_| fail("Cannot connect to the local audio server."))?;
        Ok(client)
    }
    fn dispatch(&mut self) -> Result<()> {
        match self.mainloop.iterate(false) {
            IterateResult::Success(_) => {}
            _ => return Err(fail("The audio event loop stopped.")),
        }
        if matches!(
            self.context.get_state(),
            ContextState::Failed | ContextState::Terminated
        ) {
            return Err(fail(
                "The audio server disconnected. The captured audio was kept.",
            ));
        }
        Ok(())
    }
    fn wait(
        &mut self,
        control: &dyn CaptureControl,
        deadline: Instant,
        mut ready: impl FnMut(&Self) -> Result<bool>,
    ) -> Result<()> {
        loop {
            if control.wait_for_stop(Duration::ZERO) {
                return Err(Error::Stopped);
            }
            self.dispatch()?;
            if ready(self)? {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(fail("The audio server did not respond in time."));
            }
            if control.wait_for_stop(TICK.min(deadline.saturating_duration_since(Instant::now()))) {
                return Err(Error::Stopped);
            }
        }
    }
    fn operation<C: ?Sized>(
        &mut self,
        mut operation: Operation<C>,
        control: &dyn CaptureControl,
        deadline: Instant,
    ) -> Result<()> {
        let result = self.wait(control, deadline, |_| match operation.get_state() {
            OperationState::Done => Ok(true),
            OperationState::Cancelled => Err(fail("An audio request was cancelled.")),
            OperationState::Running => Ok(false),
        });
        if result.is_err() && operation.get_state() == OperationState::Running {
            operation.cancel();
        }
        result
    }
    fn default_source(
        &mut self,
        control: &dyn CaptureControl,
        deadline: Instant,
    ) -> Result<String> {
        let value = Rc::new(RefCell::new(None));
        let out = value.clone();
        let operation = self.context.introspect().get_server_info(move |info| {
            *out.borrow_mut() = Some(
                info.default_source_name
                    .as_ref()
                    .map(|name| name.to_string()),
            );
        });
        self.operation(operation, control, deadline)?;
        let result = value.borrow_mut().take();
        result
            .flatten()
            .filter(|name| !name.is_empty())
            .ok_or_else(|| fail("No default microphone input is available."))
    }
    fn source(
        &mut self,
        name: &str,
        control: &dyn CaptureControl,
        deadline: Instant,
    ) -> Result<Source> {
        let value = Rc::new(RefCell::new(None));
        let out = value.clone();
        let operation = self
            .context
            .introspect()
            .get_source_info_by_name(name, move |result| {
                if let ListResult::Item(info) = result {
                    *out.borrow_mut() = Some(Source {
                        name: info
                            .name
                            .as_ref()
                            .map(|name| name.to_string())
                            .unwrap_or_default(),
                        index: info.index,
                        monitor: info.monitor_of_sink.is_some(),
                    });
                }
            });
        self.operation(operation, control, deadline)?;
        let result = value.borrow_mut().take();
        result.ok_or_else(|| fail("The selected microphone input is unavailable."))
    }
    fn same_source(
        &mut self,
        expected: &Source,
        control: &dyn CaptureControl,
        deadline: Instant,
    ) -> Result<()> {
        if self.default_source(control, deadline)? != expected.name {
            return Err(fail(
                "The default microphone changed. Start a new recording to select it.",
            ));
        }
        let actual = self.source(&expected.name, control, deadline)?;
        actual.microphone()?;
        if actual != *expected {
            return Err(fail(
                "The microphone device changed. The captured audio was kept.",
            ));
        }
        Ok(())
    }
    fn stream(&self) -> &Stream {
        self.stream.as_ref().unwrap()
    }
    fn stream_mut(&mut self) -> &mut Stream {
        self.stream.as_mut().unwrap()
    }
}
fn record(server: &Path, destination: &Path, control: &mut dyn CaptureControl) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(8);
    let mut client = Client::new(server)?;
    client.wait(control, deadline, |client| {
        Ok(client.context.get_state() == ContextState::Ready)
    })?;
    let name = client.default_source(control, deadline)?;
    let selected = client.source(&name, control, deadline)?;
    selected.microphone()?;
    let spec = Spec {
        format: Format::F32le,
        channels: 1,
        rate: RATE as u32,
    };
    client.stream = Some(
        Stream::new(&mut client.context, "Microphone", &spec, None)
            .ok_or_else(|| fail("Cannot initialize the microphone stream."))?,
    );
    let overflow = Rc::new(Cell::new(false));
    let flag = overflow.clone();
    client
        .stream_mut()
        .set_overflow_callback(Some(Box::new(move || flag.set(true))));
    let moved = Rc::new(Cell::new(false));
    let flag = moved.clone();
    client
        .stream_mut()
        .set_moved_callback(Some(Box::new(move || flag.set(true))));
    let attr = pulse::def::BufferAttr {
        maxlength: 1024 * 1024,
        tlength: u32::MAX,
        prebuf: u32::MAX,
        minreq: u32::MAX,
        fragsize: 3840,
    };
    client
        .stream_mut()
        .connect_record(
            Some(&selected.name),
            Some(&attr),
            pulse::stream::FlagSet::DONT_MOVE
                | pulse::stream::FlagSet::START_CORKED
                | pulse::stream::FlagSet::ADJUST_LATENCY,
        )
        .map_err(|_| fail("Cannot connect to the selected microphone."))?;
    client.wait(control, deadline, |client| {
        match client.stream().get_state() {
            StreamState::Ready => Ok(true),
            StreamState::Failed | StreamState::Terminated => {
                Err(fail("The microphone stream could not start."))
            }
            _ => Ok(false),
        }
    })?;
    if client.stream().get_device_index() != Some(selected.index) {
        return Err(fail("The audio server selected a different input."));
    }
    client.same_source(&selected, control, deadline)?;
    if client.stream_mut().get_sample_spec() != Some(&spec) {
        return Err(fail("The microphone returned an unsupported audio format."));
    }
    let mut wav =
        Wav::create(destination).map_err(|_| fail("Cannot create the private recording file."))?;
    let uncorked = Rc::new(Cell::new(false));
    let flag = uncorked.clone();
    let operation = client
        .stream_mut()
        .uncork(Some(Box::new(move |success| flag.set(success))));
    client.operation(operation, control, deadline)?;
    if !uncorked.get() {
        return Err(fail("Cannot start the microphone stream."));
    }
    control
        .started()
        .map_err(|_| fail("The recording session is no longer available."))?;
    let result = (|| {
        let mut checked = Instant::now();
        let mut received = Instant::now();
        loop {
            client.dispatch()?;
            if overflow.get() {
                return Err(fail(
                    "The microphone buffer overflowed. The captured audio was kept.",
                ));
            }
            if moved.get() || client.stream().get_device_index() != Some(selected.index) {
                return Err(fail(
                    "The recording input changed. The captured audio was kept.",
                ));
            }
            if client.stream().get_state() != StreamState::Ready {
                return Err(fail(
                    "The microphone disconnected. The captured audio was kept.",
                ));
            }
            if checked.elapsed() >= Duration::from_secs(1) {
                client.same_source(&selected, control, Instant::now() + Duration::from_secs(2))?;
                checked = Instant::now();
            }
            if drain(client.stream_mut(), &mut wav)? {
                received = Instant::now();
            }
            if received.elapsed() > Duration::from_secs(5) {
                return Err(fail(
                    "The microphone stopped delivering audio. The captured audio was kept.",
                ));
            }
            if control.wait_for_stop(TICK) {
                // Finish only already buffered input from this verified stream.
                client.dispatch()?;
                if overflow.get()
                    || moved.get()
                    || client.stream().get_device_index() != Some(selected.index)
                {
                    return Err(fail(
                        "The recording input changed or overflowed while stopping.",
                    ));
                }
                drain(client.stream_mut(), &mut wav)?;
                return Ok(());
            }
        }
    })();
    let finished = wav
        .finish()
        .map_err(|_| fail("Cannot finalize the recording. Its last checkpoint was kept."));
    finished?;
    match result {
        Err(Error::Stopped) => Ok(()),
        other => other,
    }
}
fn drain(stream: &mut Stream, wav: &mut Wav) -> Result<bool> {
    let mut received = false;
    for _ in 0..16 {
        match stream
            .peek()
            .map_err(|_| fail("Cannot read microphone audio."))?
        {
            PeekResult::Empty => break,
            PeekResult::Hole(bytes) => {
                silence(wav, bytes)?;
                received = true;
            }
            PeekResult::Data(bytes) => {
                samples(wav, bytes)?;
                received = true;
            }
        }
        stream
            .discard()
            .map_err(|_| fail("Cannot release the microphone buffer."))?;
    }
    Ok(received)
}
fn frames(bytes: usize) -> Result<usize> {
    if bytes == 0 || bytes > MAX_PACKET || bytes % 4 != 0 {
        return Err(fail(
            "The audio server returned an invalid microphone fragment.",
        ));
    }
    Ok(bytes / 4)
}
fn samples(wav: &mut Wav, bytes: &[u8]) -> Result<()> {
    frames(bytes.len())?;
    let samples: Vec<_> = bytes
        .chunks_exact(4)
        .map(|value| f32::from_le_bytes(value.try_into().unwrap()))
        .collect();
    wav.write(&samples)
        .map_err(|_| fail("Cannot save microphone audio. Its last checkpoint was kept."))
}
fn silence(wav: &mut Wav, bytes: usize) -> Result<()> {
    let mut remaining = frames(bytes)?;
    let block = [0.0f32; 4096];
    while remaining > 0 {
        let count = remaining.min(block.len());
        wav.write(&block[..count])
            .map_err(|_| fail("Cannot save the microphone gap."))?;
        remaining -= count;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    struct Stop(bool);
    impl CaptureControl for Stop {
        fn started(&mut self) -> std::result::Result<(), String> {
            Ok(())
        }
        fn wait_for_stop(&self, timeout: Duration) -> bool {
            if !self.0 {
                std::thread::sleep(timeout);
            }
            self.0
        }
    }
    #[test]
    fn only_owned_local_unix_socket_endpoints_are_eligible() {
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("audio");
        let _listener = UnixListener::bind(&socket).unwrap();
        let local = format!("unix:{}", socket.display());
        assert_eq!(
            socket_path(Some(local.as_ref()), None),
            Some(socket.clone())
        );
        assert!(local_socket(&socket));
        assert!(socket_path(Some(std::ffi::OsStr::new("tcp:127.0.0.1:4713")), None).is_none());
        assert!(socket_path(Some(std::ffi::OsStr::new("unix:relative")), None).is_none());
        assert!(socket_path(Some(std::ffi::OsStr::new("unix:/tmp/../socket")), None).is_none());
        let alias = root.path().join("alias");
        std::os::unix::fs::symlink(&socket, &alias).unwrap();
        assert!(!local_socket(&alias));
        let regular = root.path().join("regular");
        fs::write(&regular, b"keep").unwrap();
        assert!(!local_socket(&regular));
        let backend = LinuxMicrophone {
            server: Some(socket),
        };
        assert!(backend.capabilities().supports(CaptureMode::Microphone));
        assert!(!backend
            .capabilities()
            .supports(CaptureMode::MicrophoneAndSystem));
    }
    #[test]
    fn monitor_input_is_rejected_and_identity_changes_are_distinct() {
        let mic = Source {
            name: "input".into(),
            index: 1,
            monitor: false,
        };
        assert!(mic.microphone().is_ok());
        let monitor = Source {
            monitor: true,
            ..mic.clone()
        };
        assert!(monitor.microphone().is_err());
        assert_ne!(
            mic,
            Source {
                index: 2,
                ..mic.clone()
            }
        );
        assert!(Source {
            name: String::new(),
            ..mic
        }
        .microphone()
        .is_err());
    }
    #[test]
    fn native_float_fragments_and_holes_preserve_pcm_frames_and_bounds() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("audio.wav");
        let mut wav = Wav::create(&path).unwrap();
        let data: Vec<_> = [0.5f32, -0.5, f32::NAN, 2.0]
            .into_iter()
            .flat_map(f32::to_le_bytes)
            .collect();
        samples(&mut wav, &data).unwrap();
        silence(&mut wav, 8).unwrap();
        assert!(samples(&mut wav, &[0; 3]).is_err());
        assert!(silence(&mut wav, MAX_PACKET + 4).is_err());
        wav.finish().unwrap();
        let bytes = fs::read(path).unwrap();
        assert_eq!(bytes.len(), 44 + 12);
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 12);
        assert_eq!(i16::from_le_bytes(bytes[48..50].try_into().unwrap()), 0);
        assert_eq!(i16::from_le_bytes(bytes[50..52].try_into().unwrap()), 32767);
        assert_eq!(&bytes[52..], &[0; 4]);
    }
    #[test]
    fn nonblocking_wait_observes_stop_without_connecting_or_creating_output() {
        let mainloop = Mainloop::new().unwrap();
        let context = Context::new(&mainloop, "After fixture").unwrap();
        let mut client = Client {
            stream: None,
            context,
            mainloop,
        };
        let began = Instant::now();
        assert!(matches!(
            client.wait(&Stop(true), began + Duration::from_secs(8), |_| Ok(false)),
            Err(Error::Stopped)
        ));
        assert!(began.elapsed() < Duration::from_secs(1));
    }
    #[cfg(feature = "linux-audio-fixture")]
    #[test]
    fn private_source_captures_pcm_and_saves_through_the_canonical_queue() {
        use crate::{bridge::LibraryBridge, capture::Recorder, imports::Imports, recording_import};
        use std::sync::Arc;
        let socket = PathBuf::from(
            env::var_os("AFTER_TEST_PULSE_SOCKET").expect("Run scripts/check-linux-microphone.py"),
        );
        assert!(socket.parent().unwrap().join("fixture-only").is_file());
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let engine =
            PathBuf::from(env::var_os("AFTER_TEST_ENGINE_PATH").expect("canonical fixture engine"));
        let bridge = LibraryBridge::for_development(engine, root.clone()).unwrap();
        bridge.workspace().unwrap();
        let recorder = Recorder::new(
            root.clone(),
            Arc::new(LinuxMicrophone {
                server: Some(socket),
            }),
        );
        let scenario = env::var("AFTER_TEST_AUDIO_SCENARIO").unwrap_or_else(|_| "capture".into());
        if scenario == "monitor" {
            let error = recorder.start("microphone".into()).unwrap_err();
            assert!(
                error.contains("instead of a system-audio monitor"),
                "{error}"
            );
            assert!(!root.join("captures").read_dir().unwrap().any(|entry| entry
                .unwrap()
                .path()
                .join("source.wav")
                .exists()));
            return;
        }
        let status = recorder
            .start("microphone".into())
            .expect("private virtual input must start");
        assert_eq!(status.phase, "recording");
        let path = root
            .join("captures")
            .join(status.session_id.unwrap())
            .join("source.wav");
        let deadline = Instant::now() + Duration::from_secs(4);
        while fs::metadata(&path).map(|info| info.len()).unwrap_or(0) < 44 + 4800
            && Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(20));
        }
        if scenario == "disconnect" {
            fs::write(
                PathBuf::from(env::var_os("AFTER_TEST_PULSE_SOCKET").unwrap())
                    .parent()
                    .unwrap()
                    .join("disconnect-now"),
                b"ready",
            )
            .unwrap();
            let deadline = Instant::now() + Duration::from_secs(4);
            while recorder.status().phase == "recording" && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(20));
            }
            assert_ne!(recorder.status().phase, "recording");
        }
        let mut completed = recorder.stop().unwrap();
        assert_eq!(
            completed.status.phase,
            if scenario == "disconnect" {
                "interrupted"
            } else {
                "stopped"
            },
            "{:?}",
            completed.status.warning
        );
        let original = fs::read(&completed.path).unwrap();
        assert!(
            original.len() > 44 + 4800,
            "virtual source delivered no frames"
        );
        let imports = Arc::new(Imports::default());
        let meeting = recording_import::save(
            &bridge,
            &mut completed,
            imports.reserve().unwrap(),
            Some("Private virtual microphone".into()),
            false,
        )
        .unwrap();
        assert_eq!(meeting.id, completed.session_id().unwrap());
        assert!(meeting.has_media);
        assert_eq!(fs::read(&completed.path).unwrap(), original);
        assert!(completed.path.parent().unwrap().join("imported").is_file());
    }
}
