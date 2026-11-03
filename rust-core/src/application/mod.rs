//! Workspace and queue use cases depend on contracts and domain values, not adapters.
pub(crate) mod ports;
pub(crate) mod workspace;
pub(crate) mod job_ports;
pub(crate) mod jobs;
pub(crate) mod imports;

pub(crate) mod import_ports;
pub(crate) mod import_execution;

pub(crate) mod import_recovery;

pub(crate) mod runtime_install;

pub(crate) mod speech_launch;

pub(crate) mod asr_model_install;

pub(crate) mod speech_execution;

pub(crate) mod attempt_execution;
pub(crate) mod job_recovery;

pub(crate) mod speech_jobs;

pub(crate) mod speech_preparation;

pub(crate) mod speech_check;

pub(crate) mod speech_progress;
