# Integrating main 0.18.2 with the portable architecture

The integration includes all eight main commits through `9a082ba` (0.18.2), while
retaining our domain/application extraction, Windows filesystem protections,
shared process supervisor, live reducer and leased import queue. A merge preserves
both histories. The other code branches had no new fetched tips; their preview
work is already present through the earlier integration. `updates` is a release
feed branch, not an application-code branch; it is not merged or published here.

## Combined responsibilities

- Swift retains the upstream `AfterApp`, `AfterCore`, `AfterPlatform`,
  `AfterLocalization` and `AfterPlatformMacOS` split. Historical bundle/data,
  Keychain, `POSLE_*` and Rust ABI identities stay stable. `NativeJobRuntime` moves
  with the app and imports the new package contracts. Queue diagnostics use the
  renamed `After` executable; both native startup diagnostic branches survive.
- The incoming knowledge/rebuild SQL modules live beside the canonical store in
  `infrastructure/workspace_repository/`. The compatibility facade keeps the
  established entry points. Additive v1 schema extension, migration backups,
  interrupted-migration guards, atomic source pruning, replay receipts and undo
  remain inside the existing transaction/lock boundary.
- Private files and SQLite backups use `platform_fs`, including guarded Windows
  connections. Read-only opens cannot create a database or admit writes. The
  shared feature model and profile allow-list include `knowledgeBase`.
- Queued speech authorization uses the validated captured settings before disk
  defaults. Its bounded generic parser stays in portable `ai_config`; Linux tests
  construct oversized snapshots inside the isolated process instead of exceeding
  the kernel's exec environment limit.
- `knowledge_vectors` and `source_cleanup` compose optional native mechanisms.
  Common knowledge/note operations contain no new OS branches. The Windows
  semantic adapter returns unavailable errors, never fabricated vectors. Existing
  lexical fallback remains available. Missing private agent storage needs no
  cleanup; an existing unsupported store is preserved and reported pending.

## Evidence and remaining limits

At the main integration milestone, the Arch profile passed 603 core tests plus two CLI tests, 29 host tests,
five real-engine scenarios, real Tauri IPC and process-runtime contracts. The
upstream synthetic topic performance probe remains intentionally ignored.
Portable knowledge regressions cover migration/backup, legacy edits, source
deletion, redacted replay, identifier reuse and admission against live jobs.

Real MCP tests exercise preview/approval/search/read/report/history/revocation,
independent sessions and pipe backpressure. Knowledge rebuild E2E uses only a
loopback provider: CLI generation, strict source-only preview, CAS apply, replay,
targeted undo and delayed-response rejection after source/profile/review/revocation
changes. These are protocol/behavior checks, not model-quality claims.

Swift source boundaries and verification tooling are checked locally. Swift and
Windows target toolchains are absent on this Arch machine; native Mac/Windows and
the real Swift package graph remain CI checks, not locally verified results.
The Tauri UI still lacks several new Swift product workflows; Linux capture,
speech/model runtime, Tauri queue UI binding and automatic startup reconciliation remain pending.
Swift is retained. No release, push or personal-data migration is performed.
