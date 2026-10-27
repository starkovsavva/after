//! Recording finalization is a media operation, independent of the ASR Python runtime.
use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

const BINARY: &str = "ffmpeg-macos-aarch64-v7.1";
const BINARY_SIZE: u64 = 49_368_728;
const BINARY_SHA: &str = "6d175a4743ca50256e89a8cdd731100f9cee33bd79aeea46894d209410dc6617";
const WHEEL_URL: &str = "https://files.pythonhosted.org/packages/40/5c/f3d8a657d362cc93b81aab8feda487317da5b5d31c0e1fdfd5e986e55d17/imageio_ffmpeg-0.6.0-py3-none-macosx_11_0_arm64.whl";
const WHEEL_SIZE: u64 = 21_113_891;
const WHEEL_SHA: &str = "b1ae3173414b5fc5f538a726c4e48ea97edc0d2cdc11f103afee655c463fa742";
static CANCELLED: AtomicBool = AtomicBool::new(false);
extern "C" fn cancel(_: libc::c_int) {
    CANCELLED.store(true, Ordering::Relaxed);
}
struct Signals(Vec<(i32, libc::sigaction)>);
impl Signals {
    fn install() -> Result<Self> {
        CANCELLED.store(false, Ordering::Relaxed);
        let mut guard = Self(Vec::new());
        for signal in [libc::SIGTERM, libc::SIGINT] {
            let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
            let mut previous: libc::sigaction = unsafe { std::mem::zeroed() };
            action.sa_sigaction = cancel as *const () as libc::sighandler_t;
            unsafe {
                libc::sigemptyset(&mut action.sa_mask);
            }
            ensure!(
                unsafe { libc::sigaction(signal, &action, &mut previous) } == 0,
                "Не удалось подготовить отмену сохранения."
            );
            guard.0.push((signal, previous));
        }
        Ok(guard)
    }
}
impl Drop for Signals {
    fn drop(&mut self) {
        for (signal, action) in self.0.iter().rev() {
            unsafe {
                libc::sigaction(*signal, action, std::ptr::null_mut());
            }
        }
    }
}
fn check_cancelled() -> Result<()> {
    ensure!(
        !CANCELLED.load(Ordering::Relaxed),
        "Обработка остановлена. Исходная запись сохранена."
    );
    Ok(())
}
fn progress(message: &str, fraction: f64) -> Result<()> {
    check_cancelled()?;
    let mut out = std::io::stdout().lock();
    writeln!(
        out,
        "{}",
        json!({"event":"progress", "message":message,"fraction":fraction})
    )?;
    out.flush()?;
    Ok(())
}
fn regular(path: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    ensure!(file.metadata()?.is_file(), "Ожидается обычный файл записи.");
    Ok(file)
}
fn private_directory(path: &Path) -> Result<()> {
    if !path.exists() {
        fs::create_dir(path)?;
    }
    let info = fs::symlink_metadata(path)?;
    ensure!(
        info.is_dir() && !info.file_type().is_symlink() && info.uid() == unsafe { libc::geteuid() },
        "Компоненты медиа должны находиться в собственной папке «После»."
    );
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}
struct Temporary(PathBuf);
impl Temporary {
    fn new(parent: &Path) -> Result<Self> {
        let path = parent.join(format!(".posle-finalize-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
        Ok(Self(path))
    }
}
impl Drop for Temporary {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn verified(path: &Path, size: u64, sha: &str) -> bool {
    let Ok(mut file) = regular(path) else {
        return false;
    };
    let Ok(info) = file.metadata() else {
        return false;
    };
    if info.len() != size || info.mode() & 0o022 != 0 {
        return false;
    }
    let mut hash = Sha256::new();
    let Ok(read) = std::io::copy(&mut Read::by_ref(&mut file).take(size + 1), &mut hash) else {
        return false;
    };
    let unchanged = file.metadata().is_ok_and(|after| {
        after.len() == info.len()
            && after.mtime() == info.mtime()
            && after.mtime_nsec() == info.mtime_nsec()
            && after.ctime() == info.ctime()
            && after.ctime_nsec() == info.ctime_nsec()
            && after.mode() == info.mode()
    });
    unchanged && read == size && format!("{:x}", hash.finalize()) == sha
}
fn media(root: &Path) -> Result<PathBuf> {
    let runtime = root.join("runtime");
    private_directory(&runtime)?;
    let directory = runtime.join("media");
    private_directory(&directory)?;
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(directory.join(".native-install.lock"))?;
    ensure!(lock.metadata()?.is_file(), "Некорректная блокировка медиа.");
    while unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        ensure!(
            std::io::Error::last_os_error().kind() == std::io::ErrorKind::WouldBlock,
            "Не удалось заблокировать компоненты MP3."
        );
        check_cancelled()?;
        std::thread::sleep(Duration::from_millis(50));
    }
    let target = directory.join("После Медиа");
    if verified(&target, BINARY_SIZE, BINARY_SHA) {
        return Ok(target);
    }
    let temporary = Temporary::new(&directory)?;
    let staged = temporary.0.join("media");
    // The executable is trusted by its independently pinned bytes, without
    // starting Python or trusting an installed package's mutable RECORD file.
    let donor = runtime.join(format!(
        "venv/lib/python3.12/site-packages/imageio_ffmpeg/binaries/{BINARY}"
    ));
    let parents_safe = donor
        .ancestors()
        .take_while(|p| *p != root)
        .skip(1)
        .all(|p| fs::symlink_metadata(p).is_ok_and(|i| i.is_dir() && !i.file_type().is_symlink()));
    if parents_safe && verified(&donor, BINARY_SIZE, BINARY_SHA) {
        fs::copy(&donor, &staged)?;
    } else {
        progress("Загружаю компоненты MP3 · 21 МБ…", 0.0)?;
        let wheel = temporary.0.join("media.whl");
        let mut command = Command::new("/usr/bin/curl");
        // -q must be first: a user's curlrc cannot redirect this pinned download.
        command
            .args([
                "-q",
                "--fail",
                "--silent",
                "--proto",
                "=https",
                "--connect-timeout",
                "10",
                "--max-time",
                "600",
                "--max-filesize",
                &WHEEL_SIZE.to_string(),
                "--output",
            ])
            .arg(&wheel)
            .arg(WHEEL_URL)
            .stdout(Stdio::null());
        execute_with_download_progress(command, Some(&wheel)).context("Не удалось загрузить компоненты MP3. Исходная запись сохранена; повторите при подключении к интернету.")?;
        ensure!(
            verified(&wheel, WHEEL_SIZE, WHEEL_SHA),
            "Проверка компонентов MP3 не прошла. Исходная запись сохранена."
        );
        let output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o700)
            .open(&staged)?;
        let mut command = Command::new("/usr/bin/unzip");
        command
            .arg("-p")
            .arg(&wheel)
            .arg(format!("imageio_ffmpeg/binaries/{BINARY}"))
            .stdout(Stdio::from(output));
        execute(command)?;
        // Retain the upstream BSD notice with this separately downloaded component.
        let output = File::create(temporary.0.join("LICENSE.imageio-ffmpeg"))?;
        let mut command = Command::new("/usr/bin/unzip");
        command
            .arg("-p")
            .arg(&wheel)
            .arg("imageio_ffmpeg-0.6.0.dist-info/LICENSE")
            .stdout(Stdio::from(output));
        execute(command)?;
        fs::rename(
            temporary.0.join("LICENSE.imageio-ffmpeg"),
            directory.join("LICENSE.imageio-ffmpeg"),
        )?;
    }
    ensure!(
        verified(&staged, BINARY_SIZE, BINARY_SHA),
        "Проверка движка MP3 не прошла. Исходная запись сохранена."
    );
    fs::set_permissions(&staged, fs::Permissions::from_mode(0o700))?;
    check_cancelled()?;
    fs::rename(staged, &target)?;
    Ok(target)
}
/// Each command has its own group and is reaped before its staging files are
/// removed. Cancellation or a lost UI parent terminates all descendants.
struct RunningChild {
    child: Child,
    group: i32,
    active: bool,
}
impl Drop for RunningChild {
    fn drop(&mut self) {
        if self.active {
            unsafe {
                libc::kill(-self.group, libc::SIGKILL);
            }
            let _ = self.child.wait();
        }
    }
}
fn execute(command: Command) -> Result<()> {
    execute_with_download_progress(command, None)
}
fn execute_with_download_progress(mut command: Command, download: Option<&Path>) -> Result<()> {
    check_cancelled()?;
    let parent = unsafe { libc::getppid() };
    let child = command
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .process_group(0)
        .spawn()
        .context("Не удалось запустить обработку медиа.")?;
    let group = child.id() as i32;
    let mut child = RunningChild {
        child,
        group,
        active: true,
    };
    let mut termination = None;
    let mut reported_megabytes = 0;
    loop {
        if let Some(download) = download {
            let size = fs::metadata(download)
                .map(|info| info.len().min(WHEEL_SIZE))
                .unwrap_or_default();
            let megabytes = size / 1_000_000;
            if megabytes > reported_megabytes {
                progress(
                    &format!("Загружаю компоненты MP3 · {megabytes} из 21 МБ…"),
                    size as f64 / WHEEL_SIZE as f64 * 0.08,
                )?;
                reported_megabytes = megabytes;
            }
        }
        if CANCELLED.load(Ordering::Relaxed) || (parent > 1 && unsafe { libc::getppid() } != parent)
        {
            CANCELLED.store(true, Ordering::Relaxed);
            if termination.is_none() {
                unsafe {
                    libc::kill(-group, libc::SIGTERM);
                }
                termination = Some(Instant::now());
            }
        }
        if termination.is_some_and(|time| time.elapsed() > Duration::from_secs(2)) {
            unsafe {
                libc::kill(-group, libc::SIGKILL);
            }
        }
        if let Some(status) = child.child.try_wait()? {
            child.active = false;
            check_cancelled()?;
            ensure!(
                status.success(),
                "Не удалось преобразовать запись. Исходная запись сохранена; повторите обработку."
            );
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}
fn ffmpeg(binary: &Path, arguments: Vec<String>) -> Result<()> {
    let mut command = Command::new(binary);
    command
        .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-y"])
        .args(arguments)
        .stdout(Stdio::null());
    execute(command)
}
fn path(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}
fn audio_wave(binary: &Path, source: &Path, target: &Path, track: usize, full: bool) -> Result<()> {
    let mut args = vec![
        "-copyts".into(),
        "-start_at_zero".into(),
        "-i".into(),
        path(source),
        "-map".into(),
        format!("0:a:{track}"),
        "-vn".into(),
        "-af".into(),
        "aresample=async=1:first_pts=0".into(),
    ];
    if !full {
        args.extend(["-ac".into(), "1".into()]);
    }
    args.extend([
        "-ar".into(),
        if full { "48000" } else { "16000" }.into(),
        "-c:a".into(),
        "pcm_s16le".into(),
        path(target),
    ]);
    ffmpeg(binary, args)
}
fn metadata(directory: &Path) -> Result<Value> {
    let file = regular(&directory.join("meta.json"))?;
    ensure!(
        file.metadata()?.len() <= 1024 * 1024,
        "Метаданные записи слишком большие."
    );
    let mut bytes = Vec::new();
    file.take(1024 * 1024 + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= 1024 * 1024,
        "Метаданные записи слишком большие."
    );
    Ok(serde_json::from_slice(&bytes)?)
}
fn captured_source(meta: &Value) -> Result<Option<&str>> {
    let name = meta["source"].as_str().context("Нет исходной записи.")?;
    ensure!(
        Path::new(name).file_name().and_then(|x| x.to_str()) == Some(name) && !name.is_empty(),
        "Некорректное имя записи."
    );
    Ok((name != "recording.mp3" && name.starts_with("recording.")).then_some(name))
}
fn quality(meta: &Value) -> (&'static str, &'static str) {
    match meta["recordingAudioQuality"].as_str() {
        Some("compact") => ("64k", "64k"),
        Some("standard") => ("128k", "128k"),
        Some("high") => ("192k", "192k"),
        _ => ("128k", "96k"),
    }
}
fn source_stamp(file: &File) -> Result<(u64, u64, u64, i64, i64)> {
    let m = file.metadata()?;
    Ok((m.dev(), m.ino(), m.len(), m.mtime(), m.mtime_nsec()))
}

pub fn finalize(root: &Path, directory: &Path) -> Result<()> {
    let _signals = Signals::install()?;
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(directory.join(".native-finalize.lock"))?;
    ensure!(
        lock.metadata()?.is_file(),
        "Некорректная блокировка записи."
    );
    ensure!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
        "Эта запись уже сохраняется."
    );
    let meta = metadata(directory)?;
    let Some(name) = captured_source(&meta)? else {
        return Ok(());
    };
    let source = directory.join(name);
    let input = regular(&source)?;
    let stamp = source_stamp(&input)?;
    let binary = media(root)?;
    let temporary = Temporary::new(directory)?;
    let temp = &temporary.0;
    let system = temp.join("system-full.wav");
    let mic = temp.join("microphone-full.wav");
    progress("Сохраняю встречу в MP3…", 0.1)?;
    audio_wave(&binary, &source, &system, 0, true)?;
    audio_wave(&binary, &system, &temp.join("audio.wav"), 0, false)?;
    let mut dual = meta["recordingTracks"].as_bool().unwrap_or(false);
    if dual && audio_wave(&binary, &source, &mic, 1, true).is_err() {
        check_cancelled()?;
        dual = false;
    }
    let (bitrate, isolated) = quality(&meta);
    let playback = if dual {
        audio_wave(&binary, &mic, &temp.join("microphone.wav"), 0, false)?;
        ffmpeg(
            &binary,
            vec![
                "-i".into(),
                path(&system),
                "-c:a".into(),
                "aac".into(),
                "-b:a".into(),
                isolated.into(),
                path(&temp.join("system.m4a")),
            ],
        )?;
        ffmpeg(
            &binary,
            vec![
                "-i".into(),
                path(&mic),
                "-c:a".into(),
                "aac".into(),
                "-b:a".into(),
                isolated.into(),
                path(&temp.join("microphone.m4a")),
            ],
        )?;
        let mix = temp.join("mix-full.wav");
        ffmpeg(&binary, vec!["-i".into(), path(&system), "-i".into(), path(&mic), "-filter_complex".into(), "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95:latency=1[a]".into(), "-map".into(), "[a]".into(), "-ar".into(), "48000".into(), "-c:a".into(), "pcm_s16le".into(), path(&mix)])?;
        mix
    } else {
        system
    };
    progress("Сохраняю встречу в MP3…", 0.6)?;
    ffmpeg(
        &binary,
        vec![
            "-i".into(),
            path(&playback),
            "-c:a".into(),
            "libmp3lame".into(),
            "-b:a".into(),
            bitrate.into(),
            path(&temp.join("recording.mp3")),
        ],
    )?;
    let video = meta["hasVideo"].as_bool().unwrap_or(false);
    if video {
        progress("Сохраняю видео MP4…", 0.8)?;
        ffmpeg(
            &binary,
            vec![
                "-i".into(),
                path(&source),
                "-i".into(),
                path(&playback),
                "-map".into(),
                "0:v:0".into(),
                "-map".into(),
                "1:a:0".into(),
                "-c:v".into(),
                "copy".into(),
                "-c:a".into(),
                "aac".into(),
                "-b:a".into(),
                bitrate.into(),
                "-movflags".into(),
                "+faststart".into(),
                path(&temp.join("video.mp4")),
            ],
        )?;
    }
    check_cancelled()?;
    ensure!(
        source_stamp(&regular(&source)?)? == stamp && source_stamp(&input)? == stamp,
        "Исходная запись изменилась. Повторите обработку."
    );
    let _publication_lock = crate::storage::meeting_lock(directory)?;
    check_cancelled()?;
    let mut current = metadata(directory)?;
    ensure!(
        current["source"] == meta["source"]
            && current["hasVideo"] == meta["hasVideo"]
            && current["recordingTracks"] == meta["recordingTracks"]
            && current["recordingAudioQuality"] == meta["recordingAudioQuality"],
        "Настройки записи изменились. Повторите обработку."
    );
    let mut outputs = vec!["recording.mp3", "audio.wav"];
    if dual {
        outputs.extend(["microphone.wav", "system.m4a", "microphone.m4a"]);
    }
    if video {
        outputs.push("video.mp4");
    }
    for name in outputs {
        regular(&temp.join(name))?.sync_all()?;
        fs::rename(temp.join(name), directory.join(name))?;
    }
    current["source"] = json!("recording.mp3");
    current["recordingTracks"] = json!(dual);
    crate::storage::atomic_json(&directory.join("meta.json"), &current)?;
    // A failed deletion only leaves a recoverable redundant source. Never report
    // conversion failure after successful publication of all media and metadata.
    let _ = fs::remove_file(source);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn source_names_cannot_escape_and_finalized_or_imported_media_is_noop() {
        for name in [
            "../recording.mov",
            "/recording.mov",
            "",
            "nested/recording.mov",
        ] {
            assert!(captured_source(&json!({"source":name})).is_err());
        }
        assert_eq!(
            captured_source(&json!({"source":"recording.mov"})).unwrap(),
            Some("recording.mov")
        );
        for name in ["recording.mp3", "source.mp4"] {
            assert_eq!(captured_source(&json!({"source":name})).unwrap(), None);
        }
    }
    #[test]
    fn capture_quality_snapshot_and_legacy_defaults_are_stable() {
        assert_eq!(
            quality(&json!({"recordingAudioQuality":"high"})),
            ("192k", "192k")
        );
        assert_eq!(
            quality(&json!({"recordingAudioQuality":"compact"})),
            ("64k", "64k")
        );
        assert_eq!(
            quality(&json!({"recordingAudioQuality":{"invalid":true}})),
            ("128k", "96k")
        );
    }
    #[test]
    fn pinned_binary_verification_rejects_tamper_and_symlinks() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("media");
        fs::write(&path, b"known").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let sha = format!("{:x}", Sha256::digest(b"known"));
        assert!(verified(&path, 5, &sha));
        assert!(!verified(&path, 4, &sha));
        assert!(!verified(&path, 5, &"0".repeat(64)));
        let link = root.path().join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(!verified(&link, 5, &sha));
    }
}
