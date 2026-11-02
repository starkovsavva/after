# Managed Parakeet artifact and portable generation storage

## Decision

Use the reviewed sherpa-onnx Parakeet TDT v3 int8 ONNX release for explicit local
CPU CLI transcription. The model is data, not an executable Python runtime.
`application/asr_model_install.rs` orders stage, verify and activate through a port;
`infrastructure/asr_model_store.rs` owns artifact selection/extraction/verification.
The common worker composes runtime/model guards without selecting an OS SDK.

`infrastructure/generation_store.rs` owns Unix leases, candidate identity and cleanup,
fsync and atomic active-pointer publication for both CPython and models. Candidates
cannot be published into another scope. Never delete the stable lock or previous
and unknown generations. Uncertain activation acknowledgements retain candidates.
The shared inventory verifier supports data-only layouts; CPython layouts still
require a pinned dynamic library. Neither shared component selects an artifact or
loads an interpreter/ASR SDK.

## Artifact and selection

The [official release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models)
archive `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2` is 487170055 bytes,
SHA-256 `5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf`.
`backend/asr-model-parakeet-v3-int8.json` pins all eight files and directories.
`pin_asr_model.py` verifies the archive before parsing it; native installation
verifies before extraction and checks the full tree before atomic activation.
Weights, tokens and included test WAVs must match; aliases/special files are refused.

The native receipt is not renderer authority or a speech readiness claim.
Selection requires explicit `asrModelPath`; no settings are overwritten.
Managed generations require canonical paths, owned directories and full inventory
verification. Explicit external model paths retain the existing user-selected local
compatibility boundary. Frozen job settings never fall back to live settings.

Python media uses the host-selected `sys.prefix`, confined to owned runtime
components, instead of hardcoding `runtime/venv`. This supports Linux generations
and the existing macOS host binding without changing installed packages.

## Verification and limits

`check-linux-asr.py` uses real pinned CPython, wheels and Parakeet on synthetic
English speech through import and canonical CLI transcription. It checks corrupt
archives leave activation intact, token tampering is rejected before execution,
frozen selection survives changed settings, and prior transcript/source survive.
Small manifest-generator contracts run in desktop CI; the large real-model smoke
is opt-in. Backend media contracts cover generation paths and foreign-path refusal.

This does not implement default model discovery, readiness, diarization setup,
Tauri speech jobs, acceleration, or quality guarantees across languages.
