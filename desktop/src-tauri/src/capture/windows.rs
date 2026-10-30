use super::{
    wav::{Mixer, Wav, RATE},
    Shared,
};
use std::{
    path::Path,
    sync::{
        mpsc::{Receiver, SyncSender},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use wasapi::{AudioClient, DeviceEnumerator, Direction, SampleType, StreamMode, WaveFormat};
use windows::Win32::{
    Media::Audio::IAudioCaptureClient,
    System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency},
};

type Result<T> = std::result::Result<T, String>;
struct Input {
    client: AudioClient,
    capture: IAudioCaptureClient,
    device_id: String,
    direction: Direction,
    seen_packet: bool,
}
impl Input {
    fn open(e: &DeviceEnumerator, direction: Direction) -> Result<Self> {
        let device = e
            .get_default_device(&direction)
            .map_err(|err| format!("Cannot access the audio device: {err}"))?;
        let device_id = device
            .get_id()
            .map_err(|err| format!("Cannot identify the audio device: {err}"))?;
        let mut client = device
            .get_iaudioclient()
            .map_err(|err| format!("Cannot open the audio device: {err}"))?;
        let format = WaveFormat::new(32, 32, &SampleType::Float, RATE as usize, 2, None);
        let mode = StreamMode::PollingShared {
            autoconvert: true,
            buffer_duration_hns: 5_000_000,
        };
        client
            .initialize_client(&format, &Direction::Capture, &mode)
            .map_err(|err| format!("Cannot initialize audio capture: {err}"))?;
        let capture = unsafe { client.as_iaudioclient().GetService::<IAudioCaptureClient>() }
            .map_err(|err| format!("Cannot open audio capture: {err}"))?;
        Ok(Self {
            client,
            capture,
            device_id,
            direction,
            seen_packet: false,
        })
    }
    fn drain(&mut self, index: usize, base: u64, mixer: &mut Mixer) -> Result<()> {
        loop {
            let available = unsafe { self.capture.GetNextPacketSize() }
                .map_err(|err| format!("The audio device became unavailable: {err}"))?;
            if available == 0 {
                break;
            }
            let mut ptr = std::ptr::null_mut();
            let mut frames = 0;
            let mut flags = 0;
            let mut timestamp = 0u64;
            unsafe {
                self.capture.GetBuffer(
                    &mut ptr,
                    &mut frames,
                    &mut flags,
                    None,
                    Some(&mut timestamp),
                )
            }
            .map_err(|err| format!("Cannot read audio: {err}"))?;
            // Windows permits null pData when SILENT is set. Never dereference it.
            let invalid = flags & 4 != 0 || (flags & 2 == 0 && ptr.is_null());
            let samples = if invalid || flags & 2 != 0 {
                vec![0.0; frames as usize]
            } else {
                let bytes = unsafe { std::slice::from_raw_parts(ptr, frames as usize * 8) };
                bytes
                    .chunks_exact(8)
                    .map(|frame| {
                        let left = f32::from_le_bytes(frame[0..4].try_into().unwrap());
                        let right = f32::from_le_bytes(frame[4..8].try_into().unwrap());
                        (left + right) * 0.5
                    })
                    .collect::<Vec<_>>()
            };
            unsafe { self.capture.ReleaseBuffer(frames) }
                .map_err(|err| format!("Cannot release audio buffer: {err}"))?;
            if invalid {
                return Err("Windows returned an invalid audio timestamp or buffer; the captured part was saved.".into());
            }
            // A timestamp is expressed in 100-ns units of the QPC clock.
            let offset =
                ((timestamp.saturating_sub(base) as u128 * RATE as u128) / 10_000_000) as u64;
            mixer
                .push(index, offset, &samples)
                .map_err(|err| format!("Cannot synchronize audio: {err}"))?;
            // The first packet may be marked discontinuous by WASAPI. A later
            // microphone discontinuity means frames were lost; stop and make
            // the partial recording explicit instead of reporting success.
            let lost_microphone_frames = index == 0 && self.seen_packet && flags & 1 != 0;
            self.seen_packet = true;
            if lost_microphone_frames {
                return Err("Windows reported an interruption in the microphone audio. The captured part was saved.".into());
            }
        }
        Ok(())
    }
    fn unchanged(&self, e: &DeviceEnumerator) -> Result<()> {
        let id = e
            .get_default_device(&self.direction)
            .and_then(|d| d.get_id())
            .map_err(|err| format!("The audio device became unavailable: {err}"))?;
        if id != self.device_id {
            return Err("The default audio device changed. The recording was stopped and the captured part was saved.".into());
        }
        Ok(())
    }
}
fn now_hns() -> Result<u64> {
    let mut counter = 0i64;
    let mut frequency = 0i64;
    unsafe {
        QueryPerformanceCounter(&mut counter)
            .map_err(|e| format!("Audio clock unavailable: {e}"))?;
        QueryPerformanceFrequency(&mut frequency)
            .map_err(|e| format!("Audio clock unavailable: {e}"))?;
    }
    if counter < 0 || frequency <= 0 {
        return Err("Audio clock unavailable".into());
    }
    Ok(((counter as u128 * 10_000_000) / frequency as u128) as u64)
}
pub fn record(
    path: &Path,
    mode: &str,
    stop: Receiver<()>,
    ready: SyncSender<Result<()>>,
    state: Arc<Mutex<Shared>>,
) -> Result<()> {
    let mut ready = Some(ready);
    let result = run(path, mode, stop, &mut ready, state);
    if let Some(ready) = ready {
        let _ = ready.send(result.clone());
    }
    result
}
fn run(
    path: &Path,
    mode: &str,
    stop: Receiver<()>,
    ready: &mut Option<SyncSender<Result<()>>>,
    state: Arc<Mutex<Shared>>,
) -> Result<()> {
    wasapi::initialize_mta()
        .ok()
        .map_err(|err| format!("Cannot initialize Windows audio: {err}"))?;
    let e = DeviceEnumerator::new().map_err(|err| format!("Cannot find audio devices: {err}"))?;
    let mut microphone = Input::open(&e, Direction::Capture)?;
    let mut system = if mode == "microphone_and_system" {
        Some(Input::open(&e, Direction::Render)?)
    } else {
        None
    };
    let mut wav = Wav::create(path).map_err(|err| format!("Cannot create the recording: {err}"))?;
    let mut mixer = Mixer::new();
    let base = now_hns()?;
    microphone
        .client
        .start_stream()
        .map_err(|err| format!("Cannot start microphone: {err}"))?;
    if let Some(system) = &system {
        system
            .client
            .start_stream()
            .map_err(|err| format!("Cannot start system audio: {err}"))?;
    }
    {
        let mut s = state.lock().unwrap_or_else(|e| e.into_inner());
        s.started = Some(Instant::now());
        s.status.phase = "recording".into();
    }
    if let Some(ready) = ready.take() {
        let _ = ready.send(Ok(()));
    }
    let mut last_device_check = Instant::now();
    let capture_result = loop {
        let result = (|| -> Result<()> {
            microphone.drain(0, base, &mut mixer)?;
            if let Some(system) = &mut system {
                system.drain(1, base, &mut mixer)?;
            }
            let elapsed =
                ((now_hns()?.saturating_sub(base) as u128 * RATE as u128) / 10_000_000) as u64;
            mixer
                .flush(elapsed.saturating_sub(RATE), &mut wav)
                .map_err(|e| format!("Cannot save the audio: {e}"))?;
            if last_device_check.elapsed() >= Duration::from_secs(1) {
                microphone.unchanged(&e)?;
                if let Some(system) = &system {
                    system.unchanged(&e)?;
                }
                last_device_check = Instant::now();
            }
            Ok(())
        })();
        if let Err(e) = result {
            break Err(e);
        }
        if stop.recv_timeout(Duration::from_millis(10)).is_ok() {
            // Packets can arrive during the wait. Drain once more before
            // stopping the streams so the final audio is not silently cut off.
            let final_drain = microphone.drain(0, base, &mut mixer).and_then(|_| {
                if let Some(system) = &mut system {
                    system.drain(1, base, &mut mixer)
                } else {
                    Ok(())
                }
            });
            break final_drain;
        }
    };
    let _ = microphone.client.stop_stream();
    if let Some(system) = &system {
        let _ = system.client.stop_stream();
    }
    let end = now_hns()
        .map(|n| ((n.saturating_sub(base) as u128 * RATE as u128) / 10_000_000) as u64)
        .unwrap_or(0);
    let final_result = mixer.finish(end, &mut wav).map_err(|err| {
        format!("Cannot finish the recording: {err}. The last checkpoint remains on disk.")
    });
    final_result?;
    capture_result
}
