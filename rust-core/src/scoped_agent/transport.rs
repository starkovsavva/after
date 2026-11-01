//! Private descriptor-bound control-channel experiment.
//!
//! The native side is expected to create the fixed grant only after the user
//! has selected and approved its sources, then hand one end of a socketpair to
//! one specific child. The secret capability never travels over the socket or
//! appears in command-line arguments. Search/read in this private experiment
//! are serialized with explicit grant revoke and workspace note changes
//! through the final socket write. Older apps can still change settings.json
//! without that gate, so it is not a complete publication fence. There is no
//! app/FFI/CLI/MCP entry point.
use super::*;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::thread::{self, JoinHandle};
use std::time::Instant;

const MAX_FRAME: usize = 4096;
const MAX_REQUESTS: usize = 256;

#[derive(Deserialize)]
#[serde(tag="type", deny_unknown_fields, rename_all="camelCase")]
enum ControlRequest {
    Status,
    Close,
    Search { query: String, limit: Option<usize> },
    Read {
        #[serde(rename="receiptID")] receipt_id: String,
        #[serde(rename="sourceID")] source_id: String,
        fingerprint: String,
    },
}

/// This endpoint is tied to one server-created session. Cloning the OS
/// descriptor delegates exactly that connection; it never creates a new grant.
struct ApprovedConnection {
    stream: UnixStream,
    worker: JoinHandle<()>,
}

/// Native-only approval boundary; neither the grant nor the root is accepted
/// from the model or any untrusted socket message. A missing/revoked/expired
/// grant never yields a working descriptor.
fn approve(root: &Path, grant: &str) -> Result<ApprovedConnection> {
    let (server, stream)=UnixStream::pair()?;
    server.set_read_timeout(Some(Duration::from_secs(30)))?;
    server.set_write_timeout(Some(Duration::from_secs(2)))?;
    let session=begin(root,grant)?;
    let run=session.run.clone();
    let capability_hash=digest(&session.capability);
    let root=root.to_path_buf();
    let worker=match thread::Builder::new().name("after-scoped-control".into()).spawn({
        let root=root.clone();
        move || {
            let _=serve(&root,server,&session);
            let _=end_run(&root,&session.run,&digest(&session.capability));
        }
    }) {
        Ok(worker)=>worker,
        Err(error)=>{
            let _=end_run(&root,&run,&capability_hash);
            return Err(error.into());
        }
    };
    Ok(ApprovedConnection{stream,worker})
}

fn end_run(root:&Path,run:&str,capability_hash:&str)->Result<()> {
    let db=open(root)?;
    db.execute("DELETE FROM runs WHERE id=?1 AND capability_hash=?2",params![run,capability_hash])?;
    Ok(())
}

fn respond(stream:&mut UnixStream,status:&str)->Result<()> {
    // All statuses are literals. Never reflect untrusted input, errors,
    // capabilities, paths, source identifiers or task metadata into output.
    ensure!(["ok","closed","invalid","unavailable"].contains(&status),"Некорректный статус");
    let bytes=format!("{{\"status\":\"{status}\"}}\n");
    stream.write_all(bytes.as_bytes())?;
    Ok(())
}

fn respond_content(stream:&mut UnixStream,value:Value)->Result<()> {
    let mut bytes=serde_json::to_vec(&json!({"status":"ok","value":value}))?;
    ensure!(bytes.len() <= MAX_RESPONSE+512,"Результат слишком большой");
    bytes.push(b'\n');
    // A socket write timeout limits each syscall, not the whole response. A
    // slow peer could otherwise keep both publication locks indefinitely by
    // draining a small amount before each timeout. Use one absolute deadline.
    let deadline=Instant::now()+Duration::from_millis(100);
    let mut remaining=bytes.as_slice();
    while !remaining.is_empty() {
        let timeout=deadline.checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero())
            .context("Превышено время отправки")?;
        stream.set_write_timeout(Some(timeout))?;
        match stream.write(remaining) {
            Ok(0)=>anyhow::bail!("Соединение закрыто"),
            Ok(count)=>remaining=&remaining[count..],
            Err(error) if error.kind()==std::io::ErrorKind::Interrupted => continue,
            Err(error)=>return Err(error.into()),
        }
    }
    Ok(())
}

/// Called while the shared publication gate is held. The legacy workspace
/// writer also takes this notes lock. A revision fence covers changes while
/// authorization is running; the lock then excludes note/folder edits through
/// the socket write. Global settings.json is a separate file which an old
/// binary can still replace concurrently, so this is not an external API gate.
fn publish_checked<F:FnMut(),G:FnMut()>(root:&Path,stream:&mut UnixStream,session:&Session,
        value:Value,before_final:&mut F,after_fence:&mut G)->Result<bool> {
    before_final();
    let revision=crate::workspace_repository::snapshot(root)?.revision;
    if authorize(root,session).is_err() {respond(stream,"unavailable")?; return Ok(false);}
    let directory=crate::notes::directory(root)?;
    let _notes_lock=crate::notes::lock(&directory)?;
    let current=crate::workspace_repository::load_locked(&directory)?;
    if current.revision!=revision {respond(stream,"unavailable")?; return Ok(false);}
    after_fence();
    // Limit how long a slow peer can delay an ordinary note edit. A partial
    // response closes the connection and is never retried as a fresh grant.
    respond_content(stream,value)?;
    Ok(true)
}

fn serve(root:&PathBuf,stream:UnixStream,session:&Session)->Result<()> {
    serve_with(root,stream,session,||{},||{})
}
fn serve_with<F:FnMut(),G:FnMut()>(root:&PathBuf,mut stream:UnixStream,session:&Session,
        mut before_final:F,mut after_fence:G)->Result<()> {
    let mut reader=BufReader::new(stream.try_clone()?);
    for _ in 0..MAX_REQUESTS {
        let mut frame=Vec::new();
        let count={
            let mut limited=std::io::Read::by_ref(&mut reader).take((MAX_FRAME+1) as u64);
            limited.read_until(b'\n',&mut frame)?
        };
        if count==0 {break;}
        if count>MAX_FRAME || frame.last()!=Some(&b'\n') {
            let _=respond(&mut stream,"invalid");
            break;
        }
        let request:ControlRequest=match serde_json::from_slice(&frame) {
            Ok(value)=>value,
            Err(_)=>{let _=respond(&mut stream,"invalid"); break;}
        };
        match request {
            ControlRequest::Status | ControlRequest::Close => {
                if authorize(root,session).is_err() {
                    let _=respond(&mut stream,"unavailable"); break;
                }
                if matches!(request,ControlRequest::Close) {respond(&mut stream,"closed")?; break;}
                respond(&mut stream,"ok")?;
            }
            ControlRequest::Search {query,limit} => {
                let prepared=search(root,session,&query,limit.unwrap_or(10));
                match prepared {
                    Ok(value) => {
                        // Heavy retrieval is deliberately outside the gate;
                        // revoke need only wait for the final validation/write.
                        let _publication=publication_gate(root,false)?;
                        if !publish_checked(root,&mut stream,session,value,&mut before_final,&mut after_fence)? {break;}
                    }
                    _ => { let _=respond(&mut stream,"unavailable"); break; }
                }
            }
            ControlRequest::Read {receipt_id,source_id,fingerprint} => {
                let prepared=read(root,session,&receipt_id,&source_id,&fingerprint);
                match prepared {
                    Ok(value) => {
                        let _publication=publication_gate(root,false)?;
                        if !publish_checked(root,&mut stream,session,value,&mut before_final,&mut after_fence)? {break;}
                    }
                    _ => { let _=respond(&mut stream,"unavailable"); break; }
                }
            }
        }
    }
    let _=stream.shutdown(Shutdown::Both);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::process::CommandExt;

    fn id()->String {Uuid::new_v4().to_string()}
    fn setup(root:&Path)->String {
        crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"tasks":true,"knowledgeBase":true}})).unwrap();
        let note:crate::notes::CapturedNote=serde_json::from_value(json!({"id":"scope-private","kind":"note","title":"SECRET TITLE","text":"SECRET CONTENT","revision":0,"createdAt":1.0,"updatedAt":1.0})).unwrap();
        let note=crate::notes::save_note(root,note).unwrap();
        let call=|command:&str,mut input:Value| {input["command"]=json!(command); crate::task_workspace::dispatch(root,&input).unwrap()};
        call("task-agent-settings",json!({"enabled":true,"expectedRevision":0,"operationID":id()}));
        let task=call("task-create",json!({"title":"Private task","operationID":id()}));
        create(root,task["id"].as_str().unwrap(),&[(note.id,note.revision)],now()+600).unwrap()
    }
    fn request(stream:&mut UnixStream,line:&str)->String {
        stream.write_all(line.as_bytes()).unwrap();
        let mut line=String::new();
        BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
        line
    }

    #[test]
    fn stalled_peer_cannot_hold_the_publication_locks_indefinitely() {
        use std::os::fd::AsRawFd;
        let (mut server, mut client)=UnixStream::pair().unwrap();
        // Make the response larger than the socket buffer; the client does
        // not read until after the writer's deadline has elapsed.
        let size:libc::c_int=1024;
        let rc=unsafe {libc::setsockopt(server.as_raw_fd(),libc::SOL_SOCKET,libc::SO_SNDBUF,
            &size as *const _ as *const libc::c_void,std::mem::size_of_val(&size) as libc::socklen_t)};
        assert_eq!(rc,0);
        let started=Instant::now();
        let result=respond_content(&mut server,json!({"text":"x".repeat(MAX_RESPONSE-256)}));
        assert!(result.is_err(),"a stalled client unexpectedly received the entire response");
        assert!(started.elapsed()<Duration::from_secs(2),"socket send exceeded its bounded deadline");
        server.shutdown(Shutdown::Both).unwrap();
        let mut partial=Vec::new();
        client.read_to_end(&mut partial).unwrap();
        assert!(!partial.ends_with(b"\n"),"incomplete frames must not look like complete responses");
    }

    #[test]
    fn scoped_search_and_read_are_bound_to_the_approved_connection() {
        let root=tempfile::tempdir().unwrap();
        let grant=setup(root.path());
        let mut one=approve(root.path(),&grant).unwrap();
        let mut other=approve(root.path(),&grant).unwrap();
        let response:Value=serde_json::from_str(&request(&mut one.stream,
            "{\"type\":\"search\",\"query\":\"SECRET\",\"limit\":10}\n")).unwrap();
        assert_eq!(response["status"],"ok");
        assert_eq!(response["value"]["results"].as_array().unwrap().len(),1);
        let receipt=response["value"]["receiptID"].as_str().unwrap();
        let hit=&response["value"]["results"][0];
        let source=hit["sourceID"].as_str().unwrap();
        let fingerprint=hit["fingerprint"].as_str().unwrap();
        assert!(!response.to_string().contains("scope-private"));
        let line=json!({"type":"read","receiptID":receipt,"sourceID":source,"fingerprint":fingerprint}).to_string()+"\n";
        let read:Value=serde_json::from_str(&request(&mut one.stream,&line)).unwrap();
        assert_eq!(read["value"]["text"],"SECRET CONTENT");
        // Receipts are per run, even for another approved connection to the
        // same grant. A model cannot present a receipt from another session.
        let rejected=request(&mut other.stream,&line);
        assert_eq!(rejected,"{\"status\":\"unavailable\"}\n");
        assert!(!rejected.contains("SECRET"));
        other.worker.join().unwrap();
        revoke(root.path(),&grant).unwrap();
        assert_eq!(request(&mut one.stream,&line),"{\"status\":\"unavailable\"}\n");
        one.worker.join().unwrap();
    }

    #[test]
    fn revoke_waits_for_content_write_and_no_later_publication_can_start() {
        use std::sync::mpsc;
        let root=tempfile::tempdir().unwrap();
        let grant=setup(root.path());
        let session=begin(root.path(),&grant).unwrap();
        let (server,mut client)=UnixStream::pair().unwrap();
        server.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        server.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
        client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let (ready_tx,ready_rx)=mpsc::channel();
        let (resume_tx,resume_rx)=mpsc::channel();
        let worker_root=root.path().to_path_buf();
        let worker=thread::spawn(move || {
            serve_with(&worker_root,server,&session,||{
                ready_tx.send(()).unwrap();
                resume_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            },||{}).unwrap();
        });
        client.write_all(b"{\"type\":\"search\",\"query\":\"SECRET\"}\n").unwrap();
        ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        let (done_tx,done_rx)=mpsc::channel();
        let revoke_root=root.path().to_path_buf();
        let worker_grant=grant.clone();
        let revoker=thread::spawn(move || {
            let result=revoke(&revoke_root,&worker_grant);
            done_tx.send(result.is_ok()).unwrap();
        });
        // The broker has already prepared a result but has not written it.
        // Revoke must not return until that write finishes or fails.
        assert!(matches!(done_rx.recv_timeout(Duration::from_millis(150)),Err(mpsc::RecvTimeoutError::Timeout)));
        resume_tx.send(()).unwrap();
        let mut response=String::new();
        BufReader::new(client.try_clone().unwrap()).read_line(&mut response).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&response).unwrap()["status"],"ok");
        assert!(done_rx.recv_timeout(Duration::from_secs(5)).unwrap());
        revoker.join().unwrap();
        assert_eq!(request(&mut client,"{\"type\":\"search\",\"query\":\"SECRET\"}\n"),"{\"status\":\"unavailable\"}\n");
        worker.join().unwrap();
    }

    #[test]
    fn publication_revoke_child() {
        let Some(root)=std::env::var_os("AFTER_PUBLICATION_TEST_ROOT") else {return};
        let grant=std::env::var("AFTER_PUBLICATION_TEST_GRANT").unwrap();
        println!("AFTER_REVOKE_STARTED");
        std::io::stdout().flush().unwrap();
        revoke(Path::new(&root),&grant).unwrap();
        println!("AFTER_REVOKE_FINISHED");
    }

    #[test]
    fn publication_old_settings_child() {
        let Some(root)=std::env::var_os("AFTER_PUBLICATION_SETTINGS_ROOT") else {return};
        // The released binary writes settings through the same atomic JSON
        // replacement, without taking the new publication gate.
        crate::storage::atomic_json(&Path::new(&root).join("settings.json"),
            &json!({"features":{"tasks":true,"knowledgeBase":false}})).unwrap();
    }

    #[test]
    fn legacy_style_settings_change_before_final_check_never_sends_content() {
        use std::process::Command;
        let root=tempfile::tempdir().unwrap();
        let grant=setup(root.path());
        let session=begin(root.path(),&grant).unwrap();
        let (server,mut client)=UnixStream::pair().unwrap();
        server.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let worker_root=root.path().to_path_buf();
        let writer_root=worker_root.clone();
        let worker=thread::spawn(move || serve_with(&worker_root,server,&session,|| {
            let child=Command::new(std::env::current_exe().unwrap())
                .args(["--exact","scoped_agent::transport::tests::publication_old_settings_child","--nocapture"])
                .env_clear().env("AFTER_PUBLICATION_SETTINGS_ROOT",&writer_root)
                .output().unwrap();
            assert!(child.status.success());
        },||{}).unwrap());
        let result=request(&mut client,"{\"type\":\"search\",\"query\":\"SECRET\"}\n");
        assert_eq!(result,"{\"status\":\"unavailable\"}\n");
        assert!(!result.contains("SECRET"));
        worker.join().unwrap();
        // A modification after this last check but before the socket write is
        // still possible for a non-cooperating old process. Therefore this
        // private transport remains disconnected from UI and MCP.
    }

    #[test]
    fn legacy_style_settings_writer_does_not_obey_the_new_or_workspace_gate() {
        use std::process::Command;
        let root=tempfile::tempdir().unwrap();
        let _grant=setup(root.path());
        let _publication=publication_gate(root.path(),false).unwrap();
        let notes=crate::notes::directory(root.path()).unwrap();
        let _notes=crate::notes::lock(&notes).unwrap();
        let child=Command::new(std::env::current_exe().unwrap())
            .args(["--exact","scoped_agent::transport::tests::publication_old_settings_child","--nocapture"])
            .env_clear().env("AFTER_PUBLICATION_SETTINGS_ROOT",root.path())
            .output().unwrap();
        assert!(child.status.success());
        let settings=crate::storage::regular_json(&root.path().join("settings.json")).unwrap();
        assert_eq!(settings["features"]["knowledgeBase"],false);
        // This test documents the remaining reason not to expose scoped data:
        // the old settings writer can change policy even while both gates are
        // held. A new grant's explicit revoke and workspace edits are fenced.
    }

    #[test]
    fn legacy_revoke_after_authorization_still_leaks_on_the_closed_prototype() {
        use std::process::Command;
        let root=tempfile::tempdir().unwrap();
        let grant=setup(root.path());
        let session=begin(root.path(),&grant).unwrap();
        let (server,mut client)=UnixStream::pair().unwrap();
        server.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let worker_root=root.path().to_path_buf();
        let writer_root=worker_root.clone();
        let worker=thread::spawn(move || serve_with(&worker_root,server,&session,||{},|| {
            // Same atomic settings replacement used by the released writer,
            // precisely between the last authorization and socket write.
            let child=Command::new(std::env::current_exe().unwrap())
                .args(["--exact","scoped_agent::transport::tests::publication_old_settings_child","--nocapture"])
                .env_clear().env("AFTER_PUBLICATION_SETTINGS_ROOT",&writer_root)
                .output().unwrap();
            assert!(child.status.success());
        }).unwrap());
        let response=request(&mut client,"{\"type\":\"search\",\"query\":\"SECRET\"}\n");
        // This deliberately captures the existing defect, not a successful
        // security check. Production exposure remains prohibited until the
        // legacy writer is isolated and this becomes a no-disclosure test.
        assert!(response.contains("SECRET"));
        assert_eq!(serde_json::from_str::<Value>(&response).unwrap()["status"],"ok");
        drop(client);
        worker.join().unwrap();
    }

    #[test]
    fn publication_edit_child() {
        let Some(root)=std::env::var_os("AFTER_PUBLICATION_EDIT_ROOT") else {return};
        println!("AFTER_EDIT_STARTED"); std::io::stdout().flush().unwrap();
        let root=Path::new(&root);
        let mut note=crate::notes::load_note_snapshot(root,"scope-private").unwrap();
        note.text="Changed after publication".into();
        crate::notes::save_note(root,note).unwrap();
        println!("AFTER_EDIT_FINISHED");
    }

    #[test]
    fn another_process_cannot_change_a_note_during_the_socket_write() {
        use std::process::{Command,Stdio};
        use std::sync::mpsc;
        let root=tempfile::tempdir().unwrap();
        let grant=setup(root.path());
        let session=begin(root.path(),&grant).unwrap();
        let (server,mut client)=UnixStream::pair().unwrap();
        server.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let (ready_tx,ready_rx)=mpsc::channel(); let (resume_tx,resume_rx)=mpsc::channel();
        let worker_root=root.path().to_path_buf();
        let worker=thread::spawn(move || serve_with(&worker_root,server,&session,||{},|| {
            ready_tx.send(()).unwrap(); resume_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        }).unwrap());
        client.write_all(b"{\"type\":\"search\",\"query\":\"SECRET\"}\n").unwrap();
        ready_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        let mut child=Command::new(std::env::current_exe().unwrap())
            .args(["--exact","scoped_agent::transport::tests::publication_edit_child","--nocapture"])
            .env_clear().env("AFTER_PUBLICATION_EDIT_ROOT",root.path())
            .stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
        let output=child.stdout.take().unwrap(); let (started_tx,started_rx)=mpsc::channel();
        let reader=thread::spawn(move || {
            let mut all=String::new();
            for line in BufReader::new(output).lines() {
                let line=line.unwrap();
                if line.contains("AFTER_EDIT_STARTED") {let _=started_tx.send(());}
                all.push_str(&line); all.push('\n');
            }
            all
        });
        started_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        thread::sleep(Duration::from_millis(150));
        assert!(child.try_wait().unwrap().is_none(),"note edit returned before publication");
        resume_tx.send(()).unwrap();
        let mut published=String::new(); BufReader::new(client.try_clone().unwrap()).read_line(&mut published).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&published).unwrap()["status"],"ok");
        assert!(child.wait().unwrap().success());
        assert!(reader.join().unwrap().contains("AFTER_EDIT_FINISHED"));
        assert_eq!(request(&mut client,"{\"type\":\"search\",\"query\":\"SECRET\"}\n"),"{\"status\":\"unavailable\"}\n");
        worker.join().unwrap();
    }

    #[test]
    fn revoke_from_another_process_waits_for_the_socket_write() {
        use std::process::{Command,Stdio};
        use std::sync::mpsc;
        let root=tempfile::tempdir().unwrap();
        let grant=setup(root.path());
        let session=begin(root.path(),&grant).unwrap();
        let (server,mut client)=UnixStream::pair().unwrap();
        server.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        server.set_write_timeout(Some(Duration::from_secs(10))).unwrap();
        client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let (ready_tx,ready_rx)=mpsc::channel();
        let (resume_tx,resume_rx)=mpsc::channel();
        let root_for_worker=root.path().to_path_buf();
        let worker=thread::spawn(move || serve_with(&root_for_worker,server,&session,|| {
            ready_tx.send(()).unwrap(); resume_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        },||{}).unwrap());
        client.write_all(b"{\"type\":\"search\",\"query\":\"SECRET\"}\n").unwrap();
        ready_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        let mut child=Command::new(std::env::current_exe().unwrap())
            .args(["--exact","scoped_agent::transport::tests::publication_revoke_child","--nocapture"])
            .env_clear().env("AFTER_PUBLICATION_TEST_ROOT",root.path())
            .env("AFTER_PUBLICATION_TEST_GRANT",grant).stdout(Stdio::piped()).stderr(Stdio::piped())
            .spawn().unwrap();
        let output=child.stdout.take().unwrap();
        let (started_tx,started_rx)=mpsc::channel();
        let reader=thread::spawn(move || {
            let mut all=String::new();
            for line in BufReader::new(output).lines() {
                let line=line.unwrap();
                if line.contains("AFTER_REVOKE_STARTED") {let _=started_tx.send(());}
                all.push_str(&line); all.push('\n');
            }
            all
        });
        started_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        thread::sleep(Duration::from_millis(150));
        assert!(child.try_wait().unwrap().is_none(),"cross-process revoke returned before publication");
        resume_tx.send(()).unwrap();
        let mut published=String::new();
        BufReader::new(client.try_clone().unwrap()).read_line(&mut published).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&published).unwrap()["status"],"ok");
        assert!(child.wait().unwrap().success());
        assert!(reader.join().unwrap().contains("AFTER_REVOKE_FINISHED"));
        assert_eq!(request(&mut client,"{\"type\":\"search\",\"query\":\"SECRET\"}\n"),"{\"status\":\"unavailable\"}\n");
        worker.join().unwrap();
    }

    #[test]
    fn approved_connections_are_bound_and_revocation_is_not_transferable() {
        let root=tempfile::tempdir().unwrap();
        let grant=setup(root.path());
        assert!(approve(root.path(),&id()).is_err());
        let mut one=approve(root.path(),&grant).unwrap();
        let mut two=approve(root.path(),&grant).unwrap();
        assert_eq!(request(&mut one.stream,"{\"type\":\"status\"}\n"),"{\"status\":\"ok\"}\n");
        let invalid=request(&mut two.stream,"{\"type\":\"search\",\"root\":\"/tmp\",\"query\":\"SECRET\"}\n");
        assert_eq!(invalid,"{\"status\":\"invalid\"}\n");
        assert!(!invalid.contains("SECRET"));
        two.worker.join().unwrap();
        revoke(root.path(),&grant).unwrap();
        assert_eq!(request(&mut one.stream,"{\"type\":\"status\"}\n"),"{\"status\":\"unavailable\"}\n");
        one.worker.join().unwrap();
        assert!(approve(root.path(),&grant).is_err());
    }

    #[test]
    fn oversized_or_injected_control_frame_is_not_reflected() {
        let root=tempfile::tempdir().unwrap();
        let grant=setup(root.path());
        let mut connection=approve(root.path(),&grant).unwrap();
        let payload=format!("{{\"type\":\"status\",\"query\":\"{}\"}}\n","S".repeat(MAX_FRAME+10));
        let response=request(&mut connection.stream,&payload);
        assert_eq!(response,"{\"status\":\"invalid\"}\n");
        connection.worker.join().unwrap();
    }

    #[test]
    fn revoking_one_grant_does_not_invalidate_another_approved_connection() {
        let root=tempfile::tempdir().unwrap();
        let first=setup(root.path());
        let note:crate::notes::CapturedNote=serde_json::from_value(json!({"id":"other","kind":"note","title":"Другое","text":"Отдельная область","revision":0,"createdAt":1.0,"updatedAt":1.0})).unwrap();
        let note=crate::notes::save_note(root.path(),note).unwrap();
        let task=crate::task_workspace::dispatch(root.path(),&json!({"command":"task-create","title":"Вторая задача","operationID":id()})).unwrap();
        let second=create(root.path(),task["id"].as_str().unwrap(),&[(note.id,note.revision)],now()+600).unwrap();
        let mut a=approve(root.path(),&first).unwrap();
        let mut b=approve(root.path(),&second).unwrap();
        revoke(root.path(),&first).unwrap();
        assert_eq!(request(&mut a.stream,"{\"type\":\"status\"}\n"),"{\"status\":\"unavailable\"}\n");
        assert_eq!(request(&mut b.stream,"{\"type\":\"status\"}\n"),"{\"status\":\"ok\"}\n");
        assert_eq!(request(&mut b.stream,"{\"type\":\"close\"}\n"),"{\"status\":\"closed\"}\n");
        a.worker.join().unwrap(); b.worker.join().unwrap();
        let db=open(root.path()).unwrap();
        assert_eq!(db.query_row("SELECT COUNT(*) FROM runs",[],|row|row.get::<_,i64>(0)).unwrap(),0);
    }

    /// Invoked only as a child by the following test. The numeric descriptor
    /// is not a token and is passed only in the disposable test process.
    #[test]
    fn inherited_descriptor_child() {
        let Some(raw)=std::env::var_os("AFTER_SCOPED_TEST_FD") else {return};
        let fd=raw.to_str().unwrap().parse().unwrap();
        let mut stream=unsafe {UnixStream::from_raw_fd(fd)};
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        assert_eq!(request(&mut stream,"{\"type\":\"status\"}\n"),"{\"status\":\"ok\"}\n");
        assert_eq!(request(&mut stream,"{\"type\":\"close\"}\n"),"{\"status\":\"closed\"}\n");
    }

    #[test]
    fn descriptor_crosses_a_real_process_boundary_without_capability_in_output() {
        let root=tempfile::tempdir().unwrap();
        let grant=setup(root.path());
        let connection=approve(root.path(),&grant).unwrap();
        let fd=connection.stream.as_raw_fd();
        let flags=unsafe {libc::fcntl(fd,libc::F_GETFD)};
        assert!(flags>=0);
        let mut command=std::process::Command::new(std::env::current_exe().unwrap());
        command.args(["--exact","scoped_agent::transport::tests::inherited_descriptor_child","--nocapture"])
            .env_clear().env("AFTER_SCOPED_TEST_FD",fd.to_string());
        // Clear close-on-exec only in the forked child. Temporarily changing
        // the parent's flag could leak the fd to unrelated parallel spawns.
        unsafe { command.pre_exec(move || {
            if libc::fcntl(fd,libc::F_SETFD,flags & !libc::FD_CLOEXEC)==-1 {
                Err(std::io::Error::last_os_error())
            } else {Ok(())}
        }); }
        let child=command.output();
        let child=child.unwrap();
        assert!(child.status.success(),"child exited unsuccessfully");
        let output=String::from_utf8_lossy(&child.stdout);
        assert!(!output.contains("SECRET CONTENT"));
        assert!(!output.contains(&grant));
        connection.worker.join().unwrap();
    }
}
