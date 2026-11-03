//! Durable local-speech attempt policy; no SQL, processes or platform selection.
use super::{
    attempt_execution::{AttemptOutcome, AttemptStop, AttemptStore},
    speech_work::SpeechWork,
};
use crate::domain::jobs::Job;
use anyhow::{ensure, Result};
pub(crate) use super::speech_work::KIND;
pub(crate) use super::speech_progress::SpeechObserver;
pub(crate) trait SpeechJobWorker: Send + Sync {
    fn committed(&self, work: &SpeechWork) -> Result<bool>;
    /// Return only after the entire native process tree has stopped.
    fn run(
        &self,
        work: &SpeechWork,
        stop: &AttemptStop,
        observer: &mut dyn SpeechObserver,
    ) -> Result<()>;
}
pub(crate) fn input(job:&Job)->Result<SpeechWork>{SpeechWork::from_job(job)}
pub(crate) fn execute(
    store: &dyn AttemptStore,
    worker: &dyn SpeechJobWorker,
    job: &Job,
    stop: &AttemptStop,
) -> Result<()> {
    ensure!(
        job.kind == KIND && job.state == "running" && job.attempt > 0,
        "Speech attempt is not running"
    );
    let outcome = match input(job) {
        Ok(work) => run(store, worker, job, &work, stop),
        Err(_) => AttemptOutcome::Failed,
    };
    store.finish(&job.id, job.attempt, outcome)
}
fn stopped(stop: &AttemptStop) -> AttemptOutcome {
    if stop.is_cancelled() {
        AttemptOutcome::Cancelled
    } else {
        AttemptOutcome::Interrupted
    }
}
fn run(
    store: &dyn AttemptStore,
    worker: &dyn SpeechJobWorker,
    job: &Job,
    work: &SpeechWork,
    stop: &AttemptStop,
) -> AttemptOutcome {
    match worker.committed(work) {
        Ok(true) => return AttemptOutcome::Succeeded,
        Err(_) => return AttemptOutcome::Interrupted,
        Ok(false) => {}
    }
    if stop.is_requested() {
        return stopped(stop);
    }
    let mut observer = Observer {
        store,
        job,
        stop,
        previous: 0.,
        saved: None,
    };
    let result = worker.run(work, stop, &mut observer);
    // A process acknowledgement is not publication authority. Probe the exact
    // durable receipt after cleanup, even on cancellation or lost transport.
    match worker.committed(work) {
        Ok(true) => AttemptOutcome::Succeeded,
        Err(_) => AttemptOutcome::Interrupted,
        Ok(false) if stop.is_requested() => stopped(stop),
        Ok(false) if result.is_ok() => AttemptOutcome::Interrupted,
        Ok(false) => AttemptOutcome::Failed,
    }
}
struct Observer<'a> {
    store: &'a dyn AttemptStore,
    job: &'a Job,
    stop: &'a AttemptStop,
    previous: f64,
    saved: Option<u8>,
}
impl SpeechObserver for Observer<'_> {
    fn checkpoint(&mut self, fraction: Option<f64>) -> Result<()> {
        ensure!(!self.stop.is_requested(), "Speech stopped");
        if let Some(value) = fraction {
            ensure!(
                value.is_finite() && (0.0..=1.0).contains(&value),
                "Invalid speech progress"
            );
            self.previous = self.previous.max(value);
        }
        let percent = (self.previous * 100.).floor() as u8;
        if self.saved != Some(percent) {
            if self
                .store
                .progress(&self.job.id, self.job.attempt, self.previous)?
            {
                self.stop.cancel();
                anyhow::bail!("Speech cancelled");
            }
            self.saved = Some(percent);
        }
        Ok(())
    }
}
