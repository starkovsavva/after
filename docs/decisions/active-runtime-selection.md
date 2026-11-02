# Verified active runtime selection

## Problem and boundaries

An atomic activation record selects a generation; it cannot authorize an arbitrary
interpreter. Linux execution needs a retained, verified generation. The former common Darwin
helper/legacy-layout assumption is now isolated behind a [speech launch port](speech-launch-port.md).

`platform/linux/runtime_active.rs` validates a bounded ordinary single-link
`active.json` under owned, pinned directories. The receipt must contain schema 1,
canonical UUID v4, the compiled Linux target/exact Python version, and the fixed
`<generation>/venv/bin/python` location. Unknown compatible fields remain tolerated.
Missing, oversized, linked, malformed or redirecting records fail without fallback.

The selected base is verified against the compiled complete inventory. Unix
`infrastructure/runtime_venv.rs` binds the venv's exact version, home and disabled
system-site packages, rejects duplicate config keys, and permits only the normal
owned interpreter-alias chain into that verified base. It retains config and
venv/bin directory descriptors plus alias observations for pre-execution recheck.
This is shared by macOS; Darwin policy, loader, ABI and public entry points stay
in the macOS adapter. Shared verifiers cannot select artifacts or native loaders.

## Lifetime and activation

`validate_active()` returns a `VerifiedRuntime`; the caller must recheck immediately
before execution and retain it until process ownership ends. It pins directory
identity, the complete base inventory and venv binding. Atomic replacement of the
activation record does not invalidate an already selected generation: scope
identity checks permit normal directory-entry changes, and old generations remain
available. Actual replacement of a pinned directory or venv alias/config fails.

The native `--posle-check-python-runtime --root <root>` command validates and reports
the selection; it does not execute a script. Ordinary startup does not run this
fixture or activate processing.

## Evidence and remaining work

Default contracts test record redirection/target/version, linked/oversized records,
config and alias replacement, duplicate/oversized config and directory identity.
Existing macOS synthetic venv/descriptor contracts run against the shared binding
on Linux; macOS native loader behavior still requires platform verification.

The real CPython fixture validates installed generations, rejects pointer/config/
alias redirects, then runs an opt-in `linux-runtime-fixture` contract: keep a selected
guard alive, atomically switch to another genuine installed generation, validate the
new selection and recheck the retained old selection. It restores the original
pointer before proceeding. Data and interpreters are disposable.

This is not third-party package integrity or ASR readiness. The [verified execution adapter](speech-launch-port.md) now preserves common progress,
secret filtering/cancellation and process ownership. Next: install backend-specific
dependencies and connect queued speech processing. Do not reuse macOS PyConfig on Linux.
