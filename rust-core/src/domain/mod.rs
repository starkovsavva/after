//! Platform-independent types and policies shared by every client.
pub mod config;
pub mod workspace;
pub mod tasks;
pub(crate) mod profiles;
pub(crate) mod task_validation;
pub(crate) mod workspace_validation;
pub mod jobs;
pub(crate) mod job_runtime;

pub(crate) mod knowledge;

pub mod creation_origin;
pub mod asr_models;

pub(crate) mod speech;

pub(crate) mod speech_settings;

pub(crate) mod meeting_ids;
