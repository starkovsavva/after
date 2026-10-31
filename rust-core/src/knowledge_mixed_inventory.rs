//! Bounded meeting inventory and read-only mixed topic suggestions.
//!
//! The native product view validates current permissions and exact content
//! versions before publication and navigation. This local view is not a grant
//! for an external agent and does not synchronize arbitrary legacy writers.
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

use crate::knowledge_meetings::{self, MeetingSource};

mod checkpoint;
mod mixed_topics;
mod product;

pub(crate) fn topics(root:&Path,input:&serde_json::Value,cancelled:impl Fn()->bool)->Result<serde_json::Value>{product::topics(root,input,cancelled)}
pub(crate) fn validate_source(root:&Path,input:&serde_json::Value)->Result<serde_json::Value>{product::validate_source(root,input)}

const MAX_PAGE: usize = 16;
const MAX_DOCUMENT_BYTES: usize = 16_000;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct MeetingTopicDocument {
    pub meeting_id: String,
    pub title: String,
    /// Actual sources, including fingerprints; their text is bounded per source.
    pub evidence: Vec<MeetingSource>,
    /// Bounded text used for matching; evidence keeps the exact source snippet.
    pub text: String,
    /// True means that the text does not represent the whole published meeting.
    pub partial: bool,
}

fn byte_prefix(value: &str, limit: usize) -> &str {
    let mut end = value.len().min(limit);
    while !value.is_char_boundary(end) { end -= 1; }
    &value[..end]
}

/// One node per meeting. Prefer a current summary, falling back to transcript
/// segments. Sources remain independently identifiable for opening/revalidation.
fn document(root: &Path, id: &str, folder: Option<&str>) -> Result<MeetingTopicDocument> {
    let (sources, source_partial) = knowledge_meetings::snapshot(root, id, folder)?;
    let title = sources.first().map(|source| source.title.clone()).unwrap_or_default();
    let has_summary = sources.iter().any(|source| source.kind == "summary");
    let candidates: Vec<_> = sources.into_iter().filter(|source|
        if has_summary { source.kind == "summary" } else { source.kind == "transcript" }).collect();
    let mut evidence = Vec::new();
    let mut text = String::new();
    let mut partial = source_partial || candidates.is_empty() || !has_summary;
    for source in candidates {
        let available = MAX_DOCUMENT_BYTES.saturating_sub(text.len());
        if available == 0 { partial = true; break; }
        let portion = byte_prefix(&source.text, available);
        partial |= portion.len() != source.text.len();
        text.push_str(portion);
        if text.len() < MAX_DOCUMENT_BYTES { text.push('\n'); }
        if !source.text.is_empty() { evidence.push(source); }
    }
    // Source snippets are never authoritative; truncation only affects the
    // aggregate representation. Re-reading the source restores its full text.
    Ok(MeetingTopicDocument { meeting_id: id.to_owned(), title, evidence, text, partial })
}

/// Reconstructing detects changes to the inputs, policy, and sampled text. This
/// point-in-time check is not synchronization against a legacy writer.
pub(crate) fn validate(root: &Path, folder: Option<&str>, expected: &MeetingTopicDocument) -> bool {
    document(root, &expected.meeting_id, folder).and_then(|actual| {
        Ok(serde_json::to_vec(&actual)? == serde_json::to_vec(expected)?)
    }).unwrap_or(false)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Cursor {
    membership_digest: String,
    after_id: String,
}

#[derive(Debug)]
pub(crate) struct Page {
    pub documents: Vec<MeetingTopicDocument>,
    /// Entries with malformed, unavailable or not-yet-published data.
    pub skipped: usize,
    pub examined: usize,
    pub next: Option<Cursor>,
}

/// A private in-memory directory snapshot. It is not a persisted checkpoint and
/// may include IDs outside the selected scope; never expose it through an API.
struct Inventory {
    root: PathBuf,
    folder: Option<String>,
    ids: Vec<String>,
    unknown: usize,
    membership_digest: String,
}

fn begin(root: &Path, folder: Option<&str>) -> Result<Inventory> {
    crate::storage::meeting_directory(root, "_inventory_probe")?;
    let mut ids = Vec::new();
    let mut unknown = 0usize;
    for entry in fs::read_dir(root.join("meetings"))? {
        let Ok(entry) = entry else { unknown += 1; continue };
        let Ok(kind) = entry.file_type() else { unknown += 1; continue };
        if kind.is_symlink() { unknown += 1; continue; }
        if !kind.is_dir() { continue; }
        let Some(id) = entry.file_name().to_str().map(str::to_owned) else { unknown += 1; continue };
        if crate::storage::meeting_directory(root, &id).is_err() { unknown += 1; continue; }
        ids.push(id);
    }
    ids.sort();
    let membership_digest = format!("{:x}", Sha256::digest(serde_json::to_vec(&(root, folder, &ids, unknown))?));
    Ok(Inventory { root: root.to_owned(), folder: folder.map(str::to_owned), ids, unknown, membership_digest })
}

/// The caller must perform this full check and revalidate all used documents
/// before publishing. It cannot prove that a legacy writer did not race after
/// this check; there is no atomic legacy-compatible privacy guarantee here.
fn membership_is_current(inventory: &Inventory) -> bool {
    begin(&inventory.root, inventory.folder.as_deref()).is_ok_and(|current|
        current.membership_digest == inventory.membership_digest)
}

/// Process at most `limit` entries from an in-memory listing per call. No
/// repeated whole-directory scan is performed per page. Cursor positions cannot
/// be mixed across different captured inventories or directory memberships.
fn page(inventory: &Inventory, cursor: Option<&Cursor>, limit: usize) -> Result<Page> {
    ensure!((1..=MAX_PAGE).contains(&limit), "Некорректный размер страницы встреч");
    if let Some(cursor) = cursor {
        ensure!(cursor.membership_digest == inventory.membership_digest && inventory.ids.binary_search(&cursor.after_id).is_ok(),
            "Состав библиотеки изменился. Начните индексацию заново.");
    }
    let start = cursor.map_or(0, |c| inventory.ids.partition_point(|id| id <= &c.after_id));
    let end = (start + limit).min(inventory.ids.len());
    let root=&inventory.root;
    let folder=inventory.folder.as_deref();
    let resolver = crate::ai::FeatureResolver::new(root)?;
    let mut documents = Vec::new();
    let mut skipped = if start == 0 { inventory.unknown } else { 0 };
    for id in &inventory.ids[start..end] {
        let source = serde_json::json!({"meetingID":id});
        // Excluded sources are not indexed, and no identifying information is
        // returned for them. Errors fail closed and count as unavailable.
        let allowed = resolver.features_for(&source).map(|f| f.knowledge_base);
        if !resolver.in_scope(&source, &serde_json::json!({"folderID":folder})) { continue; }
        match allowed {
            Ok(false) => continue,
            Err(_) => { skipped += 1; continue; }
            Ok(true) => {}
        }
        match document(root, id, folder) {
            Ok(item) if !item.evidence.is_empty() => documents.push(item),
            _ => skipped += 1,
        }
    }
    let next = if end < inventory.ids.len() {
        Some(Cursor { membership_digest:inventory.membership_digest.clone(), after_id: inventory.ids[end - 1].clone() })
    } else { None };
    Ok(Page { documents, skipped, examined: end - start, next })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use crate::storage::atomic_json;

    fn setup() -> tempfile::TempDir {
        let root = tempfile::tempdir().unwrap();
        atomic_json(&root.path().join("settings.json"), &json!({"features":{"knowledgeBase":true}})).unwrap();
        root
    }
    fn meeting(root: &Path, id: &str) {
        let dir = root.join("meetings").join(id);
        atomic_json(&dir.join("meta.json"), &json!({"id":id,"title":format!("Meeting {id}"),"source":"audio.mp3","createdAt":1,"status":"ready"})).unwrap();
        atomic_json(&dir.join("transcript.json"), &json!({"segments":[{"id":1,"start":0,"end":1,"text":"Бюджет и план"}]})).unwrap();
        let hash = format!("{:x}", Sha256::digest(fs::read(dir.join("transcript.json")).unwrap()));
        atomic_json(&dir.join("summary.json"), &json!({"sourceFingerprint":hash,"overview":"Обсудили бюджет"})).unwrap();
    }
    #[test]
    fn pages_cover_more_than_old_limit_and_cancel_on_membership_change() {
        let root=setup();
        for index in 0..105 { meeting(root.path(), &format!("m{index:03}")); }
        let inventory=begin(root.path(),None).unwrap();
        let mut cursor=None;
        let mut seen=Vec::new();
        loop {
            let result=page(&inventory,cursor.as_ref(),16).unwrap();
            assert_eq!(result.skipped,0);
            seen.extend(result.documents.into_iter().map(|d|d.meeting_id));
            cursor=result.next;
            if cursor.is_none() { break; }
        }
        assert_eq!(seen.len(),105);
        assert!(seen.contains(&"m104".to_owned()));
        assert!(membership_is_current(&inventory));
        meeting(root.path(),"new");
        assert!(!membership_is_current(&inventory));
    }
    #[test]
    fn aggregate_rechecks_versions_permissions_and_reports_partial() {
        let root=setup();
        meeting(root.path(),"one");
        let first=page(&begin(root.path(),None).unwrap(),None,16).unwrap().documents.remove(0);
        assert!(!first.partial);
        assert_eq!(first.evidence.len(),1);
        assert_eq!(first.evidence[0].kind,"summary");
        assert!(validate(root.path(),None,&first));
        atomic_json(&root.path().join("meetings/one/transcript.json"),&json!({"segments":[{"id":1,"start":0,"end":1,"text":"Изменение"}]})).unwrap();
        assert!(!validate(root.path(),None,&first));
        let fallback=page(&begin(root.path(),None).unwrap(),None,16).unwrap().documents.remove(0);
        assert!(fallback.partial);
        assert_eq!(fallback.evidence[0].kind,"transcript");
        atomic_json(&root.path().join("settings.json"), &json!({"features":{"knowledgeBase":false}})).unwrap();
        assert!(!validate(root.path(),None,&fallback));
        assert!(page(&begin(root.path(),None).unwrap(),None,16).unwrap().documents.is_empty());
    }
    #[test]
    fn damaged_sources_and_excluded_scope_do_not_leak_content() {
        let root=setup();
        meeting(root.path(),"one");
        meeting(root.path(),"broken");
        fs::write(root.path().join("meetings/broken/transcript.json"),b"not json").unwrap();
        let result=page(&begin(root.path(),None).unwrap(),None,16).unwrap();
        assert_eq!(result.skipped,1);
        assert_eq!(result.documents.len(),1);
        assert!(page(&begin(root.path(),Some("other")).unwrap(),None,16).unwrap().documents.is_empty());
    }

    #[test]
    fn long_sources_are_partial_and_evidence_stays_exact() {
        let root=setup();
        meeting(root.path(),"one");
        let dir=root.path().join("meetings/one");
        let hash=format!("{:x}", Sha256::digest(fs::read(dir.join("transcript.json")).unwrap()));
        atomic_json(&dir.join("summary.json"),&json!({"sourceFingerprint":hash,"overview":"а".repeat(10_000)})).unwrap();
        let item=page(&begin(root.path(),None).unwrap(),None,16).unwrap().documents.remove(0);
        assert!(item.partial);
        assert!(item.text.len() <= MAX_DOCUMENT_BYTES);
        assert!(knowledge_meetings::validate(root.path(),&item.evidence[0],None));
        assert!(validate(root.path(),None,&item));
    }

    #[test]
    fn cursor_is_bound_to_library_and_selected_scope() {
        let first=setup();
        let second=setup();
        for index in 0..2 {
            meeting(first.path(),&format!("m{index}"));
            meeting(second.path(),&format!("m{index}"));
        }
        let inventory=begin(first.path(),None).unwrap();
        let cursor=page(&inventory,None,1).unwrap().next.unwrap();
        assert!(page(&begin(second.path(),None).unwrap(),Some(&cursor),1).is_err());
        assert!(page(&begin(first.path(),Some("other")).unwrap(),Some(&cursor),1).is_err());
    }

    #[test]
    fn checkpoint_recovers_after_cancel_and_audits_live_sources() {
        let root=setup();
        for index in 0..20 { meeting(root.path(),&format!("m{index:03}")); }
        let inventory=begin(root.path(),None).unwrap();
        {
            let mut checkpoint=checkpoint::Checkpoint::open(&inventory).unwrap();
            assert!(!checkpoint.advance(&inventory,||false).unwrap());
            assert_eq!(checkpoint.progress().unwrap(),(0,16,0));
            let calls=std::cell::Cell::new(0);
            assert!(checkpoint.advance(&inventory,||{calls.set(calls.get()+1); calls.get()==2}).is_err());
            assert_eq!(checkpoint.progress().unwrap(),(0,16,0));
        }
        let mut resumed=checkpoint::Checkpoint::open(&inventory).unwrap();
        assert!(resumed.advance(&inventory,||false).unwrap());
        assert_eq!(resumed.progress().unwrap(),(1,20,0));
        assert!(resumed.audit(&inventory).unwrap());
        let index=fs::read_dir(root.path().join("knowledge-mixed-index")).unwrap().next().unwrap().unwrap().path();
        assert!(!fs::read(index).unwrap().windows("Обсудили бюджет".len()).any(|bytes|bytes=="Обсудили бюджет".as_bytes()));
        atomic_json(&root.path().join("meetings/m002/transcript.json"),&json!({"segments":[{"id":1,"start":0,"end":1,"text":"Изменение"}]})).unwrap();
        assert!(!resumed.audit(&inventory).unwrap());
        meeting(root.path(),"added");
        let changed=begin(root.path(),None).unwrap();
        assert!(checkpoint::Checkpoint::open(&changed).is_err());
        drop(resumed);
        meeting(root.path(),"m002");
        let mut fresh=checkpoint::Checkpoint::restart(&changed).unwrap();
        assert!(!fresh.advance(&changed,||false).unwrap());
        assert!(fresh.advance(&changed,||false).unwrap());
        assert_eq!(fresh.progress().unwrap(),(1,21,0));
        assert!(fresh.audit(&changed).unwrap());
    }

    #[test]
    fn checkpoint_refuses_symlinked_index_folder() {
        use std::os::unix::fs::symlink;
        let root=setup();
        meeting(root.path(),"one");
        let inventory=begin(root.path(),None).unwrap();
        let outside=tempfile::tempdir().unwrap();
        symlink(outside.path(),root.path().join("knowledge-mixed-index")).unwrap();
        assert!(checkpoint::Checkpoint::open(&inventory).is_err());
        assert_eq!(fs::read_dir(outside.path()).unwrap().count(),0);
    }

    #[test]
    fn checkpoint_recovers_empty_file_and_refuses_symlinked_database() {
        use std::os::unix::fs::{OpenOptionsExt, symlink};
        let root=setup();
        meeting(root.path(),"one");
        let inventory=begin(root.path(),None).unwrap();
        let directory=root.path().join("knowledge-mixed-index");
        fs::create_dir(&directory).unwrap();
        let scope=format!("{:x}",Sha256::digest(serde_json::to_vec(&Option::<String>::None).unwrap()));
        let path=directory.join(format!("meetings-{scope}.sqlite"));
        std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).unwrap();
        assert!(checkpoint::Checkpoint::open(&inventory).is_ok());
        fs::remove_file(&path).unwrap();
        let outside=tempfile::NamedTempFile::new().unwrap();
        symlink(outside.path(),&path).unwrap();
        assert!(checkpoint::Checkpoint::open(&inventory).is_err());
        assert_eq!(outside.as_file().metadata().unwrap().len(),0);
    }

    #[test]
    fn checkpoint_refuses_hard_linked_database_without_modifying_it() {
        let root=setup();
        meeting(root.path(),"one");
        let inventory=begin(root.path(),None).unwrap();
        let directory=root.path().join("knowledge-mixed-index");
        fs::create_dir(&directory).unwrap();
        let scope=format!("{:x}",Sha256::digest(serde_json::to_vec(&Option::<String>::None).unwrap()));
        let path=directory.join(format!("meetings-{scope}.sqlite"));
        let outside=tempfile::NamedTempFile::new().unwrap();
        fs::hard_link(outside.path(),&path).unwrap();
        assert!(checkpoint::Checkpoint::open(&inventory).is_err());
        assert_eq!(outside.as_file().metadata().unwrap().len(),0);
    }

    #[test]
    fn checkpoint_refuses_linked_sqlite_sidecars_without_touching_target() {
        use std::os::unix::fs::symlink;
        let root=setup();
        meeting(root.path(),"one");
        let inventory=begin(root.path(),None).unwrap();
        let directory=root.path().join("knowledge-mixed-index");
        fs::create_dir(&directory).unwrap();
        let scope=format!("{:x}",Sha256::digest(serde_json::to_vec(&Option::<String>::None).unwrap()));
        let outside=tempfile::NamedTempFile::new().unwrap();
        for suffix in ["-journal", "-wal", "-shm"] {
            let path=directory.join(format!("meetings-{scope}.sqlite{suffix}"));
            fs::hard_link(outside.path(),&path).unwrap();
            assert!(checkpoint::Checkpoint::open(&inventory).is_err());
            fs::remove_file(&path).unwrap();
            symlink(outside.path(),&path).unwrap();
            assert!(checkpoint::Checkpoint::open(&inventory).is_err());
            fs::remove_file(&path).unwrap();
        }
        assert_eq!(outside.as_file().metadata().unwrap().len(),0);
    }
}
