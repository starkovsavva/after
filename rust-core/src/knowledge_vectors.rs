//! Composition of optional, read-only semantic evidence for the knowledge
//! organizer. Absence of an adapter is an error, never successful inference.
#[cfg(unix)]
pub(crate) use crate::semantic::{
    cached_library_centroids, cached_manifest_is_current, cached_note_similarities,
    cached_topic_vectors, manual_suggestion_threshold,
};

#[cfg(unix)]
pub(crate) fn topic_threshold(root: &std::path::Path, manifest: &str) -> anyhow::Result<f64> {
    let config = crate::semantic::config(root)?;
    Ok(
        if config.provider == "managed"
            && config.model == crate::managed_embeddings::MODEL
            && config.model_revision == crate::managed_embeddings::REVISION
            && config.dimensions == 1024
            && config.document_prefix.is_empty()
            && crate::semantic::cached_manifest_is_current(root, manifest)
        {
            0.58
        } else {
            0.82
        },
    )
}

#[cfg(windows)]
#[path = "platform/windows/knowledge_vectors.rs"]
mod unavailable;
#[cfg(windows)]
pub(crate) use unavailable::*;

#[cfg(all(test, unix))]
#[path = "platform/windows/knowledge_vectors.rs"]
mod unavailable_contract;

#[cfg(all(test, unix))]
mod tests {
    use super::unavailable_contract as adapter;
    use std::collections::{BTreeMap, BTreeSet};

    #[test]
    fn absent_runtime_never_supplies_vectors_or_attests_source_freshness() {
        let root = tempfile::tempdir().unwrap();
        let allowed = BTreeMap::from([("note".into(), "fingerprint".into())]);
        assert!(adapter::cached_library_centroids(root.path(), &allowed, &BTreeSet::new()).is_err());
        assert!(adapter::cached_note_similarities(root.path(), "note", &allowed).is_err());
        assert!(adapter::cached_topic_vectors(root.path(), &allowed).is_err());
        assert!(adapter::topic_threshold(root.path(), "manifest").is_err());
        assert!(!adapter::cached_manifest_is_current(root.path(), "manifest"));
        assert_eq!(adapter::manual_suggestion_threshold(root.path(), "manifest"), 0.82);
        assert!(!root.path().join("cache").exists());
    }
}
