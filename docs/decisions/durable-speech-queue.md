# Durable native local speech queue

## Ownership and layers

`desktop_speech_queue.rs` composes the existing SQLite scheduler with kind
`desktop-speech`. Import and speech claims share global resource limits; speech
never claims, recovers or exposes another kind. Enqueue and explicit Run are
separate. Startup reads/reconciles every recovery page and never resumes inference.

`application/attempt_execution.rs` owns shared stop/outcome/store contracts.
`application/job_recovery.rs` owns receipt reconciliation for both scopes;
`infrastructure/attempt_store.rs` supplies their scoped SQLite adapter and compares
all observed row fields inside recovery transactions. Existing import APIs retain
compatibility exports instead of speech depending on import contracts.
`application/speech_jobs.rs` binds saved work to kind, object, revision and resource,
throttles durable progress, and resolves every completion through an exact receipt.
Committed output wins cancellation, shutdown and a lost process acknowledgement.
Unknown publication remains interrupted and cannot be retried without a successful
probe. Every mutation uses expectedAttempt; every live attempt gets fresh stop state.

The owner holds `.desktop-speech-executor.lock`, cancels/joins workers on EOF/drop,
and retains its lease through thread cleanup. Typed import/speech lease wrappers
share infrastructure without allowing one scope's token to construct the other.
Never delete either stable lock. Cooperative Drop explicitly unlocks after joins,
including transient duplicates created by unrelated concurrent forks.

## Native process boundary

`--posle-speech-queue --root /owned/root --backend /trusted/backend` uses the bounded
version-1 native queue frame format, shared with import. The request contains
`version`, UUID `id` and `request`. Closed actions: enqueue (SpeechWork input), get,
history (creation cursor), run, cancel/retry (jobId + expectedAttempt), reconcile.
It is not registered on the renderer metadata bridge. Read models contain job ID,
meeting ID, state, progress, attempt, cancellation flag and creation time; no frozen
settings, logical operation grants, receipts or private tokens are returned.

`infrastructure/speech_process.rs` executes the verified native publisher in an
owned ProcessTree and sends bounded work on stdin. It validates framed progress
and exact completion identity, drains bounded diagnostics without persisting raw
errors, and joins transport threads after stopping the process scope. Authorization
comes from native composition, never a worker acknowledgement. The shared native
exchange is generic over a closed completion schema; publication validates its
exact receipt through a caller-owned validator. A future probe completion must
not deserialize as a publication receipt or replace durable publication recovery.

A dedicated inherited lease descriptor pins ownership if the queue process dies.
It is reserved before spawn and made inheritable only in the forked child, without
changing parent descriptor flags or colliding with stdio/spawn pipes. The publisher
checks descriptor identity, lock ownership and that it leads its isolated group.

Queued Python/FFmpeg share that outer group through the explicit Unix
`ProcessTree::spawn_contained` contract; its inner handle signals/reaps only Python.
The binary's validated `NativePublisherScope` flushes its final reply, then ends its
entire isolated group on return/unwind. This intentional group termination can yield
SIGKILL even after success. The process adapter drains the reply; the application
then checks the durable receipt. Do not treat exit status as publication authority,
remove this cleanup, or apply it to an unowned caller/terminal group. Standalone CLI
and Swift paths retain their ordinary owned SDK scopes.

## Checks and remaining work

Contracts cover scope exclusion, inherited ownership after abrupt parent exit,
join-before-release, stale cancellation fences, committed-after-cancel, global
resource admission, grant-free history and recovery beyond 50/64-row boundaries.
The opt-in real ASR fixture now runs Parakeet through the persistent queue, reopens
it after completion, and checks cancellation of native/SDK/descendant processes.

Packaged backend source is staged and build-pinned by the Tauri host. Shared host
framing/process ownership lives in `native_queue_connection.rs`; deadlines belong
to `queue_budget.rs`, independently of import DTOs. `speech_queue.rs` defines the
native-only host port; `speech_queue_connection.rs` owns a verified backend source
grant through process exit and rechecks it before every RPC. Integrity failure
stops/reaps the owner before returning. `LibraryBridge.open_speech_queue()` selects
the Linux/macOS command through the platform adapter; Windows returns unsupported
before spawning. Shared grant-free state/cursors live in `queue_models.rs`, with
import compatibility exports. The native ready frame follows complete receipt
reconciliation and says nothing about runtime/model readiness. Integration checks
cover independent import/speech leases, stale attempt cancellation, queued restart
without inference, private-history exclusion and resource tampering.

Native `Prepare { meetingId }` returns private work through the queue port. The
application use case consumes settings/revision/identity ports. The domain keeps
only explicit local selection (`speechMode`, `diarization`, model path/format/name),
so other app settings and credentials never enter the generated job configuration.
The filesystem adapter reads bounded settings and checks absolute model paths;
the canonical publication adapter supplies the source/result revision. Preparation
never enqueues, infers, installs dependencies or claims runtime/model readiness.
Global selection may change after preparation; the prepared input remains frozen.
Enqueue still rejects a changed canonical revision. Renderer commands must never
accept this private input or supply frozen settings/operation grants themselves.

The explicit CLI `check-speech` now runs offline synthetic local inference and
private FFmpeg through the same guarded worker. `speech_check.py` closes models
and removes temporary PCM on normal/error paths; it never reads meetings or
publishes transcripts. Rust projects local settings, strips credentials and
requires exactly one closed, bounded completion before reporting success. This
probe is not run at queue startup. Native preflight now uses independent
`desktop-speech-check` rows under the same speech executor lease. Closed commands
are `enqueue_check`, `run_check`, `get_check`, and `cancel_check` (expectedAttempt).
Enqueue captures only local settings and never starts inference; explicit Run
claims the global local-heavy resource. Checks do not appear in speech history.

`application/speech_check.rs` owns validated work/attempt policy;
`desktop_speech_checks.rs` composes SQLite, threads and recovery. The shared
`speech_progress.rs` port keeps check policy independent of transcription policy.
The inherited publisher scope runs `check-local` with verified runtime/model
guards and a ten-minute native deadline; exact completion binds operation ID,
attempt token and frozen settings revision. Cancellation/EOF stops and joins the
native/SDK/descendant scope before lease release. Startup marks unfinished checks
interrupted, without repeating inference. Succeeded rows are historical evidence,
not a persistent readiness capability; execution still revalidates its resources.
Grant-free check summaries expose no settings, paths or private acknowledgements.
Renderer check controls are available in Settings on Linux/macOS when bundled
source verification succeeds. This capability is source/platform support, not
runtime readiness. The local-main ACL permits only status/start/cancel commands;
renderer input contains no backend path, profile, model path or private work.
`host speech_checks.rs` owns current-check policy and consumes the lazy shared
`speech_session.rs`; multiple future speech consumers can share one native owner.
Empty passive status does not create a queue. Queued checks run again only on an
explicit click, and transport failures never replay mutations. Native cancel uses
the observed ID/attempt. UI epochs reject delayed status after newer actions;
closing settings leaves ownership in the host and reopening reads its state.
Runtime/model setup and renderer transcription controls remain separate work.

Renderer speech commands, readiness/setup UI and speech controls remain pending; this native service does not advertise a UI capability.
Local speech requires explicit local settings and diarization=false. Cloud ASR,
diarization and Windows runtime remain separate work. Abrupt/forced stops may retain
unknown private speech stages; broad deletion or automatic inference recovery is
not authorized by this protocol.
