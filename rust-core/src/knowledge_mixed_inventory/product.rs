//! User-visible suggestions over explicit content versions and current scope.
//! This is a read-only local view, not a grant to an external agent.
use super::*;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

const MAX_SOURCES: usize = 2000;
const MAX_VECTORS: usize = 1000;
const PAGE_SIZE: usize = 40;
#[derive(Clone)]
struct Source {
    key: String,
    value: Value,
    text: String,
    fingerprint: String,
}
fn note_allowed(
    resolver: &crate::ai::FeatureResolver,
    note: &crate::notes::CapturedNote,
    folder: Option<&str>,
) -> bool {
    note.kind == "note"
        && note.trashed_at.is_none()
        && resolver.in_scope(&json!({"noteID":note.id}), &json!({"folderID":folder}))
        && resolver
            .features_for(&json!({"noteID":note.id}))
            .is_ok_and(|f| f.knowledge_base)
}
fn node_note(note: &crate::notes::CapturedNote) -> Source {
    let title = if note.title.trim().is_empty() {
        note.text
            .lines()
            .next()
            .unwrap_or("Заметка")
            .chars()
            .take(100)
            .collect()
    } else {
        note.title.clone()
    };
    let fingerprint = crate::knowledge::note_fingerprint(note);
    Source {
        key: format!("note:{}", note.id),
        value: json!({"kind":"note","noteID":note.id,"revision":note.revision,"title":title,"fingerprint":fingerprint}),
        text: format!("{}\n{}", note.title, note.text),
        fingerprint,
    }
}
fn node_meeting(meeting: &MeetingTopicDocument) -> Source {
    let fingerprint = format!("{:x}", Sha256::digest(serde_json::to_vec(meeting).unwrap()));
    Source {
        key: format!("meeting:{}", meeting.meeting_id),
        value: json!({"kind":"meeting","meetingID":meeting.meeting_id,"title":meeting.title,
        "fingerprint":fingerprint,"source":meeting.evidence[0],"partial":meeting.partial}),
        text: meeting.text.clone(),
        fingerprint,
    }
}
// Fixed on the separate calibration split in knowledge-mixed-product-v1.json.
// This threshold applies only to this exact model/runtime/template. Other
// models retain a conservative fallback; a small corpus is no quality promise.
fn semantic_threshold(root: &Path, manifest: &str) -> f64 {
    let Ok(config) = crate::semantic::config(root) else {
        return 0.82;
    };
    if config.provider == "managed"
        && config.model == crate::managed_embeddings::MODEL
        && config.model_revision == crate::managed_embeddings::REVISION
        && config.dimensions == 1024
        && config.document_prefix.is_empty()
        && crate::semantic::cached_manifest_is_current(root, manifest)
    {
        0.58
    } else {
        0.82
    }
}
fn cosine(a: &[f32], b: &[f32]) -> f64 {
    a.iter()
        .zip(b)
        .map(|(x, y)| *x as f64 * *y as f64)
        .sum::<f64>()
}
fn pairs(
    nodes: &[Source],
    terms: &[BTreeMap<String, (String, u32)>],
    vectors: &BTreeMap<String, Vec<f32>>,
) -> (BTreeSet<(usize, usize)>, bool) {
    let mut result = BTreeSet::new();
    if nodes.len() <= 250 {
        for a in 0..nodes.len() {
            for b in a + 1..nodes.len() {
                result.insert((a, b));
            }
        }
        return (result, false);
    }
    let mut postings: BTreeMap<&str, Vec<usize>> = BTreeMap::new();
    for (i, doc) in terms.iter().enumerate() {
        for stem in doc.keys() {
            postings.entry(stem).or_default().push(i);
        }
    }
    for entries in postings.values() {
        for (offset, a) in entries.iter().enumerate() {
            for b in entries.iter().skip(offset + 1).take(24) {
                result.insert((*a, *b));
            }
        }
    }
    // Deterministic projection neighbours avoid quadratic work while retaining
    // candidates with different words. Ranking still uses exact cosine.
    for projection in 0..12u64 {
        let mut order = nodes
            .iter()
            .enumerate()
            .filter_map(|(i, n)| {
                vectors.get(&n.key).map(|v| {
                    let score = v
                        .iter()
                        .enumerate()
                        .map(|(j, x)| {
                            let seed = (j as u64 + 1)
                                .wrapping_mul(0x9e3779b97f4a7c15)
                                .wrapping_add(projection.wrapping_mul(0xbf58476d1ce4e5b9));
                            let sign = if (seed ^ (seed >> 31)).count_ones() % 2 == 0 {
                                1.0
                            } else {
                                -1.0
                            };
                            *x as f64 * sign
                        })
                        .sum::<f64>();
                    (i, score)
                })
            })
            .collect::<Vec<_>>();
        order.sort_by(|a, b| a.1.total_cmp(&b.1).then(a.0.cmp(&b.0)));
        for (offset, (a, _)) in order.iter().enumerate() {
            for (b, _) in order.iter().skip(offset + 1).take(12) {
                result.insert(((*a).min(*b), (*a).max(*b)));
            }
        }
    }
    (result, true)
}
fn build_groups(
    nodes: &[Source],
    vectors: &BTreeMap<String, Vec<f32>>,
    threshold: f64,
    cancelled: &impl Fn() -> bool,
) -> Result<(Vec<Value>, bool)> {
    let terms = nodes
        .iter()
        .map(|n| crate::search::related_terms("", &n.text))
        .collect::<Vec<_>>();
    let (pairs, approximate) = pairs(nodes, &terms, vectors);
    let mut neighbours = vec![Vec::<(usize, f64, bool)>::new(); nodes.len()];
    for (position, (a, b)) in pairs.into_iter().enumerate() {
        if position % 128 == 0 {
            ensure!(!cancelled(), "Построение тем остановлено");
        }
        let common = terms[a]
            .keys()
            .filter(|key| terms[b].contains_key(*key))
            .count();
        let semantic = vectors
            .get(&nodes[a].key)
            .zip(vectors.get(&nodes[b].key))
            .map(|(a, b)| cosine(a, b));
        let lexical = if common >= 3 {
            common as f64 / ((terms[a].len() * terms[b].len()) as f64).sqrt()
        } else {
            0.0
        };
        // A known semantic mismatch vetoes a coincidental word overlap.
        let (score, semantic) = match semantic {
            Some(score) if score >= threshold => (score, true),
            Some(_) => continue,
            None if lexical >= 0.55 => (lexical, false),
            None => continue,
        };
        neighbours[a].push((b, score, semantic));
        neighbours[b].push((a, score, semantic));
    }
    for list in &mut neighbours {
        list.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
        list.truncate(8);
    }
    let mut groups = BTreeMap::<Vec<String>, Value>::new();
    for seed in 0..nodes.len() {
        ensure!(!cancelled(), "Построение тем остановлено");
        let mut members = vec![seed];
        for (candidate, _, _) in &neighbours[seed] {
            // Every pair must qualify: transitive chains must not combine
            // unrelated projects through a generic intermediate document.
            if members.iter().all(|member| {
                neighbours[*member].iter().any(|(n, _, _)| n == candidate)
                    && neighbours[*candidate].iter().any(|(n, _, _)| n == member)
            }) {
                members.push(*candidate);
                if members.len() == 6 {
                    break;
                }
            }
        }
        if members.len() < 2 || !members.iter().any(|i| nodes[*i].value["kind"] == "meeting") {
            continue;
        }
        members.sort();
        let mut semantic_edges = 0;
        let mut edges = 0;
        for (offset, a) in members.iter().enumerate() {
            for b in members.iter().skip(offset + 1) {
                edges += 1;
                semantic_edges += usize::from(
                    neighbours[*a]
                        .iter()
                        .any(|(n, _, semantic)| n == b && *semantic),
                );
            }
        }
        let method = if semantic_edges == edges {
            "semantic"
        } else if semantic_edges > 0 {
            "hybrid"
        } else {
            "sharedTerms"
        };
        let keys = members
            .iter()
            .map(|i| nodes[*i].key.clone())
            .collect::<Vec<_>>();
        let id = format!("{:x}", Sha256::digest(serde_json::to_vec(&keys)?));
        let mut common: BTreeMap<String, (usize, String)> = BTreeMap::new();
        for i in &members {
            for (stem, (word, _)) in &terms[*i] {
                let value = common.entry(stem.clone()).or_insert((0, word.clone()));
                value.0 += 1;
            }
        }
        let mut words = common
            .into_iter()
            .filter(|(_, v)| v.0 >= 2)
            .collect::<Vec<_>>();
        words.sort_by(|a, b| b.1 .0.cmp(&a.1 .0).then(a.0.cmp(&b.0)));
        groups.insert(keys,json!({"id":id,"terms":words.into_iter().take(3).map(|(_,(_,word))|word).collect::<Vec<_>>(),
            "sources":members.iter().map(|i|nodes[*i].value.clone()).collect::<Vec<_>>(),"method":method}));
    }
    let mut rows = groups.into_values().collect::<Vec<_>>();
    rows.sort_by(|a, b| {
        b["sources"]
            .as_array()
            .unwrap()
            .len()
            .cmp(&a["sources"].as_array().unwrap().len())
            .then(a["id"].as_str().cmp(&b["id"].as_str()))
    });
    Ok((rows, approximate))
}

pub(super) fn topics(root: &Path, input: &Value, cancelled: impl Fn() -> bool) -> Result<Value> {
    let folder = input["folderID"].as_str();
    ensure!(
        input["folderID"].is_null() || input["folderID"].is_string(),
        "Некорректная папка"
    );
    let offset = input["offset"].as_u64().unwrap_or(0) as usize;
    ensure!(
        offset <= 100_000 && offset % PAGE_SIZE == 0,
        "Некорректная страница тем"
    );
    let before = crate::notes::list(root)?;
    let resolver = crate::ai::FeatureResolver::new(root)?;
    ensure!(
        crate::ai::live_features(root)?.knowledge_base,
        "Включите базу знаний в настройках"
    );
    let notes = before
        .notes
        .iter()
        .filter(|n| note_allowed(&resolver, n, folder))
        .collect::<Vec<_>>();
    let inventory = begin(root, folder)?;
    let mut checkpoint = checkpoint::Checkpoint::open(&inventory)
        .or_else(|_| checkpoint::Checkpoint::restart(&inventory))?;
    // Resume a partial sweep; an already completed but stale snapshot is
    // rebuilt in the derived index only. Originals and manual links are never changed.
    while !checkpoint.advance(&inventory, &cancelled)? {}
    if !checkpoint.audit_with_cancel(&inventory, &cancelled)? {
        checkpoint = checkpoint::Checkpoint::restart(&inventory)?;
        while !checkpoint.advance(&inventory, &cancelled)? {}
    }
    let (meetings, total_meetings, incomplete) =
        checkpoint.collect_available(&inventory, 1000, &cancelled)?;
    let total = notes.len() + total_meetings;
    let mut nodes = Vec::new();
    // Interleave types so a large note collection cannot hide every meeting.
    let mut note_index = 0;
    let mut meeting_index = 0;
    while nodes.len() < MAX_SOURCES && (note_index < notes.len() || meeting_index < meetings.len())
    {
        if note_index < notes.len() {
            nodes.push(node_note(notes[note_index]));
            note_index += 1;
        }
        if nodes.len() < MAX_SOURCES && meeting_index < meetings.len() {
            nodes.push(node_meeting(&meetings[meeting_index]));
            meeting_index += 1;
        }
    }
    let mut allowed_notes = BTreeMap::new();
    let mut allowed_meetings = BTreeSet::new();
    for node in &nodes {
        if allowed_notes.len() + allowed_meetings.len() >= MAX_VECTORS {
            break;
        }
        if node.value["kind"] == "note" {
            let id = node.value["noteID"].as_str().unwrap();
            if resolver
                .features_for(&json!({"noteID":id}))
                .is_ok_and(|f| f.semantic_search)
            {
                allowed_notes.insert(id.to_owned(), node.fingerprint.clone());
            }
        } else {
            let id = node.value["meetingID"].as_str().unwrap();
            if resolver
                .features_for(&json!({"meetingID":id}))
                .is_ok_and(|f| f.semantic_search)
            {
                allowed_meetings.insert(id.to_owned());
            }
        }
    }
    nodes.sort_by(|a, b| a.key.cmp(&b.key));
    let semantic =
        crate::semantic::cached_library_centroids(root, &allowed_notes, &allowed_meetings)
            .ok()
            .flatten();
    let empty = BTreeMap::new();
    let vectors = semantic.as_ref().map_or(&empty, |(v, _)| v);
    let threshold = semantic
        .as_ref()
        .map_or(0.82, |(_, manifest)| semantic_threshold(root, manifest));
    let (groups, approximate) = build_groups(&nodes, vectors, threshold, &cancelled)?;
    ensure!(!cancelled(), "Построение тем остановлено");
    let after = crate::notes::list(root)?;
    ensure!(
        serde_json::to_vec(&before)? == serde_json::to_vec(&after)?,
        "Заметки изменились. Обновите темы."
    );
    let current = crate::ai::FeatureResolver::new(root)?;
    for note in notes {
        ensure!(
            note_allowed(&current, note, folder),
            "Доступ к заметкам изменился. Обновите темы."
        );
    }
    ensure!(
        checkpoint.audit_with_cancel(&inventory, &cancelled)?,
        "Материалы встреч изменились. Обновите темы."
    );
    ensure!(
        semantic
            .as_ref()
            .is_none_or(|(_, m)| crate::semantic::cached_manifest_is_current(root, m)),
        "Смысловой индекс изменился. Обновите темы."
    );
    let total_groups = groups.len();
    let page = groups
        .into_iter()
        .skip(offset)
        .take(PAGE_SIZE)
        .collect::<Vec<_>>();
    Ok(
        json!({"topics":page,"examined":nodes.len(),"total":total,"partial":incomplete || total>nodes.len() || approximate,
        "approximate":approximate,"semanticThreshold":threshold,"semanticIndexed":vectors.len(),"offset":offset,"nextOffset":if offset+page.len()<total_groups{Some(offset+PAGE_SIZE)}else{None},"topicTotal":total_groups}),
    )
}

pub(super) fn validate_source(root: &Path, input: &Value) -> Result<Value> {
    let source = &input["source"];
    let folder = input["folderID"].as_str();
    ensure!(
        input["folderID"].is_null() || input["folderID"].is_string(),
        "Некорректная папка"
    );
    let resolver = crate::ai::FeatureResolver::new(root)?;
    let valid = match source["kind"].as_str() {
        Some("note") => source["noteID"]
            .as_str()
            .and_then(|id| crate::notes::load_note_snapshot(root, id).ok())
            .is_some_and(|note| {
                note_allowed(&resolver, &note, folder)
                    && source["revision"].as_u64() == Some(note.revision)
                    && source["fingerprint"] == crate::knowledge::note_fingerprint(&note)
            }),
        Some("meeting") => source["meetingID"]
            .as_str()
            .and_then(|id| document(root, id, folder).ok())
            .is_some_and(|current| {
                source["fingerprint"]
                    == format!(
                        "{:x}",
                        Sha256::digest(serde_json::to_vec(&current).unwrap())
                    )
                    && serde_json::from_value::<MeetingSource>(source["source"].clone()).is_ok_and(
                        |s| {
                            s.meeting_id == current.meeting_id
                                && current.evidence.iter().any(|e| {
                                    e.kind == s.kind
                                        && e.segment_id == s.segment_id
                                        && e.item_index == s.item_index
                                        && e.content_fingerprint == s.content_fingerprint
                                })
                                && knowledge_meetings::validate(root, &s, folder)
                        },
                    )
            }),
        _ => false,
    };
    Ok(json!({"valid":valid}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::atomic_json;
    fn setup() -> tempfile::TempDir {
        let root = tempfile::tempdir().unwrap();
        atomic_json(
            &root.path().join("settings.json"),
            &json!({"features":{"knowledgeBase":true}}),
        )
        .unwrap();
        root
    }
    fn note(root: &Path, id: &str, text: &str) {
        crate::notes::save_note(
            root,
            serde_json::from_value(
                json!({"id":id,"kind":"note","text":text,"createdAt":0,"updatedAt":0,"revision":0}),
            )
            .unwrap(),
        )
        .unwrap();
    }
    fn meeting(root: &Path, id: &str, text: &str) {
        let dir = root.join("meetings").join(id);
        atomic_json(
            &dir.join("meta.json"),
            &json!({"id":id,"title":id,"source":"audio.mp3","createdAt":1,"status":"ready"}),
        )
        .unwrap();
        atomic_json(
            &dir.join("transcript.json"),
            &json!({"segments":[{"id":1,"start":0,"end":1,"text":text}]}),
        )
        .unwrap();
    }
    #[test]
    fn published_mixed_topics_open_exact_sources_and_recheck_scope() {
        let root = setup();
        note(root.path(), "n", "Бюджет договора пилотного проекта");
        meeting(root.path(), "m", "Бюджет договора пилотного проекта");
        meeting(root.path(), "other", "Сбор малины в саду");
        let result = topics(root.path(), &json!({}), || false).unwrap();
        assert_eq!(result["examined"], 3);
        assert_eq!(result["semanticIndexed"], 0);
        assert_eq!(result["topics"].as_array().unwrap().len(), 1);
        assert_eq!(
            result["partial"], true,
            "transcript-only representation reports partial coverage"
        );
        let sources = result["topics"][0]["sources"].as_array().unwrap();
        for source in sources {
            assert_eq!(
                validate_source(root.path(), &json!({"source":source})).unwrap()["valid"],
                true
            );
        }
        let source = sources.iter().find(|s| s["kind"] == "meeting").unwrap();
        let mut substituted = source.clone();
        substituted["source"] = serde_json::to_value(
            knowledge_meetings::snapshot(root.path(), "other", None)
                .unwrap()
                .0
                .remove(0),
        )
        .unwrap();
        assert_eq!(
            validate_source(root.path(), &json!({"source":substituted})).unwrap()["valid"],
            false,
            "another valid source cannot substitute the anchor"
        );
        assert_eq!(
            validate_source(
                root.path(),
                &json!({"source":source,"folderID":"unrelated"})
            )
            .unwrap()["valid"],
            false
        );
        meeting(root.path(), "m", "Изменённое содержание");
        assert_eq!(
            validate_source(root.path(), &json!({"source":source})).unwrap()["valid"],
            false
        );
        atomic_json(
            &root.path().join("settings.json"),
            &json!({"features":{"knowledgeBase":false}}),
        )
        .unwrap();
        assert!(topics(root.path(), &json!({}), || false).is_err());
        for source in sources {
            assert_eq!(
                validate_source(root.path(), &json!({"source":source})).unwrap()["valid"],
                false
            );
        }
    }
    #[test]
    fn empty_library_cancel_and_late_meeting_coverage() {
        let root = setup();
        assert_eq!(
            topics(root.path(), &json!({}), || false).unwrap()["topics"],
            json!([])
        );
        note(root.path(), "n", "Бюджет договора пилотного проекта");
        for i in 0..105 {
            meeting(
                root.path(),
                &format!("m{i:03}"),
                if i == 104 {
                    "Бюджет договора пилотного проекта"
                } else {
                    "Погода"
                },
            );
        }
        assert!(topics(root.path(), &json!({}), || true).is_err());
        let result = topics(root.path(), &json!({}), || false).unwrap();
        assert_eq!(result["examined"], 106);
        assert!(
            result["topics"].to_string().contains("m104"),
            "the old 100 meeting limit must not hide a matching source"
        );
        assert!(!result["topics"].to_string().contains("m003"));
    }
    #[test]
    fn semantic_groups_require_pairwise_agreement_not_transitive_chain() {
        let nodes = (0..3)
            .map(|i| Source {
                key: format!("meeting:{i}"),
                value: json!({"kind":"meeting","meetingID":i}),
                text: format!("unique{i}"),
                fingerprint: "".into(),
            })
            .collect::<Vec<_>>();
        // A~B and B~C qualify, while A and C refer to different subjects.
        let v = BTreeMap::from([
            (nodes[0].key.clone(), vec![1.0, 0.0]),
            (nodes[1].key.clone(), vec![0.8, 0.6]),
            (nodes[2].key.clone(), vec![0.0, 1.0]),
        ]);
        let (groups, _) = build_groups(&nodes, &v, 0.59, &|| false).unwrap();
        assert_eq!(groups.len(), 2);
        assert!(groups
            .iter()
            .all(|g| g["sources"].as_array().unwrap().len() == 2 && g["method"] == "semantic"));
        assert!(build_groups(&nodes, &v, 0.59, &|| true).is_err());
    }
    #[test]
    fn known_semantic_mismatch_vetoes_lexical_overlap() {
        let nodes = (0..2)
            .map(|i| Source {
                key: format!("meeting:{i}"),
                value: json!({"kind":"meeting","meetingID":i}),
                text: "Бюджет договора пилотного проекта".into(),
                fingerprint: "".into(),
            })
            .collect::<Vec<_>>();
        assert_eq!(
            build_groups(&nodes, &BTreeMap::new(), 0.6, &|| false)
                .unwrap()
                .0
                .len(),
            1
        );
        let v = BTreeMap::from([
            (nodes[0].key.clone(), vec![1.0, 0.0]),
            (nodes[1].key.clone(), vec![0.0, 1.0]),
        ]);
        assert!(build_groups(&nodes, &v, 0.6, &|| false)
            .unwrap()
            .0
            .is_empty());
    }
}
