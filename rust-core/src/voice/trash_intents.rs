//! Explicit single-object recoverable deletion; the classifier cannot supply IDs.
use super::*;
pub(super) fn supported(action: &str) -> bool {
    [
        "trashNote",
        "restoreNote",
        "trashTask",
        "restoreTask",
        "trashMeeting",
        "restoreMeeting",
    ]
    .contains(&action)
}
fn kind(action: &str) -> &str {
    if action.ends_with("Meeting") {
        "meeting"
    } else if action.ends_with("Task") {
        "task"
    } else {
        "note"
    }
}
fn restoring(action: &str) -> bool {
    action.starts_with("restore")
}
pub(super) fn public_plan(plan: &Value) -> Value {
    json!({"status":plan["status"],"planID":plan["planID"],"operationID":plan["operationID"],"title":plan["title"],"detail":plan["detail"],"target":plan["target"],"reviewRequired":plan["reviewRequired"],"selectionMode":"single","text":"","action":plan["proposal"]["action"],"candidates":plan["candidates"]})
}
fn targets(root: &Path, input: &Value, proposal: &Proposal) -> Result<Vec<Value>> {
    let object_kind = kind(&proposal.action);
    let restore = restoring(&proposal.action);
    let mut all = if restore {
        crate::trash::list(root)?["entries"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|v| v["kind"] == object_kind)
            .collect::<Vec<_>>()
    } else if object_kind == "meeting" {
        crate::storage::list_meetings(root)?
            .into_iter()
            .filter_map(|v| v["id"].as_str().map(str::to_owned))
            .map(|id| crate::trash::snapshot(root, "meeting", &id, false))
            .collect::<Result<Vec<_>>>()?
    } else {
        notes::list(root)?
            .notes
            .into_iter()
            .filter(|n| n.trashed_at.is_none() && (n.kind == "task") == (object_kind == "task"))
            .map(|n| crate::trash::snapshot(root, object_kind, &n.id, false))
            .collect::<Result<Vec<_>>>()?
    };
    let selected = input[if object_kind == "meeting" {
        "meetingID"
    } else if object_kind == "task" {
        "taskID"
    } else {
        "noteID"
    }]
    .as_str()
    .unwrap_or("")
    .trim_start_matches("manual:");
    let query = normalized(&proposal.query);
    if query.is_empty() {
        // No unscoped “delete everything” fallback: user must name or select one.
        all.retain(|v| !selected.is_empty() && v["id"] == selected);
    } else {
        let words = query.split_whitespace().collect::<Vec<_>>();
        all.retain(|v| {
            let text = normalized(&format!(
                "{} {}",
                v["title"].as_str().unwrap_or(""),
                v["detail"].as_str().unwrap_or("")
            ));
            words.iter().all(|w| text.contains(w))
        });
    }
    all.truncate(24);
    Ok(all)
}
pub(super) fn prepare(root: &Path, input: &Value, proposal: &Proposal) -> Result<Value> {
    check_action_features(root, &proposal.action)?;
    let mut candidates = targets(root, input, proposal)?;
    for c in &mut candidates {
        c["selected"] = json!(false);
    }
    let restore = restoring(&proposal.action);
    let status = if candidates.is_empty() {
        "unsupported"
    } else if candidates.len() == 1 {
        "ready"
    } else {
        "choose"
    };
    if candidates.len() == 1 {
        candidates[0]["selected"] = json!(true);
    }
    let plan = json!({"trashIntent":true,"status":status,"planID":uuid(),"operationID":uuid(),"createdAt":now(),"proposal":proposal,"title":if restore{"Восстановить из Корзины"}else{"Переместить в Корзину"},"detail":if candidates.is_empty(){"Выберите объект или укажите его название. Удаление доступно для одной встречи, заметки или задачи за раз."}else if restore{"Объект вернётся в библиотеку вместе с сохранёнными материалами."}else{"Объект можно будет восстановить в Корзине в течение 30 дней."},"reviewRequired":true,"selectionMode":"single","target":candidates.first().cloned().unwrap_or(Value::Null),"candidates":candidates});
    let directory = notes::directory(root)?;
    let _lock = notes::lock(&directory)?;
    let mut data = notes::load(&directory)?;
    data.voice_plans
        .retain(|p| now() - p["createdAt"].as_f64().unwrap_or(0.0) < PLAN_LIFETIME);
    if data.voice_plans.len() >= 100 {
        data.voice_plans.remove(0);
    }
    data.voice_plans.push(plan.clone());
    notes::persist(&directory, &data)?;
    Ok(public_plan(&plan))
}
pub(super) fn owns(root: &Path, input: &Value) -> Result<bool> {
    Ok(notes::list(root)?
        .voice_plans
        .iter()
        .any(|p| p["trashIntent"] == true && p["planID"] == input["planID"])
        || notes::list(root)?
            .voice_operations
            .iter()
            .any(|p| p["trashIntent"] == true && p["planID"] == input["planID"]))
}
pub(super) fn choose(root: &Path, input: &Value) -> Result<Value> {
    let directory = notes::directory(root)?;
    let _lock = notes::lock(&directory)?;
    let mut data = notes::load(&directory)?;
    let key = input["planID"].as_str().context("Нет поручения")?;
    let index = data
        .voice_plans
        .iter()
        .position(|p| p["planID"] == key && p["trashIntent"] == true)
        .context("Поручение не найдено")?;
    let mut plan = data.voice_plans[index].clone();
    ensure!(
        plan["status"] == "choose"
            && now() - plan["createdAt"].as_f64().unwrap_or(0.0) < PLAN_LIFETIME,
        "Подготовьте поручение заново"
    );
    let mut candidate = plan["candidates"]
        .as_array()
        .and_then(|rows| rows.iter().find(|v| v["id"] == input["targetID"]))
        .cloned()
        .context("Выберите предложенный объект")?;
    candidate["selected"] = json!(true);
    plan["candidates"] = json!([candidate.clone()]);
    plan["target"] = candidate;
    plan["status"] = json!("ready");
    data.voice_plans[index] = plan.clone();
    notes::persist(&directory, &data)?;
    Ok(public_plan(&plan))
}
pub(super) fn apply(root: &Path, input: &Value) -> Result<Value> {
    check_saved_plan_features(root, input)?;
    ensure!(input["confirmed"] == true, "Подтвердите изменение");
    ensure!(
        input["text"].as_str().unwrap_or("").is_empty(),
        "Эта команда не изменяет текст"
    );
    let request_hash = hash(&json!([
        input["planID"],
        input["operationID"],
        input["selectedTargetIDs"]
    ]));
    let data = notes::list(root)?;
    let operation = input["operationID"].as_str().context("Нет операции")?;
    if let Some(entry) = data
        .voice_operations
        .iter()
        .find(|v| v["trashIntent"] == true && v["operationID"] == operation)
    {
        ensure!(
            entry["planID"] == input["planID"] && entry["requestHash"] == request_hash,
            "Операция принадлежит другому поручению или набору объектов"
        );
        return Ok(entry["result"].clone());
    }
    let plan = stored_plan(&data, input["planID"].as_str().context("Нет поручения")?)?.clone();
    ensure!(
        plan["trashIntent"] == true
            && plan["status"] == "ready"
            && plan["operationID"] == operation
            && input["confirmed"] == true,
        "Проверьте и подтвердите объект перед изменением"
    );
    let selected = input["selectedTargetIDs"]
        .as_array()
        .context("Выберите объект")?;
    ensure!(
        selected.len() == 1 && selected[0] == plan["target"]["id"],
        "Выберите предложенный объект"
    );
    let action = plan["proposal"]["action"].as_str().unwrap_or("");
    let output = crate::trash::change(
        root,
        &json!({"kind":kind(action),"id":plan["target"]["id"],"restore":restoring(action),"expectedFingerprint":plan["target"]["fingerprint"],"operationID":operation}),
    )?;
    let directory = notes::directory(root)?;
    let _lock = notes::lock(&directory)?;
    let mut data = notes::load(&directory)?;
    if !data
        .voice_operations
        .iter()
        .any(|v| v["trashIntent"] == true && v["operationID"] == operation)
    {
        if data.voice_operations.len() >= 500 {
            let index = data
                .voice_operations
                .iter()
                .position(|r| r["pending"] != true)
                .context("Слишком много поручений")?;
            data.voice_operations.remove(index);
        }
        data.voice_operations.push(json!({"trashIntent":true,"operationID":operation,"requestHash":request_hash,"planID":input["planID"],"plan":plan,"createdAt":now(),"result":output,"pending":false}));
        notes::persist(&directory, &data)?;
    }
    Ok(output)
}
pub(super) fn owns_operation(_root: &Path, _input: &Value) -> Result<bool> {
    Ok(false)
}
pub(super) fn undo(_root: &Path, _input: &Value) -> Result<Value> {
    bail!("Восстановите объект в Корзине")
}

#[cfg(test)]
mod tests {
    use super::*;
    fn proposal(action: &str) -> Proposal {
        serde_json::from_value(json!({"action":action,"query":"","title":"","text":"","due":"","owner":"","setDue":false,"setOwner":false,"setCompleted":false,"completed":false,"cards":[]})).unwrap()
    }
    #[test]
    fn delete_review_retry_and_restore_follow_typed_targets() {
        let temp = crate::voice::enabled_test_root();
        let root = temp.path();
        let n = notes::save_note(
            root,
            serde_json::from_value(
                json!({"id":"n1","text":"Мысли","createdAt":0.0,"updatedAt":0.0}),
            )
            .unwrap(),
        )
        .unwrap();
        let prepared = prepare(root, &json!({"noteID":n.id}), &proposal("trashNote")).unwrap();
        assert_eq!(prepared["reviewRequired"], true);
        assert!(notes::list(root).unwrap().notes[0].trashed_at.is_none());
        let mut input = json!({"planID":prepared["planID"],"operationID":prepared["operationID"],"selectedTargetIDs":[n.id],"confirmed":false,"text":""});
        assert!(apply(root, &input).is_err());
        input["confirmed"] = json!(true);
        let output = apply(root, &input).unwrap();
        assert_eq!(output["target"]["kind"], "trash");
        assert_eq!(apply(root, &input).unwrap(), output);
        let mut altered = input.clone();
        altered["selectedTargetIDs"] = json!(["another"]);
        assert!(apply(root, &altered).is_err());
        assert!(notes::list(root).unwrap().notes[0].trashed_at.is_some());
        let restore = prepare(root, &json!({"noteID":n.id}), &proposal("restoreNote")).unwrap();
        input["planID"] = restore["planID"].clone();
        input["operationID"] = restore["operationID"].clone();
        apply(root, &input).unwrap();
        assert!(notes::list(root).unwrap().notes[0].trashed_at.is_none());
    }
    #[test]
    fn unscoped_delete_cannot_select_whole_library() {
        let temp = crate::voice::enabled_test_root();
        let root = temp.path();
        let p = prepare(root, &json!({}), &proposal("trashNote")).unwrap();
        assert_eq!(p["status"], "unsupported");
        assert!(p["candidates"].as_array().unwrap().is_empty());
    }
}
