"""Brand the app-owned FFmpeg executable without changing installed packages."""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile


def _sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def install(source: Path, root: Path) -> Path:
    """Copy a verified dependency locally; never follow a foreign target link."""
    source = source.resolve(strict=True)
    if not source.is_file() or not os.access(source, os.X_OK):
        raise RuntimeError("Не найден установленный движок обработки аудио. Подготовьте распознавание в настройках.")
    runtime = root / "runtime"
    target_dir = runtime / "media"
    for directory in (runtime, target_dir):
        if directory.is_symlink():
            raise RuntimeError("Папка обработки аудио не должна быть ссылкой.")
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    target = target_dir / "После Медиа"
    marker = target_dir / "source.json"
    lock = target_dir / ".identity.lock"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(lock, flags, 0o600), "r+") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise RuntimeError("Не удалось подготовить обработку аудио.")
        fcntl.flock(stream, fcntl.LOCK_EX)
        if target.is_symlink() or marker.is_symlink():
            raise RuntimeError("Файлы обработки аудио не должны быть ссылками.")
        source_stat = source.stat()
        identity = {"source": str(source), "size": source_stat.st_size, "mtime": source_stat.st_mtime_ns,
                    "sha256": _sha256(source)}
        try:
            current = json.loads(marker.read_text())
        except (OSError, ValueError):
            current = None
        if current == identity and target.is_file() and target.stat().st_size == source_stat.st_size and os.access(target, os.X_OK):
            # Size and timestamps cannot detect a damaged private copy. Compare
            # its bytes with the installed dependency so Prepare can repair it.
            try:
                if _sha256(target) == identity["sha256"]:
                    return target
            except OSError:
                pass
        temporary = None
        try:
            fd, temporary = tempfile.mkstemp(prefix=".media-", dir=target_dir)
            with os.fdopen(fd, "wb") as output, source.open("rb") as original:
                shutil.copyfileobj(original, output)
                output.flush()
                os.fsync(output.fileno())
                os.fchmod(output.fileno(), 0o700)
            os.replace(temporary, target)
            temporary = None
            # The executable bytes (including its existing code signature) are
            # unchanged. A later package upgrade replaces this private copy.
            fd, temporary = tempfile.mkstemp(prefix=".source-", dir=target_dir)
            with os.fdopen(fd, "w") as output:
                json.dump(identity, output)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, marker)
            temporary = None
        finally:
            if temporary is not None:
                Path(temporary).unlink(missing_ok=True)
    return target


def configure(root: Path) -> Path:
    for directory in (root / "runtime", root / "runtime/venv", root / "runtime/venv/bin"):
        if directory.is_symlink():
            raise RuntimeError("Среда распознавания должна находиться в собственной папке After. Подготовьте её в настройках.")
    import imageio_ffmpeg
    # Only the dependency installed in this private runtime is copied. Ambient
    # overrides must not redirect app-owned executable setup to another app.
    os.environ.pop("IMAGEIO_FFMPEG_EXE", None)
    source = Path(imageio_ffmpeg.get_ffmpeg_exe()).resolve(strict=True)
    venv = (root / "runtime/venv").resolve(strict=True)
    if not source.is_relative_to(venv):
        raise RuntimeError("Не найден собственный движок аудио. Подготовьте распознавание в настройках.")
    target = install(source, root)
    binary_dir = target.parent / "bin"
    if binary_dir.is_symlink():
        raise RuntimeError("Папка обработки аудио не должна быть ссылкой.")
    binary_dir.mkdir(mode=0o700, exist_ok=True)
    alias = binary_dir / "ffmpeg"
    expected = "../" + target.name
    if alias.is_symlink():
        if os.readlink(alias) != expected:
            raise RuntimeError("Не удалось подготовить собственный движок аудио.")
    elif alias.exists():
        raise RuntimeError("Не удалось подготовить собственный движок аудио.")
    else:
        alias.symlink_to(expected)
    os.environ["IMAGEIO_FFMPEG_EXE"] = str(target)
    os.environ["PATH"] = str(binary_dir) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin")
    return target
