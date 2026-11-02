# Runtime inventory verification separate from platform loading

## Problem

The macOS Python runtime module combined complete file verification, artifact
selection, venv binding and dynamic loading. Linux could not reuse the integrity
boundary without also inheriting Darwin library names and loader assumptions.

## Decision

`infrastructure/runtime_tree.rs` owns descriptor-based Unix inventory verification.
Its caller supplies a trusted `Policy` and `Layout`: required bootstrap files and
which verified file to hold as the library. The verifier neither reads a local
manifest as authority nor selects/downloads/executes Python. It requires the
library in the required inventory and rejects an empty or incomplete layout.

Ownership/mode checks, no-follow `openat`, full SHA-256 inventory, alias validation,
held descriptors and metadata recheck preserve the existing macOS behavior.
Required-file checks now take the caller's layout instead of hardcoded `.dylib`
paths. Unix APIs remain in this infrastructure adapter; domain and application
modules do not acquire filesystem or ABI dependencies.

The macOS adapter retains the compiled manifest, exact Python paths/version,
venv configuration and interpreter-alias rules, narrowly scoped debug fixture,
`/dev/fd` loading and loaded-image verification. Public Rust and C entry points
are unchanged. The macOS in-process `PyConfig` ABI is not reused for Linux.

## Verification and remaining work

Twenty-one synthetic contracts run on Linux: ELF-style file inventory and the
existing macOS composition's descriptor replacement, venv redirect and exact
version checks. No native extension or interpreter is loaded by these tests.
The source guard rejects native-loader, embedded-artifact and platform-selection
dependencies in the shared verifier. Full desktop regressions retain real-engine
and Tauri IPC coverage. Actual macOS loader/SDK behavior needs macOS CI/native
verification; Linux execution is not evidence for those behaviors.

Linux now has a [reviewed pinned distribution and real archive/venv fixture](linux-pinned-cpython.md).
It still needs an installer with verification before execution and rollback, an isolated execution adapter,
backend-specific speech dependencies, and real queued ASR integration. Windows
needs its own secure file adapter; Unix code is not a Windows verifier. No
capability or installation-success claim is enabled by this extraction.
