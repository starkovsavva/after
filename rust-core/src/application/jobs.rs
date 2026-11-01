//! Shared durable queue use cases. Admission and lifecycle policy run against a
//! transaction port; storage, time, identity and live worker handles stay outside.
use super::job_ports::{
    JobClock, JobIds, JobMatchScope, JobQueueRepository, JobQueueTransaction, JobSelection,
};
use crate::domain::jobs::{
    chatgpt_account, chatgpt_execution_account, reached_chatgpt_limit, resource_available, Job,
    JobDefinition, JobMutation, JobQueueSnapshot, JobResource,
};
use anyhow::{ensure, Result};
use std::collections::HashSet;

pub(crate) struct ClaimRequest {
    pub job_id: Option<String>,
    pub allowed_resources: Option<Vec<JobResource>>,
    pub excluded_accounts: Vec<String>,
}

pub(crate) enum JobCommand {
    Enqueue {
        definition: JobDefinition,
        follow_ups: Vec<JobDefinition>,
    },
    List,
    Get {
        id: String,
    },
    Claim(ClaimRequest),
    Mutate {
        id: String,
        expected_attempt: Option<u64>,
        mutation: JobMutation,
    },
    Recover,
}

pub(crate) enum JobReply {
    Enqueued {
        job: Job,
        deduplicated: bool,
        follow_ups: Vec<Job>,
    },
    Snapshot(JobQueueSnapshot),
    Job(Job),
    Claimed(Option<Job>),
    Recovered {
        recovered: usize,
        jobs: Vec<Job>,
    },
}

pub(crate) struct JobQueue<R, C, I> {
    pub repository: R,
    pub clock: C,
    pub ids: I,
    /// Composition-root ownership boundary. None preserves the native legacy API.
    /// This is not a process lease: recovery still requires exclusive ownership
    /// of the selected executor kind.
    pub kind: Option<&'static str>,
}

impl<R: JobQueueRepository, C: JobClock, I: JobIds> JobQueue<R, C, I> {
    pub fn execute(&self, command: JobCommand) -> Result<JobReply> {
        match command {
            JobCommand::List => Ok(JobReply::Snapshot(self.repository.snapshot(self.kind)?)),
            JobCommand::Get { id } => {
                let job = self.repository.get(&id)?;
                self.owned(&job)?;
                Ok(JobReply::Job(job))
            }
            JobCommand::Enqueue {
                definition,
                follow_ups,
            } => {
                self.owned_kind(&definition.kind)?;
                definition.validate()?;
                ensure!(
                    follow_ups.len() <= 16,
                    "Слишком много следующих этапов задания"
                );
                let parent = definition.into_job(self.ids.next(), self.clock.now());
                self.repository.transaction(|transaction| {
                    let (parent, deduplicated) =
                        self.insert(transaction, parent, JobMatchScope::Pending)?;
                    let mut children = Vec::new();
                    for definition in follow_ups {
                        self.owned_kind(&definition.kind)?;
                        definition.validate()?;
                        let mut child = definition.into_job(self.ids.next(), self.clock.now());
                        ensure!(
                            child.object_id == parent.object_id,
                            "Связанные этапы должны относиться к одному объекту"
                        );
                        child.input_revision = child.input_revision.replace("$parent", &parent.id);
                        if !child.dependencies.contains(&parent.id) {
                            child.dependencies.push(parent.id.clone());
                        }
                        // Terminal children deduplicate too: re-subscribing must
                        // not revive a stage explicitly cancelled by the user.
                        let (child, _) =
                            self.insert(transaction, child, JobMatchScope::AnyState)?;
                        children.push(child);
                    }
                    Ok(JobReply::Enqueued {
                        job: parent,
                        deduplicated,
                        follow_ups: children,
                    })
                })
            }
            JobCommand::Claim(request) => self.repository.transaction(|transaction| {
                self.block_descendants(transaction)?;
                let jobs = transaction.selected(JobSelection::Active)?;
                let running: Vec<_> = jobs.iter().filter(|job| job.state == "running").collect();
                let paused: HashSet<_> = transaction
                    .paused_jobs()?
                    .iter()
                    .filter_map(chatgpt_account)
                    .map(str::to_owned)
                    .collect();
                for job in jobs.iter().filter(|job| job.state == "queued") {
                    if self.kind.is_some_and(|kind| kind != job.kind)
                        || request.job_id.as_ref().is_some_and(|id| id != &job.id)
                        || chatgpt_execution_account(&job.config)
                            .is_some_and(|account| paused.contains(account))
                        || chatgpt_execution_account(&job.config).is_some_and(|account| {
                            request
                                .excluded_accounts
                                .iter()
                                .any(|excluded| excluded == account)
                        })
                        || request.allowed_resources.as_ref().is_some_and(|resources| {
                            !resources
                                .iter()
                                .any(|resource| resource.as_str() == job.resource)
                        })
                        || !resource_available(job, &running)
                    {
                        continue;
                    }
                    let states = self.dependency_states(transaction, job)?;
                    if !states
                        .iter()
                        .all(|state| state.as_deref() == Some("succeeded"))
                    {
                        continue;
                    }
                    let mut job = job.clone();
                    job.state = "running".into();
                    job.progress = 0.0;
                    job.message.clear();
                    job.cancel_requested = false;
                    job.attempt += 1;
                    job.updated_at = self.clock.now();
                    transaction.save(&job)?;
                    return Ok(JobReply::Claimed(Some(job)));
                }
                Ok(JobReply::Claimed(None))
            }),
            JobCommand::Mutate {
                id,
                expected_attempt,
                mutation,
            } => {
                self.repository.transaction(|transaction| {
                    let mut job = transaction.get(&id)?;
                    self.owned(&job)?;
                    let previous_state = job.state.clone();
                    if let Some(attempt) = expected_attempt {
                        ensure!(attempt == job.attempt, "Попытка задания уже изменилась");
                    }
                    if !job.apply(&mutation)? {
                        return Ok(JobReply::Job(job));
                    }
                    job.updated_at = self.clock.now();
                    transaction.save(&job)?;
                    if let Some(account) = chatgpt_account(&job) {
                        if matches!(mutation, JobMutation::Update(_))
                            && job.state == "failed"
                            && reached_chatgpt_limit(&job.message)
                        {
                            transaction.pause_account(account, &job.id)?;
                        } else if matches!(mutation, JobMutation::Retry { .. }) {
                            // Rejected paid retries never clear persisted consent gates.
                            transaction.resume_account(account)?;
                        }
                    }
                    if job.state != previous_state {
                        self.block_descendants(transaction)?;
                    }
                    Ok(JobReply::Job(job))
                })
            }
            JobCommand::Recover => {
                let recovered = self.repository.transaction(|transaction| {
                    let jobs = transaction.selected(JobSelection::Running)?;
                    let jobs: Vec<_> = jobs
                        .into_iter()
                        .filter(|job| self.kind.is_none_or(|kind| kind == job.kind))
                        .collect();
                    let recovered = jobs.len();
                    for mut job in jobs {
                        job.state = "interrupted".into();
                        job.message = "Работа прервалась. Можно продолжить вручную.".into();
                        job.cancel_requested = false;
                        job.updated_at = self.clock.now();
                        transaction.save(&job)?;
                    }
                    self.block_descendants(transaction)?;
                    Ok(recovered)
                })?;
                Ok(JobReply::Recovered {
                    recovered,
                    jobs: self.repository.snapshot(self.kind)?.jobs,
                })
            }
        }
    }

    fn owned_kind(&self, kind: &str) -> Result<()> {
        ensure!(
            self.kind.is_none_or(|owned| owned == kind),
            "Задание принадлежит другому исполнителю"
        );
        Ok(())
    }

    fn owned(&self, job: &Job) -> Result<()> {
        self.owned_kind(&job.kind)
    }

    fn insert(
        &self,
        transaction: &mut dyn JobQueueTransaction,
        job: Job,
        scope: JobMatchScope,
    ) -> Result<(Job, bool)> {
        if let Some(existing) = transaction.matching(&job, scope)? {
            return Ok((existing, true));
        }
        for dependency in &job.dependencies {
            self.owned(&transaction.get(dependency)?)?;
        }
        ensure!(
            transaction.active_count()? < 256,
            "В очереди уже 256 операций. Дождитесь завершения или отмените лишние."
        );
        transaction.save(&job)?;
        Ok((job, false))
    }

    fn dependency_states(
        &self,
        transaction: &dyn JobQueueTransaction,
        job: &Job,
    ) -> Result<Vec<Option<String>>> {
        job.dependencies
            .iter()
            .map(|id| transaction.state(id))
            .collect()
    }

    /// Preserve the fixed-point propagation used by existing libraries. Only
    /// dependency-blocked stages revive, never explicitly cancelled children.
    fn block_descendants(&self, transaction: &mut dyn JobQueueTransaction) -> Result<()> {
        loop {
            let mut changed = false;
            for mut job in transaction.selected(JobSelection::WaitingDependencies)? {
                if self.kind.is_some_and(|kind| kind != job.kind) {
                    continue;
                }
                let states = self.dependency_states(transaction, &job)?;
                let blocked = states.iter().any(|state| {
                    state.as_ref().is_none_or(|state| {
                        ["failed", "cancelled", "interrupted", "blocked"].contains(&state.as_str())
                    })
                });
                if job.state == "queued" && blocked {
                    job.state = "blocked".into();
                    job.message =
                        "Предыдущий этап не завершён. Повторите его или отмените этот этап.".into();
                } else if job.state == "blocked"
                    && states
                        .iter()
                        .all(|state| state.as_deref() == Some("succeeded"))
                {
                    job.state = "queued".into();
                    job.message.clear();
                } else {
                    continue;
                }
                job.updated_at = self.clock.now();
                transaction.save(&job)?;
                changed = true;
            }
            if !changed {
                return Ok(());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::jobs::{JobUpdate, UpdateField};
    use anyhow::Context;
    use serde_json::{json, to_value};
    use std::{
        cell::{Cell, RefCell},
        collections::BTreeMap,
    };

    #[derive(Clone, Default)]
    struct MemoryState {
        jobs: Vec<Job>,
        pauses: BTreeMap<String, String>,
    }
    #[derive(Default)]
    struct MemoryRepository {
        state: RefCell<MemoryState>,
        transactions: Cell<usize>,
        fail_save: Cell<Option<usize>>,
    }
    struct Session<'a> {
        state: &'a mut MemoryState,
        saves: usize,
        fail_save: Option<usize>,
    }
    impl JobQueueRepository for MemoryRepository {
        fn snapshot(&self, kind: Option<&str>) -> Result<JobQueueSnapshot> {
            let state = self.state.borrow();
            Ok(JobQueueSnapshot {
                jobs: state
                    .jobs
                    .iter()
                    .filter(|job| kind.is_none_or(|kind| kind == job.kind))
                    .cloned()
                    .collect(),
                total: state
                    .jobs
                    .iter()
                    .filter(|job| kind.is_none_or(|kind| kind == job.kind))
                    .count() as u64,
                paused_chatgpt_failures: state
                    .pauses
                    .values()
                    .map(|id| self.get(id))
                    .collect::<Result<Vec<_>>>()?
                    .into_iter()
                    .filter(|job| kind.is_none_or(|kind| kind == job.kind))
                    .collect(),
            })
        }
        fn recovery_candidates(
            &self,
            kind: &str,
            after: Option<&str>,
            limit: usize,
        ) -> Result<Vec<Job>> {
            let mut jobs: Vec<_> = self
                .state
                .borrow()
                .jobs
                .iter()
                .filter(|job| {
                    job.kind == kind
                        && ["running", "interrupted"].contains(&job.state.as_str())
                        && after.is_none_or(|after| job.id.as_str() > after)
                })
                .cloned()
                .collect();
            jobs.sort_by(|a, b| a.id.cmp(&b.id));
            jobs.truncate(limit);
            Ok(jobs)
        }
        fn get(&self, id: &str) -> Result<Job> {
            self.state
                .borrow()
                .jobs
                .iter()
                .find(|job| job.id == id)
                .cloned()
                .context("missing fixture job")
        }
        fn transaction<T>(
            &self,
            action: impl FnOnce(&mut dyn JobQueueTransaction) -> Result<T>,
        ) -> Result<T> {
            self.transactions.set(self.transactions.get() + 1);
            let mut state = self.state.borrow().clone();
            let result = action(&mut Session {
                state: &mut state,
                saves: 0,
                fail_save: self.fail_save.get(),
            })?;
            *self.state.borrow_mut() = state;
            Ok(result)
        }
    }
    impl JobQueueTransaction for Session<'_> {
        fn selected(&self, selection: JobSelection) -> Result<Vec<Job>> {
            let states = match selection {
                JobSelection::Active => &["queued", "running"][..],
                JobSelection::WaitingDependencies => &["queued", "blocked"][..],
                JobSelection::Running => &["running"][..],
            };
            Ok(self
                .state
                .jobs
                .iter()
                .filter(|job| states.contains(&job.state.as_str()))
                .cloned()
                .collect())
        }
        fn get(&self, id: &str) -> Result<Job> {
            self.state
                .jobs
                .iter()
                .find(|job| job.id == id)
                .cloned()
                .context("missing fixture job")
        }
        fn state(&self, id: &str) -> Result<Option<String>> {
            Ok(self
                .state
                .jobs
                .iter()
                .find(|job| job.id == id)
                .map(|job| job.state.clone()))
        }
        fn matching(&self, job: &Job, scope: JobMatchScope) -> Result<Option<Job>> {
            let key = job.dedup_key()?;
            Ok(self
                .state
                .jobs
                .iter()
                .find(|other| {
                    other.dedup_key().unwrap() == key
                        && (matches!(scope, JobMatchScope::AnyState)
                            || ["queued", "running", "interrupted", "blocked"]
                                .contains(&other.state.as_str()))
                })
                .cloned())
        }
        fn active_count(&self) -> Result<u64> {
            Ok(self
                .state
                .jobs
                .iter()
                .filter(|job| ["queued", "running"].contains(&job.state.as_str()))
                .count() as u64)
        }
        fn paused_jobs(&self) -> Result<Vec<Job>> {
            self.state.pauses.values().map(|id| self.get(id)).collect()
        }
        fn save(&mut self, job: &Job) -> Result<()> {
            self.saves += 1;
            ensure!(self.fail_save != Some(self.saves), "injected save failure");
            if let Some(index) = self.state.jobs.iter().position(|other| other.id == job.id) {
                self.state.jobs[index] = job.clone();
            } else {
                self.state.jobs.push(job.clone());
            }
            Ok(())
        }
        fn pause_account(&mut self, account: &str, job: &str) -> Result<()> {
            self.state.pauses.insert(account.into(), job.into());
            Ok(())
        }
        fn resume_account(&mut self, account: &str) -> Result<()> {
            self.state.pauses.remove(account);
            Ok(())
        }
    }
    #[derive(Default)]
    struct Clock(Cell<u64>);
    impl JobClock for Clock {
        fn now(&self) -> f64 {
            self.0.set(self.0.get() + 1);
            self.0.get() as f64
        }
    }
    #[derive(Default)]
    struct Ids(Cell<usize>);
    impl JobIds for Ids {
        fn next(&self) -> String {
            self.0.set(self.0.get() + 1);
            format!("test-{}", self.0.get())
        }
    }
    fn queue() -> JobQueue<MemoryRepository, Clock, Ids> {
        JobQueue {
            repository: MemoryRepository::default(),
            clock: Clock::default(),
            ids: Ids::default(),
            kind: None,
        }
    }
    fn definition(object: &str) -> JobDefinition {
        JobDefinition {
            kind: "example".into(),
            object_id: object.into(),
            input_revision: "v1".into(),
            config: json!({}),
            resource: JobResource::Cloud,
            dependencies: Vec::new(),
            title: "Example".into(),
            paid: false,
        }
    }
    fn submit(queue: &JobQueue<MemoryRepository, Clock, Ids>, definition: JobDefinition) -> Job {
        match queue
            .execute(JobCommand::Enqueue {
                definition,
                follow_ups: Vec::new(),
            })
            .unwrap()
        {
            JobReply::Enqueued { job, .. } => job,
            _ => panic!("expected enqueue"),
        }
    }
    fn claim(queue: &JobQueue<MemoryRepository, Clock, Ids>, id: &str) -> Option<Job> {
        match queue
            .execute(JobCommand::Claim(ClaimRequest {
                excluded_accounts: Vec::new(),
                job_id: Some(id.into()),
                allowed_resources: None,
            }))
            .unwrap()
        {
            JobReply::Claimed(job) => job,
            _ => panic!("expected claim"),
        }
    }

    #[test]
    fn scoped_executor_cannot_read_mutate_enqueue_or_recover_foreign_jobs() {
        let mut queue = queue();
        let foreign = submit(&queue, definition("foreign"));
        claim(&queue, &foreign.id).unwrap();
        let mut own_definition = definition("owned");
        own_definition.kind = "desktop-import".into();
        let own = submit(&queue, own_definition);
        claim(&queue, &own.id).unwrap();
        let before = to_value(queue.repository.get(&foreign.id).unwrap()).unwrap();
        queue.kind = Some("desktop-import");
        assert!(queue
            .execute(JobCommand::Get {
                id: foreign.id.clone()
            })
            .is_err());
        assert!(queue
            .execute(JobCommand::Mutate {
                id: foreign.id.clone(),
                expected_attempt: Some(1),
                mutation: JobMutation::Cancel,
            })
            .is_err());
        let ticks = queue.clock.0.get();
        let identities = queue.ids.0.get();
        assert!(queue
            .execute(JobCommand::Enqueue {
                definition: definition("forbidden"),
                follow_ups: Vec::new(),
            })
            .is_err());
        assert_eq!(queue.clock.0.get(), ticks);
        assert_eq!(queue.ids.0.get(), identities);
        match queue.execute(JobCommand::Recover).unwrap() {
            JobReply::Recovered { recovered, jobs } => {
                assert_eq!(recovered, 1);
                assert_eq!(jobs.len(), 1);
                assert_eq!(jobs[0].id, own.id);
                assert_eq!(jobs[0].state, "interrupted");
            }
            _ => panic!("expected recovery"),
        }
        assert_eq!(
            to_value(queue.repository.get(&foreign.id).unwrap()).unwrap(),
            before
        );
        assert!(claim(&queue, &foreign.id).is_none());
        assert!(claim(&queue, &own.id).is_none());
    }

    #[test]
    fn scoped_claim_observes_foreign_resource_usage_and_does_not_propagate_foreign_dependencies() {
        let mut queue = queue();
        let mut input = definition("foreign-heavy");
        input.resource = JobResource::LocalHeavy;
        let foreign = submit(&queue, input);
        claim(&queue, &foreign.id).unwrap();
        let mut input = definition("own-heavy");
        input.kind = "desktop-import".into();
        input.resource = JobResource::LocalHeavy;
        let own = submit(&queue, input);
        let parent = submit(&queue, definition("parent"));
        let mut child = definition("child");
        child.dependencies = vec![parent.id.clone()];
        let child = submit(&queue, child);
        // Simulate a previously failed dependency without propagating it yet.
        queue
            .repository
            .state
            .borrow_mut()
            .jobs
            .iter_mut()
            .find(|job| job.id == parent.id)
            .unwrap()
            .state = "failed".into();
        queue.kind = Some("desktop-import");
        assert!(claim(&queue, &own.id).is_none());
        assert_eq!(queue.repository.get(&child.id).unwrap().state, "queued");
        queue
            .repository
            .state
            .borrow_mut()
            .jobs
            .iter_mut()
            .find(|job| job.id == foreign.id)
            .unwrap()
            .state = "succeeded".into();
        assert_eq!(claim(&queue, &own.id).unwrap().attempt, 1);
        assert_eq!(queue.repository.get(&child.id).unwrap().state, "queued");
    }

    #[test]
    fn scoped_chains_reject_foreign_follow_ups_and_dependencies_atomically() {
        let mut queue = queue();
        let foreign = submit(&queue, definition("foreign"));
        queue.kind = Some("desktop-import");
        let mut input = definition("parent");
        input.kind = "desktop-import".into();
        assert!(queue
            .execute(JobCommand::Enqueue {
                definition: input,
                follow_ups: vec![definition("parent")],
            })
            .is_err());
        assert_eq!(queue.repository.state.borrow().jobs.len(), 1);
        let mut input = definition("child");
        input.kind = "desktop-import".into();
        input.dependencies.push(foreign.id);
        assert!(queue
            .execute(JobCommand::Enqueue {
                definition: input,
                follow_ups: Vec::new(),
            })
            .is_err());
        assert_eq!(queue.repository.state.borrow().jobs.len(), 1);
    }

    #[test]
    fn invalid_definition_has_no_storage_identity_or_clock_effects() {
        let queue = queue();
        let mut input = definition("a");
        input.config = json!({"nested":{"api_key":"never persist"}});
        assert!(queue
            .execute(JobCommand::Enqueue {
                definition: input,
                follow_ups: Vec::new()
            })
            .is_err());
        assert_eq!(queue.repository.transactions.get(), 0);
        assert_eq!(queue.ids.0.get(), 0);
        assert_eq!(queue.clock.0.get(), 0);
    }

    #[test]
    fn failure_in_follow_up_rolls_back_the_entire_chain() {
        let queue = queue();
        queue.repository.fail_save.set(Some(2));
        let result = queue.execute(JobCommand::Enqueue {
            definition: definition("a"),
            follow_ups: vec![JobDefinition {
                kind: "summarize".into(),
                input_revision: "dependency:$parent".into(),
                ..definition("a")
            }],
        });
        assert!(result.is_err());
        assert!(queue.repository.state.borrow().jobs.is_empty());
        assert_eq!(queue.repository.transactions.get(), 1);
    }

    #[test]
    fn repeated_completion_ignores_late_fields_but_stale_attempt_still_fails() {
        let queue = queue();
        let id = submit(&queue, definition("a")).id;
        claim(&queue, &id).unwrap();
        queue
            .execute(JobCommand::Mutate {
                id: id.clone(),
                expected_attempt: Some(1),
                mutation: JobMutation::Update(JobUpdate {
                    state: Some("succeeded".into()),
                    progress: UpdateField::Unchanged,
                    message: UpdateField::Set("saved".into()),
                    result: Some(json!({"saved":true})),
                }),
            })
            .unwrap();
        let before = queue.repository.get(&id).unwrap();
        let ticks = queue.clock.0.get();
        queue
            .execute(JobCommand::Mutate {
                id: id.clone(),
                expected_attempt: Some(1),
                mutation: JobMutation::Update(JobUpdate {
                    state: Some("succeeded".into()),
                    progress: UpdateField::Invalid,
                    message: UpdateField::Invalid,
                    result: Some(json!({"token":"late"})),
                }),
            })
            .unwrap();
        assert_eq!(
            to_value(queue.repository.get(&id).unwrap()).unwrap(),
            to_value(before).unwrap()
        );
        assert_eq!(queue.clock.0.get(), ticks);
        assert!(queue
            .execute(JobCommand::Mutate {
                id,
                expected_attempt: Some(0),
                mutation: JobMutation::Cancel
            })
            .is_err());
    }

    #[test]
    fn paid_retry_keeps_quota_gate_until_explicit_confirmation() {
        let queue = queue();
        let mut input = definition("a");
        input.paid = true;
        input.config = json!({"command":"example", "settings":{"mode":"cloud","cloudProvider":"chatgpt","chatGPTAccountID":"account"}});
        let id = submit(&queue, input).id;
        claim(&queue, &id).unwrap();
        queue.execute(JobCommand::Mutate { id: id.clone(), expected_attempt: Some(1),
            mutation: JobMutation::Update(JobUpdate { state: Some("failed".into()), progress: UpdateField::Unchanged,
                message: UpdateField::Set("ChatGPT: HTTP 429 · subscription_sharing_usage_limit_exceeded. Retry later.".into()), result: None }) }).unwrap();
        assert_eq!(queue.repository.state.borrow().pauses["account"], id);
        let ticks = queue.clock.0.get();
        assert!(queue
            .execute(JobCommand::Mutate {
                id: id.clone(),
                expected_attempt: Some(1),
                mutation: JobMutation::Retry {
                    confirm_paid: false
                }
            })
            .is_err());
        assert_eq!(queue.repository.get(&id).unwrap().state, "failed");
        assert_eq!(queue.repository.state.borrow().pauses["account"], id);
        assert_eq!(queue.clock.0.get(), ticks);
        queue
            .execute(JobCommand::Mutate {
                id: id.clone(),
                expected_attempt: Some(1),
                mutation: JobMutation::Retry { confirm_paid: true },
            })
            .unwrap();
        assert!(queue.repository.state.borrow().pauses.is_empty());
        assert_eq!(claim(&queue, &id).unwrap().attempt, 2);
        queue.execute(JobCommand::Recover).unwrap();
        assert_eq!(queue.repository.get(&id).unwrap().state, "interrupted");
        assert!(claim(&queue, &id).is_none());
    }
}
