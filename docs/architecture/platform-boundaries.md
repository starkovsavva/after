# Platform boundaries

The macOS application remains the product implemented by this repository. These
boundaries separate reusable values and workflow policy from native mechanisms;
they do not implement a Windows or Linux application. The application version
remains 0.18.0 during this refactor.

## Swift targets

| Target | Responsibility | Allowed dependencies |
| --- | --- | --- |
| `AfterCore` | Value models, feature policy, calendar layout, task dates and source identity | Foundation |
| `AfterPlatform` | Package-scoped service contracts, worker/account/calendar values and runtime admission | Foundation, `AfterCore` |
| `AfterLocalization` | `L`, `LF`, locale observation and the bundled translation catalog | Foundation, Observation |
| `AfterPlatformMacOS` | Native capture, playback, permission, process, credential, authentication and calendar implementations | `AfterCore`, `AfterPlatform`, `AfterLocalization`, required macOS SDKs |
| `AfterApp` | SwiftUI/AppKit presentation, application state, workflows and adapter composition | The targets above and Sparkle on macOS |

Dependencies point toward the value/contract layer. No shared target may import
`AfterApp` or refer to `AppStore`. API used only within this package uses `package`
access. Native diagnostics use `@testable` for adapter internals instead of making
implementation details public.

`Package.swift` selects the application, macOS adapter and Sparkle dependency only
on a macOS host. Other hosts have the three portable targets and their unit-test
targets; resolving that graph does not require a macOS binary framework.

## Native mechanisms and workflow ownership

- `Media/` owns ScreenCaptureKit capture selection, microphone routing, clock/PCM
  normalization, video conversion, recording writers, short dictation and AVPlayer
  resources. `MeetingRecordingBackend` and `AudioPlaybackSession` carry values and
  callbacks across the boundary. Apple media objects do not appear in the contracts.
- `Calendar/` owns EventKit stores, authorization mapping, native notifications and
  native event mutation. Asynchronous agenda reads return immutable snapshots.
  Explicit writes use `CalendarWriteClient` on the main actor and revalidate access,
  writability, recurrence and the expected event state immediately before saving.
- `Runtime/` owns subprocess pipes and cancellation, sanitized child environments,
  managed model identities and the local model process lifecycle. A runner admits
  one execution at a time. Task cancellation and delayed termination belong to
  that execution, never to a later child. JSONL frames are limited to 16 MiB;
  cumulative progress output is streamed rather than capped at that total.
  Managed model startup checks cancellation, its generation and the same live
  process after each health probe. Failed current startup cleans up its child;
  superseded work cannot terminate a newer reuse of that process. These lifecycle
  checks do not attest which process owns a TCP listener.
- `Security/` owns Keychain operations. The existing service/account identifiers
  remain stable; inaccessible storage must not be reported as an empty account.
- `Authentication/` owns the account actor, PKCE/token checks, native cryptographic
  operations, token persistence and loopback listener. The app supplies rendered
  callback-page data and browser opening; the service does not import UI artwork
  or application state.
- `System/` owns IOKit idle-sleep leases and Carbon global shortcut registrations.
  A failed shortcut registration remains an explicit failure.
- `NativeRust/` owns the Swift FFI bridge, native library verification and embedded
  speech service. The bridge continues to exchange JSON rather than native model
  layouts.

`AppStore`, `RecordingCoordinator`, `BackgroundJobs`, `QuickCapture`,
`CalendarStore`, `VoiceCommands` and `ChatGPTAccount` retain their workflows. They
may use UI frameworks but must not import capture, EventKit, IOKit, Carbon,
Security, Darwin or Network directly. `PlatformComposition.swift` selects the
macOS media factories; injection points allow synthetic implementations in checks.
Other native choices, such as calendar writers and browser presentation, remain
explicit at application construction points.

Recording ownership, finalization and job admission remain application policy.
`SourcePlaybackState` keeps evidence freshness checks before loading, after loading
and after seeking; `ClipPlaybackSession` owns only media mechanics. `CalendarStore`
keeps task-link merge rules, durable creation intents, conflict handling and
knowledge-source selection. Native calendar updates preserve notes, attendees,
alerts and URLs that the application does not own.

## Rust runtime boundary

`rust-core/src/platform/mod.rs` selects implementations under `platform/macos/`:

- `python_runtime.rs`: pinned distribution inventory, held descriptors and loaded
  image/version verification;
- `embedded_speech.rs`: the persistent in-process CPython host and existing C ABI;
- `managed_embedding_transport.rs`: bounded Unix-socket requests to the verified
  live child, including peer identity, cancellation and timeout checks;
- `filesystem.rs`: APFS clone optimization; failure selects the existing verified
  streamed-copy path and is never reported as a successful installation;
- `python_host.rs`: a separate binary-only entry point included by `main.rs`, before
  worker threads start. It is not another in-process host in the library.

The established crate paths `python_runtime` and `embedded_speech` are re-exported
for compatibility. The `posle_request`, `posle_free_string`, `posle_speech_run` and
`posle_speech_set_cancelled` C exports retain their contracts.

Rust domain and persistence modules still use Unix permissions, descriptors,
locking and process semantics. Moving the Darwin runtime leaves does **not** make
that crate Windows-ready. No success stubs stand in for missing native adapters.
A future platform needs its own implementation and threat-model validation, plus
explicit work on the remaining Unix assumptions.

The Rust repository owns the library's SQLite persistence. Embedded Python must
use that boundary rather than opening `core.sqlite` with a second SQLite runtime
inside the same process. Integration-test SQL inspection runs in a separate
short-lived process; it does not share the process that loads the Rust C ABI.

## Trust properties that must survive another adapter

The signed executable's `__TEXT` digest remains the native library trust root;
a bundle resource or `Bundle.module` cannot replace it. Native loading keeps the
verified inode open. Python's expected inventory is compiled into the runtime,
not taken from a replaceable local manifest. Transport never sends a request to a
replacement child/socket after verification.

The Swift Rust bridge preserves lexical child paths for Rust validation rather
than resolving a symlink before the boundary. Calendar connection stays explicit,
previews do not create EventKit stores, and a failed event save retains its durable
recovery marker. Native test injection does not bypass these rules in release code.

## Checks

Run the architecture guard and its parser regressions from the repository root:

```sh
python3 scripts/check_platform_boundaries.py
python3 -m unittest discover -s scripts -p test_platform_boundaries.py -v
python3 scripts/check_process_runner.py
python3 scripts/check_local_service.py
```

The guard scans all source branches, including inactive `#if`, scoped imports and
`@testable import`. Comments and string literals are not dependencies. It validates
the host's actual target graph using `swift package dump-package`, which evaluates
the local manifest without resolving or fetching dependencies. Cycles and forbidden
portable dependencies fail the check. `--package-json` accepts an existing dump;
`--disable-sandbox` is available when SwiftPM runs inside another restricted sandbox.
This lexical guard complements compiler checks; it is not a Swift parser or a full
runtime security audit.

The runner fixture compiles the actual adapter and contracts with the installed
SDK, then launches disposable native children. It checks admission, task and
callback cancellation, forced termination of a child that ignores SIGTERM,
stale cancellation versus a later run, bounded frames, pipe teardown and retry.
It does not use model weights, user libraries, accounts or audio devices.
The local service fixture uses signed disposable native children and synthetic
HTTP probes to check reuse, startup cancellation, exited children, superseding
ownership and external-provider isolation. It does not contact a real model
server or establish TCP listener identity.

App diagnostics may import native SDKs to construct media samples or native fakes.
They are outside the portable target allowlists. Existing native checks cover
capture writers/clocks/routes, recording lifecycle and stale-source playback.
Calendar checks also exercise lazy adapter activation, stale editor refusal,
expected-version writes, durable marker retry and permission-revocation teardown.
Rust runtime and transport tests move with their implementations.

The Ubuntu CI job checks the installed Swift 6 toolchain, builds `AfterCore` and
`AfterPlatform`, and runs the portable Swift tests (including localization resources).
The macOS job checks the native graph and the application build. Local validation
of this refactor was performed on macOS; adding the Ubuntu job is not evidence of
an executed Linux pass, and neither job establishes a Linux or Windows UI/runtime.
