//! Storage, recovery, clock and identity adapters; no calls to legacy operation facades.
pub(crate) mod corrections;
pub(crate) mod workspace_adapters;
pub(crate) mod workspace_files;
pub(crate) mod workspace_repository;
pub(crate) mod job_queue;
pub(crate) mod job_context;
pub(crate) mod import_source;

pub(crate) mod executor_lease;

pub(crate) mod agent_store_layout;

// Both macOS and Linux choose their own pinned policy/layout at composition.
#[cfg(unix)]
#[allow(dead_code)]
pub(crate) mod runtime_tree;

#[cfg(unix)]
pub(crate) mod runtime_venv;

pub(crate) mod artifact_download;

#[cfg(unix)]
pub(crate) mod generation_store;

#[cfg(unix)]
pub(crate) mod asr_model_store;

#[cfg(unix)]
pub(crate) mod speech_settings;

#[cfg(unix)]
pub(crate) mod speech_publication;

pub(crate) mod attempt_store;

#[cfg(unix)]
pub(crate) mod speech_process;

pub(crate) mod native_queue_transport;
