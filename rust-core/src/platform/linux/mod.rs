//! Linux-specific runtime composition; no Darwin loader or PyConfig layout.
pub mod python_runtime;

mod runtime_install;

mod runtime_active;

pub(super) mod speech_launch;

mod speech_dependencies;
