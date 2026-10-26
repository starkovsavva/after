"""Short, explicit dictation through the selected ASR, without a meeting record.

The caller owns and removes the input session. This module never persists text,
changes settings, downloads models or starts microphone capture.
"""
from __future__ import annotations

import math
import os
from pathlib import Path
import stat
import tempfile
import uuid
import wave

MAX_SECONDS = 180
MAX_INPUT_BYTES = 32 * 1024 * 1024


def validate_input(root: Path, value) -> Path:
    if not isinstance(value, str):
        raise RuntimeError("Не выбрана запись голосового поручения.")
    audio = Path(value)
    sessions = root / "voice-inputs"
    if (not audio.is_absolute() or ".." in audio.parts or audio.parent.parent != sessions
            or sessions.is_symlink() or audio.parent.is_symlink() or audio.is_symlink()
            or audio.suffix.lower() not in (".wav", ".m4a", ".aac", ".mp3", ".caf")):
        raise RuntimeError("Голосовое поручение должно находиться в собственной папке приложения.")
    try:
        uuid.UUID(audio.parent.name)
        info = audio.stat(follow_symlinks=False)
    except (ValueError, OSError):
        raise RuntimeError("Не удалось открыть запись голосового поручения.") from None
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
            or not 0 < info.st_size <= MAX_INPUT_BYTES):
        raise RuntimeError("Нужна собственная аудиозапись размером до 32 МБ.")
    return audio


def _segments(values, duration):
    result = []
    for index, value in enumerate(values):
        try:
            start, end, text = float(value["start"]), float(value["end"]), value["text"]
        except (KeyError, TypeError, ValueError):
            raise RuntimeError("Модель вернула некорректную диктовку.") from None
        if (not isinstance(text, str) or not math.isfinite(start) or not math.isfinite(end)
                or start < 0 or end < start or end > duration + 0.5):
            raise RuntimeError("Модель вернула некорректную диктовку.")
        if text.strip():
            result.append({"id": index, "start": min(start, duration), "end": min(end, duration),
                           "text": text.strip(), "speaker": "self", "overlap": False})
    if sum(len(segment["text"]) for segment in result) > 20_000:
        raise RuntimeError("Диктовка слишком длинная. Сформулируйте поручение короче.")
    return result


def transcribe(root: Path, audio: Path, settings: dict, key: str | None, check, emit):
    import engine
    mode = settings.get("speechMode", "local")
    if mode not in ("local", "cloud"):
        raise RuntimeError("Выберите локальное или облачное распознавание в настройках.")
    if mode == "cloud":
        import cloud_speech
        # Validate before reading or transmitting the source. The credential is
        # explicit memory only; the app's environment and settings stay intact.
        cloud_speech.endpoint(settings)
        cloud_speech.request_fields(settings)
        if not key or not isinstance(key, str) or len(key) > 16_000 or any(c in key for c in "\r\n"):
            raise RuntimeError("Добавьте ключ распознавания в настройках.")
    check()
    emit("progress", message="Подготавливаю диктовку…", fraction=0.03)
    # Private generated output cannot replace any app data or follow a supplied
    # path. Decode only a bounded interval; longer sources are explicitly refused.
    with tempfile.TemporaryDirectory(prefix=".dictation-", dir=audio.parent) as temporary:
        # Hold the original regular file open without following a late symlink,
        # then decode our private snapshot rather than reopening a mutable path.
        descriptor = os.open(audio, os.O_RDONLY | os.O_NOFOLLOW)
        snapshot = Path(temporary) / ("input" + audio.suffix.lower())
        with os.fdopen(descriptor, "rb") as source:
            info = os.fstat(source.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
                    or not 0 < info.st_size <= MAX_INPUT_BYTES):
                raise RuntimeError("Не удалось открыть собственную запись поручения.")
            with snapshot.open("xb") as target:
                total = 0
                while block := source.read(128 * 1024):
                    check()
                    total += len(block)
                    if total > MAX_INPUT_BYTES:
                        raise RuntimeError("Запись поручения превышает 32 МБ.")
                    target.write(block)
        wav = Path(temporary) / "audio.wav"
        engine.ffmpeg("-i", snapshot, "-map", "0:a:0", "-vn", "-t", str(MAX_SECONDS + 0.05),
                      "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav)
        check()
        with wave.open(str(wav), "rb") as source:
            if source.getnchannels() != 1 or source.getsampwidth() != 2 or source.getframerate() != 16000:
                raise RuntimeError("Не удалось подготовить диктовку.")
            duration = source.getnframes() / source.getframerate()
        if not 0.2 <= duration <= MAX_SECONDS:
            raise RuntimeError("Диктовка должна длиться от 0,2 секунды до 3 минут.")
        warnings = []
        def progress(done, total):
            check()
            emit("progress", message="Распознаю поручение…", fraction=0.1 + 0.85 * min(done / max(total, 1), 1))
        if mode == "cloud":
            def upload(path, selected, credential):
                check()
                result = cloud_speech.upload(path, selected, credential, timeout=30)
                check()
                return result
            values, warnings, _ = cloud_speech.transcribe(wav, root, settings, progress, key=key, uploader=upload)
            model = settings.get("speechCloudModel", "gpt-transcribe")
        else:
            selected = engine.resolve_asr(root, allow_download=False)
            check()
            emit("progress", message=f"Загружаю {selected['name']}…", fraction=0.08)
            adapter = engine.ASRAdapter(selected, root)
            try:
                check()
                tokens = adapter.transcribe(wav, progress)
                check()
                values = engine.group_tokens(tokens, [], fixed_speaker="self")
            finally:
                adapter.close()
            model = selected["name"]
            if "v2" in selected.get("path", "").lower():
                warnings.append("Parakeet v2 распознаёт только английский. Для русского выберите v3.")
        check()
        segments = _segments(values, duration)
        text = " ".join(segment["text"] for segment in segments)
        if not text:
            raise RuntimeError("Речь не обнаружена. Попробуйте продиктовать поручение ещё раз.")
        check()
    # The input and existing library are never mutated, including on cancel.
    emit("done", text=text, segments=segments, duration=duration, model=model, warnings=warnings, pid=os.getpid())
