//! Task metadata and references share the canonical notes transaction. Files and
//! repositories are references only; no task operation traverses external paths.
use crate::notes::{self, CapturedNote, NotesWorkspace};
use crate::storage;
use anyhow::{bail, ensure, Context, Result};
use chrono::Utc;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::Path;
use uuid::Uuid;

const CONFLICT: &str =
    "Задача или её контекст изменились. Обновите данные перед повтором; ваши изменения сохранены.";
const MAX_EVENTS: usize = 500;
const FULL_OPERATIONS: usize = 64;
const MAX_OPERATION_BYTES: usize = 4 * 1_048_576;
const MAX_CONTEXT: usize = 180_000;
fn now() -> f64 {
    Utc::now().timestamp_millis() as f64 / 1000.0
}
fn uuid() -> String {
    Uuid::new_v4().to_string()
}
fn hash(value: &Value) -> String {
    format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(value).expect("JSON"))
    )
}
fn valid_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn bounded(s: &str, max: usize) -> bool {
    s.len() <= max && !s.contains('\0')
}
fn title(note: &CapturedNote) -> String {
    if note.title.trim().is_empty() {
        note.text
            .lines()
            .find(|s| !s.trim().is_empty())
            .unwrap_or("Задача")
            .chars()
            .take(150)
            .collect()
    } else {
        note.title.clone()
    }
}
fn str_field<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key].as_str().with_context(|| format!("Нет поля {key}"))
}
fn bump(note: &mut CapturedNote) -> Result<()> {
    note.revision = note
        .revision
        .checked_add(1)
        .context("Слишком большая ревизия")?;
    note.updated_at = now();
    Ok(())
}
fn checked_url(s: &str) -> bool {
    s.is_empty()
        || reqwest::Url::parse(s).is_ok_and(|u| {
            matches!(u.scheme(), "http" | "https")
                && !u.host_str().unwrap_or("").is_empty()
                && u.username().is_empty()
                && u.password().is_none()
        })
}

mod types;
pub use types::*;

fn event(kind: &str, text: &str, actor: &str) -> TaskEvent {
    TaskEvent {
        id: uuid(),
        kind: kind.into(),
        text: text.into(),
        actor: actor.into(),
        created_at: now(),
        artifacts: vec![],
        snapshot: None,
        claim_id: None,
    }
}
fn add_event(record: &mut TaskRecord, e: TaskEvent) -> Result<()> {
    record.history.push(e);
    trim_history(record)
}
fn trim_history(record: &mut TaskRecord) -> Result<()> {
    while record.history.len() > MAX_EVENTS
        || serde_json::to_vec(&record.history)?.len() > 1_048_576
    {
        let last_report = record.history.iter().rposition(|e| e.kind == "report");
        let removable = record
            .history
            .iter()
            .enumerate()
            .position(|(i, e)| {
                let claimed = record
                    .claim
                    .as_ref()
                    .is_some_and(|c| e.kind == "claimed" && e.created_at >= c.claimed_at);
                !claimed && !(record.claim.is_some() && Some(i) == last_report)
            })
            .context("Слишком большой результат задачи")?;
        record.history.remove(removable);
    }
    Ok(())
}
fn record_for(workspace: &NotesWorkspace, id: &str) -> TaskRecord {
    if let Some(r) = workspace.task_workspaces.iter().find(|r| r.note_id == id) {
        return r.clone();
    }
    let mut r = TaskRecord {
        note_id: id.into(),
        status: "todo".into(),
        source: "local".into(),
        ..Default::default()
    };
    if let Some(note) = workspace.notes.iter().find(|n| n.id == id) {
        if let Some(o) = &note.task_origin {
            let refs = o["segmentIDs"]
                .as_array()
                .map(|ids| {
                    ids.iter()
                        .filter_map(Value::as_u64)
                        .take(200)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            if let Some(meeting) = o["meetingID"].as_str() {
                r.materials.push(TaskMaterial {
                    id: format!("source-{}", hash(o)),
                    kind: "meeting".into(),
                    title: "Источник задачи".into(),
                    meeting_id: Some(meeting.into()),
                    segment_ids: refs,
                    created_at: note.created_at,
                    ..Default::default()
                });
            }
        }
    }
    r
}
fn effective_status(note: &CapturedNote, r: &TaskRecord) -> String {
    if note.completed {
        "done".into()
    } else if ["todo", "doing", "blocked"].contains(&r.status.as_str()) {
        r.status.clone()
    } else {
        "todo".into()
    }
}
fn save_record(workspace: &mut NotesWorkspace, record: TaskRecord) {
    if let Some(i) = workspace
        .task_workspaces
        .iter()
        .position(|r| r.note_id == record.note_id)
    {
        workspace.task_workspaces[i] = record;
    } else {
        workspace.task_workspaces.push(record);
    }
}
fn canonical_id(id: &str) -> &str {
    id.strip_prefix("manual:").unwrap_or(id)
}

pub(crate) fn validate_workspace(workspace: &NotesWorkspace) -> Result<()> {
    ensure!(
        workspace.task_workspaces.len() <= 10_000 && workspace.task_plans.len() <= 100,
        "Слишком много данных задач"
    );
    let mut ids = HashSet::new();
    for r in &workspace.task_workspaces {
        ensure!(
            valid_id(&r.note_id) && ids.insert(&r.note_id),
            "Некорректная задача в рабочей области"
        );
        ensure!(
            ["todo", "doing", "blocked", "done"].contains(&r.status.as_str())
                && ["local", "manual", "yandex", "google"].contains(&r.source.as_str()),
            "Некорректный статус или источник задачи"
        );
        ensure!(
            bounded(&r.external_url, 4096)
                && checked_url(&r.external_url)
                && bounded(&r.project, 512)
                && r.materials.len() <= 200
                && r.history.len() <= MAX_EVENTS,
            "Некорректные материалы задачи"
        );
        let mut mids = HashSet::new();
        for m in &r.materials {
            validate_material(m)?;
            ensure!(mids.insert(&m.id), "Повторный материал задачи");
        }
        for e in &r.history {
            ensure!(
                valid_id(&e.id)
                    && bounded(&e.kind, 80)
                    && bounded(&e.text, 20_000)
                    && bounded(&e.actor, 256)
                    && e.created_at.is_finite()
                    && e.created_at >= 0.0,
                "Некорректное событие задачи"
            );
            validate_artifacts(&e.artifacts)?;
            if let Some(s) = &e.snapshot {
                ensure!(
                    serde_json::to_vec(s)?.len() <= MAX_CONTEXT + 20_000,
                    "Слишком большой снимок контекста"
                );
            }
        }
        if let Some(c) = &r.claim {
            ensure!(
                valid_id(&c.id)
                    && bounded(&c.agent_id, 256)
                    && !c.agent_id.is_empty()
                    && c.claimed_at.is_finite()
                    && c.context_version.len() == 64,
                "Некорректное принятие задачи агентом"
            );
        }
    }
    Ok(())
}
fn validate_material(m: &TaskMaterial) -> Result<()> {
    ensure!(
        valid_id(&m.id)
            && ["note", "meeting", "file", "folder", "repository", "link"]
                .contains(&m.kind.as_str())
            && bounded(&m.title, 1024)
            && !m.title.trim().is_empty(),
        "Некорректный материал задачи"
    );
    ensure!(
        m.segment_ids.len() <= 200 && m.created_at.is_finite() && m.created_at >= 0.0,
        "Некорректный источник материала"
    );
    if let Some(id) = &m.note_id {
        ensure!(valid_id(id), "Некорректная заметка материала");
    }
    if let Some(id) = &m.meeting_id {
        ensure!(valid_id(id), "Некорректная встреча материала");
    }
    if let Some(id) = &m.attachment_id {
        ensure!(valid_id(id), "Некорректное вложение материала");
    }
    if let Some(path) = &m.path {
        ensure!(
            bounded(path, 4096) && !path.trim().is_empty(),
            "Некорректная ссылка на папку"
        );
    }
    if let Some(url) = &m.url {
        ensure!(
            bounded(url, 4096) && checked_url(url) && !url.is_empty(),
            "Используйте ссылку HTTP или HTTPS без пароля"
        );
    }
    ensure!(
        match m.kind.as_str() {
            "note" => m.note_id.is_some(),
            "file" => m.note_id.is_some() && m.attachment_id.is_some(),
            "meeting" => m.meeting_id.is_some(),
            "folder" => m.path.is_some(),
            "repository" => m.path.is_some() || m.url.is_some(),
            "link" => m.url.is_some(),
            _ => false,
        },
        "Укажите источник материала"
    );
    Ok(())
}
fn validate_artifacts(items: &[TaskArtifact]) -> Result<()> {
    ensure!(
        items.len() <= 20,
        "За один раз можно сохранить до 20 результатов"
    );
    for a in items {
        ensure!(
            valid_id(&a.id)
                && bounded(&a.title, 1024)
                && bounded(&a.kind, 80)
                && bounded(&a.text, 30_000)
                && a.url.as_deref().is_none_or(checked_url),
            "Некорректный результат агента"
        );
    }
    ensure!(
        serde_json::to_vec(items)?.len() <= 90_000,
        "Результаты агента слишком большие"
    );
    Ok(())
}
fn source_rows(root: &Path, meeting_id: &str, ids: &[u64]) -> Result<(String, String)> {
    let dir = storage::meeting_directory(root, meeting_id)?;
    let _lock = storage::meeting_lock(&dir)?;
    let meta = storage::regular_json(&dir.join("meta.json"))?;
    ensure!(
        meta["id"].as_str() == Some(meeting_id),
        "Встреча недоступна"
    );
    if ids.is_empty() {
        return Ok((String::new(), hash(&meta)));
    }
    ensure!(
        std::fs::symlink_metadata(dir.join("transcript.json"))?.len() <= 64 * 1_048_576,
        "Транскрипция слишком большая"
    );
    let transcript = storage::regular_json(&dir.join("transcript.json"))?;
    let segments = transcript["segments"]
        .as_array()
        .context("Нет исходных реплик")?;
    let mut selected = Vec::new();
    for id in ids {
        let found = segments
            .iter()
            .filter(|s| s["id"].as_u64() == Some(*id))
            .collect::<Vec<_>>();
        ensure!(
            found.len() == 1,
            "Исходная реплика изменилась или недоступна"
        );
        selected.push(found[0].clone());
    }
    Ok((
        serde_json::to_string(&selected)?,
        hash(&json!([meta["title"], selected])),
    ))
}
fn material_view(
    root: &Path,
    workspace: &NotesWorkspace,
    material: &TaskMaterial,
) -> TaskMaterialView {
    let mut v = TaskMaterialView {
        material: material.clone(),
        text: None,
        available: true,
        note_revision: None,
        source_fingerprint: None,
    };
    match material.kind.as_str() {
        "note" | "file" => {
            if let Some(note) = workspace
                .notes
                .iter()
                .find(|n| Some(&n.id) == material.note_id.as_ref() && n.trashed_at.is_none())
            {
                v.note_revision = Some(note.revision);
                if material.kind == "file" {
                    if let Some(a) = note
                        .attachments
                        .iter()
                        .find(|a| Some(&a.id) == material.attachment_id.as_ref())
                    {
                        v.material.title = a.name.clone();
                        v.text = Some(a.extracted_text.clone());
                    } else {
                        v.available = false;
                    }
                } else {
                    v.material.title = title(note);
                    v.text = Some(note.text.clone());
                }
            } else {
                v.available = false;
            }
        }
        "meeting" => match source_rows(
            root,
            material.meeting_id.as_deref().unwrap_or(""),
            &material.segment_ids,
        ) {
            Ok((text, stamp)) => {
                v.text = Some(text);
                v.source_fingerprint = Some(stamp);
            }
            Err(_) => v.available = false,
        },
        // Do not stat, enumerate or open a workspace path. The host agent owns
        // its independent filesystem grant; this app only shares a reference.
        "folder" | "repository" | "link" => {}
        _ => v.available = false,
    }
    v
}
fn note_details(root: &Path, workspace: &NotesWorkspace, note: &CapturedNote) -> TaskDetails {
    note_details_mode(root, workspace, note, true)
}
fn note_details_mode(
    root: &Path,
    workspace: &NotesWorkspace,
    note: &CapturedNote,
    include_details: bool,
) -> TaskDetails {
    let r = record_for(workspace, &note.id);
    let status = effective_status(note, &r);
    let project = if r.project.is_empty() {
        workspace
            .contexts
            .iter()
            .find(|c| Some(&c.meeting_id) == note.meeting_id.as_ref())
            .map(|c| c.project.clone())
            .unwrap_or_default()
    } else {
        r.project.clone()
    };
    let mut history = if include_details {
        r.history.clone()
    } else {
        vec![]
    };
    if include_details {
        history.extend(note.history.iter().filter_map(|h| {
            Some(TaskEvent {
                id: h["id"].as_str()?.into(),
                kind: "legacy".into(),
                text: h["text"].as_str()?.into(),
                actor: "user".into(),
                created_at: h["createdAt"].as_f64()?,
                artifacts: vec![],
                snapshot: None,
                claim_id: None,
            })
        }));
    }
    history.reverse();
    history.sort_by(|a, b| b.created_at.total_cmp(&a.created_at));
    TaskDetails {
        id: format!("manual:{}", note.id),
        title: title(note),
        text: note.text.clone(),
        status,
        completed: note.completed,
        owner: note.owner.clone(),
        due: note.due.clone(),
        source: r.source,
        external_url: r.external_url,
        project,
        revision: note.revision,
        created_at: note.created_at,
        updated_at: note.updated_at,
        virtual_task: false,
        meeting_id: note.meeting_id.clone(),
        source_fingerprint: note.task_origin.as_ref().map(hash).unwrap_or_default(),
        materials: if include_details {
            r.materials
                .iter()
                .map(|m| material_view(root, workspace, m))
                .collect()
        } else {
            vec![]
        },
        material_count: r.materials.len(),
        history_count: r.history.len() + note.history.len(),
        history,
        agent_access: r.agent_access,
        claim: r.claim,
    }
}
fn summary_task(root: &Path, workspace: &NotesWorkspace, id: &str) -> Result<(TaskDetails, Value)> {
    let parts = id.split(':').collect::<Vec<_>>();
    ensure!(
        parts.len() == 3 && parts[0] == "summary" && valid_id(parts[1]) && parts[2].len() == 64,
        "Некорректный ID задачи"
    );
    let dir = storage::meeting_directory(root, parts[1])?;
    let _lock = storage::meeting_lock(&dir)?;
    let meta = storage::regular_json(&dir.join("meta.json"))?;
    ensure!(
        meta["id"].as_str() == Some(parts[1]),
        "Задача больше не существует"
    );
    ensure!(
        std::fs::symlink_metadata(dir.join("summary.json"))?.len() <= 8 * 1_048_576,
        "Конспект слишком большой"
    );
    let summary = storage::regular_json(&dir.join("summary.json"))?;
    let item = summary["items"]
        .as_array()
        .context("Задача больше не существует")?
        .iter()
        .find(|i| i["kind"] == "action" && notes::task_signature(i) == parts[2])
        .context("Задача конспекта изменилась")?
        .clone();
    let origin = json!({"meetingID":parts[1],"itemSignature":parts[2],"sourceText":item["text"],"segmentIDs":item["segmentIDs"],"summaryTaskID":id});
    if let Some(note) = workspace.notes.iter().find(|n| {
        n.kind == "task"
            && n.task_origin
                .as_ref()
                .is_some_and(|o| o["meetingID"] == parts[1] && o["itemSignature"] == parts[2])
    }) {
        ensure!(note.trashed_at.is_none(), "Задача находится в Корзине или уже удалена. Восстановите её, чтобы продолжить.");
        return Ok((note_details(root, workspace, note), origin));
    }
    Ok((
        virtual_details(workspace, id, parts[1], &meta, &item)?,
        origin,
    ))
}
fn virtual_details(
    workspace: &NotesWorkspace,
    id: &str,
    meeting_id: &str,
    meta: &Value,
    item: &Value,
) -> Result<TaskDetails> {
    let text = item["text"]
        .as_str()
        .context("Нет текста задачи")?
        .to_owned();
    let insight = format!(
        "action-{}-{text}",
        item["segmentIDs"]
            .as_array()
            .unwrap_or(&vec![])
            .iter()
            .filter_map(Value::as_u64)
            .map(|id| id.to_string())
            .collect::<Vec<_>>()
            .join("-")
    );
    let completed = meta["completedTasks"]
        .as_array()
        .is_some_and(|items| items.iter().any(|v| v.as_str() == Some(&insight)));
    Ok(TaskDetails {
        id: id.into(),
        title: text
            .lines()
            .next()
            .unwrap_or("Задача")
            .chars()
            .take(150)
            .collect(),
        text,
        status: if completed { "done" } else { "todo" }.into(),
        completed,
        owner: item["owner"].as_str().unwrap_or("").into(),
        due: item["due"].as_str().unwrap_or("").into(),
        source: "local".into(),
        external_url: String::new(),
        project: workspace
            .contexts
            .iter()
            .find(|c| c.meeting_id == meeting_id)
            .map(|c| c.project.clone())
            .unwrap_or_default(),
        revision: 0,
        created_at: meta["createdAt"].as_f64().unwrap_or(0.0),
        updated_at: meta["createdAt"].as_f64().unwrap_or(0.0),
        virtual_task: true,
        meeting_id: Some(meeting_id.into()),
        source_fingerprint: hash(&item),
        materials: vec![],
        history: vec![],
        material_count: 0,
        history_count: 0,
        agent_access: AgentAccess::default(),
        claim: None,
    })
}
fn details(root: &Path, workspace: &NotesWorkspace, id: &str) -> Result<TaskDetails> {
    if let Some(note) = workspace
        .notes
        .iter()
        .find(|n| n.id == canonical_id(id) && n.kind == "task" && n.trashed_at.is_none())
    {
        return Ok(note_details(root, workspace, note));
    }
    if id.starts_with("summary:") {
        // A materialized task remains addressable through its source alias even
        // after summary regeneration removes the original item.
        if let Some(note) = workspace.notes.iter().find(|n| {
            n.kind == "task"
                && n.trashed_at.is_none()
                && n.task_origin
                    .as_ref()
                    .is_some_and(|o| o["summaryTaskID"] == id)
        }) {
            return Ok(note_details(root, workspace, note));
        }
        return Ok(summary_task(root, workspace, id)?.0);
    }
    bail!("Задача больше не существует")
}
fn materialize(root: &Path, workspace: &mut NotesWorkspace, id: &str) -> Result<usize> {
    let d = details(root, workspace, id)?;
    if !d.virtual_task {
        return workspace
            .notes
            .iter()
            .position(|n| n.id == canonical_id(&d.id))
            .context("Задача недоступна");
    }
    let (_, origin) = summary_task(root, workspace, id)?;
    let note: CapturedNote = serde_json::from_value(
        json!({"id":uuid(),"kind":"task","title":d.title,"text":d.text,"owner":d.owner,"due":d.due,"completed":d.completed,"meetingID":d.meeting_id,"createdAt":now(),"updatedAt":now(),"revision":1,"taskOrigin":origin}),
    )?;
    workspace.notes.push(note);
    Ok(workspace.notes.len() - 1)
}
fn context(root: &Path, workspace: &NotesWorkspace, id: &str, agent: bool) -> Result<TaskContext> {
    context_mask(root, workspace, id, agent, agent)
}
fn context_mask(
    root: &Path,
    workspace: &NotesWorkspace,
    id: &str,
    agent: bool,
    shared_only: bool,
) -> Result<TaskContext> {
    let mut task = details(root, workspace, id)?;
    if agent {
        ensure!(
            workspace.task_integration.enabled && task.agent_access.enabled,
            "Доступ агента к задаче выключен"
        );
    }
    task.history.clear();
    task.history_count = 0;
    task.materials.retain(|m| !shared_only || m.material.shared);
    task.material_count = task.materials.len();
    // The fingerprint covers complete source values before response truncation.
    // History and claim metadata are excluded: they are not task evidence.
    let manifest = json!({"task":[task.id,task.revision,task.source_fingerprint,task.title,task.text,task.status,task.owner,task.due,task.project,task.agent_access.enabled],"materials":task.materials});
    let materials = std::mem::take(&mut task.materials);
    let mut c = TaskContext {
        task,
        materials,
        context_version: hash(&manifest),
        generated_at: now(),
        truncated: false,
    };
    while serde_json::to_vec(&c)?.len() > MAX_CONTEXT {
        if let Some(text) = c
            .materials
            .iter_mut()
            .filter_map(|m| m.text.as_mut())
            .max_by_key(|t| t.len())
            .filter(|t| !t.is_empty())
        {
            let mut end = text.len() / 2;
            while !text.is_char_boundary(end) {
                end -= 1;
            }
            text.truncate(end);
        } else if !c.task.text.is_empty() {
            let mut end = c.task.text.len() / 2;
            while !c.task.text.is_char_boundary(end) {
                end -= 1;
            }
            c.task.text.truncate(end);
        } else {
            bail!("Слишком много материалов в контексте задачи");
        }
        c.truncated = true;
    }
    Ok(c)
}
fn require_revision(d: &TaskDetails, input: &Value) -> Result<()> {
    ensure!(
        input["expectedRevision"].as_u64() == Some(d.revision),
        CONFLICT
    );
    if d.virtual_task {
        ensure!(
            input["expectedSourceFingerprint"].as_str() == Some(d.source_fingerprint.as_str()),
            CONFLICT
        );
    } else if let Some(stamp) = input["expectedSourceFingerprint"].as_str() {
        ensure!(stamp == d.source_fingerprint, CONFLICT);
    }
    Ok(())
}
fn operation_fingerprint(input: &Value) -> String {
    let mut v = input.clone();
    if let Some(o) = v.as_object_mut() {
        o.remove("root");
    }
    hash(&v)
}
fn replay(workspace: &NotesWorkspace, input: &Value) -> Result<Option<Value>> {
    let id = str_field(input, "operationID")?;
    ensure!(valid_id(id), "Некорректный ID операции");
    if let Some(old) = workspace
        .task_operations
        .iter()
        .find(|o| o["operationID"] == id)
    {
        ensure!(
            old["fingerprint"].as_str() == Some(operation_fingerprint(input).as_str()),
            "Этот ID операции уже использован с другим содержимым"
        );
        ensure!(old["undone"] != true, "Эта операция уже отменена");
        ensure!(
            old["expired"] != true,
            "Срок безопасного повтора операции истёк. Перечитайте задачу перед новым действием."
        );
        return Ok(Some(old["result"].clone()));
    }
    Ok(None)
}
fn remember(
    workspace: &mut NotesWorkspace,
    input: &Value,
    result: Value,
    before: Value,
    after: Value,
) -> Result<Value> {
    let mut receipt = json!({"operationID":input["operationID"],"fingerprint":operation_fingerprint(input),"result":result,"before":before,"after":after,"createdAt":now(),"undone":false});
    if input["command"] == "task-batch-apply" {
        let mut request = input.clone();
        if let Some(o) = request.as_object_mut() {
            o.remove("root");
        }
        receipt["request"] = request;
    }
    workspace.task_operations.push(receipt);
    // Keep recent undo data; older IDs remain compact tombstones so replay can
    // never create a second task after retention expires.
    let mut full = workspace
        .task_operations
        .iter()
        .filter(|o| o["expired"] != true)
        .count();
    let mut bytes = serde_json::to_vec(&workspace.task_operations)?.len();
    let last = workspace.task_operations.len() - 1;
    for i in 0..last {
        if full <= FULL_OPERATIONS && bytes <= MAX_OPERATION_BYTES {
            break;
        }
        if workspace.task_operations[i]["expired"] == true {
            continue;
        }
        let old = &workspace.task_operations[i];
        let old_len = serde_json::to_vec(old)?.len();
        let compact = json!({"operationID":old["operationID"],"fingerprint":old["fingerprint"],"expired":true,"undone":old["undone"]});
        bytes = bytes.saturating_sub(old_len) + serde_json::to_vec(&compact)?.len();
        full -= 1;
        workspace.task_operations[i] = compact;
    }
    Ok(result)
}

fn task_state(workspace: &NotesWorkspace, id: &str) -> Value {
    let n = workspace.notes.iter().find(|n| n.id == canonical_id(id));
    json!({"note":n,"record":workspace.task_workspaces.iter().find(|r|r.note_id==canonical_id(id))})
}
fn persist(root: &Path, workspace: &NotesWorkspace) -> Result<()> {
    notes::persist(&notes::directory(root)?, workspace)
}
fn create(root: &Path, workspace: &mut NotesWorkspace, input: &Value) -> Result<Value> {
    if let Some(result) = replay(workspace, input)? {
        return Ok(result);
    }
    let name = str_field(input, "title")?.trim();
    let text = input["text"].as_str().unwrap_or("");
    ensure!(
        !name.is_empty() && bounded(name, 1024) && bounded(text, 100_000),
        "Укажите название и сократите слишком длинный текст задачи"
    );
    let source = input["source"].as_str().unwrap_or("local");
    let url = input["externalURL"].as_str().unwrap_or("");
    ensure!(
        ["local", "manual", "yandex", "google"].contains(&source) && checked_url(url),
        "Некорректный источник или ссылка задачи"
    );
    let id = uuid();
    let t = now();
    let note: CapturedNote = serde_json::from_value(
        json!({"id":id,"kind":"task","title":name,"text":text,"owner":input["owner"].as_str().unwrap_or(""),"due":input["due"].as_str().unwrap_or(""),"completed":false,"revision":1,"createdAt":t,"updatedAt":t}),
    )?;
    let mut r = TaskRecord {
        note_id: id.clone(),
        status: "todo".into(),
        source: source.into(),
        external_url: url.into(),
        project: input["project"].as_str().unwrap_or("").into(),
        ..Default::default()
    };
    add_event(&mut r, event("created", "Задача создана", "user"))?;
    workspace.notes.push(note);
    save_record(workspace, r);
    let result = serde_json::to_value(details(root, workspace, &id)?)?;
    remember(
        workspace,
        input,
        result,
        Value::Null,
        task_state(workspace, &id),
    )
}
fn update(root: &Path, workspace: &mut NotesWorkspace, input: &Value) -> Result<Value> {
    if let Some(result) = replay(workspace, input)? {
        return Ok(result);
    }
    let id = str_field(input, "taskID")?;
    let d = details(root, workspace, id)?;
    require_revision(&d, input)?;
    let before = if d.virtual_task {
        Value::Null
    } else {
        task_state(workspace, &d.id)
    };
    let index = materialize(root, workspace, id)?;
    let note_id = workspace.notes[index].id.clone();
    let mut r = record_for(workspace, &note_id);
    let patch = input["patch"].as_object().context("Нет изменений задачи")?;
    ensure!(
        !patch.is_empty()
            && patch.keys().all(|k| [
                "title",
                "text",
                "status",
                "due",
                "owner",
                "project",
                "source",
                "externalURL",
                "agentAccess"
            ]
            .contains(&k.as_str())),
        "Неизвестное поле задачи"
    );
    for (key, value) in patch {
        match key.as_str() {
            "status" => {
                let status = value.as_str().context("Нет статуса задачи")?;
                ensure!(
                    ["todo", "doing", "blocked", "done"].contains(&status),
                    "Неизвестный статус задачи"
                );
                r.status = status.into();
                workspace.notes[index].completed = status == "done";
                if status != "doing" {
                    r.claim = None;
                }
            }
            "source" => {
                let s = value.as_str().context("Нет источника задачи")?;
                ensure!(
                    ["local", "manual", "yandex", "google"].contains(&s),
                    "Неизвестный источник задачи"
                );
                r.source = s.into();
            }
            "externalURL" => {
                let u = value.as_str().context("Нет ссылки")?;
                ensure!(
                    checked_url(u) && bounded(u, 4096),
                    "Используйте HTTP или HTTPS ссылку без пароля"
                );
                r.external_url = u.into();
            }
            "project" => {
                let p = value.as_str().context("Нет проекта")?;
                ensure!(bounded(p, 512), "Название проекта слишком длинное");
                r.project = p.into();
            }
            "agentAccess" => {
                let access: AgentAccess =
                    serde_json::from_value(value.clone()).context("Некорректный доступ агента")?;
                if !access.enabled {
                    r.claim = None;
                }
                r.agent_access = access;
            }
            _ => {
                let s = value.as_str().context("Поле задачи должно быть текстом")?;
                ensure!(
                    bounded(s, if key == "text" { 100_000 } else { 1024 }),
                    "Текст задачи слишком длинный"
                );
                let n = &mut workspace.notes[index];
                match key.as_str() {
                    "title" => {
                        ensure!(!s.trim().is_empty(), "Укажите название задачи");
                        n.title = s.into();
                    }
                    "text" => {
                        n.text = s.into();
                        n.content_rtf.clear();
                        n.expansion = None;
                    }
                    "due" => n.due = s.into(),
                    "owner" => n.owner = s.into(),
                    _ => unreachable!(),
                }
            }
        }
    }
    bump(&mut workspace.notes[index])?;
    add_event(&mut r, event("updated", "Задача обновлена", "user"))?;
    save_record(workspace, r);
    let result = serde_json::to_value(details(root, workspace, &note_id)?)?;
    remember(
        workspace,
        input,
        result,
        before,
        task_state(workspace, &note_id),
    )
}
fn link(root: &Path, workspace: &mut NotesWorkspace, input: &Value, unlink: bool) -> Result<Value> {
    if let Some(result) = replay(workspace, input)? {
        return Ok(result);
    }
    let id = str_field(input, "taskID")?;
    let d = details(root, workspace, id)?;
    require_revision(&d, input)?;
    let before = if d.virtual_task {
        Value::Null
    } else {
        task_state(workspace, &d.id)
    };
    let index = materialize(root, workspace, id)?;
    let note_id = workspace.notes[index].id.clone();
    let mut r = record_for(workspace, &note_id);
    let mut created = Value::Null;
    if unlink {
        let id = str_field(input, "materialID")?;
        let at = r
            .materials
            .iter()
            .position(|m| m.id == id)
            .context("Материал уже откреплён")?;
        r.materials.remove(at);
        add_event(
            &mut r,
            event("materialUnlinked", "Материал откреплён от задачи", "user"),
        )?;
    } else {
        let raw = input.get("material").context("Нет материала")?;
        if let Some(at) = raw["id"]
            .as_str()
            .and_then(|id| r.materials.iter().position(|m| m.id == id))
        {
            ensure!(
                raw.as_object().is_some_and(|o| o
                    .keys()
                    .all(|k| ["id", "shared", "title"].contains(&k.as_str()))),
                "Существующий материал можно переименовать или изменить его доступ"
            );
            if let Some(shared) = raw["shared"].as_bool() {
                r.materials[at].shared = shared;
            }
            if let Some(title) = raw["title"].as_str() {
                ensure!(
                    !title.trim().is_empty() && bounded(title, 1024),
                    "Укажите название материала"
                );
                r.materials[at].title = title.into();
            }
            add_event(
                &mut r,
                event("materialAccess", "Доступ к материалу обновлён", "user"),
            )?;
        } else {
            let mut m: TaskMaterial =
                serde_json::from_value(raw.clone()).context("Некорректный материал")?;
            m.id = uuid();
            m.created_at = now();
            if m.kind == "note" && m.note_id.is_none() {
                let text = str_field(raw, "text")?.trim();
                ensure!(
                    !text.is_empty() && bounded(text, 100_000),
                    "Введите мысль к задаче"
                );
                let n: CapturedNote = serde_json::from_value(
                    json!({"id":uuid(),"kind":"note","title":m.title,"text":text,"meetingID":workspace.notes[index].meeting_id,"createdAt":now(),"updatedAt":now(),"revision":1}),
                )?;
                m.note_id = Some(n.id.clone());
                created = serde_json::to_value(&n)?;
                workspace.notes.push(n);
            }
            validate_material(&m)?;
            if ["note", "file"].contains(&m.kind.as_str()) {
                let n = workspace
                    .notes
                    .iter()
                    .find(|n| Some(&n.id) == m.note_id.as_ref() && n.trashed_at.is_none())
                    .context("Заметка больше не существует")?;
                ensure!(
                    n.id != note_id,
                    "Задача не может быть собственным материалом"
                );
                if m.kind == "file" {
                    ensure!(
                        n.attachments
                            .iter()
                            .any(|a| Some(&a.id) == m.attachment_id.as_ref()),
                        "Вложение больше не существует"
                    );
                }
            }
            if m.kind == "meeting" {
                source_rows(root, m.meeting_id.as_deref().unwrap_or(""), &m.segment_ids)?;
            }
            ensure!(r.materials.len() < 200, "В задаче уже 200 материалов");
            ensure!(
                !r.materials.iter().any(|old| old.kind == m.kind
                    && old.note_id == m.note_id
                    && old.meeting_id == m.meeting_id
                    && old.segment_ids == m.segment_ids
                    && old.attachment_id == m.attachment_id
                    && old.path == m.path
                    && old.url == m.url),
                "Этот материал уже прикреплён"
            );
            r.materials.push(m);
            add_event(
                &mut r,
                event("materialLinked", "Материал прикреплён к задаче", "user"),
            )?;
        }
    }
    bump(&mut workspace.notes[index])?;
    save_record(workspace, r);
    let result = serde_json::to_value(details(root, workspace, &note_id)?)?;
    let mut after = task_state(workspace, &note_id);
    after["createdNote"] = created;
    remember(workspace, input, result, before, after)
}
fn agent_action(
    root: &Path,
    workspace: &mut NotesWorkspace,
    input: &Value,
    command: &str,
) -> Result<Value> {
    let id = str_field(input, "taskID")?;
    let d = details(root, workspace, id)?;
    ensure!(
        workspace.task_integration.enabled && d.agent_access.enabled,
        "Доступ агента к задаче выключен"
    );
    if let Some(result) = replay(workspace, input)? {
        return Ok(result);
    }
    require_revision(&d, input)?;
    if command != "task-agent-claim" {
        ensure!(
            d.status == "doing" && !d.completed,
            "Задача больше не находится в работе. Обновите её состояние перед действием агента."
        );
    }
    let actor = str_field(input, "agentID")?;
    ensure!(
        !actor.trim().is_empty() && bounded(actor, 256),
        "Укажите агента"
    );
    let current_context = context(root, workspace, id, true)?;
    if ["task-agent-claim", "task-agent-complete"].contains(&command) {
        ensure!(
            input["expectedContextVersion"].as_str()
                == Some(current_context.context_version.as_str()),
            CONFLICT
        );
    }
    let index = materialize(root, workspace, id)?;
    let note_id = workspace.notes[index].id.clone();
    let mut r = record_for(workspace, &note_id);
    let before = task_state(workspace, &note_id);
    if command == "task-agent-claim" {
        ensure!(
            r.claim.is_none(),
            "Задача уже принята агентом. Сначала освободите её."
        );
        ensure!(d.status != "done", "Задача уже завершена");
        r.claim = Some(TaskClaim {
            id: uuid(),
            agent_id: actor.into(),
            claimed_at: now(),
            context_version: current_context.context_version.clone(),
        });
        r.status = "doing".into();
        workspace.notes[index].completed = false;
        let mut e = event("claimed", "Агент принял задачу в работу", actor);
        e.claim_id = r.claim.as_ref().map(|c| c.id.clone());
        e.snapshot = Some(serde_json::to_value(&current_context)?);
        add_event(&mut r, e)?;
    } else {
        let claim = r
            .claim
            .as_ref()
            .context("Сначала примите задачу в работу")?;
        ensure!(
            input["claimID"].as_str() == Some(claim.id.as_str()) && claim.agent_id == actor,
            "Задача принята другим запуском агента"
        );
        match command {
            "task-agent-progress" | "task-agent-report" => {
                let text = input["text"].as_str().unwrap_or("");
                ensure!(bounded(text, 20_000), "Сократите сообщение агента");
                let mut artifacts: Vec<TaskArtifact> = serde_json::from_value(
                    input.get("artifacts").cloned().unwrap_or_else(|| json!([])),
                )?;
                for a in &mut artifacts {
                    if a.id.is_empty() {
                        a.id = uuid();
                    }
                }
                validate_artifacts(&artifacts)?;
                ensure!(
                    !text.trim().is_empty() || !artifacts.is_empty(),
                    "Добавьте описание или результат работы"
                );
                let mut e = event(
                    if command == "task-agent-report" {
                        "report"
                    } else {
                        "progress"
                    },
                    text,
                    actor,
                );
                e.claim_id = r.claim.as_ref().map(|c| c.id.clone());
                e.artifacts = artifacts;
                add_event(&mut r, e)?;
            }
            "task-agent-complete" => {
                ensure!(r.history.iter().rfind(|e|e.kind=="report"&&e.claim_id.as_deref()==Some(claim.id.as_str())).is_some_and(|e|e.snapshot.as_ref().is_some_and(|s|s["contextVersion"]==current_context.context_version)),"Контекст изменился после отчёта. Учтите изменения и сохраните новый отчёт перед завершением.");
                workspace.notes[index].completed = true;
                r.status = "done".into();
                r.claim = None;
                add_event(&mut r, event("completed", "Агент завершил задачу", actor))?;
            }
            "task-agent-release" => {
                let text = str_field(input, "text")?;
                ensure!(
                    !text.trim().is_empty() && bounded(text, 20_000),
                    "Опишите, что осталось сделать"
                );
                r.claim = None;
                r.status = "todo".into();
                workspace.notes[index].completed = false;
                add_event(&mut r, event("released", text, actor))?;
            }
            _ => bail!("Неизвестное действие агента"),
        }
    }
    bump(&mut workspace.notes[index])?;
    save_record(workspace, r);
    if command == "task-agent-report" {
        let report_context = context(root, workspace, &note_id, true)?;
        let r = workspace
            .task_workspaces
            .iter_mut()
            .find(|r| r.note_id == note_id)
            .unwrap();
        if let Some(e) = r.history.iter_mut().rfind(|e| e.kind == "report") {
            e.snapshot = Some(serde_json::to_value(report_context)?);
        }
        trim_history(r)?;
    }
    let result = serde_json::to_value(details(root, workspace, &note_id)?)?;
    remember(
        workspace,
        input,
        result,
        before,
        task_state(workspace, &note_id),
    )
}
fn list(root: &Path, workspace: &NotesWorkspace, input: &Value) -> Result<Value> {
    let agent = input["agentOnly"].as_bool().unwrap_or(false);
    if agent {
        ensure!(
            workspace.task_integration.enabled,
            "MCP выключен в настройках «После»"
        );
    }
    let query = input["query"].as_str().unwrap_or("");
    let matcher = crate::search::QueryMatcher::new(query)?;
    let include_details = input["includeDetails"].as_bool().unwrap_or(false) && !agent;
    let mut tasks = workspace
        .notes
        .iter()
        .filter(|n| n.kind == "task" && n.trashed_at.is_none())
        .map(|n| note_details_mode(root, workspace, n, include_details))
        .collect::<Vec<_>>();
    let mut warnings = Vec::new();
    if !agent {
        for meta in storage::list_meetings(root)? {
            let Some(id) = meta["id"].as_str() else {
                continue;
            };
            let dir = storage::meeting_directory(root, id)?;
            let summary = match storage::regular_json(&dir.join("summary.json")) {
                Ok(s) => s,
                Err(_) => continue,
            };
            let Some(items) = summary["items"].as_array() else {
                continue;
            };
            let mut seen = HashSet::new();
            for item in items.iter().take(10_000).filter(|i| i["kind"] == "action") {
                let signature = notes::task_signature(item);
                if !seen.insert(signature.clone()) {
                    continue;
                }
                if workspace.notes.iter().any(|n| {
                    n.task_origin
                        .as_ref()
                        .is_some_and(|o| o["meetingID"] == id && o["itemSignature"] == signature)
                }) {
                    continue;
                }
                match virtual_details(
                    workspace,
                    &format!("summary:{id}:{signature}"),
                    id,
                    &meta,
                    item,
                ) {
                    Ok(d) => tasks.push(d),
                    Err(_) => {
                        warnings.push(format!("Встреча {id}: задача обновляется или недоступна"))
                    }
                }
            }
        }
    }
    tasks.retain(|d| {
        (!agent || d.agent_access.enabled)
            && input["project"]
                .as_str()
                .is_none_or(|p| p == "all" || p == d.project)
            && input["status"]
                .as_str()
                .is_none_or(|s| s == "all" || s == d.status || (s == "open" && !d.completed))
            && matcher.matches(&format!("{} {} {} {}", d.title, d.text, d.owner, d.project))
    });
    tasks.sort_by(|a, b| b.updated_at.total_cmp(&a.updated_at).then(a.id.cmp(&b.id)));
    let total = tasks.len();
    let offset = if let Some(raw) = input.get("offset") {
        raw.as_u64()
            .context("Смещение должно быть неотрицательным")?
            .min(usize::MAX as u64) as usize
    } else {
        0
    };
    let limit = if let Some(raw) = input.get("limit") {
        let limit = raw
            .as_u64()
            .context("Лимит должен быть целым положительным числом")?;
        ensure!(
            (1..=500).contains(&limit),
            "За один запрос можно получить от 1 до 500 задач"
        );
        limit as usize
    } else if agent || include_details {
        200
    } else {
        total
    };
    tasks = tasks.into_iter().skip(offset).take(limit).collect();
    let next_offset =
        (offset.saturating_add(tasks.len()) < total).then_some(offset.saturating_add(tasks.len()));
    for d in &mut tasks {
        if !include_details {
            d.text = d.text.chars().take(600).collect();
        }
        if agent {
            d.history.clear();
            d.history_count = 0;
            d.materials.clear();
            d.material_count = workspace
                .task_workspaces
                .iter()
                .find(|r| format!("manual:{}", r.note_id) == d.id)
                .map(|r| r.materials.iter().filter(|m| m.shared).count())
                .unwrap_or(0);
        }
    }
    Ok(
        json!({"tasks":tasks,"warnings":warnings.into_iter().take(30).collect::<Vec<_>>(),"total":total,"truncated":next_offset.is_some(),"nextOffset":next_offset}),
    )
}
fn preview(root: &Path, workspace: &mut NotesWorkspace, input: &Value) -> Result<Value> {
    let action = str_field(input, "action")?;
    ensure!(
        ["appendContext", "complete", "reopen"].contains(&action),
        "Неизвестное пакетное действие"
    );
    let raw = input["items"].as_array().context("Выберите задачи")?;
    ensure!(
        !raw.is_empty() && raw.len() <= 30,
        "Выберите от 1 до 30 задач"
    );
    let text = input["text"].as_str().unwrap_or("");
    ensure!(
        bounded(text, 20_000) && (action != "appendContext" || !text.trim().is_empty()),
        "Добавьте текст контекста"
    );
    let mut items = Vec::new();
    let mut seen = HashSet::new();
    for item in raw {
        let id = str_field(item, "taskID")?;
        ensure!(seen.insert(id), "Повторная задача в поручении");
        let d = details(root, workspace, id)?;
        require_revision(&d, item)?;
        if let Some(project) = input["project"].as_str() {
            ensure!(
                project == "all" || project == d.project,
                "Задача находится за пределами выбранного проекта"
            );
        }
        let c = context(root, workspace, id, false)?;
        if let Some(expected) = item["expectedContextVersion"].as_str() {
            ensure!(expected == c.context_version, CONFLICT);
        }
        let reason = item["reason"].as_str().unwrap_or("");
        ensure!(bounded(reason, 1000), "Слишком длинное объяснение поиска");
        items.push(json!({"taskID":d.id,"title":d.title,"revision":d.revision,"status":d.status,"sourceFingerprint":d.source_fingerprint,"contextVersion":c.context_version,"reason":reason,"selected":!d.completed}));
    }
    workspace
        .task_plans
        .retain(|p| now() - p["createdAt"].as_f64().unwrap_or(0.0) < 86_400.0);
    while workspace.task_plans.len() >= 100 {
        workspace.task_plans.remove(0);
    }
    let p = json!({"planID":uuid(),"action":action,"text":text,"items":items,"createdAt":now()});
    workspace.task_plans.push(p.clone());
    Ok(p)
}
fn batch_apply(root: &Path, workspace: &mut NotesWorkspace, input: &Value) -> Result<Value> {
    if let Some(result) = replay(workspace, input)? {
        return Ok(result);
    }
    let plan_id = str_field(input, "planID")?;
    let plan = workspace
        .task_plans
        .iter()
        .find(|p| p["planID"] == plan_id)
        .context("Поручение больше недоступно")?
        .clone();
    ensure!(
        now() - plan["createdAt"].as_f64().unwrap_or(0.0) < 86_400.0,
        "Поручение устарело. Подготовьте его заново."
    );
    let ids = input["taskIDs"].as_array().context("Выберите задачи")?;
    ensure!(
        !ids.is_empty() && ids.len() <= 30,
        "Выберите от 1 до 30 задач"
    );
    let mut seen = HashSet::new();
    let mut selected = Vec::new();
    for id in ids {
        let id = id.as_str().context("Некорректная задача")?;
        ensure!(seen.insert(id), "Задача выбрана дважды");
        let item = plan["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["taskID"] == id)
            .context("Нельзя добавить задачу за пределами предпросмотра")?;
        let d = details(root, workspace, id)?;
        ensure!(
            Some(d.revision) == item["revision"].as_u64()
                && d.source_fingerprint == item["sourceFingerprint"].as_str().unwrap_or(""),
            CONFLICT
        );
        ensure!(
            context(root, workspace, id, false)?.context_version
                == item["contextVersion"].as_str().unwrap_or(""),
            CONFLICT
        );
        selected.push(d);
    }
    let action = plan["action"].as_str().unwrap();
    let text = input["text"]
        .as_str()
        .or_else(|| plan["text"].as_str())
        .unwrap_or("")
        .trim();
    ensure!(
        bounded(text, 20_000) && (action != "appendContext" || !text.is_empty()),
        "Добавьте текст контекста"
    );
    let mut before = Vec::new();
    let mut after = Vec::new();
    let mut results = Vec::new();
    let mut created_note = None;
    if action == "appendContext" {
        let note: CapturedNote = serde_json::from_value(
            json!({"id":uuid(),"kind":"note","title":"Контекст из поручения","text":text,"createdAt":now(),"updatedAt":now(),"revision":1}),
        )?;
        created_note = Some(note.clone());
        workspace.notes.push(note);
    }
    for d in selected {
        let old = if d.virtual_task {
            Value::Null
        } else {
            task_state(workspace, &d.id)
        };
        let index = materialize(root, workspace, &d.id)?;
        let note_id = workspace.notes[index].id.clone();
        let mut r = record_for(workspace, &note_id);
        if let Some(note) = &created_note {
            ensure!(r.materials.len() < 200, "В задаче уже 200 материалов");
            r.materials.push(TaskMaterial {
                id: uuid(),
                kind: "note".into(),
                title: note.title.clone(),
                note_id: Some(note.id.clone()),
                shared: r.agent_access.enabled,
                created_at: now(),
                ..Default::default()
            });
            add_event(
                &mut r,
                event("contextAdded", "Добавлен контекст из поручения", "user"),
            )?;
        } else {
            let completed = action == "complete";
            workspace.notes[index].completed = completed;
            r.status = if completed { "done" } else { "doing" }.into();
            r.claim = None;
            add_event(
                &mut r,
                event(
                    if completed { "completed" } else { "reopened" },
                    if completed {
                        "Задача завершена поручением"
                    } else {
                        "Задача возвращена в работу"
                    },
                    "user",
                ),
            )?;
        }
        bump(&mut workspace.notes[index])?;
        save_record(workspace, r);
        before.push(json!({"taskID":format!("manual:{note_id}"),"state":old}));
        after.push(
            json!({"taskID":format!("manual:{note_id}"),"state":task_state(workspace,&note_id)}),
        );
        results.push(details(root, workspace, &note_id)?);
    }
    let result = json!({"tasks":results,"operationID":input["operationID"],"canUndo":true});
    remember(
        workspace,
        input,
        result,
        json!({"tasks":before}),
        json!({"tasks":after,"createdNotes":created_note.into_iter().collect::<Vec<_>>()}),
    )
}
fn undo(root: &Path, workspace: &mut NotesWorkspace, input: &Value) -> Result<Value> {
    let id = str_field(input, "operationID")?;
    let op_index = workspace
        .task_operations
        .iter()
        .position(|p| p["operationID"] == id)
        .context("Операция больше недоступна")?;
    let op = workspace.task_operations[op_index].clone();
    ensure!(
        op["expired"] != true,
        "Срок отмены операции истёк. Последние изменения можно исправить в задаче."
    );
    if op["undone"] == true {
        return Ok(json!({"undone":true,"tasks":[]}));
    }
    ensure!(
        op["before"].is_object() || op["before"].is_null(),
        "Эта операция не поддерживает отмену"
    );
    let mut rows = Vec::new();
    let mut created_notes = Vec::new();
    if let Some(tasks) = op["after"]["tasks"].as_array() {
        for (i, row) in tasks.iter().enumerate() {
            rows.push((
                row["taskID"]
                    .as_str()
                    .context("Нет задачи операции")?
                    .to_owned(),
                op["before"]["tasks"][i]["state"].clone(),
                row["state"].clone(),
            ));
        }
        created_notes = op["after"]["createdNotes"]
            .as_array()
            .cloned()
            .unwrap_or_default();
    } else {
        let after = &op["after"];
        let note_id = after["note"]["id"]
            .as_str()
            .context("Эта операция не поддерживает отмену")?;
        let mut pure = after.clone();
        if let Some(n) = pure.as_object_mut().unwrap().remove("createdNote") {
            if !n.is_null() {
                created_notes.push(n);
            }
        }
        rows.push((format!("manual:{note_id}"), op["before"].clone(), pure));
    }
    let affected = rows
        .iter()
        .map(|(id, _, _)| canonical_id(id).to_owned())
        .collect::<HashSet<_>>();
    for (id, _, after) in &rows {
        ensure!(
            task_state(workspace, id) == *after,
            "После поручения задача изменилась. Отмена сохранит новые данные."
        );
    }
    for note in &created_notes {
        let id = note["id"].as_str().context("Нет заметки операции")?;
        ensure!(
            workspace
                .notes
                .iter()
                .find(|n| n.id == id)
                .map(serde_json::to_value)
                .transpose()?
                == Some(note.clone()),
            "Созданная заметка уже изменена. Отмена сохранит новые данные."
        );
        ensure!(
            !workspace
                .task_workspaces
                .iter()
                .any(|r| !affected.contains(&r.note_id)
                    && r.materials.iter().any(|m| m.note_id.as_deref() == Some(id))),
            "Заметка уже используется другой задачей. Открепите её вручную."
        );
    }
    let mut result_ids = Vec::new();
    for (id, before, after) in rows {
        let raw = canonical_id(&id);
        let index = workspace
            .notes
            .iter()
            .position(|n| n.id == raw)
            .context(CONFLICT)?;
        if before.is_null() {
            workspace.notes.remove(index);
            workspace.task_workspaces.retain(|r| r.note_id != raw);
            if let Some(alias) = after["note"]["taskOrigin"]["summaryTaskID"].as_str() {
                result_ids.push(alias.to_owned());
            }
        } else {
            let mut n: CapturedNote = serde_json::from_value(before["note"].clone())?;
            n.revision = workspace.notes[index].revision;
            bump(&mut n)?;
            workspace.notes[index] = n;
            workspace.task_workspaces.retain(|r| r.note_id != raw);
            if !before["record"].is_null() {
                workspace
                    .task_workspaces
                    .push(serde_json::from_value(before["record"].clone())?);
            }
            result_ids.push(id);
        }
    }
    for n in created_notes {
        workspace
            .notes
            .retain(|note| Some(note.id.as_str()) != n["id"].as_str());
    }
    workspace.task_operations[op_index]["undone"] = json!(true);
    let tasks = result_ids
        .iter()
        .filter_map(|id| details(root, workspace, id).ok())
        .collect::<Vec<_>>();
    Ok(json!({"undone":true,"tasks":tasks}))
}
fn agent_result(workspace: &NotesWorkspace, mut v: Value) -> Value {
    // A receipt contains the original result for idempotency. Permissions are
    // evaluated now: replay must not resurrect a revoked note or folder path.
    let allowed = v["id"]
        .as_str()
        .and_then(|id| {
            workspace
                .task_workspaces
                .iter()
                .find(|r| r.note_id == canonical_id(id))
        })
        .map(|r| {
            r.materials
                .iter()
                .filter(|m| m.shared)
                .map(|m| m.id.as_str())
                .collect::<HashSet<_>>()
        })
        .unwrap_or_default();
    if let Some(items) = v["materials"].as_array_mut() {
        items.retain(|m| {
            m["shared"].as_bool() == Some(true)
                && m["id"].as_str().is_some_and(|id| allowed.contains(id))
        });
        v["materialCount"] = json!(items.len());
    }
    if let Some(events) = v["history"].as_array_mut() {
        for event in events {
            if let Some(o) = event.as_object_mut() {
                o.remove("snapshot");
            }
        }
    }
    v
}
/// UI, voice and stdio MCP call this same transactional boundary. MCP transport
/// supplies agentOnly itself; only native UI exposes settings and sharing edits.
pub fn dispatch(root: &Path, input: &Value) -> Result<Value> {
    let command = str_field(input, "command")?;
    let dir = notes::directory(root)?;
    let _lock = notes::lock(&dir)?;
    let mut workspace = notes::load(&dir)?;
    let agent = input["agentOnly"].as_bool().unwrap_or(false);
    if agent {
        ensure!(
            workspace.task_integration.enabled,
            "MCP выключен в настройках «После»"
        );
        ensure!(
            [
                "task-list",
                "task-context",
                "task-get",
                "task-agent-claim",
                "task-agent-progress",
                "task-agent-report",
                "task-agent-complete",
                "task-agent-release"
            ]
            .contains(&command),
            "Это действие недоступно агенту"
        );
    }
    match command {
        "task-list" => return list(root, &workspace, input),
        "task-get" => {
            let d = details(root, &workspace, str_field(input, "taskID")?)?;
            if agent {
                ensure!(d.agent_access.enabled, "Доступ агента к задаче выключен");
            }
            let v = serde_json::to_value(d)?;
            return Ok(if agent {
                agent_result(&workspace, v)
            } else {
                v
            });
        }
        "task-context" => {
            let shared = agent || input["sharedOnly"].as_bool().unwrap_or(false);
            return Ok(serde_json::to_value(context_mask(
                root,
                &workspace,
                str_field(input, "taskID")?,
                agent,
                shared,
            )?)?);
        }
        "task-operation-inspect" => {
            let id = str_field(input, "operationID")?;
            let plan = str_field(input, "planID")?;
            let Some(receipt) = workspace
                .task_operations
                .iter()
                .find(|o| o["operationID"] == id)
            else {
                return Ok(json!({"committed":false}));
            };
            ensure!(
                receipt["expired"] != true,
                "Срок восстановления операции истёк. Проверьте задачу перед повтором."
            );
            ensure!(
                receipt["request"]["command"] == "task-batch-apply"
                    && receipt["request"]["planID"] == plan,
                "Операция принадлежит другому поручению"
            );
            ensure!(
                receipt["fingerprint"].as_str() == Some(hash(&receipt["request"]).as_str()),
                "Повреждена запись операции. Проверьте задачу перед повтором."
            );
            return Ok(
                json!({"committed":true,"result":receipt["result"],"request":receipt["request"],"undone":receipt["undone"]}),
            );
        }
        "task-agent-settings" => {
            if input.get("enabled").is_none() {
                return Ok(serde_json::to_value(&workspace.task_integration)?);
            }
            if let Some(result) = replay(&workspace, input)? {
                return Ok(result);
            }
            ensure!(
                input["expectedRevision"].as_u64() == Some(workspace.task_integration.revision),
                CONFLICT
            );
            workspace.task_integration.enabled =
                input["enabled"].as_bool().context("Нет состояния MCP")?;
            workspace.task_integration.revision = workspace
                .task_integration
                .revision
                .checked_add(1)
                .context("Слишком большая ревизия")?;
            // Revocation invalidates all outstanding claims. Re-enabling never
            // revives a previous agent's completion capability.
            if !workspace.task_integration.enabled {
                for r in &mut workspace.task_workspaces {
                    r.claim = None;
                }
            }
            let result = serde_json::to_value(&workspace.task_integration)?;
            let result = remember(&mut workspace, input, result, Value::Null, Value::Null)?;
            persist(root, &workspace)?;
            return Ok(result);
        }
        _ => {}
    }
    let result = match command {
        "task-create" => create(root, &mut workspace, input)?,
        "task-details-update" => update(root, &mut workspace, input)?,
        "task-material-link" => link(root, &mut workspace, input, false)?,
        "task-material-unlink" => link(root, &mut workspace, input, true)?,
        "task-batch-preview" => preview(root, &mut workspace, input)?,
        "task-batch-apply" => batch_apply(root, &mut workspace, input)?,
        "task-operation-undo" => undo(root, &mut workspace, input)?,
        "task-agent-claim"
        | "task-agent-progress"
        | "task-agent-report"
        | "task-agent-complete"
        | "task-agent-release" => agent_action(root, &mut workspace, input, command)?,
        _ => bail!("Неизвестная команда задач"),
    };
    persist(root, &workspace)?;
    Ok(if agent {
        agent_result(&workspace, result)
    } else {
        result
    })
}

#[cfg(test)]
mod tests;
