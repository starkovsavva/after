# Repository Guidelines

## Project Structure & Module Organization

macOS client and cross-platform preview; internal names retain `Posle`.

- `desktop/src/`: React/TypeScript UI, translations, styles, tests; `desktop/e2e/`: Playwright scenarios.
- `desktop/src-tauri/`: Rust host, typed IPC, Windows capture/media adapters, and `tests/real_engine.rs`.
- `rust-core/src/`: storage, search, tasks, cards, jobs, CLI, platform adapters. Keep domain rules here.
- `process-runtime/`: scoped child processes shared by engine/host; Unix groups and Windows Job Objects stay in adapters.
- `Sources/PosleApp/`, `Sources/PosleCore/`, `Tests/`: SwiftUI/AppKit client, Swift models, and core checks.
- `backend/`: Python speech runtime. `scripts/`: verification/build tooling. `packaging/` and desktop icons contain assets.
- `docs/desktop.md`: desktop setup and limitations; `docs/development.md`: macOS workflow. `docs/specs/` contains plans; verify descriptions against code.

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

Target full Arch support while preserving macOS/Windows; Linux capture/ASR remain pending. Follow SOLID: UI → application → domain; OS details stay in adapters. Workspace: `application/workspace.rs`, contracts in `application/ports.rs`. Queue: `application/jobs.rs`, transaction/clock/ID ports in `application/job_ports.rs`, models/transitions in `domain/jobs.rs`. Live rules: `domain/job_runtime.rs`; Swift `NativeJobRuntime` owns transient state and interprets decisions; never persist/reuse this state. SQL/files/time/identity adapters live in `infrastructure/`. Keep claim/admission/dependencies and chain writes transactional. Import WorkerHost: host `worker_host.rs` port, `process_worker.rs` adapter, engine `desktop_worker.rs`; bounded progress/cancel protocol and exact commit receipts. Native `imports.rs` owns transient UI status. Host `import_queue.rs` defines a native-only durable queue port; engine `desktop_queue.rs` fixes scope to `desktop-import`. Keep grants/receipts out of renderer DTOs. Scoped claims obey global resource limits; scope is not a process lease. Automatic desktop execution/recovery needs an exclusive lifetime lease and receipt reconciliation; it remains pending. Defer destructive actions and Swift removal until approved after parity. Stages: `docs/linux-implementation-plan.md`; coordinator ADR: `docs/decisions/live-job-coordinator.md`.

## Agent Maintenance

Update this file when structure, commands, conventions, or implementation status changes. Recheck after branch switches; preserve platform adapters and domain fixes when rebasing. Replace stale guidance; validate commands against manifests/workflows. Native startup check: `scripts/check-desktop-linux.py` (custom-protocol debug build, temporary data).
