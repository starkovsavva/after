# Linux CPU dependency profile before activation

## Artifact policy

`requirements-linux-cpu.txt` records direct package versions; the native installer
uses compiled `python-wheels-linux-x86_64.json`, covering all 9 resolved direct and
transitive wheels for CPython 3.12/Linux x86_64 GNU. MLX, Torch and GPU runtimes are
absent. Existing macOS requirements/setup are unchanged.

The wheel set was resolved by the verified private CPython with binary-only PyPI
downloads. `pin_linux_speech_wheels.py --refresh` explicitly reads official
`https://pypi.org/pypi/<name>/<version>/json`, compares downloaded bytes with the
release's SHA-256/size and records the exact files.pythonhosted.org asset URL.
Ordinary checks are offline and never derive authority from installed packages.
Updating requirements alone does not change the compiled runtime policy.

## Installation boundary

`--profile linux-cpu` extends generation preparation before activation. Source may
be HTTPS or an explicit read-only wheelhouse. Shared infrastructure
`artifact_download.rs` copies into a new private file and verifies size/hash before
any archive/package parser consumes it; CPython staging uses the same adapter.
Malformed filenames, sources, hashes and incomplete profiles fail.

The verified CPython's bundled ensurepip bootstraps pip in the new venv. Installation
uses only the staged wheelhouse, all pinned hashes, no index, no dependencies
outside the explicit set, no source builds or bytecode compilation. Pip configuration
is disabled through `PIP_CONFIG_FILE=/dev/null` and isolated mode; no credentials
or Python/loader overrides enter installer children. `pip check` verifies closure.
See [pip secure installs](https://pip.pypa.io/en/stable/topics/secure-installs/) and
[configuration](https://pip.pypa.io/en/stable/topics/configuration/).

A compiled offline probe checks all package versions/imports, executes a tiny
ONNX Identity graph on CPU and converts synthetic silent audio with the wheel's
FFmpeg. The binary must reside inside the venv; system fallback fails. The probe's
model uses the [official ONNX protobuf format](https://github.com/onnx/onnx/blob/main/onnx/onnx.proto3).
Base CPython is reverified, then the existing generation protocol publishes only
a successful candidate. The local profile receipt reports provenance/probe success;
it is not a trust root or a model-readiness capability.

## Evidence and limits

`check-linux-speech-profile.py` exercises base installation, corrupt-wheel refusal
without changing activation/leaking its candidate, full CPU installation, actual
ONNX/FFmpeg probe, active-generation validation and previous-generation retention.
Both local-cache and real HTTPS paths pass on Arch. Ubuntu CI is configured;
remote execution is not claimed. Default desktop/IPC regression remains separate.

No speech model or personal audio is used; `ready-v2` is not written. Package files
after installation are a separate trust boundary: installed RECORD/profile metadata
is never used as authenticity proof. This does not establish ASR accuracy or model
integrity. Next: reviewed CPU model catalog/assets, real speech recognition,
controlled backend packaging and durable Tauri speech jobs.
