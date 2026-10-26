"""Serialized, persistent ASR inside the native app's own process.

No sys.stdout/stderr redirection, os.environ mutation, interpreter shutdown,
background server or implicit model download. Native callbacks carry progress.
"""
from __future__ import annotations

import contextlib
import ctypes
import gc
import importlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from types import SimpleNamespace
import wave

_SESSION = 0


class Cancelled(BaseException):
    """Cannot be swallowed by optional diarization's except Exception handler."""


def _safe_environment(values):
    fragments = ("API_KEY", "ACCESS_KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "COOKIE")
    return {key: value for key, value in values.items()
            if not any(fragment in key.upper() for fragment in fragments)
            and key not in ("PYTHONHOME", "PYTHONPATH", "PYTHONEXECUTABLE", "__PYVENV_LAUNCHER__")}


def _media(root: Path):
    """Locate only the dependency inside this runtime, ignoring ambient overrides."""
    import imageio_ffmpeg
    from imageio_ffmpeg._definitions import FNAME_PER_PLATFORM, get_platform
    from media_runtime import install
    source = Path(imageio_ffmpeg.__file__).resolve().parent / "binaries" / FNAME_PER_PLATFORM[get_platform()]
    venv = (root / "runtime/venv").resolve(strict=True)
    if not source.resolve(strict=True).is_relative_to(venv):
        raise RuntimeError("Не найдены собственные компоненты обработки аудио.")
    return install(source, root)


def _pcm_numpy_audio(path, sample_rate=16000, **_):
    import numpy as np
    from engine import read_pcm_frames
    with wave.open(str(path)) as audio:
        if audio.getnchannels() != 1 or audio.getsampwidth() != 2 or audio.getframerate() != sample_rate:
            raise RuntimeError("Для распознавания нужна подготовленная дорожка PCM 16 бит, моно 16 кГц.")
        return np.frombuffer(read_pcm_frames(audio, audio.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0


def _pcm_mlx_audio(path, sampling_rate, dtype=None):
    import mlx.core as mx
    return mx.array(_pcm_numpy_audio(path, sampling_rate))


def _patch_audio_loaders(selected):
    """Prepared PCM needs no nested ffmpeg or process-global PATH change."""
    if selected["layout"] == "mlx":
        import parakeet_mlx.parakeet
        parakeet_mlx.parakeet.load_audio = _pcm_mlx_audio


def _validate(request):
    root = Path(request["root"])
    if not root.is_absolute() or ".." in root.parts or root.is_symlink():
        raise RuntimeError("Нужна собственная папка данных приложения.")
    command = request.get("command")
    if command not in ("transcribe", "diarize", "finalize", "probe", "dictate"):
        raise RuntimeError("Эта команда не поддерживается встроенным распознаванием.")
    if command == "probe":
        return root, None, command
    if command == "dictate":
        from short_speech import validate_input
        if (root / "settings.json").is_symlink():
            raise RuntimeError("Настройки не должны быть символической ссылкой.")
        return root, validate_input(root, request.get("audio")), command
    meeting = Path(request["meeting"])
    if not meeting.is_absolute() or meeting.parent != root / "meetings" or (root / "meetings").is_symlink() or meeting.is_symlink() or not meeting.is_dir():
        raise RuntimeError("Встреча должна находиться в библиотеке приложения.")
    meta_path = meeting / "meta.json"
    if meta_path.is_symlink() or not meta_path.is_file():
        raise RuntimeError("Не удалось открыть данные встречи.")
    meta = json.loads(meta_path.read_text())
    source = meta.get("source", "")
    if not source or Path(source).name != source:
        raise RuntimeError("Недопустимый путь записи встречи.")
    if not isinstance(request.get("speakers", 0), int) or not 0 <= request.get("speakers", 0) <= 100:
        raise RuntimeError("Укажите число участников от 0 до 100.")
    for name in (source, "audio.wav", "microphone.wav", "system.m4a", "microphone.m4a", "playback.mp3", "recording.mp3", "video.mp4", "transcript.json", "summary.json"):
        if (meeting / name).is_symlink():
            raise RuntimeError("Данные встречи не должны быть символическими ссылками.")
    return root, meeting, command


def run(raw: str) -> str:
    global _SESSION
    request = json.loads(raw)
    event_pointer = int(request.get("eventCallback", 0))
    event = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_void_p)(event_pointer) if event_pointer else None
    cancel_pointer = int(request.get("cancelCallback", 0))
    cancelled = ctypes.CFUNCTYPE(ctypes.c_int)(cancel_pointer) if cancel_pointer else lambda: 0
    context = ctypes.c_void_p(int(request.get("eventContext", 0)))
    last_done = None
    committing = False
    environment = _safe_environment(os.environ)
    secrets = [value for name, value in os.environ.items() if name not in environment and (len(value) >= 4 or name == "POSLE_SPEECH_API_KEY" and value)]

    if isinstance(request.get("apiKey"), str) and request["apiKey"]:
        secrets.append(request["apiKey"])

    def check():
        # A publication transaction is a short, non-cancellable checkpoint.
        # Never interrupt metadata rollback or report a fully saved result as cancelled.
        if not committing and cancelled():
            raise Cancelled()

    def emit(kind, **values):
        nonlocal last_done
        check()
        payload = {"event": kind, **values}
        if kind == "done":
            last_done = payload
        if event is not None:
            event(json.dumps(payload, ensure_ascii=False).encode(), context)

    restored = []
    settings_token = None
    settings_context = None
    def replace(module, name, value):
        restored.append((module, name, getattr(module, name)))
        setattr(module, name, value)

    try:
        root, meeting, command = _validate(request)
        check()
        _SESSION += 1
        if command == "probe":
            memory = {}
            if "mlx.core" in sys.modules:
                mx = sys.modules["mlx.core"]
                memory = {"mlxActiveBytes": mx.get_active_memory(), "mlxCacheBytes": mx.get_cache_memory()}
            emit("done", pid=os.getpid(), session=_SESSION, python=sys.version.split()[0], **memory)
            return json.dumps({"ok": True, "value": last_done})
        import engine
        snapshot = request.get("settings")
        if snapshot is not None:
            if not isinstance(snapshot, dict) or len(json.dumps(snapshot)) > 262144:
                raise RuntimeError("Некорректные настройки задания.")
            original_load = engine.load
            replace(engine, "load", lambda path, default=None: snapshot if path == root / "settings.json" else original_load(path, default))
            settings_context = engine.local_models.SETTINGS_OVERRIDE
            settings_token = settings_context.set(snapshot)
            original_json = engine.local_models._json
            replace(engine.local_models, "_json", lambda path: snapshot if path == root / "settings.json" else original_json(path))
        settings = engine.load(root / "settings.json", {})
        if command == "transcribe" and settings.get("speechMode", "local") != "local":
            raise RuntimeError("Для облачного распознавания выберите облачный обработчик.")
        media = _media(root)
        environment["IMAGEIO_FFMPEG_EXE"] = str(media)
        environment["HF_HUB_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["HF_HOME"] = str(root / "cache/huggingface")
        original_popen = subprocess.Popen
        def safe_popen(*arguments, **options):
            check()
            options["env"] = _safe_environment(options.get("env") or environment)
            return original_popen(*arguments, **options)
        replace(subprocess, "Popen", safe_popen)

        def ffmpeg(*arguments):
            check()
            process = original_popen([str(media), "-nostdin", "-hide_banner", "-loglevel", "error", "-y", *map(str, arguments)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, start_new_session=True)
            try:
                while True:
                    try:
                        output, errors = process.communicate(timeout=0.1)
                        break
                    except subprocess.TimeoutExpired:
                        check()
                check()
                if process.returncode:
                    raise RuntimeError("Не удалось прочитать аудио: " + errors.decode(errors="replace")[-1800:])
            finally:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    try:
                        process.communicate(timeout=0.8)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.communicate()
        replace(engine, "ffmpeg", ffmpeg)
        replace(engine, "emit", emit)
        # engine's subprocess protocol redirects stdout around MLX. Embedded
        # callbacks do not need it; leave the app's Python stdio untouched.
        replace(engine, "contextlib", SimpleNamespace(redirect_stdout=lambda _: contextlib.nullcontext()))
        original_publication = engine.publication
        @contextlib.contextmanager
        def publication():
            nonlocal committing
            check()
            previous, committing = committing, True
            try:
                with original_publication():
                    yield
                # Finalization has no subprocess event of its own. Confirm its
                # committed metadata before cancellation becomes observable.
                if command == "finalize":
                    emit("done")
            finally:
                committing = previous
        replace(engine, "publication", publication)
        original_resolve = engine.resolve_asr
        def resolve(root, allow_download=False):
            check()
            selected = original_resolve(root, allow_download=False)
            _patch_audio_loaders(selected)
            return selected
        replace(engine, "resolve_asr", resolve)
        original_speaker_models = engine.speaker_models
        def speaker_models(root):
            check()
            if not engine.speaker_models_installed(root):
                raise RuntimeError("Подготовьте модели разделения собеседников в настройках.")
            return original_speaker_models(root)
        replace(engine, "speaker_models", speaker_models)
        if command == "dictate":
            from short_speech import transcribe as dictate
            dictate(root, meeting, settings, request.get("apiKey"), check, emit)
        elif command == "transcribe":
            engine.transcribe(meeting, root, request.get("speakers", 0), request.get("diarization", True))
        elif command == "diarize":
            engine.rediarize(meeting, root, request.get("speakers", 0))
        else:
            engine.finalize_recording(meeting)
            # Already finalized/imported media is an idempotent no-op and has
            # no publication context; still acknowledge the successful run.
            if last_done is None:
                emit("done")
        if last_done is None:
            raise RuntimeError("Модуль не подтвердил сохранение результата.")
        return json.dumps({"ok": True, "value": last_done}, ensure_ascii=False)
    except Cancelled:
        return json.dumps({"ok": False, "cancelled": True, "error": "Обработка остановлена. Исходная запись сохранена."}, ensure_ascii=False)
    except BaseException as error:
        message = str(error) or "Не удалось завершить распознавание. Исходная запись сохранена."
        for secret in secrets:
            message = message.replace(secret, "[hidden]")
        return json.dumps({"ok": False, "error": message[:2000]}, ensure_ascii=False)
    finally:
        if settings_token is not None:
            settings_context.reset(settings_token)
        for module, name, original in reversed(restored):
            setattr(module, name, original)
        gc.collect()
        if "mlx.core" in sys.modules:
            mx = sys.modules["mlx.core"]
            try:
                mx.synchronize()
                mx.clear_cache()
            except Exception:
                pass
        # Do not restore os.environ: the bridge never mutates it, and changing
        # process environment during a Swift/Rust operation would be unsafe.
