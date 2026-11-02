# Linux microphone through the capture port

## Decision

`capture/linux.rs` implements `CaptureBackend` using libpulse's asynchronous
standard mainloop on the existing recorder worker. PipeWire-Pulse and PulseAudio
share this protocol; no PulseAudio daemon is bundled or started. Composition stays
in `capture_platform.rs`; lifecycle, recovery and queue policies remain portable.

Only an owned local Unix socket is eligible. Default is
`$XDG_RUNTIME_DIR/pulse/native`; an explicit `PULSE_SERVER` must be an absolute
`unix:` endpoint. Capability reads filesystem metadata without opening a device.
An explicit recording start resolves and verifies the default non-monitor source,
creates a corked mono float32/48 kHz stream, checks device identity, then uncorks.
The shared WAV writer preserves 16-bit PCM/checkpoints. System capture is not
advertised.

Dispatch, initialization and operations have bounded waits and observe cancellation.
The stream cannot move automatically. Device/default changes, overflow, missing
frames and disconnect interrupt capture, finalize the prefix and retain it for
existing durable import/recovery. No SDK callback mutates recorder state. Errors
avoid exposing device names. Context and stream disconnect on every exit path.

## Verification and limits

`scripts/check-linux-microphone.py` starts an isolated PipeWire server with no
hardware modules or session manager. It negotiates and links the sole virtual
source explicitly, runs the real libpulse adapter and imports through the real
canonical engine. `--scenario disconnect` verifies interrupted-prefix import;
`--scenario monitor` checks refusal before capture. These fixtures are opt-in via
`linux-audio-fixture`; ordinary host tests do not open devices.

Unit tests cover endpoint restrictions, source identity, fragment bounds, gap PCM
and cancellation. Physical microphone quality, permission UX and desktop-specific
behavior still need an authorized hardware check. A present socket does not prove
an available microphone. System audio, screen capture and Linux ASR remain pending.

## References

- [PulseAudio asynchronous API](https://www.freedesktop.org/software/pulseaudio/doxygen/async.html)
- [Source information and monitor identity](https://www.freedesktop.org/software/pulseaudio/doxygen/structpa__source__info.html)
- [Stream lifecycle](https://www.freedesktop.org/software/pulseaudio/doxygen/streams.html)
- [PipeWire CLI and parameter negotiation](https://docs.pipewire.org/page_man_pw-cli_1.html)
