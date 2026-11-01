//! Storage, recovery, clock and identity adapters; no calls to legacy operation facades.
pub(crate) mod corrections;
pub(crate) mod workspace_adapters;
pub(crate) mod workspace_files;
pub(crate) mod workspace_repository;
pub(crate) mod job_queue;
pub(crate) mod job_context;
