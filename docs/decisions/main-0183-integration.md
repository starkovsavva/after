# Main 0.18.3 integration with portability work

## Source changes

Integrate main through `333286e`: material origin filters, immutable note/card
provenance, summary-copy origin checks, search-field styling, Swift diagnostics,
release metadata, README and current screenshots. Swift native UI changes are
retained; this does not claim new filter UI in the Tauri preview.

Conflicts keep the portable workspace/domain/application/infrastructure split:
`CapturedNote.creation_origin` lives in `domain/workspace.rs`, its value type and
raw-note preservation rule in `domain/creation_origin.rs`. The old public
`creation_origin::CreationOrigin` path remains a compatibility export. Canonical
SQL commit applies the origin rule before validation within the existing
transaction/CAS/receipt/outbox flow. Upstream note/card/voice/recovery tests are
retained. The Windows metadata-only request boundary remains alongside the new
Unix summary-origin helper. No runtime/capture/queue adapters are discarded.

## Other remote branches

Windows preview/cross-platform source changes were already integrated by rebase.
Patch equivalence matches all ordinary commits except the original packaging
commit; its rebased counterpart contains the same Windows implementation plus
later main/updater fixes. Current Windows smoke and renamed-app update checks
are retained. Recording this ancestry must not reapply obsolete file layouts.

`updates` is the release-publishing branch containing only generated `appcast.xml`.
Per `scripts/update_feed.py` it never changes source main/HEAD, so its published
0.18.3 feed remains separate from this source merge. No release/feed is published.

## Validation

Use the portable desktop profile, source architecture guards, localization,
platform-boundary and updater contracts, then rebuild/stage the engine and run
native Linux WebView startup. Swift source boundaries are checked on Linux;
actual SwiftUI/native filter diagnostics require macOS and are not claimed here.
Unfinished managed-ASR work is kept outside the merge and restored afterward.
