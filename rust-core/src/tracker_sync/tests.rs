use super::*;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::thread;

#[derive(Clone, Debug)]
struct Request {
    method: String,
    path: String,
    headers: String,
    body: Value,
}
struct Fixture {
    base: String,
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Fixture {
    fn new(
        mut handle: impl FnMut(Request) -> Option<(u16, Vec<(String, String)>, Value)> + Send + 'static,
    ) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let thread = thread::spawn(move || {
            while !stopping.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        stream
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        let mut bytes = vec![];
                        let mut header_end = None;
                        let mut wanted = 0;
                        loop {
                            let mut part = [0u8; 4096];
                            let n = stream.read(&mut part).unwrap_or(0);
                            if n == 0 {
                                break;
                            }
                            bytes.extend_from_slice(&part[..n]);
                            if header_end.is_none() {
                                if let Some(at) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                                    header_end = Some(at + 4);
                                    let text = String::from_utf8_lossy(&bytes[..at]);
                                    wanted = text
                                        .lines()
                                        .find_map(|l| {
                                            l.to_ascii_lowercase()
                                                .strip_prefix("content-length:")
                                                .and_then(|v| v.trim().parse::<usize>().ok())
                                        })
                                        .unwrap_or(0);
                                }
                            }
                            if header_end.is_some_and(|end| bytes.len() >= end + wanted) {
                                break;
                            }
                        }
                        let Some(end) = header_end else {
                            continue;
                        };
                        let headers = String::from_utf8_lossy(&bytes[..end]).to_string();
                        let mut first = headers.lines().next().unwrap().split_whitespace();
                        let method = first.next().unwrap().to_string();
                        let path = first.next().unwrap().to_string();
                        let body = if wanted > 0 {
                            serde_json::from_slice(&bytes[end..end + wanted]).unwrap()
                        } else {
                            Value::Null
                        };
                        if let Some((status, extra, value)) = handle(Request {
                            method,
                            path,
                            headers,
                            body,
                        }) {
                            let body = serde_json::to_vec(&value).unwrap();
                            let extra = extra
                                .into_iter()
                                .map(|(k, v)| format!("{k}: {v}\r\n"))
                                .collect::<String>();
                            let response=format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n{extra}\r\n",body.len());
                            let _ = stream.write_all(response.as_bytes());
                            let _ = stream.write_all(&body);
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(3))
                    }
                    Err(e) => panic!("{e}"),
                }
            }
        });
        Self {
            base: format!("http://{address}"),
            stop,
            thread: Some(thread),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        let _ = TcpStream::connect(self.base.trim_start_matches("http://"));
        if let Some(t) = self.thread.take() {
            t.join().unwrap();
        }
    }
}
fn ok(value: Value) -> Option<(u16, Vec<(String, String)>, Value)> {
    Some((200, vec![], value))
}
fn config(root: &Path, provider: &str, push: bool) -> TrackerConfiguration {
    let c = TrackerConfiguration {
        id: format!("connection-{provider}"),
        provider: provider.into(),
        account: "Личный тест".into(),
        organization_id: if provider == "yandex" {
            "test-org".into()
        } else {
            String::new()
        },
        enabled: true,
        push_enabled: push,
        scopes: vec!["scope-1".into()],
        expires_at: Some(now() + 3600.),
        ..Default::default()
    };
    request(root, "tracker-configure", &json!({"configuration":c})).unwrap();
    configuration(&load(&database(root).unwrap()).unwrap(), &c.id).unwrap()
}
fn sync_args(c: &TrackerConfiguration, f: &Fixture) -> Value {
    json!({"connectionID":c.id,"token":"fixture-not-a-secret","force":true,"testBaseURL":f.base})
}
fn google(id: &str, title: &str, etag: &str) -> Value {
    json!({"id":id,"title":title,"notes":"Описание","etag":etag,"status":"needsAction","webViewLink":"https://tasks.google.com/task/x"})
}
fn edit(root: &Path, local_id: &str, title: &str) {
    let mut note = notes::list(root)
        .unwrap()
        .notes
        .into_iter()
        .find(|n| n.id == local_id)
        .unwrap();
    note.title = title.into();
    notes::save_note(root, note).unwrap();
}
fn created(root: &Path) -> String {
    let task = crate::task_workspace::dispatch(
        root,
        &json!({"command":"task-create","operationID":id(),"title":"Новая","text":"Из После"}),
    )
    .unwrap();
    task["id"]
        .as_str()
        .unwrap()
        .strip_prefix("manual:")
        .unwrap()
        .into()
}

#[test]
fn marker_and_provider_projection_do_not_destroy_text() {
    assert_eq!(
        strip_marker("Описание\n\n[posle:2b2e69a3-1234-5678-abcd-aaaaaaaaaaaa]"),
        "Описание"
    );
    assert_eq!(
        strip_marker("Фраза [posle:ordinary]"),
        "Фраза [posle:ordinary]"
    );
    let fields = Fields {
        title: "t".into(),
        text: "body".into(),
        status: "blocked".into(),
        due: String::new(),
        owner: "me".into(),
    };
    assert_eq!(provider_fields(fields, "google").status, "todo");
}
#[test]
fn paginated_google_pull_never_sends_token_to_disk() {
    let root = tempfile::tempdir().unwrap();
    let c = config(root.path(), "google", false);
    let requests = Arc::new(Mutex::new(vec![]));
    let seen = requests.clone();
    let f = Fixture::new(move |r| {
        assert_eq!(r.method, "GET");
        assert!(
            r.path.contains("showHidden=true")
                && r.path.contains("showCompleted=true")
                && r.path.contains("showDeleted=true")
        );
        seen.lock().unwrap().push(r.path.clone());
        if r.path.contains("pageToken=next") {
            ok(json!({"items":[google("two","Вторая","etag2")]}))
        } else {
            ok(json!({"items":[google("one","Первая","etag1")],"nextPageToken":"next"}))
        }
    });
    let result = request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    assert_eq!(result["linkedCount"], 2);
    assert_eq!(notes::list(root.path()).unwrap().notes.len(), 2);
    assert_eq!(requests.lock().unwrap().len(), 2);
    let bytes = fs::read(root.path().join("notes/tracker-sync.sqlite")).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("fixture-not-a-secret"));
    request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    assert_eq!(notes::list(root.path()).unwrap().notes.len(), 2);
}
#[test]
fn google_push_uses_etag_and_acknowledges_exact_target() {
    let root = tempfile::tempdir().unwrap();
    let c = config(root.path(), "google", true);
    let remote = Arc::new(Mutex::new(google("one", "Оригинал", "v1")));
    let data = remote.clone();
    let writes = Arc::new(Mutex::new(0));
    let count = writes.clone();
    let f = Fixture::new(move |r| {
        let mut value = data.lock().unwrap();
        match r.method.as_str() {
            "GET" if r.path.contains("/tasks?") => ok(json!({"items":[value.clone()]})),
            "GET" => ok(value.clone()),
            "PATCH" => {
                assert!(r.headers.to_ascii_lowercase().contains("if-match: v1"));
                *count.lock().unwrap() += 1;
                for (k, v) in r.body.as_object().unwrap() {
                    value[k] = v.clone();
                }
                value["etag"] = json!("v2");
                ok(value.clone())
            }
            _ => panic!("unexpected {r:?}"),
        }
    });
    request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    let local = notes::list(root.path()).unwrap().notes[0].id.clone();
    edit(root.path(), &local, "Исправлено локально");
    let result = request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    assert_eq!(result["pending"].as_array().unwrap().len(), 0);
    assert_eq!(remote.lock().unwrap()["title"], "Исправлено локально");
    request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    assert_eq!(*writes.lock().unwrap(), 1);
}
#[test]
fn conflicting_edits_need_explicit_fresh_resolution() {
    let root = tempfile::tempdir().unwrap();
    let c = config(root.path(), "google", true);
    let remote = Arc::new(Mutex::new(google("one", "Исходная", "v1")));
    let data = remote.clone();
    let writes = Arc::new(Mutex::new(0));
    let count = writes.clone();
    let f = Fixture::new(move |r| {
        let mut value = data.lock().unwrap();
        if r.method == "PATCH" {
            *count.lock().unwrap() += 1;
            for (k, v) in r.body.as_object().unwrap() {
                value[k] = v.clone();
            }
            value["etag"] = json!("v4");
            return ok(value.clone());
        }
        if r.path.contains("/tasks?") {
            ok(json!({"items":[value.clone()]}))
        } else {
            ok(value.clone())
        }
    });
    request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    let local = notes::list(root.path()).unwrap().notes[0].id.clone();
    edit(root.path(), &local, "Моя версия");
    *remote.lock().unwrap() = google("one", "Удалённая версия", "v2");
    let result = request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    let conflict = result["conflicts"][0].clone();
    assert_eq!(*writes.lock().unwrap(), 0);
    let mut args = sync_args(&c, &f);
    args["conflictID"] = conflict["id"].clone();
    args["fingerprint"] = conflict["fingerprint"].clone();
    args["resolution"] = json!("local");
    *remote.lock().unwrap() = google("one", "Ещё изменилось", "v3");
    assert!(request(root.path(), "tracker-resolve", &args)
        .unwrap_err()
        .to_string()
        .contains("после сравнения"));
    let result = request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    args["fingerprint"] = result["conflicts"][0]["fingerprint"].clone();
    request(root.path(), "tracker-resolve", &args).unwrap();
    request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    assert_eq!(*writes.lock().unwrap(), 1);
    assert_eq!(remote.lock().unwrap()["title"], "Моя версия");
}
#[test]
fn remote_delete_is_not_propagated_and_unlink_stays_detached() {
    let root = tempfile::tempdir().unwrap();
    let c = config(root.path(), "google", true);
    let remote = Arc::new(Mutex::new(google("one", "Сохранить", "v1")));
    let data = remote.clone();
    let f = Fixture::new(move |r| {
        assert_eq!(r.method, "GET");
        ok(json!({"items":[data.lock().unwrap().clone()]}))
    });
    request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    remote.lock().unwrap()["deleted"] = json!(true);
    let value = request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    let conflict = &value["conflicts"][0];
    assert_eq!(notes::list(root.path()).unwrap().notes[0].trashed_at, None);
    request(root.path(),"tracker-resolve",&json!({"connectionID":c.id,"conflictID":conflict["id"],"fingerprint":conflict["fingerprint"],"resolution":"unlink"})).unwrap();
    remote.lock().unwrap()["deleted"] = json!(false);
    request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    assert_eq!(notes::list(root.path()).unwrap().notes.len(), 1);
    assert_eq!(
        load(&database(root.path()).unwrap())
            .unwrap()
            .bindings
            .len(),
        0
    );
}
#[test]
fn google_uncertain_create_reconciles_without_duplicate_post_or_import() {
    let root = tempfile::tempdir().unwrap();
    let c = config(root.path(), "google", true);
    let local = created(root.path());
    request(
        root.path(),
        "tracker-export",
        &json!({"connectionID":c.id,"taskID":local,"scope":"scope-1"}),
    )
    .unwrap();
    let remote = Arc::new(Mutex::new(None::<Value>));
    let data = remote.clone();
    let posts = Arc::new(Mutex::new(0));
    let count = posts.clone();
    let f = Fixture::new(move |r| {
        if r.method == "POST" {
            *count.lock().unwrap() += 1;
            let mut value = r.body;
            value["id"] = json!("created");
            value["etag"] = json!("v1");
            *data.lock().unwrap() = Some(value);
            return None;
        }
        assert_eq!(r.method, "GET");
        if r.path.contains("/tasks?") {
            ok(json!({"items":data.lock().unwrap().iter().cloned().collect::<Vec<_>>()}))
        } else {
            ok(data.lock().unwrap().clone().unwrap())
        }
    });
    assert!(request(root.path(), "tracker-sync", &sync_args(&c, &f)).is_err());
    assert_eq!(*posts.lock().unwrap(), 1);
    let value = request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    assert_eq!(*posts.lock().unwrap(), 1);
    assert_eq!(value["pending"].as_array().unwrap().len(), 0);
    assert_eq!(value["linkedCount"], 1);
    assert_eq!(notes::list(root.path()).unwrap().notes.len(), 1);
}
#[test]
fn google_uncertain_create_not_visible_never_reposts() {
    let root = tempfile::tempdir().unwrap();
    let c = config(root.path(), "google", true);
    let local = created(root.path());
    request(
        root.path(),
        "tracker-export",
        &json!({"connectionID":c.id,"taskID":local,"scope":"scope-1"}),
    )
    .unwrap();
    let posts = Arc::new(Mutex::new(0));
    let count = posts.clone();
    let f = Fixture::new(move |r| {
        if r.method == "POST" {
            *count.lock().unwrap() += 1;
            None
        } else {
            ok(json!({"items":[]}))
        }
    });
    request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap_err();
    let error = request(root.path(), "tracker-sync", &sync_args(&c, &f))
        .unwrap_err()
        .to_string();
    assert!(error.contains("Повторный POST остановлен"));
    assert_eq!(*posts.lock().unwrap(), 1);
}
#[test]
fn rate_limit_and_auth_errors_are_persisted_without_response_text() {
    for code in [429, 401] {
        let root = tempfile::tempdir().unwrap();
        let c = config(root.path(), "google", false);
        let f = Fixture::new(move |_| {
            Some((
                code,
                vec![("Retry-After".into(), "120".into())],
                json!({"error":"fixture-not-a-secret confidential meeting"}),
            ))
        });
        let error = request(root.path(), "tracker-sync", &sync_args(&c, &f))
            .unwrap_err()
            .to_string();
        assert!(!error.contains("confidential"));
        let j = load(&database(root.path()).unwrap()).unwrap();
        let c = configuration(&j, &c.id).unwrap();
        assert_eq!(c.requires_auth, code == 401);
        if code == 429 {
            assert!(c.retry_at.unwrap() > now() + 100.);
        } else {
            assert!(c.retry_at.is_none());
        }
    }
}
#[test]
fn partial_page_failure_imports_nothing_and_cannot_send_local_changes() {
    let root = tempfile::tempdir().unwrap();
    let c = config(root.path(), "google", true);
    let f = Fixture::new(move |r| {
        assert_eq!(r.method, "GET");
        if r.path.contains("pageToken=next") {
            Some((503, vec![], json!({})))
        } else {
            ok(json!({"items":[google("one","Первый","v1")],"nextPageToken":"next"}))
        }
    });
    assert!(request(root.path(), "tracker-sync", &sync_args(&c, &f)).is_err());
    assert!(notes::list(root.path()).unwrap().notes.is_empty());
}
#[test]
fn explicit_disconnect_keeps_tasks_and_cannot_change_bound_account() {
    let root = tempfile::tempdir().unwrap();
    let mut c = config(root.path(), "google", false);
    let f = Fixture::new(move |_| ok(json!({"items":[google("one","Локальная копия","v1")]})));
    request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    c.account = "Другой аккаунт".into();
    assert!(request(
        root.path(),
        "tracker-configure",
        &json!({"configuration":c,"expectedRevision":c.revision})
    )
    .is_err());
    request(
        root.path(),
        "tracker-disconnect",
        &json!({"connectionID":c.id,"expectedRevision":c.revision}),
    )
    .unwrap();
    assert_eq!(notes::list(root.path()).unwrap().notes.len(), 1);
    assert!(request(root.path(), "tracker-sync", &sync_args(&c, &f))
        .unwrap_err()
        .to_string()
        .contains("выключена"));
}
#[test]
fn yandex_headers_pagination_due_dates_and_status_transition() {
    let root = tempfile::tempdir().unwrap();
    let c = config(root.path(), "yandex", true);
    let remote = Arc::new(Mutex::new(
        json!({"key":"QUEUE-1","summary":"Задача","description":"Контекст","version":1,"status":{"key":"open"},"dueDate":"2026-11-01","assignee":{"id":"me"}}),
    ));
    let data = remote.clone();
    let transitions = Arc::new(Mutex::new(0));
    let count = transitions.clone();
    let f = Fixture::new(move |r| {
        assert!(r.headers.contains("OAuth fixture-not-a-secret"));
        assert!(r
            .headers
            .to_ascii_lowercase()
            .contains("x-org-id: test-org"));
        let mut value = data.lock().unwrap();
        if r.path.starts_with("/v3/issues/_search") {
            assert_eq!(r.body["filter"]["queue"], "scope-1");
            return Some((
                200,
                vec![("X-Total-Pages".into(), "1".into())],
                json!([value.clone()]),
            ));
        }
        if r.path.ends_with("/transitions") {
            return ok(json!([{"id":"start","to":{"key":"inProgress"}}]));
        }
        if r.path.contains("/transitions/start/_execute") {
            assert!(r.path.contains("version=1"));
            *count.lock().unwrap() += 1;
            value["version"] = json!(2);
            value["status"] = json!({"key":"inProgress"});
            return ok(json!([]));
        }
        assert_eq!(r.method, "GET");
        ok(value.clone())
    });
    request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    let note = notes::list(root.path()).unwrap().notes[0].clone();
    assert_eq!(note.due, "2026-11-01");
    let dir = notes::directory(root.path()).unwrap();
    {
        let _lock = notes::lock(&dir).unwrap();
        let mut w = notes::load(&dir).unwrap();
        w.task_workspaces[0].status = "doing".into();
        notes::persist(&dir, &w).unwrap();
    }
    request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    assert_eq!(*transitions.lock().unwrap(), 1);
    assert_eq!(remote.lock().unwrap()["status"]["key"], "inProgress");
}
#[test]
fn imported_revision_receipt_preserves_later_local_edit_after_cache_crash() {
    let root = tempfile::tempdir().unwrap();
    let c = config(root.path(), "google", false);
    let api = Api::new(c.clone(), &json!({"token":"fixture"})).unwrap();
    let remote = api
        .remote("scope-1", &google("one", "Remote", "v1"))
        .unwrap();
    let before = apply_remote(root.path(), &c, &remote, "stable-local", None).unwrap();
    edit(root.path(), "stable-local", "Later local edit");
    let replay = apply_remote(root.path(), &c, &remote, "stable-local", None).unwrap();
    assert_eq!(replay, before);
    assert_eq!(
        notes::list(root.path()).unwrap().notes[0].title,
        "Later local edit"
    );
}

#[test]
fn state_read_does_not_wait_for_network_session_lock() {
    let root = tempfile::tempdir().unwrap();
    config(root.path(), "google", false);
    let directory = notes::directory(root.path()).unwrap();
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(directory.join(".tracker-sync.lock"))
        .unwrap();
    lock.lock().unwrap();
    let path = root.path().to_path_buf();
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = thread::spawn(move || {
        tx.send(request(&path, "tracker-state", &json!({})))
            .unwrap();
    });
    let result = rx.recv_timeout(Duration::from_secs(2));
    drop(lock);
    reader.join().unwrap();
    assert!(result.is_ok(), "tracker-state waited for network lock");
    assert!(result.unwrap().is_ok());
}
#[test]
fn trashed_local_task_with_queued_update_creates_visible_conflict() {
    let root = tempfile::tempdir().unwrap();
    let c = config(root.path(), "google", true);
    let remote = google("one", "Remote", "v1");
    let value = remote.clone();
    let f = Fixture::new(move |r| {
        assert_eq!(r.method, "GET");
        ok(json!({"items":[value.clone()]}))
    });
    request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    let db = database(root.path()).unwrap();
    let mut j = load(&db).unwrap();
    let binding = j.bindings[0].clone();
    j.pending.push(Pending {
        id: id(),
        connection: c.id.clone(),
        local_id: binding.local_id.clone(),
        scope: binding.scope.clone(),
        remote_id: Some(binding.remote_id.clone()),
        desired: binding.local.clone(),
        base: Some(binding.remote.clone()),
        sent: true,
        attempts: 1,
    });
    save(&db, &j).unwrap();
    let note = notes::list(root.path()).unwrap().notes[0].clone();
    crate::notes::dispatch(
        root.path(),
        &json!({"command":"note-trash","id":note.id,"revision":note.revision}),
    )
    .unwrap();
    let state = request(root.path(), "tracker-sync", &sync_args(&c, &f)).unwrap();
    assert_eq!(state["conflicts"].as_array().unwrap().len(), 1);
    let conflict = &state["conflicts"][0];
    request(root.path(),"tracker-resolve",&json!({"connectionID":c.id,"conflictID":conflict["id"],"fingerprint":conflict["fingerprint"],"resolution":"unlink"})).unwrap();
    assert!(load(&db).unwrap().pending.is_empty());
}
