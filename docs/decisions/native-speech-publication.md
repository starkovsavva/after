# Native staged speech publication

## Boundary

A Tauri speech executor must distinguish an interrupted worker from a committed
result whose reply was lost. The existing Python CLI publishes directly; the
new native path instead gives inference an owned copy of the inputs. It never
passes the canonical meeting directory to inference.

`application/speech_execution.rs` defines the closed version-1 local request,
publication and inference ports, and reconciliation order. `domain/speech.rs`
validates transcript structure/timing without OS dependencies.
`infrastructure/speech_publication.rs` owns files, locks, SHA-256 snapshots,
staging and atomic publication. `speech_job.rs` composes it with the existing
verified runtime/model launch and process-tree supervisor. Legacy CLI/Swift
execution remains compatible; those paths do not automatically use this protocol.

## Native protocol

`--posle-speech-job --root /owned/root --backend /backend` accepts bounded JSON
on stdin. `{"inspect":"<meeting UUID>"}` returns `speechJob.inputRevision`.
Execution requires `version: 1`, `operationId`, `attemptToken`, `meetingId`,
`inputRevision` and frozen `settings`. IDs are canonical UUIDs; settings require
explicit `speechMode: "local"` and `diarization: false`. Success emits a final
`done` event with `speechJob.receipt`. No arbitrary command is accepted.

The revision covers source/available separate tracks, track selection and exact
previous transcript/summary bytes. Staging verifies every copied input against
its captured digest. Inference writes only the private stage. Publication checks
original directory identity and the current revision under the meeting lock;
source/result edits reject publication, while unrelated title edits survive.
Output is bounded and validated before canonical writes.

The transcript contains private `_posleSpeechReceipt`, atomically with the result.
The receipt binds operation/attempt/meeting, input revision and frozen settings
digest; reusing IDs with another configuration cannot claim the prior result.
An exact receipt proves completion before another inference attempt, including
when runtime/model components subsequently become unavailable. Renderer meeting
DTOs expose only transcript segments, never this receipt or private attempt token.
This is native evidence of publication, not renderer authorization.

## Recovery

Before retiring a previous summary, persist `.speech-publication.json`. Under
the same lock, receipt recovery either confirms the published transcript and
cleans its retired summary, or restores that summary when the prior transcript
still matches. Unknown outcomes preserve journal and backup and block new work.
No inference or automatic retry occurs during recovery. Cleanup failure after
an exact committed receipt cannot turn success into an invitation to rerun.

Completed/failed stages clean their own owned directory. Abrupt process death
can leave a private `.speech-work-*` directory; no broad startup deletion of
unknown stages is implemented. Staging temporarily duplicates input media and
hashes/copies under the meeting lock, but never holds that lock during inference.

## Evidence and remaining work

Rust tests cover isolated inference, idempotent receipts, source/result conflicts,
meeting replacement, title preservation, invalid output/aliases/stage identity,
rollback/commit recovery and unresolved outcomes. The opt-in real Parakeet fixture
uses this native path and retries an already committed request while model bytes
are damaged, proving reconciliation avoids another model execution.

This prepares the worker/publication boundary. Durable speech queue ownership,
progress/cancel protocol, recovery at Tauri startup, UI and speech readiness are
still required. Cloud ASR, diarization and Windows runtime are separate adapters;
this slice does not advertise those capabilities.
