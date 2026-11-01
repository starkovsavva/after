use super::*;
use std::collections::BTreeSet;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc, Mutex,
};
use std::thread;

/// Protocol/ordering fixture. Deliberately assigned vectors verify plumbing,
/// freshness and rank fusion; they do NOT measure a real model's RU/EN quality.
struct Fixture {
    endpoint: String,
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
    hook: Arc<Mutex<Option<Box<dyn FnOnce() + Send>>>>,
    calls: Arc<AtomicUsize>,
    payloads: Arc<Mutex<Vec<Value>>>,
}
impl Fixture {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        let hook: Arc<Mutex<Option<Box<dyn FnOnce() + Send>>>> = Arc::new(Mutex::new(None));
        let server_hook = hook.clone();
        let calls = Arc::new(AtomicUsize::new(0));
        let server_calls = calls.clone();
        let payloads = Arc::new(Mutex::new(Vec::new()));
        let server_payloads = payloads.clone();
        let handle = thread::spawn(move || {
            while !flag.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        // macOS accept inherits O_NONBLOCK from the listening
                        // socket. HTTP bytes may arrive after accept succeeds.
                        stream.set_nonblocking(false).unwrap();
                        stream
                            .set_read_timeout(Some(Duration::from_secs(10)))
                            .unwrap();
                        let mut bytes = Vec::new();
                        let mut chunk = [0; 2048];
                        let mut target = None;
                        loop {
                            let n = stream.read(&mut chunk).unwrap_or(0);
                            if n == 0 {
                                break;
                            }
                            bytes.extend_from_slice(&chunk[..n]);
                            if let Some(offset) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                                if target.is_none() {
                                    let headers = String::from_utf8_lossy(&bytes[..offset]);
                                    let size = headers
                                        .lines()
                                        .find_map(|l| {
                                            l.to_lowercase()
                                                .strip_prefix("content-length:")
                                                .and_then(|s| s.trim().parse::<usize>().ok())
                                        })
                                        .unwrap_or(0);
                                    target = Some(offset + 4 + size);
                                }
                                if bytes.len() >= target.unwrap() {
                                    break;
                                }
                            }
                        }
                        let Some(header) = bytes.windows(4).position(|w| w == b"\r\n\r\n") else {
                            continue;
                        };
                        let value: Value =
                            serde_json::from_slice(&bytes[header + 4..]).unwrap_or(Value::Null);
                        if value["input"].is_array() {
                            server_calls.fetch_add(1, Ordering::SeqCst);
                            server_payloads.lock().unwrap().push(value["input"].clone());
                            let next = server_hook.lock().unwrap().take();
                            if let Some(callback) = next {
                                callback();
                            }
                        }
                        let data = if value.is_null() {
                            json!({"models":[{"name":"fixture","digest":"sha256:fixture-v1"}]})
                        } else {
                            let vectors = value["input"]
                                .as_array()
                                .unwrap_or_else(|| {
                                    panic!("Unexpected synthetic fixture payload: {value}")
                                })
                                .iter()
                                .enumerate()
                                .map(|(index, text)| {
                                    let t = text.as_str().unwrap().to_lowercase();
                                    let v = if t.contains("устойчив") || t.contains("resilien")
                                    {
                                        vec![1.0, 0.0, 0.0]
                                    } else if t.contains("budget") || t.contains("бюджет") {
                                        vec![0.0, 1.0, 0.0]
                                    } else {
                                        vec![0.0, 0.0, 1.0]
                                    };
                                    json!({"index":index,"embedding":v})
                                })
                                .collect::<Vec<_>>();
                            json!({"data":vectors})
                        };
                        let body = data.to_string();
                        let _=write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body);
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2))
                    }
                    Err(_) => break,
                }
            }
        });
        Self {
            endpoint: format!("http://{address}/v1"),
            stop,
            thread: Some(handle),
            hook,
            calls,
            payloads,
        }
    }
    fn config(&self) -> Config {
        Config {
            enabled: true,
            provider: "openai".into(),
            endpoint: self.endpoint.clone(),
            model: "fixture".into(),
            model_revision: "fixture-v1".into(),
            dimensions: 3,
            query_prefix: String::new(),
            ..Config::default()
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}
fn note(root: &Path, id: &str, text: &str) -> Value {
    crate::notes::dispatch(root,&json!({"command":"note-save","note":{"id":id,"kind":"note","title":text,"text":text,"createdAt":1,"updatedAt":1,"revision":0}})).unwrap()
}
fn configure(root: &Path, c: &Config) {
    let mut settings: Value = fs::read(root.join("settings.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or(json!({}));
    settings["features"] =
        json!({"semanticSearch":true,"assistant":true,"cards":true,"tasks":true});
    crate::storage::atomic_json(&root.join("settings.json"), &settings).unwrap();
    dispatch(root, &json!({"command":"semantic-config","config":c})).unwrap();
}

#[test]
fn manually_confirmed_qwen_suggestions_use_only_the_evaluated_model_snapshot() {
    let root = tempfile::tempdir().unwrap();
    let mut c = Config {
        enabled: true,
        provider: "ollama".into(),
        endpoint: "http://127.0.0.1:11434".into(),
        model: "qwen3-embedding:0.6b".into(),
        model_revision: "ac6da0dfba84a81fdbfbaf330198c33cd77c4cdfc53e8bc50eb581914a15621d".into(),
        dimensions: 1024,
        ..Config::default()
    };
    configure(root.path(), &c);
    let original = manifest(&c);
    assert_eq!(manual_suggestion_threshold(root.path(), &original), 0.43);
    assert_eq!(
        manual_suggestion_threshold(root.path(), "changed-manifest"),
        0.82
    );
    c.model_revision = "different-model".into();
    configure(root.path(), &c);
    assert_eq!(
        manual_suggestion_threshold(root.path(), &manifest(&c)),
        0.82
    );
    c.model_revision = "ac6da0dfba84a81fdbfbaf330198c33cd77c4cdfc53e8bc50eb581914a15621d".into();
    c.document_prefix = "other template".into();
    configure(root.path(), &c);
    assert_eq!(
        manual_suggestion_threshold(root.path(), &manifest(&c)),
        0.82
    );
    c.document_prefix.clear();
    c.provider = "openai".into();
    configure(root.path(), &c);
    assert_eq!(
        manual_suggestion_threshold(root.path(), &manifest(&c)),
        0.82
    );
}

#[test]
fn managed_manual_suggestions_require_exact_evaluated_model_and_document_template() {
    let root = tempfile::tempdir().unwrap();
    let mut c = Config {
        enabled: true,
        model_revision: crate::managed_embeddings::REVISION.into(),
        ..Config::default()
    };
    configure(root.path(), &c);
    assert_eq!(
        manual_suggestion_threshold(root.path(), &manifest(&c)),
        0.43
    );
    assert_eq!(manual_suggestion_threshold(root.path(), "stale"), 0.82);
    c.document_prefix = "different document input".into();
    configure(root.path(), &c);
    assert_eq!(
        manual_suggestion_threshold(root.path(), &manifest(&c)),
        0.82
    );
}

#[test]
fn evaluated_qwen_threshold_exposes_only_manual_suggestions_not_topic_edges() {
    // Controlled vectors exercise the real cached-index and KB paths; the
    // separate local-model smoke measures quality and is not replaced by this.
    let directory = tempfile::tempdir().unwrap();
    let canonical = directory.path().canonicalize().unwrap();
    let root = canonical.as_path();
    let fixture = Fixture::start();
    let mut c = fixture.config();
    configure(root, &c);
    let mut settings: Value = fs::read(root.join("settings.json"))
        .ok()
        .and_then(|v| serde_json::from_slice(&v).ok())
        .unwrap();
    settings["features"]["knowledgeBase"] = json!(true);
    crate::storage::atomic_json(&root.join("settings.json"), &settings).unwrap();
    for (id, text) in [
        ("a", "sequoia mountain"),
        ("b", "океанский берег"),
        ("c", "bright orchid"),
        ("d", "космический корабль"),
    ] {
        note(root, id, text);
    }
    assert_eq!(
        refresh(root, &json!({"maxDocuments":32})).unwrap()["complete"],
        true
    );
    c.provider = "ollama".into();
    c.endpoint = "http://127.0.0.1:11434".into();
    c.model = "qwen3-embedding:0.6b".into();
    c.model_revision = "ac6da0dfba84a81fdbfbaf330198c33cd77c4cdfc53e8bc50eb581914a15621d".into();
    c.dimensions = 1024;
    c.document_prefix.clear();
    configure(root, &c);
    // configure() sets only the standard search features; preserve KB opt-in.
    let mut settings: Value =
        serde_json::from_slice(&fs::read(root.join("settings.json")).unwrap()).unwrap();
    settings["features"]["knowledgeBase"] = json!(true);
    crate::storage::atomic_json(&root.join("settings.json"), &settings).unwrap();
    let db = connection(root).unwrap();
    let rows = db
        .prepare("SELECT generation,id,source FROM vectors")
        .unwrap()
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap();
    assert_eq!(rows.len(), 4);
    for (generation, id, source) in rows {
        let source: Value = serde_json::from_str(&source).unwrap();
        let index = match source["noteID"].as_str().unwrap() {
            "a" => 1,
            "b" => 2,
            "c" => 3,
            "d" => 4,
            _ => panic!("unexpected note"),
        };
        let mut vector = vec![0.0f32; 1024];
        vector[0] = std::f32::consts::FRAC_1_SQRT_2;
        vector[index] = std::f32::consts::FRAC_1_SQRT_2;
        db.execute(
            "UPDATE vectors SET vector=?1 WHERE generation=?2 AND id=?3",
            params![blob(&vector), generation, id],
        )
        .unwrap();
    }
    db.execute("UPDATE generations SET manifest=?1", [manifest(&c)])
        .unwrap();
    drop(db);
    let allowed = ["a", "b", "c", "d"]
        .into_iter()
        .map(|id| {
            (
                id.to_string(),
                crate::knowledge::note_fingerprint(
                    &crate::notes::load_note_snapshot(root, id).unwrap(),
                ),
            )
        })
        .collect::<BTreeMap<_, _>>();
    let cached = cached_note_similarities(root, "a", &allowed)
        .unwrap()
        .expect("cached vectors");
    assert_eq!(manual_suggestion_threshold(root, &cached.1), 0.43);
    assert_eq!(cached.0.len(), 3);
    let snapshot = crate::workspace_repository::knowledge_dispatch(
        root,
        &json!({"command":"kb-snapshot","noteID":"a"}),
    )
    .unwrap();
    let suggestions=crate::workspace_repository::knowledge_dispatch(root,&json!({"command":"kb-suggestions","noteID":"a",
        "expectedWorkspaceRevision":snapshot["workspaceRevision"],"expectedKBRevision":snapshot["kbRevision"]})).unwrap();
    let items = suggestions["items"].as_array().unwrap();
    assert_eq!(items.len(), 3);
    assert!(items.iter().all(|item| item["method"] == "semantic"));
    let topics=crate::workspace_repository::knowledge_dispatch(root,&json!({"command":"kb-topics",
        "expectedWorkspaceRevision":snapshot["workspaceRevision"],"expectedKBRevision":snapshot["kbRevision"]})).unwrap();
    assert!(
        topics["topics"].as_array().unwrap().is_empty(),
        "manual suggestion cut-off must not create automatic topic edges"
    );
}

#[test]
fn synthetic_evaluation_input_matches_the_real_empty_title_note_document() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path();
    let mut c = Config::default();
    c.enabled = true;
    configure(root, &c);
    let text = "Подготовить вымышленный текст для проверки";
    crate::notes::dispatch(
        root,
        &json!({"command":"note-save","note":{
            "id":"fixture","kind":"note","title":"","text":text,
            "createdAt":1,"updatedAt":1,"revision":0
        }}),
    )
    .unwrap();
    let (documents, _) = corpus(root, &c).unwrap();
    let doc = documents
        .iter()
        .find(|document| document.source["noteID"] == "fixture")
        .expect("note document");
    assert_eq!(doc.text, format!("{text}\n{text}\n\n"));
}

#[test]
fn knowledge_suggestions_reuse_only_current_permitted_vectors_without_new_requests() {
    let directory = tempfile::tempdir().unwrap();
    let canonical = directory.path().canonicalize().unwrap();
    let root = canonical.as_path();
    let fixture = Fixture::start();
    let c = fixture.config();
    configure(root, &c);
    let mut settings: Value =
        serde_json::from_slice(&fs::read(root.join("settings.json")).unwrap()).unwrap();
    settings["features"]["knowledgeBase"] = json!(true);
    crate::storage::atomic_json(&root.join("settings.json"), &settings).unwrap();
    let empty_allowed = BTreeMap::from([("a".into(), "x".into())]);
    assert!(cached_note_similarities(root, "a", &empty_allowed)
        .unwrap()
        .is_none());
    assert!(
        !root.join("cache/semantic/index.sqlite").exists(),
        "reading suggestions must not create an index"
    );
    note(root, "a", "resilience recovering failures");
    note(root, "b", "устойчивость аварийной системы");
    note(root, "unrelated", "budget forecast expenditure");
    assert_eq!(
        refresh(root, &json!({"maxDocuments":32})).unwrap()["complete"],
        true
    );
    let calls = fixture.calls.load(Ordering::SeqCst);
    let snapshot = crate::workspace_repository::knowledge_dispatch(
        root,
        &json!({"command":"kb-snapshot","noteID":"a"}),
    )
    .unwrap();
    let get = |snapshot: &Value| {
        crate::workspace_repository::knowledge_dispatch(root,&json!({"command":"kb-suggestions","noteID":"a","expectedWorkspaceRevision":snapshot["workspaceRevision"],"expectedKBRevision":snapshot["kbRevision"]})).unwrap()
    };
    let result = get(&snapshot);
    assert_eq!(result["items"][0]["noteID"], "b");
    assert_eq!(result["items"][0]["method"], "semantic");
    assert_eq!(
        fixture.calls.load(Ordering::SeqCst),
        calls,
        "reading cached vectors must never call the model"
    );
    let sidecar = root.join("cache/semantic/index.sqlite-wal");
    std::os::unix::fs::symlink(root.join("settings.json"), &sidecar).unwrap();
    assert!(
        cached_note_similarities(root, "a", &empty_allowed).is_err(),
        "index sidecars must not be symlinks"
    );
    fs::remove_file(sidecar).unwrap();
    let a = crate::notes::load_note_snapshot(root, "a").unwrap();
    let b = crate::notes::load_note_snapshot(root, "b").unwrap();
    crate::workspace_repository::knowledge_dispatch(root,&json!({"command":"kb-feedback-change",
        "operationID":uuid::Uuid::new_v4().to_string(),"expectedWorkspaceRevision":snapshot["workspaceRevision"],
        "expectedKBRevision":snapshot["kbRevision"],"expectedFromRevision":a.revision,"expectedToRevision":b.revision,
        "fromID":"a","toID":"b","blocked":true})).unwrap();
    let blocked = crate::workspace_repository::knowledge_dispatch(
        root,
        &json!({"command":"kb-snapshot","noteID":"a"}),
    )
    .unwrap();
    assert!(
        get(&blocked)["items"]
            .as_array()
            .unwrap()
            .iter()
            .all(|v| v["noteID"] != "b"),
        "blocked pairs must not return through the vector path"
    );
    crate::workspace_repository::knowledge_dispatch(root,&json!({"command":"kb-feedback-change",
        "operationID":uuid::Uuid::new_v4().to_string(),"expectedWorkspaceRevision":blocked["workspaceRevision"],
        "expectedKBRevision":blocked["kbRevision"],"expectedFromRevision":a.revision,"expectedToRevision":b.revision,
        "fromID":"a","toID":"b","blocked":false})).unwrap();
    let mut edited = crate::notes::load_note_snapshot(root, "b").unwrap();
    edited.text = "completely rewritten note".into();
    crate::notes::save_note(root, edited).unwrap();
    let snapshot = crate::workspace_repository::knowledge_dispatch(
        root,
        &json!({"command":"kb-snapshot","noteID":"a"}),
    )
    .unwrap();
    assert!(
        get(&snapshot)["items"]
            .as_array()
            .unwrap()
            .iter()
            .all(|v| v["noteID"] != "b"),
        "a stale vector must not be reused after an edit"
    );
    let mut changed = c.clone();
    changed.model_revision = "different-model".into();
    configure(root, &changed);
    settings["features"]["knowledgeBase"] = json!(true);
    crate::storage::atomic_json(&root.join("settings.json"), &settings).unwrap();
    let allowed = BTreeMap::from([("a".into(), "x".into())]);
    assert!(
        cached_note_similarities(root, "a", &allowed)
            .unwrap()
            .is_none(),
        "vectors from another model manifest must not be reused"
    );
}

#[test]
fn knowledge_topics_use_cached_semantic_vectors_without_calls_and_respect_block_and_staleness() {
    let directory = tempfile::tempdir().unwrap();
    let canonical = directory.path().canonicalize().unwrap();
    let root = canonical.as_path();
    let fixture = Fixture::start();
    let c = fixture.config();
    configure(root, &c);
    let mut settings: Value =
        serde_json::from_slice(&fs::read(root.join("settings.json")).unwrap()).unwrap();
    settings["features"]["knowledgeBase"] = json!(true);
    crate::storage::atomic_json(&root.join("settings.json"), &settings).unwrap();
    for (id, text) in [
        ("a", "resilience glaciers"),
        ("b", "resiliency medicine"),
        ("c", "устойчивость облака"),
        ("d", "устойчивость канала"),
        ("unrelated", "budget forecast expenditure"),
    ] {
        note(root, id, text);
    }
    assert_eq!(
        refresh(root, &json!({"maxDocuments":32})).unwrap()["complete"],
        true
    );
    let calls = fixture.calls.load(Ordering::SeqCst);
    let snapshot = || {
        crate::workspace_repository::knowledge_dispatch(root, &json!({"command":"kb-snapshot"}))
            .unwrap()
    };
    let get = |s: &Value| {
        crate::workspace_repository::knowledge_dispatch(
            root,
            &json!({"command":"kb-topics",
        "expectedWorkspaceRevision":s["workspaceRevision"],"expectedKBRevision":s["kbRevision"]}),
        )
        .unwrap()
    };
    let s = snapshot();
    let result = get(&s);
    assert_eq!(result["method"], "mixed");
    assert_eq!(result["semanticIndexed"], 5);
    let topic = result["topics"]
        .as_array()
        .unwrap()
        .iter()
        .find(|topic| topic["method"] == "mixed")
        .expect("cross-language semantic group");
    let ids = topic["sources"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["noteID"].as_str().unwrap())
        .collect::<BTreeSet<_>>();
    assert_eq!(ids, BTreeSet::from(["a", "b", "c", "d"]));
    assert_eq!(
        fixture.calls.load(Ordering::SeqCst),
        calls,
        "topic construction must not call a model"
    );
    let a = crate::notes::load_note_snapshot(root, "a").unwrap();
    let b = crate::notes::load_note_snapshot(root, "b").unwrap();
    crate::workspace_repository::knowledge_dispatch(root,&json!({"command":"kb-feedback-change",
        "operationID":uuid::Uuid::new_v4().to_string(),"expectedWorkspaceRevision":s["workspaceRevision"],
        "expectedKBRevision":s["kbRevision"],"expectedFromRevision":a.revision,"expectedToRevision":b.revision,
        "fromID":"a","toID":"b","blocked":true})).unwrap();
    for group in get(&snapshot())["topics"].as_array().unwrap() {
        let ids = group["sources"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["noteID"].as_str().unwrap())
            .collect::<BTreeSet<_>>();
        assert!(
            !(ids.contains("a") && ids.contains("b")),
            "explicit block must survive semantic grouping"
        );
    }
    let mut changed = crate::notes::load_note_snapshot(root, "c").unwrap();
    changed.title = "other".into();
    changed.text = "completely changed".into();
    crate::notes::save_note(root, changed).unwrap();
    assert_eq!(
        get(&snapshot())["semanticIndexed"],
        4,
        "stale vectors must not contribute to topics"
    );
    assert_eq!(fixture.calls.load(Ordering::SeqCst), calls);
    settings["features"]["semanticSearch"] = json!(false);
    crate::storage::atomic_json(&root.join("settings.json"), &settings).unwrap();
    assert_eq!(
        get(&snapshot())["method"],
        "sharedTerms",
        "revoked semantic access must not contribute"
    );
}

#[test]
fn real_cosine_storage_cross_language_fixture_and_delete_freshness() {
    let root = tempfile::tempdir().unwrap();
    let canonical = root.path().canonicalize().unwrap();
    let root = canonical.as_path();
    let fixture = Fixture::start();
    configure(root, &fixture.config());
    note(
        root,
        "resilient",
        "Resilience means recovering after failures",
    );
    note(root, "budget", "Pilot budget is 200 dollars");
    let result = refresh(root, &json!({"maxDocuments":32})).unwrap();
    assert_eq!(result["complete"], true);
    assert_eq!(result["indexed"], 2);
    let hits = search(root, "карточка про устойчивость", 10, "", None).unwrap();
    assert_eq!(hits["hits"][0]["source"]["noteID"], "resilient");
    assert!(hits["hits"][0]["cosine"].as_f64().unwrap() > 0.999);
    crate::notes::dispatch(
        root,
        &json!({"command":"note-trash","id":"resilient","revision":1}),
    )
    .unwrap();
    assert!(
        search(root, "устойчивость", 10, "", None).unwrap()["hits"]
            .as_array()
            .unwrap()
            .is_empty(),
        "deleted sources are excluded before refresh"
    );
}
#[test]
fn generation_is_atomic_model_change_rejects_old_vectors_and_chunks_reuse() {
    let root = tempfile::tempdir().unwrap();
    let canonical = root.path().canonicalize().unwrap();
    let root = canonical.as_path();
    let fixture = Fixture::start();
    let mut c = fixture.config();
    configure(root, &c);
    note(root, "a", "Resilience");
    note(root, "b", "budget");
    let first = refresh(root, &json!({"maxDocuments":1})).unwrap();
    assert_eq!(first["complete"], false);
    assert_eq!(
        search(root, "resilience", 5, "", None).unwrap()["needsRefresh"],
        true
    );
    assert_eq!(
        refresh(root, &json!({"maxDocuments":1})).unwrap()["complete"],
        true
    );
    assert_eq!(
        refresh(root, &json!({"maxDocuments":1})).unwrap()["added"],
        0
    );
    c.model_revision = "fixture-v2".into();
    configure(root, &c);
    assert_eq!(
        search(root, "resilience", 5, "", None).unwrap()["needsRefresh"],
        true
    );
    let r = refresh(root, &json!({"maxDocuments":1})).unwrap();
    assert_eq!(r["complete"], false);
    assert_eq!(r["indexed"], 1);
    configure(
        root,
        &Config {
            enabled: false,
            ..c
        },
    );
    assert_eq!(
        search(root, "resilience", 5, "", None).unwrap()["enabled"],
        false
    );
}
#[test]
fn embeddings_reject_bad_vectors_and_cloud_without_consent() {
    assert!(normalize(&json!([0, 0, 0]), 3).is_err());
    assert!(normalize(&json!([1, 2]), 3).is_err());
    assert!(decode(&[0, 0, 0], 3).is_err());
    let c = Config {
        provider: "openai".into(),
        endpoint: "https://provider.example/v1".into(),
        ..Config::default()
    };
    assert!(validate(&c).is_err());
    assert!(validate(&Config {
        allow_cloud: true,
        ..c
    })
    .is_ok());
    for endpoint in [
        "http://192.168.1.2/v1",
        "http://localhost.evil/v1",
        "https://user:secret@example.com/v1",
        "https://example.com/v1?token=secret",
    ] {
        assert!(validate(&Config {
            endpoint: endpoint.into(),
            allow_cloud: true,
            ..Config::default()
        })
        .is_err());
    }
}
#[test]
fn chunking_is_utf8_safe_and_hashes_manifest_and_source_version() {
    let s = json!({"id":"s_test","title":"Русский","sourceFingerprint":"v1"});
    let text = "устойчивость ".repeat(800);
    let docs = chunk_source("note:a", &text, &s, true);
    assert!(docs.len() > 2);
    assert!(docs
        .iter()
        .all(|d| d.source["excerpt"].as_str().unwrap().len() <= CHUNK_BYTES));
    assert_eq!(
        docs.iter()
            .map(|d| d.source["excerpt"].as_str().unwrap())
            .collect::<String>(),
        text
    );
    let mut c = Config::default();
    let before = manifest(&c);
    c.query_prefix = "different".into();
    assert_ne!(before, manifest(&c));
}

#[test]
fn credentials_are_bound_to_snapshot_before_any_endpoint_request() {
    let root = tempfile::tempdir().unwrap();
    let canonical = root.path().canonicalize().unwrap();
    let root = canonical.as_path();
    let a = Fixture::start();
    let b = Fixture::start();
    let ca = a.config();
    configure(root, &ca);
    note(root, "a", "Resilience");
    refresh(root, &json!({"maxDocuments":32})).unwrap();
    let binding = dispatch(root, &json!({"command":"semantic-config"})).unwrap()["fingerprint"]
        .as_str()
        .unwrap()
        .to_owned();
    configure(root, &b.config());
    let stale = dispatch(root, &json!({"command":"semantic-refresh","apiKey":"synthetic-key-for-A","configFingerprint":binding})).unwrap_err();
    assert!(stale.to_string().contains("изменились"));
    let missing = dispatch(
        root,
        &json!({"command":"semantic-refresh","apiKey":"synthetic-key-for-A"}),
    )
    .unwrap_err();
    assert!(missing.to_string().contains("версия настроек"));
    assert!(
        search(root, "resilience", 5, "synthetic-key-for-A", Some(&binding))
            .unwrap_err()
            .to_string()
            .contains("изменились")
    );
    assert!(dispatch(root,&json!({"command":"semantic-models","apiKey":"synthetic-key-for-A","configFingerprint":binding})).unwrap_err().to_string().contains("изменились"));
    assert_eq!(
        b.calls.load(Ordering::SeqCst),
        0,
        "stale credentials never reach endpoint B"
    );
}

#[test]
fn revoking_folder_during_one_batch_prevents_all_later_requests() {
    let temp = tempfile::tempdir().unwrap();
    let base = temp.path().canonicalize().unwrap();
    let root = base.join("library");
    let code = base.join("project");
    fs::create_dir_all(&code).unwrap();
    fs::write(
        code.join("main.rs"),
        "fn example() { recovery(); }\n".repeat(2000),
    )
    .unwrap();
    let task=crate::task_workspace::dispatch(&root,&json!({"command":"task-create","title":"Review","operationID":uuid::Uuid::new_v4().to_string()})).unwrap();
    let task=crate::task_workspace::dispatch(&root,&json!({"command":"task-material-link","taskID":task["id"],"expectedRevision":task["revision"],"operationID":uuid::Uuid::new_v4().to_string(),"material":{"kind":"repository","title":"Code","path":code}})).unwrap();
    let task_id = task["id"].as_str().unwrap().to_owned();
    let material = task["materials"][0]["id"].as_str().unwrap().to_owned();
    crate::storage::atomic_json(
        &root.join("settings.json"),
        &json!({"features":{"tasks":true}}),
    )
    .unwrap();
    crate::code_index::dispatch(&root,&json!({"command":"code-index-grant","taskID":task_id,"materialID":material,"enabled":true})).unwrap();
    let fixture = Fixture::start();
    configure(&root, &fixture.config());
    let root2 = root.clone();
    let task2 = task_id.clone();
    let material2 = material.clone();
    *fixture.hook.lock().unwrap() = Some(Box::new(move || {
        crate::code_index::dispatch(&root2,&json!({"command":"code-index-grant","taskID":task2,"materialID":material2,"enabled":false})).unwrap();
    }));
    let result = refresh(&root, &json!({"maxDocuments":32})).unwrap();
    assert!(
        result["total"].as_u64().unwrap() > 8,
        "fixture must span several network batches"
    );
    let payloads = fixture.payloads.lock().unwrap();
    assert!(!payloads.is_empty());
    assert!(payloads[0].to_string().contains("fn example"));
    assert!(payloads.iter().skip(1).all(|p|!p.to_string().contains("fn example")),"revoked folder must not enter a later HTTP batch; unrelated current task text remains allowed");
    drop(payloads);
    assert_eq!(
        refresh(&root, &json!({"maxDocuments":32})).unwrap()["complete"],
        true
    );
}

#[test]
fn module_off_blocks_semantic_network_before_any_provider_call() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let fixture = Fixture::start();
    dispatch(
        &root,
        &json!({"command":"semantic-config","config":fixture.config()}),
    )
    .unwrap();
    note(&root, "a", "Resilience");
    assert!(refresh(&root, &json!({}))
        .unwrap_err()
        .to_string()
        .contains("Включите"));
    assert_eq!(
        search(&root, "resilience", 10, "", None).unwrap()["enabled"],
        false
    );
    for command in ["semantic-check", "semantic-models", "semantic-pull"] {
        assert!(dispatch(&root, &json!({"command":command}))
            .unwrap_err()
            .to_string()
            .contains("Включите"));
    }
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 0);
}
#[test]
fn module_revocation_during_embedding_discards_vectors_and_stops_further_batches() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let fixture = Fixture::start();
    configure(&root, &fixture.config());
    for i in 0..12 {
        note(&root, &format!("n-{i}"), "Resilience");
    }
    let changed = root.clone();
    *fixture.hook.lock().unwrap() = Some(Box::new(move || {
        crate::storage::atomic_json(&changed.join("settings.json"), &json!({"features":{}}))
            .unwrap();
    }));
    assert!(refresh(&root, &json!({"maxDocuments":32})).is_err());
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 1);
    let db = connection(&root).unwrap();
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM vectors", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert!(db
        .query_row("SELECT value FROM state WHERE key='active'", [], |r| r
            .get::<_, String>(
            0
        ))
        .optional()
        .unwrap()
        .is_none());
    assert_eq!(crate::notes::list(&root).unwrap().notes.len(), 12);
    configure(&root, &fixture.config());
    assert_eq!(
        refresh(&root, &json!({"maxDocuments":32})).unwrap()["complete"],
        true
    );
}

#[test]
fn managed_configuration_is_local_fixed_and_never_accepts_external_endpoint() {
    let c = Config::default();
    assert_eq!(c.provider, "managed");
    assert!(c.endpoint.is_empty() && validate(&c).is_ok());
    assert!(validate(&Config {
        endpoint: "http://127.0.0.1:9999".into(),
        ..c.clone()
    })
    .is_err());
    assert!(validate(&Config {
        allow_cloud: true,
        ..c.clone()
    })
    .is_err());
    assert!(validate(&Config {
        model_revision: "replacement".into(),
        ..c
    })
    .is_err());
}

#[test]
fn cached_library_centroids_are_typed_and_exclude_changed_notes() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().canonicalize().unwrap();
    let fixture = Fixture::start();
    configure(root.as_path(), &fixture.config());
    note(root.as_path(), "a", "resilience");
    note(root.as_path(), "b", "budget");
    dispatch(
        root.as_path(),
        &json!({"command":"semantic-refresh","maxDocuments":8}),
    )
    .unwrap();
    let allowed = BTreeMap::from([(
        "a".to_string(),
        crate::knowledge::note_fingerprint(
            &crate::notes::load_note_snapshot(root.as_path(), "a").unwrap(),
        ),
    )]);
    let calls = fixture.calls.load(Ordering::SeqCst);
    let (vectors, _) = cached_library_centroids(root.as_path(), &allowed, &BTreeSet::new())
        .unwrap()
        .unwrap();
    assert_eq!(vectors.keys().cloned().collect::<Vec<_>>(), vec!["note:a"]);
    assert_eq!(fixture.calls.load(Ordering::SeqCst), calls);
    let stale = BTreeMap::from([("a".to_string(), "changed".to_string())]);
    assert!(
        cached_library_centroids(root.as_path(), &stale, &BTreeSet::new())
            .unwrap()
            .is_none()
    );
}
