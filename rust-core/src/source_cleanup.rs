//! Composition of the source cleanup boundary. Canonical note deletion does not
//! select an operating system or know the private agent store's physical layout.
#[cfg(unix)]
pub(crate) use crate::scoped_agent::reconcile_deleted_sources;

#[cfg(windows)]
#[path = "platform/windows/source_cleanup.rs"]
mod unavailable;
#[cfg(windows)]
pub(crate) use unavailable::reconcile_deleted_sources;

#[cfg(all(test, unix))]
#[path = "platform/windows/source_cleanup.rs"]
mod unavailable_contract;

#[cfg(all(test, unix))]
mod tests {
    #[test]
    fn absent_store_needs_no_cleanup_but_existing_data_is_never_reported_clean() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(
            super::unavailable_contract::reconcile_deleted_sources(root.path()).unwrap(),
            0
        );
        let path = root
            .path()
            .join(crate::infrastructure::agent_store_layout::DATABASE);
        std::fs::write(&path, b"preserve this private store").unwrap();
        assert!(super::unavailable_contract::reconcile_deleted_sources(root.path()).is_err());
        assert_eq!(std::fs::read(path).unwrap(), b"preserve this private store");
    }
}
