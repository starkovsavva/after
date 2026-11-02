# Linux runtime installation through immutable generations

## Decision and ownership

Application `runtime_install.rs` orders stage → distribution verification → venv
preparation → environment verification → activation through a port. Linux
`platform/linux/runtime_install.rs` implements network, files and subprocesses.
No shell command strings, macOS tools or platform APIs enter the coordinator.

Installation requires an owned absolute root and an explicit local archive or
network request. A fixed `runtime/linux-python/.install.lock` holds a kernel lease
for the entire operation; never unlink it. Each candidate has a UUID directory
and a pinned directory identity. Path replacement stops work and prevents Drop
from deleting the replacement. Linked roots and linked/multiply-linked lock files
are rejected.

The staged archive must match the compiled size and SHA-256 before trusted GNU
tar parses it. HTTPS downloads have a timeout and size bound. Full native file
verification precedes all downloaded-code execution. The base is sealed readonly;
CPython creates a clean venv without pip at its final generation path. Children
use the existing process-tree supervisor, a 60-second deadline, no shell and a
minimal environment without credentials or loader/Python overrides. Exact version,
base/venv prefixes and SSL are probed, and the base is reverified.

## Publication and failure

The complete generation is synced before a private activation record is synced
and atomically renamed to `active.json`, followed by parent-directory sync.
Previously active generations are never overwritten, merged or removed. Ordinary
pre-publication failures discard only the current candidate; cleanup skips aliases
and unseals owned directories. If publication may have succeeded but its final
acknowledgement fails, both generations are retained and the error states this.
A process crash can leave an unreferenced candidate; later installations neither
reuse nor garbage-collect unknown generations. No crash/power-loss hardware test
is claimed; this uses the filesystem rename/fsync protocol.

## Verification and limits

Contracts cover failure ordering, exclusive lease/release, failed activation,
previous-generation retention, linked roots/locks, readonly cleanup and candidate
replacement. The real archive fixture installs, rejects a damaged archive without
changing active bytes or leaking its candidate, installs a second generation and
executes both retained interpreters. The network fixture also exercises the native
Rust downloader. All data is disposable; source/materials are never uploaded.

Default installation creates CPython and a clean venv. The optional
[Linux CPU profile](linux-cpu-speech-profile.md) installs pinned wheels before activation.
Neither mode writes `ready-v2`, installs speech models, loads macOS PyConfig or enables ASR. Verified [active-generation selection](active-runtime-selection.md) is now available.
Next: backend-specific dependencies, Linux speech execution and queue integration,
cancellation and admission against live processing. Existing macOS setup is unchanged.
