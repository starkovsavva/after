# Repository Guidelines

## Project Structure & Module Organization

After macOS client and cross-platform Tauri preview. Preserve historical bundle IDs, data paths, Keychain identifiers, `POSLE_*` and Rust/FFI names.

- `desktop/src/`: React/TypeScript UI, translations, styles, tests; `desktop/e2e/`: Playwright scenarios.
- `desktop/src-tauri/`: Rust host, typed IPC, Windows capture/media adapters, and `tests/real_engine.rs`.
- `rust-core/src/`: storage, search, tasks, cards, jobs, CLI, platform adapters. Keep domain rules here.
- `process-runtime/`: scoped child processes shared by engine/host; Unix groups and Windows Job Objects stay in adapters.
- `Sources/AfterApp/`: SwiftUI/AppKit; `AfterCore/`: portable models; `AfterPlatform/`: contracts; `AfterLocalization/`: translations; `AfterPlatformMacOS/`: Apple adapters. `Tests/` contains portable and native checks.
- `backend/`: Python speech runtime. `scripts/`: verification/build tooling. `packaging/` and desktop icons contain assets.
- `backend.md` describes canonical storage; `docs/architecture/platform-boundaries.md` and `docs/design-system.md` describe native boundaries and UI. `docs/desktop.md`: desktop setup and limitations; `docs/development.md`: macOS workflow. `docs/specs/` contains plans; verify descriptions against code.

## Build, Test, and Development Commands

Desktop needs Node 24+, Rust stable, and Tauri dependencies; Arch setup: `docs/linux.md`. From root:

```sh
cargo build --manifest-path rust-core/Cargo.toml --locked --target-dir .build/rust
python3 scripts/stage-desktop-engine.py
cd desktop
npm ci --ignore-scripts
npm run tauri dev
```

After core changes, rebuild/stage the engine and rebuild the host to refresh its digest. Never commit binaries.

In `desktop/`: `npm run build` checks TypeScript/builds Vite; `npm test` runs model tests; `npm run test:e2e` runs Playwright (install Chromium). `npm run dev` serves UI; `/?demo=1` enables synthetic data.

Run `cargo test --manifest-path desktop/src-tauri/Cargo.toml --locked` for host tests; substitute `rust-core/Cargo.toml` for core tests. Real-engine/installer checks: `docs/desktop.md`, `.github/workflows/windows-preview.yml`.

`python3 scripts/verify.py desktop` checks process-runtime/core/frontend/host/real IPC without Swift. Run process tests alone with `cargo test --manifest-path process-runtime/Cargo.toml --locked --target-dir .build/rust`. Pure models/validation: `rust-core/src/domain/`; boundaries: `python3 scripts/check_layers.py`; native adapters/resource lookup: host `platform.rs`.

For macOS, `python3 scripts/verify.py quick` builds/tests Swift, Python, and Rust; `native` requires a graphical Mac session; `queue` runs only synthetic Swift/Rust queue checks. `bash scripts/build.sh` requires an Apple signing certificate.

## Coding Style & Naming Conventions

Match nearby code: two-space TypeScript, four-space Swift/Rust/Python; PascalCase types/components, camelCase UI members, snake_case Rust/Python functions. No shared formatter exists. Preserve typed IPC, revisions, filesystem protections.

## Testing Guidelines

Use Node, Playwright `*.spec.ts`, Rust, Python `test_*.py`, and Swift checks. Use disposable libraries and debug `AFTER_DATA_DIR`; no coverage threshold exists. Mac checks need Apple tools and `/private/tmp`; Linux needs WebKitGTK 4.1 (not 6.0). Desktop uses `app.posle.desktop`.

## Commit & Pull Request Guidelines

Commit every completed, verified milestone separately before starting the next one. Include implementation, relevant checks, and current documentation; never bundle unfinished later stages. Do not push unless requested. Use imperative subjects. PRs describe behavior, issues, checks, platform limitations; include UI screenshots.

## Architecture & Portability

Target full Arch support while preserving macOS/Windows; Linux capture/ASR remain pending. Follow SOLID: UI → application → domain; OS details stay in adapters. Workspace: `application/workspace.rs`, contracts in `application/ports.rs`. Queue: `application/jobs.rs`, transaction/clock/ID ports in `application/job_ports.rs`, models/transitions in `domain/jobs.rs`. Live rules: `domain/job_runtime.rs`; Swift `NativeJobRuntime` owns transient state and interprets decisions; never persist/reuse this state. SQL/files/time/identity adapters live in `infrastructure/`. Keep claim/admission/dependencies and chain writes transactional. Knowledge SQL/rebuild lives in `infrastructure/workspace_repository/`; optional vectors/source cleanup use composition boundaries, preserving private data when adapters are unavailable. Import WorkerHost: host `worker_host.rs` port, `process_worker.rs` adapter, engine `desktop_worker.rs`; bounded progress/cancel protocol and exact commit receipts. Native `imports.rs` owns transient UI status. Host `import_queue.rs` defines a native-only durable queue port; `LibraryBridge.open_import_queue()` returns its leased `queue_connection.rs` adapter. Engine `desktop_queue_service.rs` holds an infrastructure kernel lease and fixes scope to `desktop-import`. Never delete `.desktop-import-executor.lock` or expose queue through metadata IPC. Keep grants/receipts out of renderer DTOs. Scoped claims obey global resource limits; scope is not a process lease. Explicit native `Run` now owns import threads until cancel/join; policies and contracts live in `application/import_execution.rs` and `import_ports.rs`. Preserve logical receipt IDs on retry and fence ledger writes by attempt. Native queue open reconciles all receipt pages before returning; policies live in `application/import_recovery.rs`. Recovery only probes receipts, never copies/retries; preserve unknown outcomes and compare observed records before writes. File-picker UI uses `queued_import.rs` through `ImportQueueSession`; shared request budgets observe cancellation during RPC and stop/reap before receipt fallback. Progress is fractional. Recordings still use standalone WorkerHost. `import_history.rs` maps private DTOs to grant-free renderer history (latest 50, explicit truncation). Startup/history reads reconcile without resuming; explicit resume/cancel use expectedAttempt. `Imports.reserve()` serializes maintenance/startup, and fresh controlId fences live cancellation across retries. UI coalesces only in-flight history reads. See `docs/decisions/import-history-and-resume.md`; full history pagination remains pending. Defer destructive actions and Swift removal until approved after parity. Main 0.18.2 integration: `docs/decisions/main-0182-integration.md`. Stages: `docs/linux-implementation-plan.md`; coordinator ADR: `docs/decisions/live-job-coordinator.md`.

## Data & Trust Boundaries

Use disposable libraries, synthetic providers and explicit feature grants. Source read access does not authorize cloud upload. Preserve C ABI/JSON, CAS, atomic receipts, unknown compatible fields and current-source checks. Keep credentials out of logs, fixtures, queue and process arguments. Never weaken runtime/model/library integrity checks to pass tests. Python does not own canonical SQLite. Swift platform contracts must not depend on AppStore; check `scripts/check_platform_boundaries.py` (Swift package graph requires Swift 6).

## Agent Maintenance

Update this file when structure, commands, conventions, or implementation status changes. Recheck after branch switches; preserve platform adapters and domain fixes when rebasing. Replace stale guidance; validate commands against manifests/workflows. Native startup check: `scripts/check-desktop-linux.py` (custom-protocol debug build, temporary data).
