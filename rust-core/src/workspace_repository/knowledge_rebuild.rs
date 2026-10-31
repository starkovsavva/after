//! Explicit, reviewable knowledge edits. A provider only supplies a proposal;
//! the private draft captures trusted note versions and the transaction owns
//! every durable ID. Receipts contain affected rows, never a workspace backup.
use super::*;
use uuid::Uuid;

const MAX_SOURCES: usize = 30;
const MAX_INPUT: usize = 60_000;
const MAX_OUTPUT: usize = 160_000;
const STALE: &str =
    "Исходные заметки изменились или стали недоступны. Подготовьте перестройку заново.";
const UNDO_CHANGED: &str =
    "Результат перестройки уже изменён. Отмена остановлена, чтобы сохранить ваши изменения.";

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Edit {
    #[serde(rename = "noteID")]
    note_id: String,
    title: String,
    text: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NewNote {
    key: String,
    title: String,
    text: String,
    #[serde(rename = "sourceNoteIDs")]
    source_note_ids: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Reference {
    #[serde(default, rename = "noteID", skip_serializing_if = "Option::is_none")]
    note_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    draft_key: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Collection {
    key: String,
    name: String,
    members: Vec<Reference>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Link {
    from: Reference,
    to: Reference,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Proposal {
    title: String,
    summary: String,
    edits: Vec<Edit>,
    new_notes: Vec<NewNote>,
    collections: Vec<Collection>,
    links: Vec<Link>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Source {
    id: String,
    title: String,
    text: String,
    revision: u64,
    fingerprint: String,
    entity_version: u64,
    #[serde(rename = "folderID")]
    folder_id: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Draft {
    #[serde(rename = "draftID")]
    draft_id: String,
    #[serde(rename = "libraryID")]
    library_id: String,
    #[serde(rename = "folderID")]
    folder_id: Option<String>,
    instruction: String,
    notes: Vec<Source>,
    created_at: f64,
    #[serde(default)]
    invalidated: bool,
}
struct StoredDraft {
    context: Draft,
    revision: u64,
    proposal: Option<Proposal>,
    proposal_hash: Option<String>,
    applied: bool,
}

fn uuid() -> String {
    Uuid::new_v4().to_string()
}
fn identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
}
fn text(value: &str, max: usize, required: bool) -> Result<()> {
    ensure!(
        value.len() <= max && !value.contains('\0') && (!required || !value.trim().is_empty()),
        "Некорректный или слишком длинный текст перестройки"
    );
    Ok(())
}
fn string<'a>(input: &'a Value, key: &str) -> Result<&'a str> {
    input[key]
        .as_str()
        .with_context(|| format!("Нет поля {key}"))
}
fn uuid_field<'a>(input: &'a Value, key: &str) -> Result<&'a str> {
    let value = string(input, key)?;
    ensure!(
        Uuid::parse_str(value).is_ok(),
        "Некорректный идентификатор перестройки"
    );
    Ok(value)
}
fn increment(value: u64) -> Result<u64> {
    value
        .checked_add(1)
        .filter(|n| *n <= i64::MAX as u64)
        .context("Слишком большая ревизия")
}
fn install(connection: &Connection) -> Result<()> {
    let version: Option<String> = connection
        .query_row(
            "SELECT value FROM workspace_metadata WHERE key='knowledge_rebuild_schema'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    ensure!(
        version.as_deref().is_none_or(|v| v == "1"),
        "Перестройка создана более новой версией приложения"
    );
    // Additive extension: old v1 writers continue to use their existing tables.
    connection.execute_batch("CREATE TABLE IF NOT EXISTS kb_rebuild_drafts(
        id TEXT PRIMARY KEY,context TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,
        proposal TEXT,proposal_hash TEXT,applied INTEGER NOT NULL DEFAULT 0,created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS kb_rebuild_operations(
        operation_id TEXT PRIMARY KEY,draft_id TEXT NOT NULL UNIQUE,request_hash TEXT NOT NULL,
        before_value TEXT NOT NULL,after_value TEXT NOT NULL,result TEXT NOT NULL,
        title TEXT NOT NULL,summary TEXT NOT NULL,applied_at REAL NOT NULL,undone_at REAL);
        INSERT OR IGNORE INTO workspace_metadata(key,value) VALUES('knowledge_rebuild_schema','1');")?;
    Ok(())
}
fn raw_note<'a>(workspace: &'a WorkspaceSnapshot, id: &str) -> Result<&'a Value> {
    workspace.value["notes"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|n| n["id"] == id)
        .context(STALE)
}
fn entity_version(connection: &Connection, id: &str) -> Result<u64> {
    let (version,deleted):(i64,bool)=connection.query_row("SELECT workspace_revision,deleted FROM workspace_entities WHERE kind='note' AND entity_id=?1",[id],|r|Ok((r.get(0)?,r.get::<_,i64>(1)?!=0)))?;
    ensure!(version > 0 && !deleted, "{STALE}");
    Ok(version as u64)
}
fn check_sources(
    root: &Path,
    connection: &Connection,
    workspace: &WorkspaceSnapshot,
    draft: &Draft,
    versions: bool,
) -> Result<()> {
    ensure!(
        !draft.invalidated
            && !draft.notes.is_empty()
            && knowledge::state(connection)?.0 == draft.library_id,
        "{STALE}"
    );
    if versions {
        ensure!(
            draft.created_at <= now() && now() - draft.created_at <= 7.0 * 86400.0,
            "Черновик перестройки устарел. Подготовьте предложение заново."
        );
    }
    let resolver = crate::ai::FeatureResolver::new(root)?;
    // Validate explicit scope even when the notes themselves inherited it.
    if let Some(folder) = &draft.folder_id {
        ensure!(
            resolver
                .features_for(&json!({"folderID":folder}))?
                .knowledge_base,
            "База знаний выключена в этой папке"
        );
    }
    for source in &draft.notes {
        let raw = raw_note(workspace, &source.id)?;
        let current: crate::notes::CapturedNote = serde_json::from_value(raw.clone())?;
        let reference = json!({"noteID":source.id});
        let folder = resolver.folder_for(&reference)?;
        ensure!(
            current.kind == "note"
                && current.trashed_at.is_none()
                && resolver.features_for(&reference)?.knowledge_base
                && folder == source.folder_id
                && draft
                    .folder_id
                    .as_ref()
                    .is_none_or(|scope| folder.as_ref() == Some(scope)),
            "{STALE}"
        );
        if versions {
            ensure!(
                current.revision == source.revision
                    && hash(raw)? == source.fingerprint
                    && entity_version(connection, &source.id)? == source.entity_version,
                "{STALE}"
            );
        }
    }
    Ok(())
}
fn public_context(draft: &Draft, revision: u64) -> Value {
    json!({"draftID":draft.draft_id,"draftRevision":revision,"libraryID":draft.library_id,"instruction":draft.instruction,
        "folderID":draft.folder_id,"createdAt":draft.created_at,"notes":draft.notes.iter().map(|n|json!({"id":n.id,"title":n.title,"text":n.text,"revision":n.revision,"folderID":n.folder_id})).collect::<Vec<_>>()})
}
fn read_draft(connection: &Connection, id: &str) -> Result<StoredDraft> {
    ensure!(
        Uuid::parse_str(id).is_ok(),
        "Некорректный черновик перестройки"
    );
    let row:Option<(String,i64,Option<String>,Option<String>,bool)>=connection.query_row("SELECT context,revision,proposal,proposal_hash,applied FROM kb_rebuild_drafts WHERE id=?1",[id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get::<_,i64>(4)?!=0))).optional()?;
    let (context, revision, proposal, proposal_hash, applied) =
        row.context("Черновик перестройки больше недоступен")?;
    ensure!(revision >= 0, "Повреждён черновик перестройки");
    let context: Draft = serde_json::from_str(&context)?;
    ensure!(context.draft_id == id, "Повреждён черновик перестройки");
    let proposal = proposal
        .map(|s| serde_json::from_str::<Proposal>(&s))
        .transpose()?;
    if let Some(value) = &proposal {
        ensure!(
            proposal_hash.as_ref() == Some(&hash(&serde_json::to_value(value)?)?),
            "Повреждён черновик перестройки"
        );
    }
    Ok(StoredDraft {
        context,
        revision: revision as u64,
        proposal,
        proposal_hash,
        applied,
    })
}
fn prepare(
    root: &Path,
    connection: &mut Connection,
    workspace: &WorkspaceSnapshot,
    input: &Value,
) -> Result<Value> {
    let ids = input["noteIDs"]
        .as_array()
        .context("Выберите заметки для перестройки")?;
    ensure!(
        (1..=MAX_SOURCES).contains(&ids.len()),
        "Выберите от 1 до 30 заметок"
    );
    let instruction = string(input, "instruction")?;
    text(instruction, 4000, true)?;
    let instruction = instruction.trim();
    let folder_id = match input.get("folderID") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if identifier(s) => Some(s.clone()),
        _ => bail!("Некорректная папка перестройки"),
    };
    let resolver = crate::ai::FeatureResolver::new(root)?;
    let mut notes = Vec::new();
    let mut seen = BTreeSet::new();
    let mut bytes = 0;
    for id in ids {
        let id = id.as_str().context("Некорректная заметка")?;
        ensure!(
            identifier(id) && seen.insert(id),
            "Некорректная или повторная заметка"
        );
        let raw = raw_note(workspace, id)?;
        let note: crate::notes::CapturedNote = serde_json::from_value(raw.clone())?;
        let reference = json!({"noteID":id});
        let folder = resolver.folder_for(&reference)?;
        ensure!(
            note.kind == "note"
                && note.trashed_at.is_none()
                && resolver.features_for(&reference)?.knowledge_base
                && folder_id
                    .as_ref()
                    .is_none_or(|scope| folder.as_ref() == Some(scope)),
            "Заметка недоступна в выбранной области"
        );
        bytes += note.text.len() + note.title.len();
        ensure!(
            bytes <= MAX_INPUT,
            "Выбранные заметки превышают 60 КБ текста"
        );
        notes.push(Source {
            id: id.into(),
            title: note.title,
            text: note.text,
            revision: note.revision,
            fingerprint: hash(raw)?,
            entity_version: entity_version(connection, id)?,
            folder_id: folder,
        });
    }
    let draft = Draft {
        draft_id: uuid(),
        library_id: knowledge::state(connection)?.0,
        folder_id,
        instruction: instruction.into(),
        notes,
        created_at: now(),
        invalidated: false,
    };
    check_sources(root, connection, workspace, &draft, true)?;
    let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute(
        "INSERT INTO kb_rebuild_drafts(id,context,created_at) VALUES(?1,?2,?3)",
        params![
            draft.draft_id,
            serde_json::to_string(&draft)?,
            draft.created_at
        ],
    )?;
    // Pending drafts are disposable. Applied drafts remain for replay/undo.
    tx.execute("DELETE FROM kb_rebuild_drafts WHERE applied=0 AND id IN (SELECT id FROM kb_rebuild_drafts WHERE applied=0 ORDER BY created_at DESC,id DESC LIMIT -1 OFFSET 64)",[])?;
    tx.commit()?;
    Ok(public_context(&draft, 0))
}
fn reference(
    reference: &Reference,
    sources: &BTreeSet<&str>,
    keys: &BTreeSet<&str>,
) -> Result<String> {
    match (&reference.note_id, &reference.draft_key) {
        (Some(id), None) if sources.contains(id.as_str()) => Ok(format!("note:{id}")),
        (None, Some(key)) if keys.contains(key.as_str()) => Ok(format!("draft:{key}")),
        _ => bail!("Предложение ссылается на заметку вне выбранных источников"),
    }
}
fn validate_proposal(value: &Value, draft: &Draft) -> Result<Proposal> {
    ensure!(
        serde_json::to_vec(value)?.len() <= MAX_OUTPUT,
        "Предложение превышает 160 КБ"
    );
    let mut proposal: Proposal = serde_json::from_value(value.clone())
        .context("Некорректный формат предложения перестройки")?;
    text(&proposal.title, 500, true)?;
    text(&proposal.summary, 8000, false)?;
    ensure!(
        proposal.edits.len() <= 30
            && proposal.new_notes.len() <= 30
            && proposal.collections.len() <= 12
            && proposal.links.len() <= 60,
        "Слишком много изменений в предложении"
    );
    ensure!(
        !(proposal.edits.is_empty()
            && proposal.new_notes.is_empty()
            && proposal.collections.is_empty()
            && proposal.links.is_empty()),
        "Предложение не содержит изменений"
    );
    let sources = draft
        .notes
        .iter()
        .map(|n| n.id.as_str())
        .collect::<BTreeSet<_>>();
    let mut edited = BTreeSet::new();
    for edit in &proposal.edits {
        ensure!(
            sources.contains(edit.note_id.as_str()) && edited.insert(&edit.note_id),
            "Повторная или недоступная заметка для изменения"
        );
        text(&edit.title, 1024, false)?;
        text(&edit.text, 100_000, false)?;
    }
    let mut keys = BTreeSet::new();
    let mut total_links = 0;
    for note in &proposal.new_notes {
        ensure!(
            identifier(&note.key) && note.key.len() <= 64 && keys.insert(note.key.as_str()),
            "Некорректный или повторный ключ новой заметки"
        );
        text(&note.title, 1024, true)?;
        text(&note.text, 100_000, true)?;
        let mut parents = BTreeSet::new();
        let mut folders = BTreeSet::new();
        ensure!(
            !note.source_note_ids.is_empty() && note.source_note_ids.len() <= MAX_SOURCES,
            "Новой заметке нужны выбранные источники"
        );
        for id in &note.source_note_ids {
            ensure!(
                sources.contains(id.as_str()) && parents.insert(id),
                "Повторный или недоступный источник новой заметки"
            );
            folders.insert(
                draft
                    .notes
                    .iter()
                    .find(|n| &n.id == id)
                    .unwrap()
                    .folder_id
                    .as_deref(),
            );
        }
        ensure!(
            folders.len() == 1,
            "Нельзя объединять заметки из разных папок в одну новую заметку"
        );
        total_links += parents.len();
    }
    let mut group_keys = BTreeSet::new();
    let mut groups = BTreeSet::new();
    for group in &mut proposal.collections {
        ensure!(
            identifier(&group.key)
                && group.key.len() <= 64
                && !keys.contains(group.key.as_str())
                && group_keys.insert(group.key.clone()),
            "Некорректный или повторный ключ подборки"
        );
        group.name = group.name.trim().into();
        text(&group.name, 500, true)?;
        ensure!(
            !group.name.chars().any(char::is_control),
            "Некорректное название подборки"
        );
        ensure!(
            !group.members.is_empty() && group.members.len() <= 60,
            "Некорректный состав подборки"
        );
        let mut members = BTreeSet::new();
        for item in &group.members {
            ensure!(
                members.insert(reference(item, &sources, &keys)?),
                "Повторная заметка в подборке"
            );
        }
        ensure!(groups.insert(members), "Повторный состав подборки");
    }
    let mut pairs = BTreeSet::new();
    // Provenance is a durable source link, included in the common link budget.
    for note in &proposal.new_notes {
        for source in &note.source_note_ids {
            pairs.insert((format!("draft:{}", note.key), format!("note:{source}")));
        }
    }
    for link in &proposal.links {
        let from = reference(&link.from, &sources, &keys)?;
        let to = reference(&link.to, &sources, &keys)?;
        ensure!(
            from != to && pairs.insert((from, to)),
            "Повторная связь или ссылка заметки на саму себя"
        );
        total_links += 1;
    }
    ensure!(
        total_links <= 60,
        "Предложение превышает 60 связей, включая ссылки на источники"
    );
    Ok(proposal)
}
fn preview(
    root: &Path,
    connection: &mut Connection,
    workspace: &WorkspaceSnapshot,
    input: &Value,
) -> Result<Value> {
    let id = uuid_field(input, "draftID")?;
    let saved = read_draft(connection, id)?;
    ensure!(!saved.applied, "Эта перестройка уже применена");
    let expected = input["expectedDraftRevision"]
        .as_u64()
        .context("Нет ревизии черновика")?;
    ensure!(
        saved.revision == expected,
        "Черновик изменился. Проверьте предложение заново."
    );
    check_sources(root, connection, workspace, &saved.context, true)?;
    let proposal = validate_proposal(&input["proposal"], &saved.context)?;
    let digest = hash(&serde_json::to_value(&proposal)?)?;
    let revision = increment(saved.revision)?;
    let before = proposal
        .edits
        .iter()
        .map(|edit| {
            let n = saved
                .context
                .notes
                .iter()
                .find(|n| n.id == edit.note_id)
                .unwrap();
            json!({"noteID":n.id,"title":n.title,"text":n.text,"revision":n.revision})
        })
        .collect::<Vec<_>>();
    ensure!(connection.execute("UPDATE kb_rebuild_drafts SET revision=?1,proposal=?2,proposal_hash=?3 WHERE id=?4 AND revision=?5 AND applied=0",params![revision as i64,serde_json::to_string(&proposal)?,digest,id,expected as i64])?==1,"Черновик изменился. Проверьте предложение заново.");
    Ok(
        json!({"draftID":id,"draftRevision":revision,"libraryID":saved.context.library_id,"proposalHash":digest,"proposal":proposal,"beforeEdits":before}),
    )
}
fn resolved(reference: &Reference, ids: &BTreeMap<String, String>) -> String {
    reference
        .note_id
        .clone()
        .unwrap_or_else(|| ids[reference.draft_key.as_ref().unwrap()].clone())
}
fn row_guard(connection: &Connection, workspace: &WorkspaceSnapshot, id: &str) -> Result<Value> {
    let raw = raw_note(workspace, id)?;
    Ok(json!({"id":id,"fingerprint":hash(raw)?,"entityVersion":entity_version(connection,id)?}))
}
fn dependencies(connection: &Connection, created: &BTreeSet<String>) -> Result<Value> {
    let links = knowledge::list_links(connection)?
        .into_iter()
        .filter(|row| {
            created.contains(row["fromID"].as_str().unwrap_or(""))
                || created.contains(row["toID"].as_str().unwrap_or(""))
        })
        .collect::<Vec<_>>();
    let groups = knowledge::list_collections(connection)?
        .into_iter()
        .filter(|row| {
            row["members"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .any(|id| created.contains(id))
        })
        .collect::<Vec<_>>();
    let meetings = knowledge::list_meeting_links(connection, None)?
        .into_iter()
        .filter(|row| created.contains(row["noteID"].as_str().unwrap_or("")))
        .collect::<Vec<_>>();
    Ok(json!({"links":links,"collections":groups,"meetingLinks":meetings}))
}
fn finish_changes(
    tx: &Transaction<'_>,
    workspace: &WorkspaceSnapshot,
    value: Value,
    operation: &str,
    kind: &str,
) -> Result<(WorkspaceSnapshot, u64)> {
    let (_, kb_revision, _) = knowledge::state(tx)?;
    let kb_next = increment(kb_revision)?;
    let snapshot = commit(tx, Some(workspace), value, kind)?;
    let snapshot = if snapshot.revision == workspace.revision {
        // A proposal containing only groups/links still publishes one workspace
        // event; a text edit already published that event in commit().
        let next = increment(workspace.revision)?;
        tx.execute(
            "UPDATE workspace_state SET revision=?1,updated_at=?2 WHERE singleton=1",
            params![next as i64, now()],
        )?;
        tx.execute("INSERT INTO workspace_outbox VALUES(?1,?2,?3,?4,?5)",params![uuid(),next as i64,kind,now(),serde_json::to_string(&json!({"schemaVersion":1,"workspaceRevision":next,"operationID":operation,"changes":[]}))?])?;
        WorkspaceSnapshot {
            revision: next,
            ..snapshot
        }
    } else {
        snapshot
    };
    // commit may prune newly removed notes during undo and advance KB once.
    let current = knowledge::state(tx)?.1;
    let next = kb_next.max(increment(current)?);
    tx.execute(
        "UPDATE kb_state SET revision=?1,fingerprint=?2 WHERE singleton=1",
        params![next as i64, knowledge::fingerprint(tx)?],
    )?;
    tx.execute(
        "INSERT INTO kb_events VALUES(?1,?2,?3,?4)",
        params![operation, next as i64, kind, now()],
    )?;
    Ok((snapshot, next))
}
fn apply(
    root: &Path,
    connection: &mut Connection,
    workspace: &WorkspaceSnapshot,
    directory: &Path,
    input: &Value,
) -> Result<Value> {
    let id = uuid_field(input, "draftID")?;
    let operation = uuid_field(input, "operationID")?;
    let expected = input["expectedDraftRevision"]
        .as_u64()
        .context("Нет ревизии черновика")?;
    let request = hash(&json!({"draftID":id,"expectedDraftRevision":expected}))?;
    let saved = read_draft(connection, id)?;
    check_sources(root, connection, workspace, &saved.context, false)?;
    if let Some((digest,result,undone))=connection.query_row("SELECT request_hash,result,undone_at IS NOT NULL FROM kb_rebuild_operations WHERE operation_id=?1",[operation],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,bool>(2)?))).optional()? {
        ensure!(digest==request,"Этот ID операции уже использован с другим содержимым"); let mut result:Value=serde_json::from_str(&result)?;result["undone"]=json!(undone);return Ok(result)
    }
    ensure!(
        !saved.applied && saved.revision == expected && expected > 0,
        "Черновик изменился. Проверьте предложение заново."
    );
    let proposal = validate_proposal(
        &serde_json::to_value(saved.proposal.context("Сначала проверьте предложение")?)?,
        &saved.context,
    )?;
    ensure!(
        saved.proposal_hash.as_ref() == Some(&hash(&serde_json::to_value(&proposal)?)?),
        "Предложение изменилось"
    );
    let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    check_sources(root, &tx, workspace, &saved.context, true)?;
    let mut value = workspace.value.clone();
    let timestamp = now();
    let mut before_notes = Vec::new();
    let mut changed_ids = Vec::new();
    let mut ids = BTreeMap::new();
    let notes = value["notes"].as_array_mut().context("Нет заметок")?;
    for edit in &proposal.edits {
        let note = notes
            .iter_mut()
            .find(|n| n["id"] == edit.note_id)
            .context(STALE)?;
        before_notes.push(note.clone());
        changed_ids.push(edit.note_id.clone());
        if note["text"].as_str() != Some(&edit.text) {
            let object = note.as_object_mut().context("Некорректная заметка")?;
            object.insert("contentRTF".into(), json!(""));
            object.remove("contentRtf");
            object.remove("expansion");
        }
        note["title"] = json!(edit.title);
        note["text"] = json!(edit.text);
        note["revision"] = json!(increment(note["revision"].as_u64().unwrap_or(0))?);
        note["updatedAt"] = json!(timestamp);
    }
    for new in &proposal.new_notes {
        let note_id = uuid();
        let source = saved
            .context
            .notes
            .iter()
            .find(|s| s.id == new.source_note_ids[0])
            .unwrap();
        let note: crate::notes::CapturedNote = serde_json::from_value(
            json!({"id":note_id,"kind":"note","title":new.title,"text":new.text,
            "folderID":source.folder_id,"createdAt":timestamp,"updatedAt":timestamp,"revision":1}),
        )?;
        let mut raw = serde_json::to_value(note)?;
        raw["knowledgeRebuildOrigin"] =
            json!({"operationID":operation,"sourceNoteIDs":new.source_note_ids});
        notes.push(raw);
        changed_ids.push(note_id.clone());
        ids.insert(new.key.clone(), note_id);
    }
    validate(&value)?;
    let mut collections = Vec::new();
    let count: i64 = tx.query_row("SELECT COUNT(*) FROM kb_collections", [], |r| r.get(0))?;
    ensure!(
        count + proposal.collections.len() as i64 <= 1000,
        "Достигнут предел сохранённых подборок"
    );
    for group in &proposal.collections {
        let id = uuid();
        let members = group
            .members
            .iter()
            .map(|r| resolved(r, &ids))
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();
        tx.execute(
            "INSERT INTO kb_collections VALUES(?1,?2,?3,1,0,1,?4,?4)",
            params![id, group.name, serde_json::to_string(&members)?, timestamp],
        )?;
        collections.push(id);
    }
    let mut pairs = Vec::new();
    for note in &proposal.new_notes {
        for source in &note.source_note_ids {
            pairs.push((ids[&note.key].clone(), source.clone()));
        }
    }
    for link in &proposal.links {
        pairs.push((resolved(&link.from, &ids), resolved(&link.to, &ids)));
    }
    let mut links = Vec::new();
    for (from, to) in pairs {
        let exists:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM kb_links WHERE from_id=?1 AND to_id=?2 AND relation='manual_link' AND deleted=0)",params![from,to],|r|r.get(0))?;
        if exists {
            continue;
        }
        let id = uuid();
        tx.execute(
            "INSERT INTO kb_links VALUES(?1,?2,?3,'manual_link','',1,0,?4,?4)",
            params![id, from, to, timestamp],
        )?;
        links.push(id);
    }
    let (next, kb_revision) =
        finish_changes(&tx, workspace, value, operation, "knowledge.rebuild")?;
    let created = ids.values().cloned().collect::<BTreeSet<_>>();
    let guards = changed_ids
        .iter()
        .map(|id| row_guard(&tx, &next, id))
        .collect::<Result<Vec<_>>>()?;
    let after = json!({"notes":guards,"collections":knowledge::list_collections(&tx)?.into_iter().filter(|c|collections.iter().any(|id|c["id"]==*id)).collect::<Vec<_>>(),
        "links":knowledge::list_links(&tx)?.into_iter().filter(|l|links.iter().any(|id|l["id"]==*id)).collect::<Vec<_>>(),"dependencies":dependencies(&tx,&created)?});
    let result = json!({"operationID":operation,"draftID":id,"workspaceRevision":next.revision,"kbRevision":kb_revision,
        "editedNoteIDs":proposal.edits.iter().map(|e|&e.note_id).collect::<Vec<_>>(),"createdNotes":ids.iter().map(|(key,id)|json!({"key":key,"noteID":id})).collect::<Vec<_>>(),"collectionIDs":collections,"linkIDs":links,"undone":false});
    tx.execute(
        "INSERT INTO kb_rebuild_operations VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,NULL)",
        params![
            operation,
            id,
            request,
            serde_json::to_string(&json!({"notes":before_notes}))?,
            serde_json::to_string(&after)?,
            serde_json::to_string(&result)?,
            proposal.title,
            proposal.summary,
            timestamp
        ],
    )?;
    ensure!(
        tx.execute(
            "UPDATE kb_rebuild_drafts SET applied=1 WHERE id=?1 AND applied=0 AND revision=?2",
            params![id, expected as i64]
        )? == 1,
        "Черновик изменился"
    );
    check_sources(root, &tx, workspace, &saved.context, false)?;
    #[cfg(test)]
    tests::fail_before_commit(root)?;
    tx.commit()?;
    compatibility_export(directory, &next, true);
    Ok(result)
}
fn created_ids(result: &Value) -> BTreeSet<String> {
    result["createdNotes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|n| n["noteID"].as_str().map(str::to_owned))
        .collect()
}
fn check_undo(
    connection: &Connection,
    workspace: &WorkspaceSnapshot,
    after: &Value,
    result: &Value,
) -> Result<()> {
    for guard in after["notes"]
        .as_array()
        .context("Повреждена квитанция перестройки")?
    {
        let id = string(guard, "id")?;
        ensure!(
            row_guard(connection, workspace, id)? == *guard,
            "{UNDO_CHANGED}"
        );
    }
    let current_groups = knowledge::list_collections(connection)?;
    for row in after["collections"]
        .as_array()
        .context("Повреждена квитанция перестройки")?
    {
        ensure!(current_groups.iter().any(|r| r == row), "{UNDO_CHANGED}");
    }
    let current_links = knowledge::list_links(connection)?;
    for row in after["links"]
        .as_array()
        .context("Повреждена квитанция перестройки")?
    {
        ensure!(current_links.iter().any(|r| r == row), "{UNDO_CHANGED}");
    }
    ensure!(
        dependencies(connection, &created_ids(result))? == after["dependencies"],
        "{UNDO_CHANGED}"
    );
    Ok(())
}
fn undo(
    root: &Path,
    connection: &mut Connection,
    workspace: &WorkspaceSnapshot,
    directory: &Path,
    input: &Value,
) -> Result<Value> {
    let operation = uuid_field(input, "operationID")?;
    let row:Option<(String,String,String,String,bool)>=connection.query_row("SELECT draft_id,before_value,after_value,result,undone_at IS NOT NULL FROM kb_rebuild_operations WHERE operation_id=?1",[operation],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional()?;
    let (draft, before, after, result, undone) = row.context("Операция перестройки не найдена")?;
    let draft = read_draft(connection, &draft)?;
    check_sources(root, connection, workspace, &draft.context, false)?;
    let mut result: Value = serde_json::from_str(&result)?;
    if undone {
        result["undone"] = json!(true);
        return Ok(result);
    }
    let before: Value = serde_json::from_str(&before)?;
    let after: Value = serde_json::from_str(&after)?;
    let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    check_undo(&tx, workspace, &after, &result)?;
    let mut value = workspace.value.clone();
    let created = created_ids(&result);
    let notes = value["notes"].as_array_mut().context("Нет заметок")?;
    notes.retain(|n| !created.contains(n["id"].as_str().unwrap_or("")));
    for original in before["notes"]
        .as_array()
        .context("Повреждена квитанция перестройки")?
    {
        let note = notes
            .iter_mut()
            .find(|n| n["id"] == original["id"])
            .context(UNDO_CHANGED)?;
        let revision = increment(note["revision"].as_u64().unwrap_or(0))?;
        *note = original.clone();
        note["revision"] = json!(revision);
        note["updatedAt"] = json!(now());
    }
    for row in after["collections"].as_array().unwrap() {
        tx.execute(
            "DELETE FROM kb_collections WHERE id=?1",
            [string(row, "id")?],
        )?;
    }
    for row in after["links"].as_array().unwrap() {
        tx.execute("DELETE FROM kb_links WHERE id=?1", [string(row, "id")?])?;
    }
    // Mark this receipt inside the transaction before commit's hard-delete
    // hook: removing our own generated notes is the intended undo, while other
    // drafts depending on those notes must still be invalidated atomically.
    tx.execute(
        "UPDATE kb_rebuild_operations SET undone_at=?1 WHERE operation_id=?2 AND undone_at IS NULL",
        params![now(), operation],
    )?;
    let (next, kb_revision) =
        finish_changes(&tx, workspace, value, &uuid(), "knowledge.rebuild-undo")?;
    result["undone"] = json!(true);
    result["workspaceRevision"] = json!(next.revision);
    result["kbRevision"] = json!(kb_revision);
    tx.execute(
        "UPDATE kb_rebuild_operations SET undone_at=?1,result=?2 WHERE operation_id=?3",
        params![now(), serde_json::to_string(&result)?, operation],
    )?;
    check_sources(root, &tx, workspace, &draft.context, false)?;
    #[cfg(test)]
    tests::fail_before_commit(root)?;
    tx.commit()?;
    compatibility_export(directory, &next, true);
    Ok(result)
}
fn history(
    root: &Path,
    connection: &Connection,
    workspace: &WorkspaceSnapshot,
    input: &Value,
) -> Result<Value> {
    let limit = input
        .get("limit")
        .map(|n| {
            n.as_u64()
                .filter(|n| (1..=50).contains(n))
                .context("Некорректный размер истории")
        })
        .transpose()?
        .unwrap_or(20);
    let mut query=connection.prepare("SELECT operation_id,draft_id,title,summary,applied_at,undone_at,result,after_value FROM kb_rebuild_operations ORDER BY applied_at DESC,operation_id DESC LIMIT ?1")?;
    let rows = query
        .query_map([limit as i64], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, f64>(4)?,
                r.get::<_, Option<f64>>(5)?,
                r.get::<_, String>(6)?,
                r.get::<_, String>(7)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut operations = Vec::new();
    for (operation, draft, title, summary, applied, undone, result, after) in rows {
        let draft = read_draft(connection, &draft)?;
        // Titles/summaries can quote private sources. Revoked scope hides the
        // whole receipt rather than leaking model output through history.
        if check_sources(root, connection, workspace, &draft.context, false).is_err() {
            continue;
        }
        let result: Value = serde_json::from_str(&result)?;
        let after: Value = serde_json::from_str(&after)?;
        operations.push(json!({"operationID":operation,"title":title,"summary":summary,"appliedAt":applied,"undoneAt":undone,
            "createdNoteIDs":created_ids(&result),"editedNoteIDs":result["editedNoteIDs"],"canUndo":undone.is_none() && check_undo(connection,workspace,&after,&result).is_ok()}));
    }
    Ok(json!({"operations":operations}))
}

/// Participate in the existing hard-delete hook, including its replay of old
/// writers' outbox events. Retain only operation tombstones, never deleted text.
pub(super) fn prune_removed(tx: &Transaction<'_>, removed: &BTreeSet<String>) -> Result<bool> {
    let installed:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='kb_rebuild_drafts')",[],|r|r.get(0))?;
    if !installed || removed.is_empty() {
        return Ok(false);
    }
    let mut query = tx.prepare("SELECT id,context FROM kb_rebuild_drafts")?;
    let drafts = query
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(query);
    let mut affected = BTreeSet::new();
    for (id, context) in &drafts {
        let draft: Draft = serde_json::from_str(context)?;
        if draft.notes.iter().any(|n| removed.contains(&n.id)) {
            affected.insert(id.clone());
        }
    }
    let mut query =
        tx.prepare("SELECT draft_id,result FROM kb_rebuild_operations WHERE undone_at IS NULL")?;
    let operations = query
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(query);
    for (id, result) in operations {
        let result: Value = serde_json::from_str(&result)?;
        if !created_ids(&result).is_disjoint(removed) {
            affected.insert(id);
        }
    }
    for (id, context) in drafts {
        if !affected.contains(&id) {
            continue;
        }
        let mut draft: Draft = serde_json::from_str(&context)?;
        draft.invalidated = true;
        draft.notes.clear();
        draft.instruction.clear();
        tx.execute("UPDATE kb_rebuild_drafts SET context=?1,proposal=NULL,proposal_hash=NULL,applied=1 WHERE id=?2",params![serde_json::to_string(&draft)?,id])?;
        tx.execute("UPDATE kb_rebuild_operations SET before_value='null',after_value='null',title='',summary='',undone_at=COALESCE(undone_at,?1) WHERE draft_id=?2",params![now(),id])?;
    }
    Ok(!affected.is_empty())
}

fn locked<T>(
    root: &Path,
    body: impl FnOnce(&Path, &mut Connection, &WorkspaceSnapshot) -> Result<T>,
) -> Result<T> {
    let directory = crate::notes::directory(root)?;
    let _lock = crate::notes::lock(&directory)?;
    crate::corrections::recover_notes_transaction(&directory)?;
    let mut connection = open(&directory)?;
    let workspace = initialize(&mut connection, &directory)?;
    ensure!(
        crate::folders::available_features(root)?.knowledge_base,
        "Включите базу знаний в настройках"
    );
    knowledge::migrate(&mut connection, &directory, &workspace)?;
    install(&connection)?;
    body(&directory, &mut connection, &workspace)
}
pub(super) fn context(root: &Path, id: &str) -> Result<Value> {
    locked(root, |_, connection, workspace| {
        let saved = read_draft(connection, id)?;
        ensure!(!saved.applied, "Эта перестройка уже применена");
        check_sources(root, connection, workspace, &saved.context, true)?;
        Ok(public_context(&saved.context, saved.revision))
    })
}
pub(super) fn dispatch(root: &Path, input: &Value) -> Result<Value> {
    let command = string(input, "command")?;
    ensure!(
        [
            "kb-rebuild-prepare",
            "kb-rebuild-preview",
            "kb-rebuild-apply",
            "kb-rebuild-undo",
            "kb-rebuild-history"
        ]
        .contains(&command),
        "Неизвестная команда перестройки"
    );
    locked(root, |directory, connection, workspace| match command {
        "kb-rebuild-prepare" => prepare(root, connection, workspace, input),
        "kb-rebuild-preview" => preview(root, connection, workspace, input),
        "kb-rebuild-apply" => apply(root, connection, workspace, directory, input),
        "kb-rebuild-undo" => undo(root, connection, workspace, directory, input),
        "kb-rebuild-history" => history(root, connection, workspace, input),
        _ => unreachable!(),
    })
}
#[cfg(test)]
#[path = "knowledge_rebuild/tests.rs"]
mod tests;
