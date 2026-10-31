//! Bounded transport for the pinned app-owned embedding process.
//!
//! Used by managed_embeddings for all semantic consumers. The caller owns
//! the actual child for its entire lifetime and trusts that verified runtime
//! not to pass accepted sockets elsewhere. Arbitrary hostile processes with
//! the same user's file/memory access are outside the app trust boundary.
//! This module deliberately fails closed; it never reconnects or follows a
//! redirect after checking the peer of the connected descriptor.

use anyhow::{bail, ensure, Context, Result};
use serde_json::Value;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::Child;
use std::time::{Duration, Instant};

const MAX_REQUEST: usize = 64 * 1024;
const MAX_HEADERS: usize = 16 * 1024;
const MAX_RESPONSE: usize = 2 * 1024 * 1024;
const MAX_TIMEOUT: Duration = Duration::from_secs(120);

fn active(child: &mut Child, cancelled: &impl Fn() -> bool, deadline: Instant) -> Result<()> {
    ensure!(!cancelled(), "embedding operation cancelled");
    ensure!(Instant::now() < deadline, "embedding operation timed out");
    ensure!(child.try_wait()?.is_none(), "embedding process exited");
    Ok(())
}

fn wait_fd(
    stream: &UnixStream,
    events: i16,
    child: &mut Child,
    cancelled: &impl Fn() -> bool,
    deadline: Instant,
) -> Result<()> {
    loop {
        active(child, cancelled, deadline)?;
        let remaining = deadline.saturating_duration_since(Instant::now());
        let timeout = remaining.min(Duration::from_millis(50)).as_millis().max(1) as i32;
        let mut entry = libc::pollfd {
            fd: stream.as_raw_fd(),
            events,
            revents: 0,
        };
        let result = unsafe { libc::poll(&mut entry, 1, timeout) };
        if result < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error.into());
        }
        if result == 0 {
            continue;
        }
        ensure!(
            entry.revents & libc::POLLNVAL == 0,
            "invalid embedding socket"
        );
        return Ok(());
    }
}

fn connect(
    path: &Path,
    child: &mut Child,
    cancelled: &impl Fn() -> bool,
    deadline: Instant,
) -> Result<UnixStream> {
    active(child, cancelled, deadline)?;
    let raw_path = path.as_os_str().as_bytes();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    ensure!(
        path.is_absolute() && !raw_path.contains(&0) && raw_path.len() < address.sun_path.len(),
        "invalid embedding socket path"
    );
    address.sun_family = libc::AF_UNIX as _;
    address.sun_len =
        (std::mem::offset_of!(libc::sockaddr_un, sun_path) + raw_path.len() + 1) as u8;
    for (slot, byte) in address.sun_path.iter_mut().zip(raw_path) {
        *slot = *byte as _;
    }
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let stream = unsafe { UnixStream::from_raw_fd(fd) };
    // Darwin does not expose atomic SOCK_CLOEXEC for socket(). This prevents
    // inheritance after fcntl succeeds but does NOT close the socket/fcntl race
    // against concurrent process creation. Keep this component unexposed until
    // it runs in a dedicated helper that cannot concurrently spawn children or
    // an equally strong process-wide synchronization mechanism is proven.
    ensure!(
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } == 0,
        "cannot mark embedding socket close-on-exec"
    );
    stream.set_nonblocking(true)?;
    let no_sigpipe: libc::c_int = 1;
    ensure!(
        unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_NOSIGPIPE,
                (&no_sigpipe as *const libc::c_int).cast(),
                std::mem::size_of_val(&no_sigpipe) as _,
            )
        } == 0,
        "cannot configure embedding socket"
    );
    let result = unsafe {
        libc::connect(
            fd,
            (&address as *const libc::sockaddr_un).cast(),
            address.sun_len as _,
        )
    };
    if result != 0 {
        let error = std::io::Error::last_os_error();
        if !matches!(error.raw_os_error(), Some(libc::EINPROGRESS | libc::EAGAIN)) {
            return Err(error.into());
        }
        wait_fd(&stream, libc::POLLOUT, child, cancelled, deadline)?;
        let mut socket_error: libc::c_int = 0;
        let mut len = std::mem::size_of_val(&socket_error) as libc::socklen_t;
        ensure!(
            unsafe {
                libc::getsockopt(
                    fd,
                    libc::SOL_SOCKET,
                    libc::SO_ERROR,
                    (&mut socket_error as *mut libc::c_int).cast(),
                    &mut len,
                )
            } == 0
                && socket_error == 0,
            "embedding socket connection failed"
        );
    }
    // pid is returned by the kernel for this already-connected descriptor,
    // never read from the socket file, server's JSON, or process name.
    let mut pid: libc::pid_t = 0;
    let mut pid_len = std::mem::size_of_val(&pid) as libc::socklen_t;
    ensure!(
        unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_LOCAL,
                libc::LOCAL_PEERPID,
                (&mut pid as *mut libc::pid_t).cast(),
                &mut pid_len,
            )
        } == 0
            && pid_len as usize == std::mem::size_of_val(&pid)
            && pid > 0
            && pid as u32 == child.id(),
        "embedding socket peer is not the managed process"
    );
    let (mut uid, mut gid): (libc::uid_t, libc::gid_t) = (0, 0);
    ensure!(
        unsafe { libc::getpeereid(fd, &mut uid, &mut gid) } == 0
            && uid == unsafe { libc::geteuid() },
        "embedding socket peer has unexpected credentials"
    );
    active(child, cancelled, deadline)?;
    Ok(stream)
}

fn send(
    stream: &mut UnixStream,
    mut bytes: &[u8],
    child: &mut Child,
    cancelled: &impl Fn() -> bool,
    deadline: Instant,
) -> Result<()> {
    while !bytes.is_empty() {
        active(child, cancelled, deadline)?;
        match stream.write(bytes) {
            Ok(0) => bail!("embedding socket closed while sending"),
            Ok(n) => bytes = &bytes[n..],
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                wait_fd(stream, libc::POLLOUT, child, cancelled, deadline)?
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn receive(
    stream: &mut UnixStream,
    out: &mut Vec<u8>,
    max: usize,
    child: &mut Child,
    cancelled: &impl Fn() -> bool,
    deadline: Instant,
) -> Result<usize> {
    active(child, cancelled, deadline)?;
    let mut buf = [0u8; 4096];
    let space = max.saturating_sub(out.len());
    ensure!(space > 0, "embedding response is too large");
    loop {
        active(child, cancelled, deadline)?;
        match stream.read(&mut buf[..space.min(4096)]) {
            Ok(n) => {
                out.extend_from_slice(&buf[..n]);
                return Ok(n);
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                wait_fd(stream, libc::POLLIN, child, cancelled, deadline)?
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.into()),
        }
    }
}

/// Experimental closed component. No request bytes are sent until this exact
/// connection is bound to the still-owned child. Caller must separately verify
/// executable/model provenance and coordinate model lifetime and recording.
#[allow(dead_code)]
pub(crate) fn embeddings(
    path: &Path,
    child: &mut Child,
    body: &Value,
    cancelled: impl Fn() -> bool,
    timeout: Duration,
) -> Result<Value> {
    ensure!(
        !timeout.is_zero() && timeout <= MAX_TIMEOUT,
        "invalid embedding timeout"
    );
    let deadline = Instant::now() + timeout;
    let payload = serde_json::to_vec(body)?;
    ensure!(
        payload.len() <= MAX_REQUEST,
        "embedding request is too large"
    );
    let mut stream = connect(path, child, &cancelled, deadline)?;
    let header = format!("POST /v1/embeddings HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", payload.len());
    send(&mut stream, header.as_bytes(), child, &cancelled, deadline)?;
    send(&mut stream, &payload, child, &cancelled, deadline)?;
    let mut bytes = Vec::new();
    let header_end = loop {
        if let Some(index) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            ensure!(index + 4 <= MAX_HEADERS, "embedding headers are too large");
            break index + 4;
        }
        ensure!(bytes.len() < MAX_HEADERS, "embedding headers are too large");
        ensure!(
            receive(
                &mut stream,
                &mut bytes,
                MAX_HEADERS + MAX_RESPONSE,
                child,
                &cancelled,
                deadline
            )? > 0,
            "embedding response is truncated"
        );
    };
    let headers = std::str::from_utf8(&bytes[..header_end]).context("invalid embedding headers")?;
    let mut lines = headers.split("\r\n");
    ensure!(
        lines.next() == Some("HTTP/1.1 200 OK"),
        "embedding server rejected request"
    );
    let mut content_length = None;
    for line in lines.filter(|line| !line.is_empty()) {
        let (name, value) = line.split_once(':').context("invalid embedding header")?;
        ensure!(
            name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-'),
            "invalid embedding header name"
        );
        if name.eq_ignore_ascii_case("transfer-encoding")
            || name.eq_ignore_ascii_case("content-encoding")
        {
            bail!("unsupported embedding response encoding");
        }
        if name.eq_ignore_ascii_case("content-length") {
            ensure!(
                content_length.is_none(),
                "duplicate embedding content length"
            );
            let len: usize = value
                .trim()
                .parse()
                .context("invalid embedding content length")?;
            ensure!(len <= MAX_RESPONSE, "embedding response is too large");
            content_length = Some(len);
        }
    }
    let length = content_length.context("missing embedding content length")?;
    ensure!(
        bytes.len() - header_end <= length,
        "embedding response exceeds content length"
    );
    while bytes.len() - header_end < length {
        ensure!(
            receive(
                &mut stream,
                &mut bytes,
                header_end + length,
                child,
                &cancelled,
                deadline
            )? > 0,
            "embedding response is truncated"
        );
    }
    active(child, &cancelled, deadline)?;
    serde_json::from_slice(&bytes[header_end..]).context("invalid embedding JSON")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::{BufRead, BufReader};
    use std::process::{Command, Stdio};
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    };
    use std::thread;

    const SERVER: &str = r#"
import os, socket, sys, time
path, marker, mode = sys.argv[1:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(8)
print('ready', flush=True)
c, _ = s.accept()
c.settimeout(2)
try:
    data = c.recv(65536)
    if data:
        with open(marker, 'wb') as f: f.write(b'received')
        while b'\r\n\r\n' not in data: data += c.recv(65536)
        head, body = data.split(b'\r\n\r\n', 1)
        size = int(next(line.split(b':', 1)[1] for line in head.split(b'\r\n') if line.lower().startswith(b'content-length:')))
        while len(body) < size: body += c.recv(65536)
        if mode == 'hang': time.sleep(10)
        elif mode == 'good': c.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{"ok":true}')
        elif mode == 'redirect': c.sendall(b'HTTP/1.1 302 Found\r\nContent-Length: 2\r\n\r\n{}')
        elif mode == 'duplicate': c.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}')
        elif mode == 'oversize': c.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 9999999\r\n\r\n')
        elif mode == 'chunked': c.sendall(b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n')
        elif mode == 'badjson': c.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx')
        elif mode == 'truncated': c.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n{}'); c.shutdown(socket.SHUT_WR)
        time.sleep(10)
finally:
    c.close()
"#;

    struct Fixture {
        _directory: tempfile::TempDir,
        child: Child,
        socket: std::path::PathBuf,
        marker: std::path::PathBuf,
    }
    impl Fixture {
        fn start(mode: &str) -> Self {
            Self::at(mode, None)
        }
        fn at(mode: &str, socket_override: Option<&Path>) -> Self {
            let directory = tempfile::Builder::new()
                .prefix("after-uds-")
                .tempdir_in("/private/tmp")
                .unwrap();
            let socket = socket_override
                .map(Path::to_path_buf)
                .unwrap_or_else(|| directory.path().join("server.sock"));
            let marker = directory.path().join("received");
            let mut child = Command::new("/usr/bin/python3")
                .args(["-u", "-c", SERVER])
                .arg(&socket)
                .arg(&marker)
                .arg(mode)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            let mut ready = String::new();
            BufReader::new(child.stdout.take().unwrap())
                .read_line(&mut ready)
                .unwrap();
            assert_eq!(ready, "ready\n");
            Self {
                _directory: directory,
                child,
                socket,
                marker,
            }
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    #[test]
    fn verified_child_serves_one_bounded_request() {
        let mut fixture = Fixture::start("good");
        let result = embeddings(
            &fixture.socket,
            &mut fixture.child,
            &json!({"input":["synthetic"]}),
            || false,
            Duration::from_secs(3),
        )
        .unwrap();
        assert_eq!(result, json!({"ok":true}));
        assert!(fixture.marker.exists());
    }

    #[test]
    fn connected_descriptor_is_marked_close_on_exec_and_not_inherited() {
        let mut fixture = Fixture::start("good");
        let stream = connect(
            &fixture.socket,
            &mut fixture.child,
            &|| false,
            Instant::now() + Duration::from_secs(3),
        )
        .unwrap();
        let fd = stream.as_raw_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        assert!(flags >= 0 && flags & libc::FD_CLOEXEC != 0);
        // A child can reuse the numeric descriptor during startup. Compare the
        // descriptor's identity rather than assuming EBADF means no leak.
        let mut metadata: libc::stat = unsafe { std::mem::zeroed() };
        assert_eq!(unsafe { libc::fstat(fd, &mut metadata) }, 0);
        let check = r#"import os, sys
fd, dev, ino = map(int, sys.argv[1:])
try:
    st = os.fstat(fd)
except OSError:
    sys.exit(0)
sys.exit(1 if (st.st_dev, st.st_ino) == (dev, ino) else 0)
"#;
        let status = Command::new("/usr/bin/python3")
            .args([
                "-c",
                check,
                &fd.to_string(),
                &metadata.st_dev.to_string(),
                &metadata.st_ino.to_string(),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "connected descriptor survived exec");
        assert!(!fixture.marker.exists());
    }

    #[test]
    fn wrong_live_child_never_receives_payload() {
        let attacker = Fixture::start("good");
        let mut expected = Command::new("/bin/sleep").arg("10").spawn().unwrap();
        let result = embeddings(
            &attacker.socket,
            &mut expected,
            &json!({"input":["secret fixture"]}),
            || false,
            Duration::from_secs(3),
        );
        let _ = expected.kill();
        let _ = expected.wait();
        assert!(result.unwrap_err().to_string().contains("peer"));
        thread::sleep(Duration::from_millis(50));
        assert!(!attacker.marker.exists());
    }

    #[test]
    fn replacement_at_same_unix_path_receives_no_payload() {
        let mut original = Fixture::start("good");
        std::fs::remove_file(&original.socket).unwrap();
        let replacement = Fixture::at("good", Some(&original.socket));
        let result = embeddings(
            &original.socket,
            &mut original.child,
            &json!({"input":["secret fixture"]}),
            || false,
            Duration::from_secs(3),
        );
        assert!(result.unwrap_err().to_string().contains("peer"));
        thread::sleep(Duration::from_millis(50));
        assert!(!original.marker.exists());
        assert!(!replacement.marker.exists());
    }

    #[test]
    fn reject_bad_http_responses_and_oversized_input() {
        for mode in [
            "redirect",
            "duplicate",
            "oversize",
            "chunked",
            "badjson",
            "truncated",
        ] {
            let mut fixture = Fixture::start(mode);
            assert!(
                embeddings(
                    &fixture.socket,
                    &mut fixture.child,
                    &json!({"input":["synthetic"]}),
                    || false,
                    Duration::from_secs(3)
                )
                .is_err(),
                "mode {mode}"
            );
        }
        let mut fixture = Fixture::start("good");
        let result = embeddings(
            &fixture.socket,
            &mut fixture.child,
            &json!({"input":["x".repeat(MAX_REQUEST)]}),
            || false,
            Duration::from_secs(3),
        );
        assert!(result.is_err());
        assert!(!fixture.marker.exists());
    }

    #[test]
    fn cancellation_before_and_during_io_is_prompt() {
        let mut fixture = Fixture::start("good");
        assert!(embeddings(
            &fixture.socket,
            &mut fixture.child,
            &json!({"input":["synthetic"]}),
            || true,
            Duration::from_secs(3)
        )
        .is_err());
        assert!(!fixture.marker.exists());
        let mut fixture = Fixture::start("hang");
        let cancelled = Arc::new(AtomicBool::new(false));
        let flag = cancelled.clone();
        let trigger = thread::spawn(move || {
            thread::sleep(Duration::from_millis(150));
            flag.store(true, Ordering::SeqCst);
        });
        let start = Instant::now();
        let result = embeddings(
            &fixture.socket,
            &mut fixture.child,
            &json!({"input":["synthetic"]}),
            || cancelled.load(Ordering::SeqCst),
            Duration::from_secs(3),
        );
        trigger.join().unwrap();
        assert!(result.unwrap_err().to_string().contains("cancelled"));
        assert!(start.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn stalled_server_times_out_and_exited_child_is_rejected() {
        let mut fixture = Fixture::start("hang");
        let result = embeddings(
            &fixture.socket,
            &mut fixture.child,
            &json!({"input":["synthetic"]}),
            || false,
            Duration::from_millis(180),
        );
        assert!(result.unwrap_err().to_string().contains("timed out"));
        let mut fixture = Fixture::start("good");
        fixture.child.kill().unwrap();
        fixture.child.wait().unwrap();
        assert!(embeddings(
            &fixture.socket,
            &mut fixture.child,
            &json!({}),
            || false,
            Duration::from_secs(1)
        )
        .is_err());
        assert!(!fixture.marker.exists());
    }

    #[test]
    #[ignore = "requires explicit local llama-server and Qwen GGUF model paths; no downloads"]
    fn real_qwen_over_verified_child_unix_socket() {
        use sha2::{Digest, Sha256};
        use std::io::Read as _;
        let binary = std::path::PathBuf::from(
            std::env::var_os("AFTER_TEST_LLAMA_SERVER").expect("set AFTER_TEST_LLAMA_SERVER"),
        );
        let model = std::path::PathBuf::from(
            std::env::var_os("AFTER_TEST_EMBEDDING_MODEL").expect("set AFTER_TEST_EMBEDDING_MODEL"),
        );
        assert!(binary.is_absolute() && model.is_absolute());
        let mut file = std::fs::File::open(&model).unwrap();
        let mut digest = Sha256::new();
        let mut buffer = vec![0; 1024 * 1024];
        loop {
            let n = file.read(&mut buffer).unwrap();
            if n == 0 {
                break;
            }
            digest.update(&buffer[..n]);
        }
        assert_eq!(
            format!("{:x}", digest.finalize()),
            "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439"
        );
        let directory = tempfile::Builder::new()
            .prefix("after-qwen-")
            .tempdir_in("/private/tmp")
            .unwrap();
        let socket = directory.path().join("llama.sock");
        let profile = format!("(version 1) (allow default) (deny file-write*) (allow file-write* (subpath \"{}\")) (deny network-inbound (local ip \"*:*\")) (deny network-outbound (remote ip \"*:*\"))", directory.path().display());
        struct ModelChild(Child);
        impl Drop for ModelChild {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let mut child = ModelChild(
            Command::new("/usr/bin/sandbox-exec")
                .args(["-p", &profile])
                .arg(binary)
                .arg("--model")
                .arg(model)
                .arg("--embedding")
                .arg("--host")
                .arg(&socket)
                .args(["--ctx-size", "2048", "--n-gpu-layers", "0"])
                .env_clear()
                .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
                .env("HOME", directory.path())
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        let end = Instant::now() + Duration::from_secs(90);
        let mut last_error = String::new();
        let result = loop {
            assert!(
                child.0.try_wait().unwrap().is_none(),
                "model process exited: {last_error}"
            );
            assert!(Instant::now() < end, "model did not start: {last_error}");
            match embeddings(
                &socket,
                &mut child.0,
                &json!({"model":"local","input":["Синтетический тест смыслового поиска."]}),
                || false,
                Duration::from_secs(30),
            ) {
                Ok(value) => break value,
                Err(error) => {
                    last_error = format!("{error:#}");
                    thread::sleep(Duration::from_millis(250));
                }
            }
        };
        drop(child);
        let vector = result["data"][0]["embedding"]
            .as_array()
            .expect("embedding vector");
        assert_eq!(vector.len(), 1024);
        assert!(vector
            .iter()
            .all(|value| value.as_f64().is_some_and(f64::is_finite)));
    }
}
