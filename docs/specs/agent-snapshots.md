# Agent access to approved snapshots

Implemented scope: a task and 1–50 explicitly selected notes, reviewed in full
and approved by the user for one connected MCP process. The agent can search
and read that copy, then submit attributed reports with artifacts and citations
to exact source versions. This is a separate permission from legacy task MCP.
It is not live search across the library, a permission to edit originals, or a
sandbox for clients that also have independent shell/file access.

## User workflow

1. From a task menu choose **Share a snapshot with an agent…**. The sheet shows
   the local MCP configuration; the client starts `After Engine mcp-share
   --root <library>` and calls `after_share_status`.
2. Enable **Allow snapshot sharing**, compare the connection code shown by the
   client with After, and select notes. Client names are self-reported labels,
   not identity proof. Codes are routing hints, not credentials.
3. **Preview snapshot** captures a draft and displays every included source in
   full. The task text is also included. No original attachment is implicitly
   fetched. **Share this snapshot** approves the exact stored draft digest.
   Editing or deleting an original while the preview is open does not silently
   change the copy being approved. A draft expires after 10 minutes.
4. The client can enumerate, search and read only this copy for up to 24 hours.
   To request a refreshed or different copy in the same connection, the client
   calls `after_share_request_snapshot`. This revokes the previous share and
   returns a new code without granting access. The user inspects and approves
   a new preview. A restarted MCP process also requires explicit approval. There is no
   automatic approval or silent refresh/expansion of scope.
5. Reports appear in the task's history, including saved artifacts and evidence
   buttons opening the exact saved source version. Reports identify agent
   claims; they do not mutate the original task's status or legacy history.
6. Revoke an individual share in the sheet/history, or disable snapshot sharing
   in settings to revoke all shares. Re-enabling does not restore revoked
   shares. Copies and reports remain as local history; revocation cannot erase
   material the client already received.

## Ownership and persistence

`rust-core/src/scoped_share.rs` owns the new authority and records in
`<library>/agent-shares/shares.sqlite`; `scoped_share/stdio.rs` owns the MCP
connection and actual stdout publication. Native UI uses separate
`agent-share-*` commands. They are not listed or callable as MCP tools.

The authority stores its own master switch, revision, approved immutable
packages, revocations, per-connection grants, read receipts and idempotent
reports. `settings.json`, legacy task grants and original sources are consulted
only to build the draft, never to authorize or publish the approved copy.
Source origin/revision/fingerprint are immutable provenance; model-visible IDs
are opaque. Capability secrets are generated in the server process and never
appear in tool arguments, UI, task metadata or command-line configuration.

The directory is private to the current user. Symlinks and unexpected hardlinks
are rejected. This protects against accidental path aliasing, not arbitrary
same-user code. The released legacy app's normal data writes do not know the
new authority or grant. No personal-library migration is required or performed.

## Protocol and revocation

The newline-delimited JSON-RPC stdio endpoint implements MCP initialization,
tool discovery and `after_share_status`, `after_share_request_snapshot`,
`after_share_sources`, `after_share_search`, `after_share_read`,
`after_share_report`. Sources enumerates metadata for all at most 51 approved
sources, without full text or any need to guess search terms. A connection cannot select its own
session, root, grant or approved sources through a tool argument. Arguments are
bounded and strictly typed. Citation receipts require reading the cited source
from the same approved share before reporting; titles come from the saved
package, not from the agent. Every report supplies the `snapshotID` returned by
status/enumeration/search/read. It must match the transport's currently approved
share before either idempotent replay or a new write. This is a fence against
stale work after renewal, not a way to select another authority or grant.

Protected responses hold a shared cross-process publication lock from
authorization through the final nonblocking stdout write. Revocation and
master disable take the exclusive lock and commit before returning. A stalled
peer gets a 250 ms total write deadline, after which the connection closes.
After revocation returns, the server starts no more protected writes for the
grant. Bytes written beforehand, including OS-buffered bytes read later, cannot
be retracted. Neither client read time nor file modification checks are used as
a substitute for this ordering contract.

Limits: 50 selected notes plus the task, 64 KiB per source, 1 MiB per snapshot,
50 unexpired previews, 100 live connections, 1,000 saved shares and 100 reports
per share. Reports are paginated; full snapshots load only when requested.
Artifacts are text or validated HTTP(S) links; no filesystem path execution.
The current implementation deliberately requires explicit approval again to
share a refreshed copy; reconnecting the client is unnecessary. It does not
offer automatic full-library sharing.

## Acceptance

- Rust `scoped_share` tests cover isolation from original changes, separate
  connection capabilities, exact digest approval, expiry, strict optional
  argument types, idempotency, read receipts, global disable, symlink rejection,
  approved idle connections and revocation's publication lock.
- `scripts/check_snapshot_agent.py` runs the real newline MCP process, edits
  selected and unselected sources/settings with the installed legacy core,
  checks two connections, citations/artifacts and denial after revocation.
- `After --preview --check-agent-snapshot` with an isolated test root exercises
  native preview → explicit approval → real MCP search/read/report → actual
  task history → saved evidence/artifact → native revoke.

These checks use disposable libraries. A release/install, successful hardware
recording, and a supported third-party client's interactive setup are distinct
acceptance activities and must not be implied by passing these tests.
