//! App-owned, CPU-bounded embeddings over a verified Unix socket. Public
//! downloads happen only in `prepare`; inference never falls back to a port.
//! The trust boundary excludes arbitrary hostile processes with this user's
//! filesystem/memory access. Hashes detect corrupt/wrong assets, and peer PID
//! prevents an unrelated socket listener from receiving note text.
use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::os::unix::{
    fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
    process::CommandExt,
};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

pub const MODEL: &str = "qwen3-embedding:0.6b";
pub const MODEL_HASH: &str = "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439";
const SERVER_HASH: &str = "3efd976f34a2469901b62c838f8b47a47f2a31bec403b4a287567a40f38658d4";
const ARCHIVE_HASH: &str = "a2d1d906a2c8febd9cb18f5c183854d0a6db5dc522940d68b0c0ed048e8dfdea";
pub const REVISION: &str = "qwen3-embedding-0.6b-06507c7b-llama-v0.40.3-cpu-v1";
const MODEL_BYTES: u64 = 639_150_592;
static RECORDING: OnceLock<Mutex<BTreeMap<PathBuf, File>>> = OnceLock::new();
static VERIFIED: OnceLock<Mutex<BTreeMap<PathBuf, (String, (u64, u64, i64, i64, i64, i64))>>> =
    OnceLock::new();

fn directory(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(m) => ensure!(
            m.is_dir() && !m.file_type().is_symlink() && m.uid() == unsafe { libc::geteuid() },
            "Недопустимая папка встроенной модели"
        ),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            fs::DirBuilder::new().mode(0o700).create(path)?
        }
        Err(e) => return Err(e.into()),
    }
    Ok(())
}
fn base(root: &Path) -> Result<PathBuf> {
    ensure!(root.is_absolute(), "Нужен абсолютный путь библиотеки");
    directory(root)?;
    let runtime = root.join("runtime");
    directory(&runtime)?;
    let path = runtime.join("semantic");
    directory(&path)?;
    Ok(path)
}
fn file(path: &Path) -> Result<File> {
    let f = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let m = f.metadata()?;
    ensure!(
        m.is_file() && m.nlink() == 1 && m.uid() == unsafe { libc::geteuid() },
        "Недопустимый файл встроенной модели"
    );
    Ok(f)
}
fn verify(path: &Path, expected: &str) -> Result<()> {
    let mut f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .context(
            "Встроенная модель не подготовлена. В настройках поиска нажмите «Подготовить модель».",
        )?;
    let m = f.metadata()?;
    ensure!(
        m.is_file() && m.nlink() == 1 && m.uid() == unsafe { libc::geteuid() },
        "Недопустимый файл встроенной модели"
    );
    let stamp = (
        m.ino(),
        m.len(),
        m.mtime(),
        m.mtime_nsec(),
        m.ctime(),
        m.ctime_nsec(),
    );
    let cache = VERIFIED.get_or_init(Default::default);
    if cache
        .lock()
        .unwrap()
        .get(path)
        .is_some_and(|(digest, known)| digest == expected && *known == stamp)
    {
        return Ok(());
    }
    let mut digest = Sha256::new();
    let mut buf = [0u8; 65536];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        digest.update(&buf[..n]);
    }
    ensure!(
        format!("{:x}", digest.finalize()) == expected,
        "Файл встроенной модели повреждён. Повторите подготовку модели."
    );
    cache
        .lock()
        .unwrap()
        .insert(path.to_owned(), (expected.into(), stamp));
    Ok(())
}
fn assets(root: &Path) -> Result<(PathBuf, PathBuf)> {
    ensure!(
        cfg!(all(target_os = "macos", target_arch = "aarch64")),
        "Встроенная модель требует Mac с Apple Silicon. Выберите Ollama или LM Studio."
    );
    let dir = base(root)?;
    let server = dir.join("After Embeddings");
    let model = dir.join("qwen3-embedding-0.6b.gguf");
    verify(&server, SERVER_HASH)?;
    verify(&model, MODEL_HASH)?;
    Ok((server, model))
}
pub fn status(root: &Path) -> Result<Value> {
    let ready = assets(root).is_ok();
    Ok(
        json!({"ready":ready,"model":MODEL,"revision":REVISION,"dimensions":1024,"downloadBytes":MODEL_BYTES+170_000_000}),
    )
}
pub fn set_recording(root: &Path, active: bool) -> Result<()> {
    let key = fs::canonicalize(root)?;
    let mut owned = RECORDING.get_or_init(Default::default).lock().unwrap();
    if active && !owned.contains_key(&key) {
        let lock = file(&base(root)?.join(".recording.lock"))?;
        lock.try_lock()
            .context("Запись уже запущена в другой копии After")?;
        owned.insert(key, lock);
    } else if !active {
        if let Some(lock) = owned.remove(&key) {
            lock.unlock()?;
        }
    }
    Ok(())
}
fn recording(root: &Path) -> bool {
    let Ok(dir) = base(root) else { return true };
    let Ok(lock) = file(&dir.join(".recording.lock")) else {
        return true;
    };
    lock.try_lock().is_err()
}
fn inference_lease(root: &Path, cancelled: &impl Fn() -> bool) -> Result<File> {
    let lock = file(&base(root)?.join(".inference.lock"))?;
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        ensure!(
            !cancelled() && !recording(root),
            "Смысловой поиск продолжится после записи"
        );
        if lock.try_lock().is_ok() {
            return Ok(lock);
        }
        ensure!(
            Instant::now() < deadline,
            "Локальная модель занята. Повторите поиск."
        );
        std::thread::sleep(Duration::from_millis(30));
    }
}

fn trusted_download_url(url: &reqwest::Url) -> bool {
    let host = url.host_str().unwrap_or("");
    url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && ([
            "github.com",
            "release-assets.githubusercontent.com",
            "objects.githubusercontent.com",
            "registry.ollama.ai",
        ]
        .contains(&host)
            || host.ends_with(".r2.cloudflarestorage.com"))
}

fn download(url: &str, path: &Path, digest: &str, max: u64) -> Result<()> {
    ensure!(
        trusted_download_url(&reqwest::Url::parse(url)?),
        "Недопустимый адрес загрузки модели"
    );
    if verify(path, digest).is_ok() {
        return Ok(());
    }
    let temporary = path.with_extension(format!("{}.part", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> {
        let client = reqwest::blocking::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(900))
            .redirect(reqwest::redirect::Policy::custom(|attempt| {
                if attempt.previous().len() > 5 || !trusted_download_url(attempt.url()) {
                    attempt.error("Unsafe model download redirect")
                } else {
                    attempt.follow()
                }
            }))
            .build()?;
        let mut response = client.get(url).send()?.error_for_status()?;
        ensure!(
            response.content_length().is_none_or(|n| n <= max),
            "Слишком большой файл модели"
        );
        let mut out = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary)?;
        let mut hash = Sha256::new();
        let mut total = 0u64;
        let mut buf = [0u8; 65536];
        loop {
            let n = response.read(&mut buf)?;
            if n == 0 {
                break;
            }
            total += n as u64;
            ensure!(total <= max, "Слишком большой файл модели");
            hash.update(&buf[..n]);
            out.write_all(&buf[..n])?;
        }
        ensure!(
            format!("{:x}", hash.finalize()) == digest,
            "Проверка скачанной модели не прошла"
        );
        out.sync_all()?;
        fs::rename(&temporary, path)?;
        Ok(())
    })();
    let _ = fs::remove_file(&temporary);
    result
}
fn copy_verified(source: &Path, destination: &Path, digest: &str) -> Result<bool> {
    if verify(source, digest).is_err() {
        return Ok(false);
    }
    let temp = destination.with_extension(format!("{}.part", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> {
        fs::copy(source, &temp)?;
        fs::set_permissions(&temp, fs::Permissions::from_mode(0o600))?;
        verify(&temp, digest)?;
        fs::rename(&temp, destination)?;
        Ok(())
    })();
    let _ = fs::remove_file(&temp);
    result?;
    Ok(true)
}
fn installation_lease(root: &Path) -> Result<File> {
    let lock = file(&base(root)?.join(".install.lock"))?;
    lock.try_lock()
        .context("Подготовка модели уже выполняется")?;
    Ok(lock)
}
/// Explicit user action. Downloads only public, pinned runtime/model bytes.
pub fn prepare(root: &Path) -> Result<Value> {
    ensure!(
        cfg!(all(target_os = "macos", target_arch = "aarch64")),
        "Встроенная модель требует Mac с Apple Silicon"
    );
    ensure!(!recording(root), "Дождитесь завершения записи");
    // Downloading verified assets does not use the inference runtime. Keep
    // installers exclusive while allowing an already complete model to run;
    // partial files cannot pass assets() and publication remains atomic.
    let _installation = installation_lease(root)?;
    let dir = base(root)?;
    let server = dir.join("After Embeddings");
    if verify(&server, SERVER_HASH).is_err() {
        let candidates = [
            root.join("runtime/ollama/llama-server"),
            root.join("runtime/ollama/После Модель"),
            root.join("runtime/ollama/lib/ollama/llama-server"),
            root.join("runtime/ollama/lib/ollama/После Модель"),
        ];
        let mut copied = false;
        for source in candidates {
            if copy_verified(&source, &server, SERVER_HASH)? {
                copied = true;
                break;
            }
        }
        if !copied {
            let archive = dir.join("runtime.tgz");
            download(
                "https://github.com/ollama/ollama/releases/download/v0.40.3/ollama-darwin.tgz",
                &archive,
                ARCHIVE_HASH,
                250 * 1024 * 1024,
            )?;
            let stage = dir.join(format!("install-{}", uuid::Uuid::new_v4().simple()));
            directory(&stage)?;
            let extraction = (|| -> Result<()> {
                let result = Command::new("/usr/bin/tar")
                    .arg("-xzf")
                    .arg(&archive)
                    .arg("-C")
                    .arg(&stage)
                    .args([
                        "llama-server",
                        "LLAMA_CPP_LICENSE",
                        "LLAMA_CPP_VENDORS_LICENSE",
                    ])
                    .env_clear()
                    .env("PATH", "/usr/bin:/bin")
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()?;
                ensure!(result.success(), "Не удалось распаковать встроенную модель");
                verify(&stage.join("llama-server"), SERVER_HASH)?;
                fs::rename(stage.join("llama-server"), &server)?;
                for license in ["LLAMA_CPP_LICENSE", "LLAMA_CPP_VENDORS_LICENSE"] {
                    fs::rename(stage.join(license), dir.join(license))?;
                }
                Ok(())
            })();
            let _ = fs::remove_dir_all(&stage);
            extraction?;
            let _ = fs::remove_file(&archive);
        }
        fs::set_permissions(&server, fs::Permissions::from_mode(0o700))?;
    }
    let model = dir.join("qwen3-embedding-0.6b.gguf");
    if verify(&model, MODEL_HASH).is_err()
        && !copy_verified(
            &root.join(format!("cache/ollama-models/blobs/sha256-{MODEL_HASH}")),
            &model,
            MODEL_HASH,
        )?
    {
        download(
            &format!(
                "https://registry.ollama.ai/v2/library/qwen3-embedding/blobs/sha256:{MODEL_HASH}"
            ),
            &model,
            MODEL_HASH,
            MODEL_BYTES,
        )?;
    }
    // Preserve bundled upstream notices even when reusing an already pinned
    // runtime from another After component rather than extracting an archive.
    for (name, notice) in [
        (
            "LLAMA_CPP_LICENSE",
            include_str!("../resources/managed-embeddings/LLAMA_CPP_LICENSE"),
        ),
        (
            "LLAMA_CPP_VENDORS_LICENSE",
            include_str!("../resources/managed-embeddings/LLAMA_CPP_VENDORS_LICENSE"),
        ),
    ] {
        let mut output = file(&dir.join(name))?;
        output.set_len(0)?;
        output.write_all(notice.as_bytes())?;
        output.sync_all()?;
    }
    assets(root)?;
    Ok(json!({"downloaded":true,"ready":true,"model":MODEL,"revision":REVISION,"dimensions":1024}))
}
struct Running {
    child: Child,
    scratch: PathBuf,
}
impl Drop for Running {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.scratch);
    }
}

pub fn embed(root: &Path, inputs: &[String], cancelled: impl Fn() -> bool) -> Result<Value> {
    ensure!(
        !inputs.is_empty() && inputs.len() <= 8 && inputs.iter().all(|t| t.len() <= 6100),
        "Слишком большой пакет встроенной модели"
    );
    let _lease = inference_lease(root, &cancelled)?;
    let (binary, model) = assets(root)?;
    ensure!(
        !cancelled() && !recording(root),
        "Смысловой поиск приостановлен"
    );
    let scratch =
        PathBuf::from("/private/tmp").join(format!("after-e-{}", uuid::Uuid::new_v4().simple()));
    directory(&scratch)?;
    let socket = scratch.join("s.sock");
    let spawn = Command::new(&binary)
        .arg("--model")
        .arg(&model)
        .args(["--embedding", "--host"])
        .arg(&socket)
        .args([
            "--ctx-size",
            "4096",
            "--parallel",
            "1",
            "--threads",
            "2",
            "--threads-batch",
            "2",
            "--n-gpu-layers",
            "0",
            "--device",
            "none",
            "--no-op-offload",
            "--offline",
            "--sleep-idle-seconds",
            "2",
            "--timeout",
            "60",
        ])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("TMPDIR", &scratch)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn();
    let child = match spawn {
        Ok(child) => child,
        Err(e) => {
            let _ = fs::remove_dir_all(&scratch);
            return Err(e).context("Не удалось запустить встроенную модель");
        }
    };
    let mut running = Running { child, scratch };
    let deadline = Instant::now() + Duration::from_secs(90);
    let cancelled = || cancelled() || recording(root);
    loop {
        ensure!(!cancelled(), "Смысловой поиск приостановлен");
        ensure!(
            running.child.try_wait()?.is_none(),
            "Встроенная модель не запустилась. Повторите подготовку."
        );
        ensure!(
            Instant::now() < deadline,
            "Встроенная модель долго запускается"
        );
        if socket.exists() {
            break;
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    #[cfg(target_os = "macos")]
    {
        // Retry readiness using public synthetic text only. Never retry user
        // payload on another transport/process or after an ambiguous failure.
        loop {
            ensure!(
                !cancelled() && Instant::now() < deadline,
                "Встроенная модель не готова"
            );
            let probe = crate::managed_embedding_transport::embeddings(
                &socket,
                &mut running.child,
                &json!({"model":"local","input":["After readiness"]}),
                &cancelled,
                Duration::from_secs(10),
            );
            if probe.is_ok() {
                break;
            }
            ensure!(
                running.child.try_wait()?.is_none(),
                "Встроенная модель завершилась"
            );
            std::thread::sleep(Duration::from_millis(100));
        }
        crate::managed_embedding_transport::embeddings(
            &socket,
            &mut running.child,
            &json!({"model":"local","input":inputs}),
            &cancelled,
            Duration::from_secs(60),
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        anyhow::bail!("Встроенная модель поддерживается только на macOS")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recording_lock_blocks_inference_and_releases() {
        let root = tempfile::tempdir().unwrap();
        set_recording(root.path(), true).unwrap();
        assert!(recording(root.path()));
        assert!(inference_lease(root.path(), &|| false).is_err());
        set_recording(root.path(), false).unwrap();
        assert!(!recording(root.path()));
        assert!(inference_lease(root.path(), &|| false).is_ok());
    }
    #[test]
    fn integrity_rechecks_changed_bytes_and_rejects_links() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("asset");
        fs::write(&path, b"good").unwrap();
        let digest = format!("{:x}", Sha256::digest(b"good"));
        verify(&path, &digest).unwrap();
        fs::write(&path, b"evil").unwrap();
        assert!(verify(&path, &digest).is_err());
        let link = root.path().join("alias");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(verify(&link, &digest).is_err());
    }
    #[test]
    fn missing_assets_never_download_on_status_or_inference() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(status(root.path()).unwrap()["ready"], false);
        assert!(embed(root.path(), &["private fixture".into()], || false).is_err());
        assert!(!root.path().join("runtime/semantic/runtime.tgz").exists());
    }
    #[test]
    fn preparation_lock_is_exclusive_without_blocking_inference_or_trusting_parts() {
        let root = tempfile::tempdir().unwrap();
        let installation = installation_lease(root.path()).unwrap();
        assert!(installation_lease(root.path()).is_err());
        let inference = inference_lease(root.path(), &|| false).unwrap();
        let dir = base(root.path()).unwrap();
        fs::write(dir.join("qwen3-embedding-0.6b.download.part"), b"incomplete model").unwrap();
        fs::write(dir.join("After Embeddings"), b"incomplete runtime").unwrap();
        fs::write(dir.join("qwen3-embedding-0.6b.gguf"), b"invalid model").unwrap();
        assert_eq!(status(root.path()).unwrap()["ready"], false);
        drop(installation);
        // An inference lease also must not prevent a new install from starting.
        assert!(installation_lease(root.path()).is_ok());
        drop(inference);
    }
    #[test]
    fn cancellation_prevents_loading() {
        let root = tempfile::tempdir().unwrap();
        assert!(embed(root.path(), &["fixture".into()], || true)
            .unwrap_err()
            .to_string()
            .contains("записи"));
    }
    #[test]
    fn managed_asset_redirects_are_public_https_hosts_only() {
        for url in [
            "https://github.com/ollama/ollama",
            "https://release-assets.githubusercontent.com/object",
            "https://registry.ollama.ai/blob",
            "https://bucket.r2.cloudflarestorage.com/blob",
        ] {
            assert!(trusted_download_url(&reqwest::Url::parse(url).unwrap()));
        }
        for url in [
            "http://github.com/object",
            "https://github.com.attacker.example/x",
            "https://localhost/x",
            "https://user:password@github.com/object",
            "https://r2.cloudflarestorage.com.attacker.example/x",
        ] {
            assert!(!trusted_download_url(&reqwest::Url::parse(url).unwrap()));
        }
    }
    #[test]
    fn one_inference_lease_and_cancellation_while_waiting() {
        let root = tempfile::tempdir().unwrap();
        let first = inference_lease(root.path(), &|| false).unwrap();
        let started = Instant::now();
        assert!(inference_lease(root.path(), &|| started.elapsed()
            > Duration::from_millis(40))
        .is_err());
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(first);
        assert!(inference_lease(root.path(), &|| false).is_ok());
    }
    #[test]
    fn recording_guard_is_visible_to_another_process() {
        let root = tempfile::tempdir().unwrap();
        set_recording(root.path(), true).unwrap();
        let script="import fcntl,sys; f=open(sys.argv[1],'r+');\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(0)\nsys.exit(1)";
        let status = Command::new("/usr/bin/python3")
            .args(["-c", script])
            .arg(base(root.path()).unwrap().join(".recording.lock"))
            .status()
            .unwrap();
        set_recording(root.path(), false).unwrap();
        assert!(status.success());
    }
}
