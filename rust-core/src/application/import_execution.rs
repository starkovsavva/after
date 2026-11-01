//! Portable import execution policy. It owns neither a process nor a file and
//! never persists raw worker errors, grants or an ambiguous success as failure.
use super::{
    import_ports::{
        input_for_job, ImportInput, ImportJobStore, ImportOutcome, ImportStop, ImportWorker,
        IMPORT_JOB_KIND,
    },
    imports::{ImportCancelled, ImportObserver, ImportPhase, ImportProgress},
};
use crate::domain::jobs::Job;
use anyhow::{ensure, Result};

pub(crate) fn execute(
    store: &dyn ImportJobStore,
    worker: &dyn ImportWorker,
    job: &Job,
    stop: &ImportStop,
) -> Result<()> {
    ensure!(
        job.state == "running" && job.attempt > 0 && job.kind == IMPORT_JOB_KIND,
        "Import attempt is not running"
    );
    let input = input_for_job(job);
    let outcome = match input {
        Err(_) => ImportOutcome::Failed,
        Ok(input) => run(store, worker, job, &input, stop),
    };
    store.finish(&job.id, job.attempt, outcome)
}

fn run(
    store: &dyn ImportJobStore,
    worker: &dyn ImportWorker,
    job: &Job,
    input: &ImportInput,
    stop: &ImportStop,
) -> ImportOutcome {
    match worker.committed(input) {
        Ok(true) => return ImportOutcome::Succeeded,
        Err(_) => return ImportOutcome::Interrupted,
        Ok(false) => {}
    }
    if stop.is_requested() {
        return if stop.is_cancelled() {
            ImportOutcome::Cancelled
        } else {
            ImportOutcome::Interrupted
        };
    }
    let mut observer = Observer {
        store,
        job,
        stop,
        previous: None,
        saved_percent: None,
    };
    match worker.import(input, &mut observer) {
        Ok(()) => ImportOutcome::Succeeded,
        Err(error) => match worker.committed(input) {
            Ok(true) => ImportOutcome::Succeeded,
            Err(_) => ImportOutcome::Interrupted,
            Ok(false) if error.is::<ImportCancelled>() || stop.is_requested() => {
                if stop.is_stopping() && !stop.is_cancelled() {
                    ImportOutcome::Interrupted
                } else {
                    ImportOutcome::Cancelled
                }
            }
            Ok(false) => ImportOutcome::Failed,
        },
    }
}

struct Observer<'a> {
    store: &'a dyn ImportJobStore,
    job: &'a Job,
    stop: &'a ImportStop,
    previous: Option<ImportProgress>,
    saved_percent: Option<u8>,
}
impl ImportObserver for Observer<'_> {
    fn checkpoint(&mut self, progress: ImportProgress) -> Result<()> {
        if self.stop.is_requested() {
            return Err(ImportCancelled.into());
        }
        ensure!(
            progress.copied_bytes <= progress.total_bytes,
            "Invalid import progress"
        );
        if progress.phase == ImportPhase::Committing {
            ensure!(
                progress.copied_bytes == progress.total_bytes,
                "Incomplete import publication"
            );
        }
        if let Some(previous) = &self.previous {
            ensure!(
                previous.total_bytes == progress.total_bytes
                    && previous.copied_bytes <= progress.copied_bytes
                    && (previous.phase != ImportPhase::Committing
                        || progress.phase == ImportPhase::Committing),
                "Import progress regressed"
            );
        }
        let fraction = if progress.total_bytes == 0 {
            if progress.phase == ImportPhase::Committing {
                1.0
            } else {
                0.0
            }
        } else {
            progress.copied_bytes as f64 / progress.total_bytes as f64
        };
        let percent = (fraction * 100.0).floor() as u8;
        let phase_changed = self
            .previous
            .as_ref()
            .is_none_or(|previous| previous.phase != progress.phase);
        self.previous = Some(progress);
        // Check cancellation every chunk, but bound durable progress writes to
        // percentage/phase changes instead of one SQL transaction per buffer.
        if phase_changed || self.saved_percent != Some(percent) {
            if self
                .store
                .progress(&self.job.id, self.job.attempt, fraction)?
            {
                self.stop.cancel();
                return Err(ImportCancelled.into());
            }
            self.saved_percent = Some(percent);
        }
        if self.stop.is_requested() {
            return Err(ImportCancelled.into());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::jobs::{JobDefinition, JobResource};
    use serde_json::json;
    use std::sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex,
    };

    #[derive(Default)]
    struct Store {
        progress: Mutex<Vec<f64>>,
        finished: Mutex<Vec<ImportOutcome>>,
        cancel: bool,
        fail_progress: bool,
        stale_finish: AtomicBool,
    }
    impl ImportJobStore for Store {
        fn progress(&self, _: &str, attempt: u64, fraction: f64) -> Result<bool> {
            assert_eq!(attempt, 1);
            if self.fail_progress {
                anyhow::bail!("synthetic queue failure");
            }
            self.progress.lock().unwrap().push(fraction);
            Ok(self.cancel)
        }
        fn finish(&self, _: &str, attempt: u64, outcome: ImportOutcome) -> Result<()> {
            assert_eq!(attempt, 1);
            ensure!(
                !self.stale_finish.load(Ordering::Acquire),
                "synthetic stale attempt"
            );
            self.finished.lock().unwrap().push(outcome);
            Ok(())
        }
    }
    enum Mode {
        Success,
        LostReply,
        UnknownReply,
        Regress,
        Superseded,
    }
    struct Worker {
        receipt: AtomicUsize, // 0 absent, 1 committed, 2 unknown
        called: AtomicUsize,
        mode: Mode,
        stop: Arc<ImportStop>,
        store: Arc<Store>,
    }
    impl super::super::import_ports::ImportReceipts for Worker {
        fn committed(&self, _: &ImportInput) -> Result<bool> {
            match self.receipt.load(Ordering::Acquire) {
                0 => Ok(false),
                1 => Ok(true),
                _ => anyhow::bail!("synthetic unreadable receipt"),
            }
        }
    }
    impl ImportWorker for Worker {
        fn import(&self, _: &ImportInput, observer: &mut dyn ImportObserver) -> Result<()> {
            self.called.fetch_add(1, Ordering::AcqRel);
            for copied in 0..=1000 {
                observer.checkpoint(ImportProgress {
                    phase: ImportPhase::Copying,
                    copied_bytes: copied,
                    total_bytes: 1000,
                })?;
                if matches!(self.mode, Mode::Regress) && copied == 10 {
                    observer.checkpoint(ImportProgress {
                        phase: ImportPhase::Copying,
                        copied_bytes: 9,
                        total_bytes: 1000,
                    })?;
                }
            }
            observer.checkpoint(ImportProgress {
                phase: ImportPhase::Committing,
                copied_bytes: 1000,
                total_bytes: 1000,
            })?;
            match self.mode {
                Mode::LostReply => {
                    self.receipt.store(1, Ordering::Release);
                    self.stop.cancel();
                    anyhow::bail!("synthetic sensitive worker error: /private/source.wav")
                }
                Mode::UnknownReply => {
                    self.receipt.store(2, Ordering::Release);
                    anyhow::bail!("synthetic ambiguous response")
                }
                Mode::Superseded => {
                    self.receipt.store(1, Ordering::Release);
                    self.store.stale_finish.store(true, Ordering::Release);
                }
                _ => self.receipt.store(1, Ordering::Release),
            }
            Ok(())
        }
    }
    fn fixture(mode: Mode, store: Store) -> (Arc<Store>, Worker, Job, Arc<ImportStop>) {
        let store = Arc::new(store);
        let stop = Arc::new(ImportStop::default());
        let input = ImportInput {
            operation_id: uuid::Uuid::new_v4().to_string(),
            attempt_token: uuid::Uuid::new_v4().to_string(),
            source_path: std::env::temp_dir().join("synthetic source.wav"),
            title: None,
        };
        let mut job = JobDefinition {
            kind: IMPORT_JOB_KIND.into(),
            object_id: input.operation_id.clone(),
            input_revision: "v1".into(),
            config: serde_json::to_value(input).unwrap(),
            resource: JobResource::LocalHeavy,
            dependencies: Vec::new(),
            title: "Import".into(),
            paid: false,
        }
        .into_job("job".into(), 1.0);
        job.state = "running".into();
        job.attempt = 1;
        let worker = Worker {
            receipt: AtomicUsize::new(0),
            called: AtomicUsize::new(0),
            mode,
            stop: stop.clone(),
            store: store.clone(),
        };
        (store, worker, job, stop)
    }

    #[test]
    fn committed_receipt_wins_lost_reply_and_late_cancel_without_repeating_effect() {
        let (store, worker, job, stop) = fixture(Mode::LostReply, Store::default());
        execute(&*store, &worker, &job, &stop).unwrap();
        assert_eq!(*store.finished.lock().unwrap(), [ImportOutcome::Succeeded]);
        assert!(stop.is_cancelled());
        execute(&*store, &worker, &job, &stop).unwrap();
        assert_eq!(worker.called.load(Ordering::Acquire), 1);
    }
    #[test]
    fn durable_cancel_and_unavailable_progress_abort_before_publication() {
        for store in [
            Store {
                cancel: true,
                ..Default::default()
            },
            Store {
                fail_progress: true,
                ..Default::default()
            },
        ] {
            let expected = if store.cancel {
                ImportOutcome::Cancelled
            } else {
                ImportOutcome::Failed
            };
            let (store, worker, job, stop) = fixture(Mode::Success, store);
            execute(&*store, &worker, &job, &stop).unwrap();
            assert_eq!(worker.receipt.load(Ordering::Acquire), 0);
            assert_eq!(*store.finished.lock().unwrap(), [expected]);
        }
    }
    #[test]
    fn unknown_receipt_never_authorizes_a_retry_or_a_definite_failure() {
        let (store, worker, job, stop) = fixture(Mode::UnknownReply, Store::default());
        execute(&*store, &worker, &job, &stop).unwrap();
        assert_eq!(
            *store.finished.lock().unwrap(),
            [ImportOutcome::Interrupted]
        );
        execute(&*store, &worker, &job, &stop).unwrap();
        assert_eq!(worker.called.load(Ordering::Acquire), 1);
    }
    #[test]
    fn progress_writes_are_bounded_and_regressions_cannot_publish() {
        let (store, worker, job, stop) = fixture(Mode::Success, Store::default());
        execute(&*store, &worker, &job, &stop).unwrap();
        let progress = store.progress.lock().unwrap();
        assert!(progress.len() <= 103);
        assert_eq!(*progress.first().unwrap(), 0.0);
        assert_eq!(*progress.last().unwrap(), 1.0);
        assert!(progress.windows(2).all(|pair| pair[0] <= pair[1]));
        let (store, worker, job, stop) = fixture(Mode::Regress, Store::default());
        execute(&*store, &worker, &job, &stop).unwrap();
        assert_eq!(worker.receipt.load(Ordering::Acquire), 0);
        assert_eq!(*store.finished.lock().unwrap(), [ImportOutcome::Failed]);
    }
    #[test]
    fn malformed_private_input_never_reaches_a_worker_and_stale_attempt_cannot_finish() {
        let (store, worker, mut job, stop) = fixture(Mode::Success, Store::default());
        job.config["command"] = json!("execute-arbitrary-command");
        execute(&*store, &worker, &job, &stop).unwrap();
        assert_eq!(worker.called.load(Ordering::Acquire), 0);
        assert_eq!(*store.finished.lock().unwrap(), [ImportOutcome::Failed]);
        let (store, worker, job, stop) = fixture(Mode::Superseded, Store::default());
        assert!(execute(&*store, &worker, &job, &stop).is_err());
        assert!(store.finished.lock().unwrap().is_empty());
    }

    #[test]
    fn owner_shutdown_is_interruption_but_a_committed_receipt_still_wins() {
        let (store, worker, job, stop) = fixture(Mode::Success, Store::default());
        stop.shutdown();
        execute(&*store, &worker, &job, &stop).unwrap();
        assert_eq!(worker.called.load(Ordering::Acquire), 0);
        assert_eq!(
            *store.finished.lock().unwrap(),
            [ImportOutcome::Interrupted]
        );
        worker.receipt.store(1, Ordering::Release);
        execute(&*store, &worker, &job, &stop).unwrap();
        assert_eq!(
            *store.finished.lock().unwrap(),
            [ImportOutcome::Interrupted, ImportOutcome::Succeeded]
        );
    }
}
