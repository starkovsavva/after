//! Card library and edits share the same per-meeting lock and review journal.
//! Compare-and-swap protects edits, grading and undo against stale windows.
use anyhow::{bail, ensure, Context, Result};
use chrono::{SecondsFormat, Utc};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{fs, path::{Path, PathBuf}};
use uuid::Uuid;
use crate::storage::{atomic_json, meeting_directory, meeting_lock, regular_json, recover_review, schedule};

fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> { v[key].as_str().with_context(|| format!("Нет поля {key}")) }
fn fingerprint(v: &Value) -> String { format!("{:x}", Sha256::digest(serde_json::to_vec(v).unwrap_or_default())) }
fn read(path: &Path, default: Value) -> Result<Value> {
    match fs::symlink_metadata(path) {
        Ok(meta) => { ensure!(meta.len() <= 8 * 1_048_576, "Файл карточек слишком большой"); regular_json(path) }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(default),
        Err(e) => Err(e.into()),
    }
}
fn card_index(summary: &Value, id: &str) -> Result<usize> {
    summary["cards"].as_array().context("В конспекте нет списка карточек")?.iter().position(|c| c["id"].as_str() == Some(id)).context("Карточка уже удалена")
}
fn checked_card<'a>(summary: &'a Value, input: &Value) -> Result<(usize, &'a Value)> {
    let index = card_index(summary, text(input, "cardID")?)?;
    let card = &summary["cards"][index];
    ensure!(text(input,"expectedFingerprint")? == fingerprint(card), "Карточка изменилась. Закройте редактор и откройте актуальную версию.");
    Ok((index, card))
}
fn valid_card(card: &Value) -> bool {
    ["id", "kind", "front", "back", "context"].iter().all(|k| card[*k].is_string()) &&
        ["front", "back"].iter().all(|key| card[*key].as_str().is_some_and(|text| !text.trim().is_empty())) &&
        card["segmentIDs"].as_array().is_some_and(|ids| ids.iter().all(|id| id.as_i64().is_some()))
}
fn library(root: &Path, input: &Value) -> Result<Value> {
    let mut entries = Vec::new(); let mut errors = Vec::new();
    for meeting in crate::storage::list_meetings(root)? {
        let id = text(&meeting,"id")?;
        if input["meetingID"].as_str().is_some_and(|wanted| wanted != id) { continue; }
        let result = (|| -> Result<()> {
            let dir = meeting_directory(root,id)?; let _lock = meeting_lock(&dir)?; recover_review(&dir)?;
            let summary = read(&dir.join("summary.json"), Value::Null)?;
            if summary.is_null() { return Ok(()); }
            let cards = summary["cards"].as_array().context("Конспект не содержит список карточек")?;
            let reviews = read(&dir.join("review-state.json"), json!({}))?;
            let examples = read(&dir.join("examples.json"), json!({}))?;
            ensure!(reviews.is_object() && examples.is_object(), "Повреждена история или примеры карточек");
            for card in cards {
                let card_id = card["id"].as_str().unwrap_or("");
                let review = &reviews[card_id]; let example = &examples[card_id];
                let valid_review = review.is_null() || (review["due"].as_str().is_some_and(|date| chrono::DateTime::parse_from_rfc3339(date).is_ok()) && review["count"].as_u64().is_some_and(|count| count <= i64::MAX as u64) && review["lastRating"].as_u64().is_some_and(|rating| (1..=4).contains(&rating)));
                let valid_example = example.is_null() || ["example", "translation", "explanation"].iter().all(|key| example[*key].is_string());
                if !valid_card(card) || !valid_review || !valid_example {
                    errors.push(format!("{}: не удалось прочитать карточку или её историю", meeting["title"].as_str().unwrap_or("Встреча")));
                    continue;
                }
                entries.push(json!({"meeting":meeting,"card":card,"sourceStale":summary["sourceStale"].as_bool().unwrap_or(false),"fingerprint":fingerprint(card),"suspended":card["suspended"].as_bool().unwrap_or(false),"exampleIsStale":!examples[text(card,"id")?].is_null() && examples[text(card,"id")?]["cardFingerprint"].as_str().map(|hash|hash!=fingerprint(card)).unwrap_or(card.get("editedAt").is_some()),"review":reviews[text(card,"id")?],"reviewFingerprint":fingerprint(&reviews[text(card,"id")?]),"example":examples[text(card,"id")?]}));
            }
            Ok(())
        })();
        if let Err(e) = result { errors.push(format!("{}: {e}", meeting["title"].as_str().unwrap_or("Встреча"))); }
    }
    Ok(json!({"entries":entries,"errors":errors}))
}
fn new_deck(root: &Path, title: &str, card: Value) -> Result<Value> {
    ensure!(!title.trim().is_empty() && title.len() <= 512, "Укажите название колоды до 512 символов");
    let id = Uuid::new_v4().to_string(); let dir = meeting_directory(root,&id)?;
    fs::create_dir(&dir)?;
    let result = (|| -> Result<Value> {
        let now = Utc::now().timestamp_millis() as f64 / 1000.0;
        atomic_json(&dir.join("summary.json"), &json!({"overview":"","items":[],"cards":[card],"provider":"manual","model":"manual","generatedAt":now,"warnings":[],"overviewClaims":[]}))?;
        // Keep a regular source file for compatibility with deck import/export.
        use std::{io::Write, os::unix::fs::OpenOptionsExt};
        let mut source = fs::OpenOptions::new().create_new(true).write(true).mode(0o600).open(dir.join("cards.tsv"))?;
        source.write_all(b"#separator:tab\n#html:false\n#columns:Front\tBack\tContext\tTags\n")?; source.sync_all()?;
        let meeting = json!({"id":id,"title":title.trim(),"createdAt":now,"source":"cards.tsv","status":"ready","duration":0,"speakerNames":{},"completedTasks":[],"focus":"","recordingTracks":false,"hasVideo":false,"libraryKind":"cards"});
        atomic_json(&dir.join("meta.json"), &meeting)?;
        Ok(json!({"meeting":meeting,"card":card}))
    })();
    if result.is_err() { let _=fs::remove_dir_all(&dir); }
    result
}
fn save(root: &Path, input: &Value) -> Result<Value> {
    let front = text(input,"front")?.trim(); let back = text(input,"back")?.trim();
    ensure!(!front.is_empty() && !back.is_empty(), "Заполните вопрос и ответ");
    ensure!(front.len() <= 200_000 && back.len() <= 200_000 && !front.contains('\0') && !back.contains('\0'), "Текст карточки слишком длинный или содержит нулевой байт");
    let kind = input["kind"].as_str().unwrap_or("phrase"); ensure!(["phrase","concept"].contains(&kind), "Неизвестный тип карточки");
    if input["meetingID"].as_str().filter(|s| !s.is_empty()).is_none() {
        ensure!(input["cardID"].as_str().is_none(), "Для правки выберите колоду");
        return new_deck(root,input["newDeckTitle"].as_str().unwrap_or("Мои карточки"),json!({"id":Uuid::new_v4().to_string(),"kind":kind,"front":front,"back":back,"context":"","segmentIDs":[],"editedAt":Utc::now().timestamp_millis()}));
    }
    let id = text(input,"meetingID")?; let dir = meeting_directory(root,id)?; let _lock = meeting_lock(&dir)?;
    recover_review(&dir)?;
    let meta = regular_json(&dir.join("meta.json"))?;
    let mut summary = read(&dir.join("summary.json"),Value::Null)?;
    if summary.is_null() {
        ensure!(input["cardID"].is_null(), "Карточка не найдена");
        summary=json!({"overview":"","items":[],"cards":[],"provider":"manual","model":"manual","generatedAt":Utc::now().timestamp_millis() as f64/1000.0,"warnings":[],"overviewClaims":[]});
    }
    let index = if input["cardID"].as_str().is_some() { Some(checked_card(&summary,input)?.0) } else { None };
    let mut card = index.map(|i|summary["cards"][i].clone()).unwrap_or_else(|| json!({"id":Uuid::new_v4().to_string(),"context":"","segmentIDs":[]}));
    card["front"]=json!(front); card["back"]=json!(back); card["kind"]=json!(kind); card["editedAt"]=json!(Utc::now().timestamp_millis());
    let cards = summary["cards"].as_array_mut().context("Нет списка карточек")?;
    if let Some(i)=index { cards[i]=card.clone(); } else { ensure!(cards.len()<10_000,"В колоде уже 10 000 карточек"); cards.push(card.clone()); }
    ensure!(serde_json::to_vec(&summary)?.len() <= 8*1_048_576, "Колода превышает 8 МБ");
    atomic_json(&dir.join("summary.json"),&summary)?;
    Ok(json!({"meeting":meta,"card":card}))
}
fn mutate(root: &Path, input: &Value, delete: bool) -> Result<Value> {
    let dir = meeting_directory(root,text(input,"meetingID")?)?; let _lock = meeting_lock(&dir)?; recover_review(&dir)?;
    let mut summary = regular_json(&dir.join("summary.json"))?; let (index,card)=checked_card(&summary,input)?; let old = card.clone();
    if delete {
        summary["cards"].as_array_mut().unwrap().remove(index);
        if summary.get("archivedCards").is_none() { summary["archivedCards"]=json!([]); }
        summary["archivedCards"].as_array_mut().context("Повреждён архив карточек")?.push(json!({"card":old,"deletedAt":Utc::now().timestamp_millis()}));
    } else { summary["cards"][index]["suspended"]=json!(input["suspended"].as_bool().context("Нет состояния повторения")?); }
    atomic_json(&dir.join("summary.json"),&summary)?;
    Ok(json!({"saved":true}))
}
fn review_parts(root: &Path, input: &Value) -> Result<(PathBuf, fs::File, Value, Value)> {
    let dir=meeting_directory(root,text(input,"meetingID")?)?; let lock=meeting_lock(&dir)?; recover_review(&dir)?;
    let summary=regular_json(&dir.join("summary.json"))?; let (_,card)=checked_card(&summary,input)?;
    ensure!(card["suspended"]!=true,"Карточка исключена из повторения");
    let states=read(&dir.join("review-state.json"),json!({}))?; ensure!(states.is_object(),"Повреждена история карточек");
    ensure!(input["expectedReviewFingerprint"].as_str() == Some(fingerprint(&states[text(card,"id")?]).as_str()), "История повторений изменилась. Обновите карточки перед оценкой.");
    Ok((dir,lock,card.clone(),states))
}
fn preview(root:&Path,input:&Value)->Result<Value> {
    let (_, _lock, card, states)=review_parts(root,input)?; let now=Utc::now(); let mut options=Vec::new();
    for rating in 1..=4 { let (next,_) = schedule(states.get(text(&card,"id")?),rating,now)?;
        let due=chrono::DateTime::parse_from_rfc3339(text(&next,"due")?)?;
        options.push(json!({"rating":rating,"due":next["due"],"intervalSeconds":((due.with_timezone(&Utc)-now).num_milliseconds()+500)/1000})); }
    Ok(json!({"options":options}))
}
fn review(root:&Path,input:&Value)->Result<Value> {
    let (dir, _lock, card, mut states)=review_parts(root,input)?; let card_id=text(&card,"id")?;
    let rating=input["rating"].as_u64().filter(|n|(1..=4).contains(n)).context("Оценка должна быть от 1 до 4")? as u8;
    let before=states.get(card_id).cloned().unwrap_or(Value::Null); let (state,log)=schedule(states.get(card_id),rating,Utc::now())?;
    states[card_id]=state.clone(); let token=Uuid::new_v4().to_string(); let review_id=Uuid::new_v4().to_string();
    let undo=json!({"undoID":token,"cardID":card_id,"fingerprint":fingerprint(&card),"before":before,"after":state,"reviewID":review_id});
    atomic_json(&dir.join("review-pending.json"), &json!({"states":states,"entry":{"cardID":card_id,"reviewID":review_id,"scheduler":"fsrs-rs/6.6.2","review":log},"undo":undo}))?;
    recover_review(&dir)?;
    Ok(json!({"state":state,"undoID":token,"meetingID":input["meetingID"],"cardID":card_id}))
}
fn undo(root:&Path,input:&Value)->Result<Value> {
    let dir=meeting_directory(root,text(input,"meetingID")?)?; let _lock=meeting_lock(&dir)?; recover_review(&dir)?;
    let undo=read(&dir.join("cards-review-undo.json"),Value::Null)?;
    ensure!(!undo.is_null() && text(input,"undoID")? == text(&undo,"undoID")?,"Это повторение уже нельзя отменить");
    let card_id=text(&undo,"cardID")?; let summary=regular_json(&dir.join("summary.json"))?;
    let i=card_index(&summary,card_id)?; ensure!(fingerprint(&summary["cards"][i])==text(&undo,"fingerprint")?,"Карточка уже изменена. Отмена сохранит новые данные.");
    let mut states=read(&dir.join("review-state.json"),json!({}))?;
    ensure!(states.get(card_id)==undo.get("after"),"Повторение уже изменено. Отмена сохранит новые данные.");
    if undo["before"].is_null() { states.as_object_mut().context("Повреждена история")?.remove(card_id); } else { states[card_id]=undo["before"].clone(); }
    atomic_json(&dir.join("review-pending.json"), &json!({"states":states,"entry":{"cardID":card_id,"reviewID":Uuid::new_v4().to_string(),"undoOf":undo["reviewID"],"undoneAt":Utc::now().to_rfc3339_opts(SecondsFormat::Millis,true)},"undo":null}))?;
    recover_review(&dir)?; Ok(json!({"undone":true,"cardID":card_id}))
}
pub(super) fn dispatch(root:&Path,input:&Value)->Result<Value> {
    match input["command"].as_str() {
        Some("cards-library")=>library(root,input),Some("card-save")=>save(root,input),Some("card-delete")=>mutate(root,input,true),Some("card-suspend")=>mutate(root,input,false),
        Some("cards-review-preview")=>preview(root,input),Some("cards-review")=>review(root,input),Some("cards-review-undo")=>undo(root,input),_=>bail!("Неизвестная команда карточек"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request(root:&Path,command:&str,mut args:Value)->Result<Value> { args["command"]=json!(command); dispatch(root,&args) }
    fn deck(root:&Path)->Value { request(root,"card-save",json!({"front":"follow up","back":"вернуться к вопросу","newDeckTitle":"Рабочий английский"})).unwrap() }
    fn entry(root:&Path)->Value { request(root,"cards-library",json!({})).unwrap()["entries"][0].clone() }
    fn args(entry:&Value)->Value { json!({"meetingID":entry["meeting"]["id"],"cardID":entry["card"]["id"],"expectedFingerprint":entry["fingerprint"],"expectedReviewFingerprint":entry["reviewFingerprint"]}) }
    #[test] fn edit_preserves_context_and_examples_and_rejects_stale_write() {
        let temp=tempfile::tempdir().unwrap(); let created=deck(temp.path()); let id=created["meeting"]["id"].as_str().unwrap(); let dir=meeting_directory(temp.path(),id).unwrap();
        let mut summary=regular_json(&dir.join("summary.json")).unwrap(); summary["cards"][0]["context"]=json!("original quote"); summary["cards"][0]["segmentIDs"]=json!([3]); atomic_json(&dir.join("summary.json"),&summary).unwrap();
        let example=json!({created["card"]["id"].as_str().unwrap():{"example":"A new example","translation":"Пример","explanation":""}}); atomic_json(&dir.join("examples.json"),&example).unwrap();
        let old=entry(temp.path()); let mut edit=args(&old); edit["front"]=json!("follow up on"); edit["back"]=json!("уточнить"); request(temp.path(),"card-save",edit.clone()).unwrap();
        assert!(request(temp.path(),"card-save",edit).is_err()); let new=entry(temp.path()); assert_eq!(new["card"]["context"],"original quote"); assert_eq!(new["card"]["segmentIDs"],json!([3])); assert_eq!(new["example"]["example"],"A new example");
    }
    #[test] fn suspend_and_delete_are_cas_and_preserve_archived_source() {
        let temp=tempfile::tempdir().unwrap(); deck(temp.path()); let original=entry(temp.path()); let mut a=args(&original); a["suspended"]=json!(true); request(temp.path(),"card-suspend",a).unwrap();
        let suspended=entry(temp.path()); assert_eq!(suspended["suspended"],true); assert!(request(temp.path(),"cards-review-preview",args(&suspended)).is_err());
        assert!(request(temp.path(),"card-delete",args(&original)).is_err()); request(temp.path(),"card-delete",args(&suspended)).unwrap(); assert_eq!(request(temp.path(),"cards-library",json!({})).unwrap()["entries"],json!([]));
        let dir=meeting_directory(temp.path(),suspended["meeting"]["id"].as_str().unwrap()).unwrap(); assert_eq!(regular_json(&dir.join("summary.json")).unwrap()["archivedCards"][0]["card"]["front"],"follow up");
    }
    #[test] fn real_fsrs_preview_matches_review_and_undo_restores_previous_history() {
        let temp=tempfile::tempdir().unwrap(); deck(temp.path()); let e=entry(temp.path()); let a=args(&e); let options=request(temp.path(),"cards-review-preview",a.clone()).unwrap(); assert_eq!(options["options"][0]["intervalSeconds"],60); assert_eq!(options["options"][2]["intervalSeconds"],600);
        let mut grade=a.clone(); grade["rating"]=json!(3); let saved=request(temp.path(),"cards-review",grade).unwrap(); assert_eq!(saved["state"]["count"],1);
        let undo=json!({"meetingID":saved["meetingID"],"undoID":saved["undoID"]}); request(temp.path(),"cards-review-undo",undo.clone()).unwrap(); assert!(entry(temp.path())["review"].is_null()); assert!(request(temp.path(),"cards-review-undo",undo).is_err());
    }
    #[test] fn stale_undo_cannot_overwrite_a_new_rating() {
        let temp=tempfile::tempdir().unwrap(); deck(temp.path()); let mut a=args(&entry(temp.path())); a["rating"]=json!(3); let old=request(temp.path(),"cards-review",a.clone()).unwrap(); let mut fresh=args(&entry(temp.path())); fresh["rating"]=json!(3); request(temp.path(),"cards-review",fresh).unwrap();
        assert!(request(temp.path(),"cards-review-undo",json!({"meetingID":old["meetingID"],"undoID":old["undoID"]})).is_err()); assert_eq!(entry(temp.path())["review"]["count"],2);
    }
    #[test] fn malformed_deck_reports_error_without_hiding_good_entries() {
        let temp=tempfile::tempdir().unwrap(); deck(temp.path()); let second=deck(temp.path()); let dir=meeting_directory(temp.path(),second["meeting"]["id"].as_str().unwrap()).unwrap(); fs::write(dir.join("summary.json"),b"broken").unwrap();
        let lib=request(temp.path(),"cards-library",json!({})).unwrap(); assert_eq!(lib["entries"].as_array().unwrap().len(),1); assert_eq!(lib["errors"].as_array().unwrap().len(),1);
    }
    #[test] fn one_invalid_review_does_not_make_the_whole_library_look_empty() {
        let temp=tempfile::tempdir().unwrap(); let first=deck(temp.path()); let second=deck(temp.path()); let dir=meeting_directory(temp.path(),second["meeting"]["id"].as_str().unwrap()).unwrap();
        atomic_json(&dir.join("review-state.json"),&json!({second["card"]["id"].as_str().unwrap():{"due":"invalid","count":"bad","lastRating":3}})).unwrap();
        let lib=request(temp.path(),"cards-library",json!({})).unwrap(); assert_eq!(lib["entries"].as_array().unwrap().len(),1); assert_eq!(lib["entries"][0]["meeting"]["id"],first["meeting"]["id"]); assert_eq!(lib["errors"].as_array().unwrap().len(),1);
    }
    #[test] fn transcript_edits_and_stale_examples_remain_explicit_without_resetting_cards() {
        let temp=tempfile::tempdir().unwrap(); let created=deck(temp.path()); let dir=meeting_directory(temp.path(),created["meeting"]["id"].as_str().unwrap()).unwrap();
        let mut summary=regular_json(&dir.join("summary.json")).unwrap(); summary["sourceStale"]=json!(true); atomic_json(&dir.join("summary.json"),&summary).unwrap();
        atomic_json(&dir.join("examples.json"),&json!({created["card"]["id"].as_str().unwrap():{"example":"Old practice","translation":"Старый пример","explanation":""}})).unwrap();
        let e=entry(temp.path()); assert_eq!(e["sourceStale"],true); assert_eq!(e["exampleIsStale"],true); assert_eq!(e["card"],created["card"]); assert!(e["review"].is_null());
    }
    #[test] fn concurrent_stale_windows_cannot_rate_twice() {
        let temp=tempfile::tempdir().unwrap(); deck(temp.path()); let mut a=args(&entry(temp.path())); a["rating"]=json!(3);
        let gate=std::sync::Arc::new(std::sync::Barrier::new(2)); let mut threads=Vec::new();
        for _ in 0..2 { let root=temp.path().to_path_buf(); let a=a.clone(); let gate=gate.clone(); threads.push(std::thread::spawn(move|| { gate.wait(); request(&root,"cards-review",a) })); }
        let results:Vec<_>=threads.into_iter().map(|t|t.join().unwrap()).collect(); assert_eq!(results.iter().filter(|r|r.is_ok()).count(),1); assert_eq!(entry(temp.path())["review"]["count"],1);
    }
    #[test] fn symlinks_and_blank_cards_are_rejected() {
        use std::os::unix::fs::symlink; let temp=tempfile::tempdir().unwrap(); assert!(request(temp.path(),"card-save",json!({"front":"  ","back":"a"})).is_err()); deck(temp.path()); let e=entry(temp.path()); let dir=meeting_directory(temp.path(),e["meeting"]["id"].as_str().unwrap()).unwrap(); let external=temp.path().join("outside.json"); fs::rename(dir.join("summary.json"),&external).unwrap(); symlink(&external,dir.join("summary.json")).unwrap(); assert!(request(temp.path(),"card-delete",args(&e)).is_err()); assert!(external.exists());
    }
}
