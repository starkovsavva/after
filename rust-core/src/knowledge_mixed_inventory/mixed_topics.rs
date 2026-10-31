//! Closed, non-publishing experiment for note/meeting candidate groups.
//!
//! No FFI, CLI, MCP, or UI route may use these drafts. The checks here detect
//! ordinary changes, but cannot serialize a legacy process changing policy or
//! prove meeting incarnation. Thus the result is not an authorization decision.
use super::*;
use crate::notes::CapturedNote;
use serde_json::json;
use std::collections::BTreeSet;

const MAX_NOTES:usize=2_000;
const MAX_MEETINGS:usize=200;
const MAX_PAIR_CHECKS:usize=50_000;
const MAX_MEETINGS_PER_TOPIC:usize=3;
const MAX_EVIDENCE_CONSIDERED:usize=16;

#[derive(Clone,Debug,PartialEq,Eq)]
struct EvidenceRef {
    kind:String,
    segment_id:Option<u64>,
    item_index:Option<usize>,
    content_fingerprint:String,
    policy_fingerprint:String,
}
#[derive(Clone,Debug,PartialEq,Eq)]
enum SourceRef {
    Note { id:String, revision:u64, fingerprint:String },
    Meeting { id:String, fingerprint:String, evidence:Vec<EvidenceRef> },
}
#[derive(Debug)]
struct Draft {
    sources:Vec<SourceRef>,
    /// Explanations come from the permitted note, never from omitted sources.
    shared_terms:Vec<String>,
}
#[derive(Debug)]
struct Drafts {
    topics:Vec<Draft>,
    examined_notes:usize,
    total_notes:usize,
    examined_meetings:usize,
    total_meetings:usize,
    pair_checks:usize,
    /// This experiment covers cross-type groups only, so it is always partial.
    partial:bool,
    /// Further coverage may be lost to input, comparison or per-topic limits.
    coverage_capped:bool,
}

fn permitted_notes(root:&Path,folder:Option<&str>,workspace:&crate::notes::NotesWorkspace)->Result<Vec<CapturedNote>> {
    let resolver=crate::ai::FeatureResolver::new(root)?;
    let mut notes=Vec::new();
    for note in &workspace.notes {
        if note.kind!="note" || note.trashed_at.is_some() {continue;}
        let source=json!({"noteID":note.id});
        if !resolver.in_scope(&source,&json!({"folderID":folder})) {continue;}
        if !resolver.features_for(&source).is_ok_and(|features|features.knowledge_base) {continue;}
        notes.push(note.clone());
    }
    notes.sort_by(|a,b|a.id.cmp(&b.id));
    Ok(notes)
}

/// Compare at most 2,000 notes and 200 meetings with a hard bound on pair
/// scoring. The local term matcher is not semantic inference; its output is a
/// suggestion and must never be advertised as exhaustive or high-confidence.
fn build(root:&Path,inventory:&Inventory,checkpoint:&checkpoint::Checkpoint,cancelled:&impl Fn()->bool) -> Result<Drafts> {
    ensure!(!cancelled(),"Построение тем остановлено");
    ensure!(inventory.root==root,"Некорректная библиотека индекса");
    let before=crate::notes::list(root)?;
    let mut notes=permitted_notes(root,inventory.folder.as_deref(),&before)?;
    let total_notes=notes.len();
    notes.truncate(MAX_NOTES);
    let (meetings,total_meetings,incomplete_meetings)=checkpoint.collect(inventory,MAX_MEETINGS,cancelled)?;
    // Matching, threshold and order depend only on evidence eventually
    // retained in the draft. Titles and omitted fragments cannot change them.
    let mut evidence_capped=false;
    let mut meeting_evidence=Vec::with_capacity(meetings.len());
    for meeting in &meetings {
        ensure!(!cancelled(),"Построение тем остановлено");
        evidence_capped |= meeting.evidence.len()>MAX_EVIDENCE_CONSIDERED;
        let indexed=meeting.evidence.iter().take(MAX_EVIDENCE_CONSIDERED).map(|source|(
            EvidenceRef {kind:source.kind.clone(),segment_id:source.segment_id,item_index:source.item_index,
                content_fingerprint:source.content_fingerprint.clone(),policy_fingerprint:source.policy_fingerprint.clone()},
            crate::search::related_terms("",&source.text))).collect::<Vec<_>>();
        meeting_evidence.push(indexed);
    }
    let mut topics=Vec::new();
    let mut pair_checks=0usize;
    let mut capped=false;
    let mut groups_capped=false;
    for note in &notes {
        ensure!(!cancelled(),"Построение тем остановлено");
        let terms=crate::search::related_terms(&note.title,&note.text);
        let mut matches=Vec::new();
        for (index,indexed) in meeting_evidence.iter().enumerate() {
            if pair_checks>=MAX_PAIR_CHECKS {capped=true;break;}
            if pair_checks%128==0 {ensure!(!cancelled(),"Построение тем остановлено");}
            pair_checks+=1;
            let mut evidence=indexed.iter().enumerate().filter_map(|(source_index,(_,source_terms))| {
                let supported=terms.keys().filter(|stem|source_terms.contains_key(*stem)).cloned().collect::<BTreeSet<_>>();
                // Two unrelated one-word fragments cannot manufacture a link.
                (supported.len()>=2).then_some((source_index,supported))
            }).collect::<Vec<_>>();
            evidence.sort_by(|a,b|b.1.len().cmp(&a.1.len()).then_with(||indexed[a.0].0.kind.cmp(&indexed[b.0].0.kind))
                .then_with(||indexed[a.0].0.segment_id.cmp(&indexed[b.0].0.segment_id))
                .then_with(||indexed[a.0].0.item_index.cmp(&indexed[b.0].0.item_index)));
            groups_capped |= evidence.len()>5;
            evidence.truncate(5);
            if evidence.is_empty() {continue;}
            let selected_terms=evidence.iter().flat_map(|(source,_)|indexed[*source].1.keys().cloned()).collect::<BTreeSet<_>>();
            let shared=evidence.iter().flat_map(|(_,supported)|supported.iter().cloned()).collect::<BTreeSet<_>>();
            let denominator=((terms.len()*selected_terms.len()) as f64).sqrt();
            let score=if denominator>0.0 {shared.len() as f64/denominator} else {0.0};
            if score<0.20 {continue;}
            let selected=evidence.iter().map(|(source,_)|indexed[*source].0.clone()).collect::<Vec<_>>();
            matches.push((index,score,shared,selected));
        }
        matches.sort_by(|a,b|b.1.total_cmp(&a.1).then_with(||b.2.len().cmp(&a.2.len()))
            .then_with(||meetings[a.0].meeting_id.cmp(&meetings[b.0].meeting_id)));
        groups_capped |= matches.len()>MAX_MEETINGS_PER_TOPIC;
        matches.truncate(MAX_MEETINGS_PER_TOPIC);
        if !matches.is_empty() {
            let mut sources=vec![SourceRef::Note{id:note.id.clone(),revision:note.revision,
                fingerprint:crate::knowledge::note_fingerprint(note)}];
            let mut explanations=BTreeSet::new();
            for (index,_,shared,evidence) in matches {
                for stem in shared {if let Some((word,_))=terms.get(&stem) {explanations.insert(word.clone());}}
                sources.push(SourceRef::Meeting {id:meetings[index].meeting_id.clone(),
                    fingerprint:format!("{:x}",Sha256::digest(serde_json::to_vec(&meetings[index])?)),evidence});
            }
            topics.push(Draft {sources,shared_terms:explanations.into_iter().take(4).collect()});
        }
        if capped {break;}
    }
    ensure!(!cancelled(),"Построение тем остановлено");
    let after=crate::notes::list(root)?;
    ensure!(serde_json::to_vec(&before)?==serde_json::to_vec(&after)?,"Заметки изменились. Обновите темы.");
    // Re-resolve policies for all inputs, not only the sources that happen to
    // survive in the groups: excluded inputs must not influence their labels.
    let after_notes=permitted_notes(root,inventory.folder.as_deref(),&after)?;
    ensure!(after_notes.len()==total_notes && after_notes.iter().zip(&notes).all(|(a,b)|a==b),
        "Доступ к заметкам изменился. Обновите темы.");
    ensure!(checkpoint.audit_with_cancel(inventory,cancelled)?,"Доступ к встречам изменился. Обновите темы.");
    ensure!(!cancelled(),"Построение тем остановлено");
    Ok(Drafts {topics,examined_notes:notes.len(),total_notes,examined_meetings:meetings.len(),total_meetings,
        pair_checks,partial:true,
        coverage_capped:total_notes>MAX_NOTES || total_meetings>MAX_MEETINGS || incomplete_meetings || capped || groups_capped || evidence_capped})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::atomic_json;
    use std::sync::atomic::{AtomicBool,Ordering};

    fn setup()->tempfile::TempDir {
        let root=tempfile::tempdir().unwrap();
        atomic_json(&root.path().join("settings.json"),&json!({"features":{"knowledgeBase":true}})).unwrap();
        root
    }
    fn meeting(root:&Path,id:&str,text:&str) {
        let dir=root.join("meetings").join(id);
        atomic_json(&dir.join("meta.json"),&json!({"id":id,"title":"Разговор","source":"a.mp3","createdAt":1,"status":"ready"})).unwrap();
        atomic_json(&dir.join("transcript.json"),&json!({"segments":[{"id":1,"start":0,"end":1,"text":text}]})).unwrap();
        let fingerprint=format!("{:x}",Sha256::digest(fs::read(dir.join("transcript.json")).unwrap()));
        atomic_json(&dir.join("summary.json"),&json!({"sourceFingerprint":fingerprint,"overview":text})).unwrap();
    }
    fn note(root:&Path,id:&str,text:&str,folder:Option<&str>) {
        let value=json!({"id":id,"kind":"note","text":text,"createdAt":1,"updatedAt":1,"revision":0,"folderID":folder});
        crate::notes::save_note(root,serde_json::from_value(value).unwrap()).unwrap();
    }
    fn meeting_fragments(root:&Path,id:&str,fragments:&[&str]) {
        let dir=root.join("meetings").join(id);
        atomic_json(&dir.join("meta.json"),&json!({"id":id,"title":"Разговор","source":"a.mp3","createdAt":1,"status":"ready"})).unwrap();
        let segments=fragments.iter().enumerate().map(|(i,text)|json!({"id":i+1,"start":i,"end":i+1,"text":text})).collect::<Vec<_>>();
        atomic_json(&dir.join("transcript.json"),&json!({"segments":segments})).unwrap();
        let fingerprint=format!("{:x}",Sha256::digest(fs::read(dir.join("transcript.json")).unwrap()));
        let items=fragments.iter().enumerate().map(|(i,text)|json!({"text":text,"segmentIDs":[i+1]})).collect::<Vec<_>>();
        atomic_json(&dir.join("summary.json"),&json!({"sourceFingerprint":fingerprint,"items":items})).unwrap();
    }
    fn checkpoint(root:&Path)->(Inventory,checkpoint::Checkpoint) {
        let inventory=begin(root,None).unwrap();
        let mut index=checkpoint::Checkpoint::open(&inventory).unwrap();
        while !index.advance(&inventory,||false).unwrap() {}
        (inventory,index)
    }
    #[test]
    fn related_notes_and_meetings_are_grouped_without_unrelated_sources() {
        let root=setup();
        meeting(root.path(),"budget","Бюджет закупок поставщик доставка");
        meeting(root.path(),"architecture","Архитектура сервиса сервер протокол");
        note(root.path(),"n-budget","Бюджет закупок поставщик сроки",None);
        note(root.path(),"n-architecture","Архитектура сервиса протокол защита",None);
        note(root.path(),"n-unrelated","Велосипед прогулка горы",None);
        let (inventory,index)=checkpoint(root.path());
        let result=build(root.path(),&inventory,&index,&||false).unwrap();
        assert!(result.partial);
        assert!(!result.coverage_capped);
        assert_eq!((result.examined_notes,result.total_notes,result.examined_meetings,result.total_meetings),(3,3,2,2));
        assert_eq!(result.topics.len(),2);
        assert!(result.pair_checks>=2);
        for topic in result.topics {
            let (note_id,meeting_id)=match (&topic.sources[0],&topic.sources[1]) {
                (SourceRef::Note{id:n,..},SourceRef::Meeting{id:m,..})=>(n,m), _=>panic!("typed source order"),
            };
            assert_eq!(note_id, &format!("n-{meeting_id}"));
            assert!(!topic.shared_terms.is_empty());
            if let SourceRef::Meeting {evidence,..}=&topic.sources[1] {
                assert!(!evidence.is_empty());
                assert!(evidence.iter().all(|source|source.kind=="summary" && source.content_fingerprint.len()==64));
            }
        }
    }

    #[test]
    fn paraphrase_fixture_remains_marked_partial() {
        let root=setup();
        meeting(root.path(),"health","Ребёнок врач приём лекарство");
        note(root.path(),"note","Педиатр обследование назначение ребёнок",None);
        let (inventory,index)=checkpoint(root.path());
        let result=build(root.path(),&inventory,&index,&||false).unwrap();
        assert!(result.partial);
    }
    #[test]
    fn excluded_notes_cannot_influence_groups_or_explanations() {
        let root=setup();
        meeting(root.path(),"budget","Бюджет закупок поставщик доставка");
        crate::folders::save(root.path(),crate::folders::Folder{id:"closed".into(),name:"Private".into(),revision:0,
            overrides:json!({"features":{"knowledgeBase":false}})}).unwrap();
        note(root.path(),"secret","Бюджет закупок поставщик секретный",Some("closed"));
        note(root.path(),"visible","Велосипед прогулка горы",None);
        let (inventory,index)=checkpoint(root.path());
        let result=build(root.path(),&inventory,&index,&||false).unwrap();
        assert_eq!(result.total_notes,1);
        assert!(result.topics.is_empty());
    }
    #[test]
    fn stale_or_partial_meeting_and_cancel_produce_no_drafts() {
        let root=setup();
        meeting(root.path(),"budget","Бюджет закупок поставщик доставка");
        note(root.path(),"note","Бюджет закупок поставщик",None);
        let (inventory,index)=checkpoint(root.path());
        let cancelled=AtomicBool::new(true);
        assert!(build(root.path(),&inventory,&index,&||cancelled.load(Ordering::SeqCst)).is_err());
        atomic_json(&root.path().join("meetings/budget/transcript.json"),&json!({"segments":[
            {"id":1,"start":0,"end":1,"text":"Иной текст"}]})).unwrap();
        assert!(build(root.path(),&inventory,&index,&||false).is_err());
    }

    #[test]
    fn inaccessible_meeting_is_omitted_and_changing_policy_invalidates_checkpoint() {
        let root=setup();
        meeting(root.path(),"secret","Бюджет закупок поставщик доставка");
        meeting(root.path(),"visible","Велосипед прогулка горы дорога");
        crate::folders::save(root.path(),crate::folders::Folder{id:"closed".into(),name:"Private".into(),revision:0,
            overrides:json!({"features":{"knowledgeBase":false}})}).unwrap();
        crate::notes::save_context(root.path(),serde_json::from_value(json!({"meetingID":"secret","folderID":"closed"})).unwrap()).unwrap();
        note(root.path(),"budget","Бюджет закупок поставщик",None);
        let (inventory,index)=checkpoint(root.path());
        let result=build(root.path(),&inventory,&index,&||false).unwrap();
        assert!(result.topics.is_empty());
        assert_eq!(result.total_meetings,1);
        atomic_json(&root.path().join("settings.json"),&json!({"features":{"knowledgeBase":false}})).unwrap();
        assert!(build(root.path(),&inventory,&index,&||false).is_err());
    }

    #[test]
    fn policy_revoked_during_build_never_returns_prepared_drafts() {
        let root=setup();
        meeting(root.path(),"budget","Бюджет закупок поставщик доставка");
        note(root.path(),"note","Бюджет закупок поставщик",None);
        let (inventory,index)=checkpoint(root.path());
        let calls=std::cell::Cell::new(0);
        let result=build(root.path(),&inventory,&index,&||{
            calls.set(calls.get()+1);
            if calls.get()==6 {
                atomic_json(&root.path().join("settings.json"),&json!({"features":{"knowledgeBase":false}})).unwrap();
            }
            false
        });
        assert!(calls.get()>=6);
        assert!(result.is_err());
    }

    #[test]
    fn per_topic_cap_is_reported_as_incomplete() {
        let root=setup();
        for id in ["m1","m2","m3","m4"] {meeting(root.path(),id,"Бюджет закупок поставщик доставка");}
        note(root.path(),"note","Бюджет закупок поставщик доставка",None);
        let (inventory,index)=checkpoint(root.path());
        let result=build(root.path(),&inventory,&index,&||false).unwrap();
        assert!(result.partial && result.coverage_capped);
        assert_eq!(result.topics[0].sources.len(),MAX_MEETINGS_PER_TOPIC+1);
    }

    #[test]
    fn omitted_evidence_never_contributes_explanation_words() {
        let root=setup();
        meeting_fragments(root.path(),"budget",&[
            "бюджет закупки доставка","бюджет закупки доставка","бюджет закупки доставка",
            "бюджет закупки доставка","бюджет закупки доставка","уникальный контракт"]);
        note(root.path(),"note","бюджет закупки доставка уникальный контракт",None);
        let (inventory,index)=checkpoint(root.path());
        let result=build(root.path(),&inventory,&index,&||false).unwrap();
        assert!(result.coverage_capped);
        assert_eq!(result.topics.len(),1);
        let draft=&result.topics[0];
        assert!(!draft.shared_terms.iter().any(|word|word=="уникальный" || word=="контракт"));
        match &draft.sources[1] {
            SourceRef::Meeting {evidence,..}=>{
                assert_eq!(evidence.len(),5);
                assert!(evidence.iter().all(|source|source.item_index!=Some(5)));
            }
            _=>panic!("meeting source expected"),
        }
    }

    #[test]
    fn unrelated_single_word_fragments_do_not_form_artificial_evidence() {
        let root=setup();
        meeting_fragments(root.path(),"budget",&["бюджет","закупки","доставка","уникальный","контракт","поставщик"]);
        note(root.path(),"note","бюджет закупки доставка уникальный контракт поставщик",None);
        let (inventory,index)=checkpoint(root.path());
        let result=build(root.path(),&inventory,&index,&||false).unwrap();
        assert!(result.topics.is_empty());
        assert!(result.partial);
    }

    #[test]
    fn omitted_evidence_cannot_change_score_or_order_of_selected_sources() {
        let root=setup();
        meeting_fragments(root.path(),"a",&[
            "бюджет закупки доставка","бюджет закупки доставка","бюджет закупки доставка",
            "бюджет закупки доставка","бюджет закупки доставка",
            "бюджет закупки апельсин велосипед фонарь вертолёт стакан мороженое"]);
        meeting_fragments(root.path(),"z",&[
            "бюджет закупки доставка","бюджет закупки доставка","бюджет закупки доставка",
            "бюджет закупки доставка","бюджет закупки доставка","бюджет закупки"]);
        note(root.path(),"note","бюджет закупки доставка",None);
        let (inventory,index)=checkpoint(root.path());
        let result=build(root.path(),&inventory,&index,&||false).unwrap();
        let draft=&result.topics[0];
        let ids=draft.sources.iter().skip(1).map(|source|match source {
            SourceRef::Meeting{id,evidence,..}=>{
                assert_eq!(evidence.len(),5);
                assert!(evidence.iter().all(|source|source.item_index!=Some(5)));
                id.as_str()
            }
            _=>panic!("meeting source expected"),
        }).collect::<Vec<_>>();
        assert_eq!(ids,vec!["a","z"],"omitted sixth fragments must not affect the scores");
        assert!(result.coverage_capped);
    }

    #[test]
    fn damaged_meeting_does_not_block_healthy_groups_and_is_reported() {
        let root=setup();
        meeting(root.path(),"healthy","Бюджет закупок поставщик доставка");
        meeting(root.path(),"damaged","Другая встреча");
        fs::write(root.path().join("meetings/damaged/transcript.json"),b"invalid").unwrap();
        note(root.path(),"note","Бюджет закупок поставщик",None);
        let (inventory,index)=checkpoint(root.path());
        let result=build(root.path(),&inventory,&index,&||false).unwrap();
        assert_eq!(result.topics.len(),1);
        assert!(result.partial && result.coverage_capped);
        // A previously skipped source becoming readable requires a new index;
        // it cannot be silently mixed into an old checkpoint.
        meeting(root.path(),"damaged","Бюджет закупок поставщик доставка");
        assert!(build(root.path(),&inventory,&index,&||false).is_err());
    }

    #[test]
    fn synthetic_holdout_reports_quality_without_a_pass_threshold() {
        let root=setup();
        let fixture:serde_json::Value=serde_json::from_str(include_str!("fixtures/mixed-holdout-v1.json")).unwrap();
        assert_eq!(fixture["schemaVersion"],1);
        for item in fixture["meetings"].as_array().unwrap() {
            meeting(root.path(),item["id"].as_str().unwrap(),item["text"].as_str().unwrap());
        }
        for item in fixture["notes"].as_array().unwrap() {
            note(root.path(),item["id"].as_str().unwrap(),item["text"].as_str().unwrap(),None);
        }
        let (inventory,index)=checkpoint(root.path());
        let result=build(root.path(),&inventory,&index,&||false).unwrap();
        let mut predicted=BTreeSet::new();
        for topic in &result.topics {
            let SourceRef::Note{id:note,..}=&topic.sources[0] else {panic!("note expected")};
            for source in topic.sources.iter().skip(1) {
                if let SourceRef::Meeting{id:meeting,..}=source {predicted.insert((note.clone(),meeting.clone()));}
            }
        }
        let pairs=fixture["expectedPairs"].as_array().unwrap();
        let expected=pairs.iter().map(|pair|(pair["note"].as_str().unwrap().to_owned(),
            pair["meeting"].as_str().unwrap().to_owned())).collect::<BTreeSet<_>>();
        assert!(!expected.is_empty() && expected.len()==pairs.len(),"invalid holdout labels");
        let correct=predicted.intersection(&expected).count();
        let false_positives=predicted.difference(&expected).count();
        let missed=expected.difference(&predicted).count();
        println!("synthetic holdout: correct={correct}, suggested={}, false_positives={false_positives}, missed={missed}",predicted.len());
        // No quality assertion here: this tiny corpus is a reproducible smoke
        // report, not a threshold for shipping or tuning the matcher.
        assert!(result.partial);
    }
}
