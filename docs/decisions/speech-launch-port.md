# Speech launch behind a retained runtime contract

## Decision

`application/speech_launch.rs` defines `SpeechLaunch`: executable, prefix arguments
and an optional `RuntimeGuard`. Shared `worker.rs` validates job arguments and
credential authority, then its entry facade requests platform composition. The
Unix supervisor owns stdout filtering, redaction, signal handling, cancellation,
parent disappearance and the process-tree scope. It rechecks the guard immediately
before spawn and retains it through child cleanup.

Linux composition validates the active generation and supplies its standalone
CPython with `-B -u -E -s`. These flags disable bytecode/user-site/environment Python
configuration, keep JSONL unbuffered and permit imports from the selected backend
resource directory. There is no system-Python fallback or macOS PyConfig layout.
The native backend path remains caller-selected; exposing speech in Tauri still
requires a controlled resource boundary rather than renderer-provided paths.

macOS composition retains the existing branded native helper, interpreter argument
and privileged Bash setup. The helper's exact pinned runtime, descriptor loader,
image/version checks and C ABI remain unchanged. A parent preflight checks the
legacy interpreter; full verification still happens inside the trusted helper.
Apple bundle layout lives in `platform/apple_bundle.rs`, with the established
`worker::application_contents` compatibility export.

Unsupported speech setup now fails at the platform boundary. Linux's separate
CPython/venv installer does not invoke Darwin setup or claim packages/models ready.
The Unix signal supervisor is not a Windows speech implementation; Windows still
needs its own execution/admission integration.

## Verification

Existing argument, cloud-key authority, actual-child environment and redaction
contracts now inject the Darwin launch explicitly, including on Linux. A new
refusing-guard test proves no child starts after failed runtime recheck. Source
guards reject Darwin/helper/legacy-Python selection in the shared supervisor and
platform dependencies in application contracts.

The real pinned CPython fixture runs a synthetic `engine.py` through the genuine
`prepare` CLI and supervisor. It checks venv/version, script resource imports,
Python flags, credential removal and JSONL progress. It then starts a worker and
descendant, waits until the descendant confirms SIGTERM is ignored, cancels the
supervisor and checks neither process remains running. Linux zombies awaiting
reaping are distinguished from live processes; cleanup checks PID identity before
signalling. No real speech, models, credentials or personal data are used.

Full desktop regression, real engine/IPC and native startup remain separate checks.
Actual macOS helper/signing behavior requires macOS CI/native verification. Next:
backend-specific speech dependencies/model assets, controlled resource packaging,
real CPU ONNX recognition and durable speech queue/Tauri integration.
