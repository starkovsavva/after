//! Effectful clock and identity adapters for the shared queue.
use crate::application::job_ports::{JobClock, JobIds};

pub(crate) struct SystemJobClock;
impl JobClock for SystemJobClock {
    fn now(&self) -> f64 {
        chrono::Utc::now().timestamp_millis() as f64 / 1000.0
    }
}

pub(crate) struct RandomJobIds;
impl JobIds for RandomJobIds {
    fn next(&self) -> String {
        uuid::Uuid::new_v4().to_string()
    }
}
