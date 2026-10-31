//! Bounded, read-only task selection for the native assistant.
//! It does not call a model, create tasks, or expose a new MCP tool.
use anyhow::{ensure, Context, Result};
use chrono::NaiveDate;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::path::Path;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Plan {
    intent: Intent,
    entity_kind: EntityKind,
    selector: Selector,
    scope: Scope,
    clock: Clock,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Intent { Find, Open, Inspect }
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum EntityKind { Task }
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", deny_unknown_fields, rename_all = "camelCase")]
enum Selector {
    Search { query: String },
    LatestCreated,
    DueRange {
        #[serde(rename = "startDate")] start_date: String,
        #[serde(rename = "endDateExclusive")] end_date_exclusive: String,
    },
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Scope {
    mode: ScopeMode,
    #[serde(rename = "folderID", default)]
    folder_id: Option<String>,
    #[serde(rename = "projectID", default)]
    project_id: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum ScopeMode { Library, Folder, Project }
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Clock {
    query_now: f64,
    #[serde(rename = "timeZoneID")]
    time_zone_id: String,
}

fn valid_folder(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 &&
        id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn date(value: &str) -> Result<NaiveDate> {
    ensure!(value.len() == 10, "Некорректная дата");
    let result = NaiveDate::parse_from_str(value, "%Y-%m-%d").context("Некорректная дата")?;
    ensure!(result.format("%Y-%m-%d").to_string() == value, "Некорректная дата");
    Ok(result)
}
fn fixed_zone(value: &str) -> bool {
    let Some(offset) = value.strip_prefix("GMT").or_else(|| value.strip_prefix("UTC")) else { return false };
    let Some(offset) = offset.strip_prefix('+').or_else(|| offset.strip_prefix('-')) else { return false };
    let compact = offset.replace(':', "");
    if compact.len() != 4 || !compact.bytes().all(|b| b.is_ascii_digit()) { return false; }
    let hours: u32 = compact[..2].parse().unwrap_or(99);
    let minutes: u32 = compact[2..].parse().unwrap_or(99);
    hours <= 18 && minutes < 60 && (hours < 18 || minutes == 0) &&
        (offset.len() == 4 || (offset.len() == 5 && offset.as_bytes()[2] == b':'))
}
fn validate(plan: &Plan) -> Result<()> {
    ensure!(plan.clock.query_now.is_finite() && (0.0..=253_402_300_799.0).contains(&plan.clock.query_now), "Некорректное время запроса");
    let zone = &plan.clock.time_zone_id;
    ensure!(!zone.is_empty() && zone.len() <= 128 && !zone.starts_with('/') && !zone.contains("..") &&
        zone.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'_' | b'-' | b'+' | b':')),
        "Некорректный часовой пояс");
    ensure!(Path::new("/usr/share/zoneinfo").join(zone).is_file() || zone == "GMT" || zone == "UTC" || fixed_zone(zone),
        "Неизвестный часовой пояс");
    ensure!(plan.scope.folder_id.as_ref().is_none_or(|s| valid_folder(s)) &&
        plan.scope.project_id.as_ref().is_none_or(|s| s.len() <= 512 && !s.chars().any(char::is_control)),
        "Некорректная область поиска");
    match plan.scope.mode {
        ScopeMode::Library => ensure!(plan.scope.folder_id.is_none() && plan.scope.project_id.is_none(), "Некорректная область библиотеки"),
        ScopeMode::Folder => ensure!(plan.scope.folder_id.is_some(), "Укажите папку"),
        ScopeMode::Project => ensure!(plan.scope.folder_id.is_none() && plan.scope.project_id.is_some(), "Укажите проект"),
    }
    match &plan.selector {
        Selector::Search { query } => {
            ensure!(!query.trim().is_empty() && query.len() <= 500 && !query.contains('\0'), "Укажите поисковый запрос");
            crate::search::QueryMatcher::new(query)?;
        }
        Selector::DueRange { start_date, end_date_exclusive } => {
            let start = date(start_date)?;
            let end = date(end_date_exclusive)?;
            ensure!(end > start && (end - start).num_days() <= 366, "Некорректный интервал");
        }
        Selector::LatestCreated => {}
    }
    Ok(())
}

fn task_call(root: &Path, command: &str, mut input: Value) -> Result<Value> {
    input["command"] = json!(command);
    crate::task_workspace::dispatch(root, &input)
}
fn permitted(profiles: &crate::ai::FeatureResolver, plan: &Plan, task: &Value) -> Result<bool> {
    let id = task["id"].as_str().context("Нет идентификатора задачи")?;
    let source = json!({"taskID":id});
    let folder = profiles.folder_for(&source)?;
    if plan.scope.folder_id.as_deref().is_some_and(|id| folder.as_deref() != Some(id)) { return Ok(false); }
    if plan.scope.project_id.as_deref().is_some_and(|project| task["project"].as_str() != Some(project)) { return Ok(false); }
    let features = profiles.features_for(&source)?;
    Ok(features.assistant && features.tasks)
}
fn native_creation(task: &Value, query_now: f64) -> Option<f64> {
    let time = task["createdAt"].as_f64()?;
    let native = task["virtual"] == false &&
        ["local", "manual"].contains(&task["source"].as_str().unwrap_or("")) &&
        task["sourceFingerprint"].as_str().unwrap_or("").is_empty();
    (native && time.is_finite() && time > 0.0 && time <= query_now).then_some(time)
}
fn describe(task: &Value, context: &Value, full_task: Option<&Value>, query_now: f64) -> Value {
    let history: Vec<String> = if let Some(full_task) = full_task {
        let mut events: Vec<&Value> = full_task["history"].as_array().into_iter().flatten().collect();
        events.sort_by(|a, b| b["createdAt"].as_f64().unwrap_or(0.0).total_cmp(&a["createdAt"].as_f64().unwrap_or(0.0))
            .then_with(|| a["id"].as_str().cmp(&b["id"].as_str())));
        events.into_iter()
            .filter_map(|event| event["text"].as_str())
            .filter(|text| !text.trim().is_empty())
            .take(3).map(|text| text.chars().take(300).collect()).collect()
    } else { vec![] };
    // History storage order is not a time guarantee. Select the latest report
    // before limiting its content, and retain the actor so a report is never
    // presented as an independently verified fact.
    let report = full_task.and_then(|task| task["history"].as_array())
        .into_iter().flatten()
        .filter(|event| event["kind"] == "report" && event["createdAt"].as_f64().is_some_and(|t| t.is_finite() && t > 0.0 && t <= query_now))
        .max_by(|a, b| a["createdAt"].as_f64().unwrap().total_cmp(&b["createdAt"].as_f64().unwrap())
            .then_with(|| a["id"].as_str().cmp(&b["id"].as_str())))
        .map(|event| {
            let artifacts: Vec<Value> = event["artifacts"].as_array().into_iter().flatten().take(3)
                .filter_map(|artifact| Some(json!({"id":artifact["id"].as_str()?,
                    "title":artifact["title"].as_str()?.chars().take(200).collect::<String>()}))).collect();
            let text = event["text"].as_str().unwrap_or("");
            json!({"eventID":event["id"], "actor":event["actor"], "createdAt":event["createdAt"],
                "text":text.chars().take(1000).collect::<String>(), "textTruncated":text.chars().count() > 1000,
                "artifacts":artifacts, "artifactsTruncated":event["artifacts"].as_array().is_some_and(|a| a.len() > 3)})
        });
    let history_fingerprint = full_task.map(|task| format!("{:x}",
        Sha256::digest(serde_json::to_vec(&task["history"]).expect("JSON history"))));
    json!({
        "kind":"task", "taskID":task["id"], "title":task["title"],
        "detail":task["text"], "revision":task["revision"],
        "sourceFingerprint":task["sourceFingerprint"],
        "contextVersion":context["contextVersion"], "createdAt":task["createdAt"],
        "creationProvenance":if native_creation(task, query_now).is_some() {"nativeCreation"} else {"unknown"},
        "due":task["due"], "recentHistory":history, "historyFingerprint":history_fingerprint,
        "latestReport":report
    })
}
fn find(root: &Path, plan: &Plan, limit: usize) -> Result<Value> {
    validate(plan)?;
    ensure!((1..=50).contains(&limit), "За один запрос можно получить от 1 до 50 задач");
    let profiles = crate::ai::FeatureResolver::new(root)?;
    let requested_scope = json!({"folderID":plan.scope.folder_id});
    if plan.scope.folder_id.is_some() {
        let features = profiles.features_for(&requested_scope)?;
        ensure!(features.assistant && features.tasks, "Помощник или задачи выключены в этой папке");
    } else {
        let features = crate::ai::live_features(root)?;
        ensure!(features.assistant && features.tasks, "Включите помощника и задачи в настройках");
    }
    let listing = task_call(root, "task-list", json!({"includeDetails":false}))?;
    let warnings = listing["warnings"].as_array().cloned().unwrap_or_default();
    let matcher = match &plan.selector {
        Selector::Search { query } => Some(crate::search::QueryMatcher::new(query)?),
        _ => None,
    };
    let mut candidates = Vec::new();
    let mut unknown_due = 0usize;
    for task in listing["tasks"].as_array().context("Не удалось прочитать задачи")? {
        if !permitted(&profiles, plan, task)? { continue; }
        if let Some(matcher) = &matcher {
            let text = format!("{} {} {} {}", task["title"].as_str().unwrap_or(""),
                task["text"].as_str().unwrap_or(""), task["owner"].as_str().unwrap_or(""),
                task["project"].as_str().unwrap_or(""));
            if !matcher.matches(&text) { continue; }
        }
        if let Selector::DueRange { start_date, end_date_exclusive } = &plan.selector {
            let due = task["due"].as_str().unwrap_or("");
            if due.is_empty() { continue; }
            let Ok(due) = date(due) else { unknown_due += 1; continue };
            if due < date(start_date)? || due >= date(end_date_exclusive)? { continue; }
        }
        candidates.push(task.clone());
    }
    let unknown_creation = if matches!(plan.selector, Selector::LatestCreated) {
        candidates.iter().filter(|v| native_creation(v, plan.clock.query_now).is_none()).count()
    } else { 0 };
    if matches!(plan.selector, Selector::LatestCreated) {
        candidates.sort_by(|a,b| native_creation(b, plan.clock.query_now).unwrap_or(0.0).total_cmp(&native_creation(a, plan.clock.query_now).unwrap_or(0.0))
            .then_with(|| a["id"].as_str().cmp(&b["id"].as_str())));
        // Only call something "latest" when unknown creation times and
        // inaccessible sources cannot invalidate that assertion.
        let tied = candidates.len() > 1 && native_creation(&candidates[0], plan.clock.query_now) == native_creation(&candidates[1], plan.clock.query_now);
        if unknown_creation == 0 && warnings.is_empty() && !tied {
            candidates.truncate(1);
        }
    }
    let matching = candidates.len();
    let mut targets = Vec::new();
    let mut skipped = 0usize;
    for task in candidates.iter().take(limit) {
        let id = task["id"].as_str().context("Нет идентификатора задачи")?;
        match task_call(root, "task-context", json!({"taskID":id})) {
            Ok(context) => match context["contextVersion"].as_str() {
                Some(version) if version.len() == 64 => {
                    if matches!(plan.intent, Intent::Inspect) {
                        match task_call(root, "task-get", json!({"taskID":id})) {
                            Ok(full_task) if full_task["revision"] == task["revision"] &&
                                full_task["sourceFingerprint"] == task["sourceFingerprint"] &&
                                full_task["title"] == task["title"] &&
                                full_task["due"] == task["due"] &&
                                full_task["project"] == task["project"] => {
                                let fresh_context = task_call(root, "task-context", json!({"taskID":id}));
                                let fresh_profiles = crate::ai::FeatureResolver::new(root)?;
                                if fresh_context.is_ok_and(|fresh| fresh["contextVersion"] == context["contextVersion"])
                                    && permitted(&fresh_profiles, plan, &full_task)? {
                                    targets.push(describe(task, &context, Some(&full_task), plan.clock.query_now));
                                } else { skipped += 1; }
                            }
                            Err(_) => skipped += 1,
                            _ => skipped += 1,
                        }
                    } else { targets.push(describe(task, &context, None, plan.clock.query_now)); }
                }
                _ => skipped += 1,
            },
            Err(_) => skipped += 1,
        }
    }
    // Profiles and task contents can change while the list is being prepared.
    // Fence publication against a fresh task and profile snapshot; the
    // separate validation command repeats this check before navigation.
    let mut current_targets = Vec::new();
    for target in targets {
        let id = target["taskID"].as_str().context("Нет идентификатора задачи")?;
        let valid = (|| -> Result<bool> {
            let task = task_call(root, "task-get", json!({"taskID":id}))?;
            let current_profiles = crate::ai::FeatureResolver::new(root)?;
            if !permitted(&current_profiles, plan, &task)? ||
                task["revision"] != target["revision"] ||
                task["sourceFingerprint"] != target["sourceFingerprint"] { return Ok(false); }
            let context = task_call(root, "task-context", json!({"taskID":id}))?;
            if context["contextVersion"] != target["contextVersion"] { return Ok(false); }
            if matches!(plan.intent, Intent::Inspect) {
                let digest = format!("{:x}", Sha256::digest(serde_json::to_vec(&task["history"])?));
                if target["historyFingerprint"].as_str() != Some(digest.as_str()) { return Ok(false); }
            }
            Ok(true)
        })().unwrap_or(false);
        if valid { current_targets.push(target); } else { skipped += 1; }
    }
    let targets = current_targets;
    let mut warnings = warnings;
    if unknown_creation > 0 { warnings.push(json!("У некоторых задач неизвестна дата создания.")); }
    if unknown_due > 0 { warnings.push(json!("Некоторые сроки записаны текстом и не вошли в выборку.")); }
    if skipped > 0 { warnings.push(json!("Часть задач изменилась или недоступна. Повторите поиск.")); }
    let partial = !warnings.is_empty();
    let state = if targets.is_empty() && partial { "clarify" }
        else if targets.is_empty() { "notFound" }
        else if matches!(plan.selector, Selector::LatestCreated) && (partial || matching > 1) { "clarify" }
        else { "results" };
    Ok(json!({"state":state, "selectionExplanation":match plan.selector {
            Selector::LatestCreated => "По дате создания",
            Selector::DueRange { .. } => "По сроку задачи",
            Selector::Search { .. } => "По совпадению слов",
        }, "targets":targets,
        "coverage":{"matching":matching,"returned":targets.len(),"unknownCreation":unknown_creation,"unknownDue":unknown_due},
        "warnings":warnings,"truncated":matching > limit || skipped > 0,
        "asOf":plan.clock.query_now,"plan":plan}))
}

pub fn dispatch(root: &Path, input: &Value) -> Result<Value> {
    let plan: Plan = serde_json::from_value(input["plan"].clone()).context("Некорректный план поиска")?;
    let limit = input["limit"].as_u64().unwrap_or(20) as usize;
    match input["command"].as_str() {
        Some("assistant-find") => find(root, &plan, limit),
        Some("assistant-find-validate-list") => {
            let supplied = input.get("response").context("Нет показанного списка")?;
            let fresh = find(root, &plan, limit)?;
            let signature = |response: &Value| -> Option<Vec<Value>> {
                Some(response["targets"].as_array()?.iter().map(|target| json!({
                    "kind":target["kind"], "taskID":target["taskID"], "revision":target["revision"],
                    "sourceFingerprint":target["sourceFingerprint"], "contextVersion":target["contextVersion"],
                    "historyFingerprint":target["historyFingerprint"]
                })).collect())
            };
            let valid = supplied["state"] == fresh["state"] && supplied["coverage"] == fresh["coverage"] &&
                supplied["truncated"] == fresh["truncated"] &&
                signature(supplied).is_some_and(|old| Some(old) == signature(&fresh));
            Ok(json!({"valid":valid}))
        }
        Some("assistant-find-validate") => {
            let supplied = input.get("target").context("Нет выбранной задачи")?;
            let fresh = find(root, &plan, limit)?;
            let valid = fresh["targets"].as_array().is_some_and(|targets| targets.iter().any(|target|
                supplied["kind"] == "task" &&
                supplied["taskID"].as_str() == target["taskID"].as_str() &&
                supplied["revision"].as_u64().is_some() &&
                supplied["revision"].as_u64() == target["revision"].as_u64() &&
                supplied["sourceFingerprint"].as_str().is_some() &&
                supplied["sourceFingerprint"].as_str() == target["sourceFingerprint"].as_str() &&
                supplied["contextVersion"].as_str().is_some() &&
                supplied["contextVersion"].as_str() == target["contextVersion"].as_str() &&
                (!matches!(plan.intent, Intent::Inspect) ||
                    (supplied["historyFingerprint"].as_str().is_some() &&
                     supplied["historyFingerprint"].as_str() == target["historyFingerprint"].as_str()))));
            Ok(json!({"valid":valid}))
        }
        _ => anyhow::bail!("Неизвестная команда помощника"),
    }
}

#[cfg(test)]
mod tests;
