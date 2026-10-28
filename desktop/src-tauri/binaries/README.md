# Trusted engine resource

Before a native build, stage the canonical core binary here as
`posle-engine-<rust-target-triple>` (`.exe` on Windows). `build.rs` embeds its
SHA-256 into the host. The host executes only this fixed bundled resource after
checking it against that compiled digest. No resource or missing core binary is
a supported capability-unavailable state, so a shell can compile before the core
has been ported to its platform. A staged file must be rebuilt after any change.

Debug builds alone accept absolute `AFTER_ENGINE_PATH` and `AFTER_DATA_DIR` for
isolated development fixtures. Release builds ignore both variables. The default
data location belongs to `app.posle.desktop`, never the Swift app's live library.
