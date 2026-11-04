# Explicit managed speech selection

Deployment and selection are separate actions. Installing a runtime/model never
changes `settings.json`; selection never installs, downloads or infers. A selected
model is not a readiness grant. Explicit preflight and every speech launch retain
their existing runtime/model verification.

`application/speech_selection.rs` owns selection through a port. The caller supplies
a canonical v4 generation ID and an observed opaque settings revision. The adapter
retains the same pinned, canonical settings root across the workflow, resolves the
path under its compiled managed Parakeet scope, and verifies the exact inventory. The application merges only `speechMode`, `speechLocalModel`,
`asrModelPath`, `asrModelFormat`, and `diarization`. Unknown fields, integrations,
credentials and unrelated preferences survive unchanged. The resulting profile is
explicit local Parakeet ONNX without diarization.

`infrastructure/settings_store.rs` reads at most 256 KiB through protected ordinary
files and distinguishes missing settings from an existing empty object. Revisions
bind the persisted bytes, independently of job environment overrides. Selection
checks the revision before expensive verification and again under `.settings.lock`
before commit. The model guard is rechecked under that lock, followed by another
revision check and atomic replacement. Never unlink the lock. Current FFI settings
writes participate in the same cooperating-writer protocol and retain their existing
secret-input rejection. Direct legacy writers can bypass this lock; the extra
revision check detects changes observed during verification, not arbitrary writes
after the final check. Desktop keeps its separate data root rather than sharing a
live library with an older client.

Native Unix CLI:

```sh
posle-engine --posle-local-speech-selection --root /absolute/test-library
posle-engine --posle-local-speech-selection --root /absolute/test-library \
  --select-generation <installed-generation-uuid> --expected-revision <observed-revision>
```

The response contains only `revision` and `local` (the persisted speech mode).
It contains no path, credential, private settings, or readiness flag. Stale or
invalid-model selection preserves settings; installed generations are never deleted.
An error after atomic replacement can leave a committed selection: read status
before another explicit action rather than automatically replaying it. Existing jobs keep
their immutable snapshots.

Tauri exposes `get_speech_model_configuration` and `select_managed_speech_model`
only to the local main window. `SpeechModelPanel` displays the speech mode and a
managed Parakeet deployment candidate, then sends only its generation ID and the
observed settings revision on explicit selection. Opening/refreshing settings
never selects a model, downloads, starts preflight or infers. An uncertain response
disables selection until a successful status read; epochs reject stale reads after
actions or unmount. Existing jobs retain their saved settings.

Candidate metadata is read from a bounded, protected `active.json`, with its scope,
identity, version and directory checked against compiled policy. The response
contains only generation/model IDs, not the private deployment path. It deliberately
does not hash weights or publish readiness on a status read; malformed metadata
is an error rather than an empty model list. Selection still verifies the complete
model tree. Missing candidate fields are invalid transport responses, not absence.

Model hashing uses a separate bridge process with a 60-second selection deadline,
rather than block or terminate the leased speech queue owner. The common settings
conflict marker maps to a typed `conflict` response without matching private error
strings. Host DTO/ACL, actual IPC with an existing speech owner, browser reconnect/
unknown-acknowledgement scenarios, and synthetic real ASR through this metadata
bridge cover the implementation. Runtime/model installation UI remains pending.

Tests cover extension preservation, invalid IDs/revisions, stale writes, shared
FFI locking, aliases and bounded reads. The opt-in real Linux ASR fixture now uses
this CLI to select the installed generation, rejects a stale or missing generation,
and checks private-field preservation before actual preflight/transcription.
