//! Research-only, one-shot helper. No application entry point launches it.
//!
//! This synchronous process spawns the local runtime before creating any UDS,
//! never spawns another process after that point, verifies every runtime socket
//! through the experimental transport, and exits after one bounded request.
//! Its inherited stdin/stdout are *not* yet a proven private application IPC:
//! the parent must establish and authenticate that channel without descriptor
//! inheritance races. Runtime dylib integrity, path replacement during model
//! load, resource lease and cancellation also remain unsolved. Do not ship.

#[cfg(target_os = "macos")]
#[path = "../src/platform/macos/managed_embedding_transport.rs"]
mod managed_embedding_transport;

#[cfg(target_os = "macos")]
fn run() -> anyhow::Result<()> {
    use anyhow::{ensure, Context};
    use serde::Deserialize;
    use serde_json::json;
    use sha2::{Digest, Sha256};
    use std::io::{Read, Write};
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};
    use std::time::{Duration, Instant};

    const SERVER_DIGEST: &str = "3efd976f34a2469901b62c838f8b47a47f2a31bec403b4a287567a40f38658d4";
    const MODEL_DIGEST: &str = "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439";
    const MAX_INPUT: usize = 64 * 1024;

    fn check_file(path: &Path, expected: &str) -> anyhow::Result<()> {
        ensure!(path.is_absolute(), "absolute path required");
        let mut file = std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path).context("open runtime fixture")?;
        ensure!(file.metadata()?.is_file(), "regular file required");
        let mut digest = Sha256::new();
        let mut buffer = [0; 65536];
        loop { let n = file.read(&mut buffer)?; if n == 0 { break; } digest.update(&buffer[..n]); }
        ensure!(format!("{:x}", digest.finalize()) == expected, "unexpected experimental runtime or model digest");
        Ok(())
    }
    struct Scratch(PathBuf);
    impl Drop for Scratch { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }
    struct Model(Child);
    impl Drop for Model { fn drop(&mut self) { let _ = self.0.kill(); let _ = self.0.wait(); } }
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Request { input: Vec<String> }

    let mut args = std::env::args_os().skip(1);
    let binary = PathBuf::from(args.next().context("missing test runtime")?);
    let model = PathBuf::from(args.next().context("missing test model")?);
    let parent = PathBuf::from(args.next().context("missing private test directory")?);
    ensure!(args.next().is_none(), "unexpected argument");
    check_file(&binary, SERVER_DIGEST)?;
    check_file(&model, MODEL_DIGEST)?;
    let parent_metadata = std::fs::symlink_metadata(&parent)?;
    ensure!(parent.is_absolute() && parent_metadata.is_dir() && !parent_metadata.file_type().is_symlink()
            && parent_metadata.permissions().mode() & 0o077 == 0, "private test directory required");
    let scratch = Scratch(parent.join(format!("h-{}", uuid::Uuid::new_v4().simple())));
    std::fs::DirBuilder::new().mode(0o700).create(&scratch.0).context("create private helper directory")?;
    let socket = scratch.0.join("model.sock");
    use std::os::unix::ffi::OsStrExt;
    ensure!(socket.as_os_str().as_bytes().len() < 104, "test directory path is too long for a Unix socket");
    // This is the only child spawned by the helper and is spawned before any
    // UDS is created or any user request is read from stdin.
    let mut child = Model(Command::new(&binary).arg("--model").arg(&model)
        .args(["--embedding", "--host"]).arg(&socket)
        .args(["--ctx-size", "2048", "--n-gpu-layers", "0", "--offline"])
        .env_clear().env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin").env("HOME", &scratch.0)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().context("start model process")?);
    let ready_deadline = Instant::now() + Duration::from_secs(90);
    loop {
        ensure!(Instant::now() < ready_deadline, "local embedding model did not start");
        ensure!(child.0.try_wait()?.is_none(), "local embedding process exited");
        let probe = json!({"model":"local","input":["synthetic readiness probe"]});
        if managed_embedding_transport::embeddings(&socket, &mut child.0, &probe, || false, Duration::from_secs(30)).is_ok() { break; }
        std::thread::sleep(Duration::from_millis(250));
    }
    // Only the caller-provided stdio channel carries input; this experimental
    // program cannot establish the privacy of that channel by itself.
    let mut input = Vec::new();
    std::io::stdin().lock().take((MAX_INPUT + 1) as u64).read_to_end(&mut input).context("read experimental input")?;
    ensure!(input.len() <= MAX_INPUT, "embedding request too large");
    let request: Request = serde_json::from_slice(&input)?;
    ensure!(!request.input.is_empty() && request.input.len() <= 8 &&
        request.input.iter().all(|text| !text.is_empty() && text.len() <= 5000), "invalid embedding batch");
    let result = managed_embedding_transport::embeddings(&socket, &mut child.0,
        &json!({"model":"local","input":request.input}), || false, Duration::from_secs(45))?;
    let rows = result["data"].as_array().context("embedding result missing data")?;
    ensure!(rows.len() == request.input.len(), "incorrect embedding count");
    for row in rows {
        let vector = row["embedding"].as_array().context("embedding vector missing")?;
        ensure!(vector.len() == 1024 && vector.iter().all(|n| n.as_f64().is_some_and(f64::is_finite)), "invalid embedding vector");
    }
    let output = serde_json::to_vec(&json!({"ok":true,"value":result}))?;
    ensure!(output.len() <= 2 * 1024 * 1024, "embedding response too large");
    std::io::stdout().lock().write_all(&output).context("write experimental result")?;
    Ok(())
}

fn main() {
    #[cfg(target_os = "macos")]
    if let Err(error) = run() { eprintln!("experimental helper failed: {error:#}"); std::process::exit(1); }
    #[cfg(not(target_os = "macos"))]
    { eprintln!("experimental helper requires macOS"); std::process::exit(1); }
}
