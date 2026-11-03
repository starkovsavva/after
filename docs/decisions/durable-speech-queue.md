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
comes from native composition, never a worker acknowledgement.

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
to `queue_budget.rs`, independently of import DTOs. Tauri speech bindings,
readiness/setup UI and speech controls remain pending; this native service does not advertise a UI capability.
Local speech requires explicit local settings and diarization=false. Cloud ASR,
diarization and Windows runtime remain separate work. Abrupt/forced stops may retain
unknown private speech stages; broad deletion or automatic inference recovery is
not authorized by this protocol.
