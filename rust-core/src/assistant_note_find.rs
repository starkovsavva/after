//! Deterministic, read-only note lookup for the native assistant.
//! It never creates a model job, writes notes, or grants an external agent access.
use anyhow::{ensure, Context, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields, rename_all="camelCase")]
struct Scope {
    mode: ScopeMode,
    #[serde(rename="folderID", default)]
    folder_id: Option<String>,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all="camelCase")]
enum ScopeMode { Library, Folder }

fn valid_id(id:&str)->bool {
    !id.is_empty() && id.len()<=128 && id.bytes().all(|b|b.is_ascii_alphanumeric() || b==b'-' || b==b'_')
}
fn scope(input:&Value)->Result<Scope> {
    let scope:Scope=serde_json::from_value(input["scope"].clone()).context("Неизвестная область поиска")?;
    match scope.mode {
        ScopeMode::Library => ensure!(scope.folder_id.is_none(),"Некорректная область библиотеки"),
        ScopeMode::Folder => ensure!(scope.folder_id.as_deref().is_some_and(valid_id),"Укажите папку"),
    }
    Ok(scope)
}
fn feature_fingerprint(root:&Path)->Result<String> {
    let path=root.join("settings.json");
    let settings=if path.exists() {crate::storage::regular_json(&path)?} else {json!({})};
    Ok(format!("{:x}",Sha256::digest(serde_json::to_vec(&settings["features"])?)))
}
fn scope_allowed(profiles:&crate::ai::FeatureResolver, scope:&Scope)->Result<()> {
    if let Some(folder)=scope.folder_id.as_deref() {
        ensure!(profiles.features_for(&json!({"folderID":folder}))?.assistant,
            "Помощник выключен в этой папке");
    }
    Ok(())
}
fn folder_of(note:&crate::notes::CapturedNote, folders:&BTreeMap<String,Option<String>>) -> Option<String> {
    note.folder_id.clone().or_else(||note.meeting_id.as_ref().and_then(|id|folders.get(id).cloned().flatten()))
}
fn eligible(note:&crate::notes::CapturedNote, scope:&Scope, folders:&BTreeMap<String,Option<String>>,
            profiles:&crate::ai::FeatureResolver, cache:&mut BTreeMap<Option<String>,bool>)->bool {
    if note.kind!="note" || note.trashed_at.is_some() {return false;}
    let folder=folder_of(note,folders);
    if scope.folder_id.as_ref().is_some_and(|selected|folder.as_ref()!=Some(selected)) {return false;}
    *cache.entry(folder.clone()).or_insert_with(||
        profiles.features_for(&json!({"folderID":folder})).is_ok_and(|settings|settings.assistant))
}
fn clipped(value:&str,max:usize)->String {
    let mut end=value.len().min(max);
    while !value.is_char_boundary(end) {end-=1;}
    value[..end].to_owned()
}
fn target(note:&crate::notes::CapturedNote)->Value {
    let title=if note.title.trim().is_empty() {
        note.text.lines().find(|line|!line.trim().is_empty()).unwrap_or("Заметка")
    } else {note.title.trim()};
    json!({"kind":"note","noteID":note.id,"title":clipped(title,400),"excerpt":clipped(note.text.trim(),700),
        "revision":note.revision,"sourceFingerprint":crate::knowledge::note_fingerprint(note)})
}
fn current_snapshot(root:&Path,revision:u64,settings:&str)->Result<()> {
    let current=crate::workspace_repository::snapshot(root)?;
    ensure!(current.revision==revision && feature_fingerprint(root)?==settings,
        "Заметки или настройки изменились. Повторите поиск.");
    Ok(())
}
fn find(root:&Path,input:&Value)->Result<Value> {
    let scope=scope(input)?;
    let query=input["query"].as_str().context("Введите поисковый запрос")?;
    ensure!(!query.trim().is_empty() && query.len()<=500 && !query.contains('\0'),"Некорректный поисковый запрос");
    let matcher=crate::search::QueryMatcher::new(query)?;
    ensure!(matcher.has_terms(),"Введите слова для поиска");
    let limit=match input.get("limit") {None=>20,Some(value)=>value.as_u64().context("Некорректный лимит")?};
    ensure!((1..=50).contains(&limit),"Допустимо от 1 до 50 результатов");
    ensure!(crate::folders::available_features(root)?.assistant,"Включите помощника в настройках");
    let features=feature_fingerprint(root)?;
    let snapshot=crate::workspace_repository::snapshot(root)?;
    let data:crate::notes::NotesWorkspace=serde_json::from_value(snapshot.value.clone())?;
    let profiles=crate::ai::FeatureResolver::new(root)?;
    scope_allowed(&profiles,&scope)?;
    let folders=data.contexts.iter().map(|context|(context.meeting_id.clone(),context.folder_id.clone())).collect::<BTreeMap<_,_>>();
    let mut permissions=BTreeMap::new();
    let mut matched=Vec::new();
    for note in data.notes {
        if !eligible(&note,&scope,&folders,&profiles,&mut permissions) {continue;}
        let title_match=matcher.matches(&note.title);
        if title_match || matcher.matches(&format!("{} {} {}",note.title,note.text,note.tags.join(" "))) {
            matched.push((title_match,note));
        }
    }
    matched.sort_by(|a,b|b.0.cmp(&a.0).then_with(||b.1.updated_at.total_cmp(&a.1.updated_at)).then_with(||a.1.id.cmp(&b.1.id)));
    let matching=matched.len();
    let targets=matched.into_iter().take(limit as usize).map(|(_,note)|target(&note)).collect::<Vec<_>>();
    #[cfg(test)]
    tests::pause_before_publication(root);
    current_snapshot(root,snapshot.revision,&features)?;
    let fresh=crate::ai::FeatureResolver::new(root)?;
    scope_allowed(&fresh,&scope)?;
    for value in &targets {
        let id=value["noteID"].as_str().context("Некорректная заметка")?;
        let source=json!({"noteID":id});
        ensure!(fresh.features_for(&source)?.assistant &&
            scope.folder_id.as_deref().is_none_or(|folder|fresh.folder_for(&source).is_ok_and(|actual|actual.as_deref()==Some(folder))),
            "Доступ к заметке изменился. Повторите поиск.");
    }
    // The profile lookup above reads separately; fence it against concurrent
    // workspace/settings changes before publishing the bounded result.
    current_snapshot(root,snapshot.revision,&features)?;
    Ok(json!({"state":if targets.is_empty(){"notFound"}else{"results"},"matching":matching,
        "targets":targets,"truncated":matching>limit as usize}))
}
fn validate(root:&Path,input:&Value)->Result<Value> {
    let scope=scope(input)?;
    let selected=&input["target"];
    let Some(id)=selected["noteID"].as_str().filter(|id|valid_id(id)) else {return Ok(json!({"valid":false}));};
    let Some(expected_revision)=selected["revision"].as_u64() else {return Ok(json!({"valid":false}));};
    let Some(expected_fingerprint)=selected["sourceFingerprint"].as_str().filter(|fp|fp.len()==64 && fp.bytes().all(|b|b.is_ascii_hexdigit())) else {return Ok(json!({"valid":false}));};
    if selected["kind"]!="note" {return Ok(json!({"valid":false}));}
    let features=feature_fingerprint(root)?;
    let snapshot=crate::workspace_repository::snapshot(root)?;
    let data:crate::notes::NotesWorkspace=serde_json::from_value(snapshot.value.clone())?;
    let profiles=crate::ai::FeatureResolver::new(root)?;
    if scope_allowed(&profiles,&scope).is_err() {return Ok(json!({"valid":false}));}
    let folders=data.contexts.iter().map(|context|(context.meeting_id.clone(),context.folder_id.clone())).collect::<BTreeMap<_,_>>();
    let mut permissions=BTreeMap::new();
    let valid=data.notes.iter().find(|note|note.id==id).is_some_and(|note|
        eligible(note,&scope,&folders,&profiles,&mut permissions) && note.revision==expected_revision &&
        crate::knowledge::note_fingerprint(note)==expected_fingerprint);
    if current_snapshot(root,snapshot.revision,&features).is_err() {return Ok(json!({"valid":false}));}
    let fresh=crate::ai::FeatureResolver::new(root)?;
    let value=json!({"noteID":id});
    let permitted=scope_allowed(&fresh,&scope).is_ok() && fresh.features_for(&value).is_ok_and(|features|features.assistant) &&
        scope.folder_id.as_deref().is_none_or(|folder|fresh.folder_for(&value).is_ok_and(|actual|actual.as_deref()==Some(folder)));
    Ok(json!({"valid":valid && permitted && current_snapshot(root,snapshot.revision,&features).is_ok()}))
}
pub fn dispatch(root:&Path,input:&Value)->Result<Value> {
    ensure!(root.is_absolute(),"Нужен абсолютный путь библиотеки");
    match input["command"].as_str() {
        Some("assistant-note-find")=>find(root,input),
        Some("assistant-note-validate")=>validate(root,input),
        _=>anyhow::bail!("Неизвестная команда поиска заметок"),
    }
}

#[cfg(test)]
#[path="assistant_note_find/tests.rs"]
mod tests;
