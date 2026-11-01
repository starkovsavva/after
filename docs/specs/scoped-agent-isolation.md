# Scoped MCP: isolation and migration requirements

Status: the live-library design below remains deferred. The working product
uses [explicitly approved immutable snapshots](agent-snapshots.md), with a real
MCP endpoint, native approval, separate revocation and report history. It does
not depend on moving a personal library or on legacy writers observing new
locks. Source edits and old settings cannot alter the already approved copy.

For the deferred live-library design, the private transport is **not connected** to MCP or UI. The
existing grant database alone is not an isolation boundary: authorization still
reads legacy `settings.json`, workspace and task state from the same root.
A legacy process can replace settings after validation and before publication.

## Security contract

The user chooses a specific task and inspected, versioned sources. The broker
binds a grant to the approved client connection. A model supplies search terms,
not source roots, paths, grants, capabilities or authority. Results and reports
must not enter legacy task claims/materials. All publication and revocation use
the same cross-process gate. A write holds the publication gate through completion or failure; after
revocation returns, the server starts no new writes derived from that grant.
Bytes already written, including bytes still buffered by the OS and read by
the client later, cannot be retracted. A partial frame is failure and the
connection is closed, but bytes already written may still be observed. An unresponsive peer
must not hold the publication or workspace gate indefinitely.

The authority for global privacy and scoped grants must be under the same
serialization boundary as response publication. Every action advertised as
"disable access" must act on that authority; retaining a second UI or legacy
settings file that appears to revoke access but does not is unacceptable.
Checking inode/mtime twice, watching for file notifications, checking process
IDs or taking locks ignored by the old binary is not a security barrier.

## Candidate architecture, still requiring implementation and proof

Use a new, independently identified active library root containing the
canonical data *and* its authority; no sensitive read in the new workflow may
fall back to the old root. Restrict it to the current user, reject symlinks and
unexpected hardlinks, and ensure every new settings/source writer observes the
same publication protocol. Moving only the grants DB does not solve the race.
Isolation means the released legacy application does not normally select the
new root; it does **not** protect against arbitrary same-user processes or a
legacy binary deliberately started with the new root as an override. Such
processes are outside this proposed compatibility boundary unless separately
contained by an actual OS-enforced mechanism. The scoped grant limits the new
MCP interface; it does not confine a client that separately has shell or file
system access as the same user. Protecting against that client requires a
separately designed and verified OS sandbox or account boundary.

The application must clearly indicate which library is active. A legacy app
that still points to the old library can change it, and disabling settings in
that separate copy cannot revoke the new library's grants. This distinction is
a product and migration requirement, not something file locking can conceal.
Neither automatic merging nor blocking the old binary should be promised
without a proven design. Existing old MCP access must be evaluated separately:
the new broker must not make new scoped documents, credentials, claims, or
results visible through old task records.

Current evidence: `AppStore` resolves its data directory from
`POSLE_DATA_DIR` when set, and the engine/MCP accepts an explicit `--root`.
The released core build 34 was exercised against a disposable alternate root:
it could edit notes and settings even when that root contained an unfamiliar
identity marker (`scripts/check_kb_legacy_compat.py`). A UUID, different path,
directory permissions for the same user, or a successful one-time preflight
therefore must not be treated as proof that old writers cannot touch a root.

An inventory or content comparison has a narrower role: it can report an
observed difference and abort a migration. Even identical hashes observed at
one moment do not prove a consistent snapshot across SQLite/WAL and meeting
files, nor that a writer will not change a file immediately afterwards. Until
there is a proven quiescence/consistent-snapshot and switch protocol, an
inspection result is diagnostic only and must not enable the broker. Use an
explicit `unknown`/incomplete outcome for a skipped, unreadable, changed or
unsupported source; do not silently interpret omitted sources as equal.

## Migration requirements

1. Inventory all actual source files, SQLite databases including WAL state,
   user configuration, media, paths and references. A recursive live copy is
   insufficient: a file snapshot across independent databases and files is not
   automatically consistent. Define a maintenance/quiescence protocol and
   rollback for every writer, including workers and old app instances; verify
   it with the released binary. If a consistent cut cannot be established,
   stop and leave the old library untouched.
2. Back up to a separate location and verify the backup can be opened. Stage a
   new root with unique library ID; copy using a mechanism appropriate to each
   database and file, verify completeness, integrity, permissions, references,
   quotas, and successful read-only open. Do not store secrets in a manifest.
3. Establish a durable commit point for the active-library switch. A crash at
   every intermediate step must reopen either the intact old library or the
   complete new one, never a mix. No automatic rollback may overwrite edits
   made since switching. Preserve the old root for explicit recovery.
4. Show the user the old/new distinction and handle divergence explicitly.
   Changes in the old library after the cut are not silently merged or lost.
   A separately designed reconciliation must detect conflicts, deletions,
   identical IDs with different contents and missing media; it needs explicit
   tests before offering merge. Deny the new MCP feature if the active root or
   the isolation contract is ambiguous.
5. Bring each legacy-compatible path under the threat model. Confirm that old
   application and helper launch mechanisms do not automatically select the new
   path, including overrides, restore, aliases, app updates and reopened tasks.
   Do not trust an unvalidated marker file to prove isolation.

## Required acceptance tests

- Real released legacy binary races old settings rename against publication;
  neither old source changes nor old settings become authoritative in the new
  root. Separately verify that every visible revoke action in the active
  library fences publication. Unknown settings or root identity fail closed.
- Real cross-process new-client tests for grant revoke, global disable, task
  policy change, source edit/delete/recreate, folder move, peer disconnect and
  stalled writes at every publication point. Assert server-side ordering: each write either completes or fails before
  revocation returns, and no new protected write starts afterward. Account for
  pre-revocation bytes still buffered in the OS; client read time is not proof
  of server write time. Include multiple clients,
  expired grants, replay and process crash.
- Kill migration at every durable step; verify database/WAL, notes, media,
  settings and task history. Exercise low space, permission errors, symlink
  substitution, duplicate IDs and concurrent old writers. Compare semantic
  contents, not just file names. Preserve both roots and surface divergence.
- Integrate and exercise a real supported MCP client only after these gates.
  The capability never enters the tool schema, prompts, logs, task artifacts,
  environment visible to the model, or command-line arguments.
