//! Explicitly unavailable semantic runtime. Canonical knowledge storage and
//! lexical suggestions work without claiming that an embedding model ran.
use anyhow::{bail, Result};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

pub(crate) fn cached_library_centroids(
    _: &Path,
    _: &BTreeMap<String, String>,
    _: &BTreeSet<String>,
) -> Result<Option<(BTreeMap<String, Vec<f32>>, String)>> {
    bail!("Semantic cache adapter is unavailable on this platform")
}
pub(crate) fn cached_note_similarities(
    _: &Path,
    _: &str,
    _: &BTreeMap<String, String>,
) -> Result<Option<(BTreeMap<String, f64>, String)>> {
    bail!("Semantic cache adapter is unavailable on this platform")
}
pub(crate) fn cached_topic_vectors(
    _: &Path,
    _: &BTreeMap<String, String>,
) -> Result<Option<(BTreeMap<String, Vec<f32>>, String)>> {
    bail!("Semantic cache adapter is unavailable on this platform")
}
pub(crate) fn topic_threshold(_: &Path, _: &str) -> Result<f64> {
    bail!("Semantic cache adapter is unavailable on this platform")
}
// Without a verified cache no semantic publication/navigation can be fresh.
pub(crate) fn cached_manifest_is_current(_: &Path, _: &str) -> bool {
    false
}
// Conservative lexical fallback policy; no semantic score is supplied above.
pub(crate) fn manual_suggestion_threshold(_: &Path, _: &str) -> f64 {
    0.82
}
