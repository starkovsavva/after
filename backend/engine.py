#!/usr/bin/env python3
"""Local, one-shot worker. JSONL on stdout; diagnostics on stderr. No listening server.

This worker only handles MLX/ONNX, media files, and model installation.
Meeting AI, HTTP generation, persistence APIs, and spaced repetition live in Rust.
The only network operations here download model/runtime assets.
"""
from __future__ import annotations

import argparse
import contextlib
import gc
import fcntl
import hashlib
import json
import math
import os
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import wave
from collections import defaultdict
from pathlib import Path

sys.dont_write_bytecode = True  # A signed app bundle must remain read-only.
import models as local_models

MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
SEGMENTATION_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
EMBEDDING_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx"
PROTOCOL = sys.stdout
DIARIZATION_THRESHOLD = 0.65
DIARIZATION_WARNING = "Собеседники: "


def emit(event: str, **values):
    print(json.dumps({"event": event, **values}, ensure_ascii=False), file=PROTOCOL, flush=True)


def progress(message: str, fraction: float = -1):
    emit("progress", message=message, fraction=fraction)


def load(path: Path, default=None):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def atomic(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".posle-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, allow_nan=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def download(url: str, target: Path):
    if target.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix(target.suffix + ".part")
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "Posle/0.1"})
        with urllib.request.urlopen(request, timeout=90) as source, partial.open("wb") as out:
            while block := source.read(1024 * 1024):
                out.write(block)
        os.replace(partial, target)
    finally:
        partial.unlink(missing_ok=True)


def speaker_models(root: Path):
    directory = root / "cache" / "speakers"
    segmentation = directory / "sherpa-onnx-pyannote-segmentation-3-0" / "model.onnx"
    if not segmentation.exists():
        progress("Загружаю модель разделения собеседников…")
        archive = directory / "segmentation.tar.bz2"
        download(SEGMENTATION_URL, archive)
        with tarfile.open(archive) as package:
            package.extractall(directory, filter="data")
    embedding = directory / "nemo_en_titanet_small.onnx"
    if not embedding.exists():
        progress("Загружаю модель голосов…")
        download(EMBEDDING_URL, embedding)
    return segmentation, embedding


def resolve_asr(root: Path, allow_download: bool = False):
    selected = local_models.selected_asr(root)
    if selected is not None:
        return selected
    if not allow_download:
        raise RuntimeError("Совместимая модель Parakeet не найдена. Выберите папку модели или установите её в настройках.")
    settings = load(root / "settings.json", {})
    if settings.get("asrModelFormat") == "onnx":
        raise RuntimeError("Локальная ONNX-модель не найдена. Выберите папку Parakeet ONNX или автоматический формат для установки MLX.")
    from huggingface_hub import snapshot_download
    progress("Локальная модель не найдена. Загружаю Parakeet MLX…")
    directory = snapshot_download(MODEL, cache_dir=str(root / "cache/huggingface/hub"),
                                  allow_patterns=["*.json", "*.safetensors"])
    selected = local_models.inspect_model(Path(directory), "После", "mlx")
    if not selected["compatible"]:
        raise RuntimeError("Не удалось подготовить Parakeet: " + selected["reason"])
    return selected


def prepare(root: Path):
    selected = resolve_asr(root, allow_download=True)
    progress(f"Использую скачанную модель Parakeet · {selected['format'].upper()}")
    speaker_models(root)
    emit("done", asrModel=local_models.public_model(selected))


def remove_owned_runtime_aliases(directory: Path):
    """Allow a verified upgrade to replace only our own same-directory aliases."""
    for parent in (directory, directory / "bin"):
        for original, branded in (("ollama", "После ИИ"), ("llama-server", "После Модель")):
            alias = parent / original
            target = parent / branded
            if (alias.is_symlink() and os.readlink(alias) == branded
                    and target.is_file() and not target.is_symlink()):
                alias.unlink()


def install_local(root: Path):
    """Pinned official release with independently recorded SHA256; no global install."""
    directory = root / "runtime" / "ollama"
    marker = directory / "installed-v0.40.3-signed1"
    if marker.exists():
        emit("done")
        return
    progress("Загружаю локальный движок конспекта…")
    archive = root / "cache" / "ollama-darwin-v0.40.3.tgz"
    download("https://github.com/ollama/ollama/releases/download/v0.40.3/ollama-darwin.tgz", archive)
    digest = hashlib.sha256()
    with archive.open("rb") as f:
        while block := f.read(1024 * 1024):
            digest.update(block)
    if digest.hexdigest() != "a2d1d906a2c8febd9cb18f5c183854d0a6db5dc522940d68b0c0ed048e8dfdea":
        archive.unlink(missing_ok=True)
        raise RuntimeError("Проверка загрузки Ollama не прошла. Повторите установку.")
    directory.mkdir(parents=True, exist_ok=True)
    remove_owned_runtime_aliases(directory)
    with tarfile.open(archive) as package:
        package.extractall(directory, filter="data")
    # The official tar release can carry stale arm64 signatures. Its bytes have
    # already passed the pinned SHA256 check. Give Mach-O files local signatures
    # so macOS can run this user-installed, isolated runtime reliably.
    mach_o = {b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce"}
    for binary in directory.rglob("*"):
        if binary.is_symlink() or not binary.is_file():
            continue
        with binary.open("rb") as f:
            magic = f.read(4)
        if magic in mach_o:
            status = subprocess.run(["/usr/bin/codesign", "--verify", str(binary)], capture_output=True)
            if status.returncode:
                subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(binary)], check=True,
                               stdout=sys.stderr, stderr=sys.stderr)
    marker.touch()
    emit("done")


def ffmpeg(*arguments):
    import imageio_ffmpeg
    command = [imageio_ffmpeg.get_ffmpeg_exe(), "-nostdin", "-hide_banner", "-loglevel", "error", "-y", *map(str, arguments)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("Не удалось прочитать аудио: " + result.stderr[-1800:])


def audio_wave(source: Path, target: Path, track: int = 0):
    ffmpeg("-copyts", "-start_at_zero", "-i", source, "-map", f"0:a:{track}", "-vn",
           "-af", "aresample=async=1:first_pts=0", "-ac", 1, "-ar", 16000, "-c:a", "pcm_s16le", target)


def finalize_recording(directory: Path):
    meta = load(directory / "meta.json")
    source = directory / meta["source"]
    if source.name == "recording.mp3" or not source.name.startswith("recording."):
        return
    progress("Сохраняю встречу в MP3…")
    output = directory / "recording.mp3"
    dual = meta.get("recordingTracks", False)
    # Keep common-timeline, lossless intermediates until both aligned tracks are saved.
    system_wave = directory / "audio.wav"
    audio_wave(source, system_wave)
    mic_wave = directory / "microphone.wav"
    if dual:
        try:
            audio_wave(source, mic_wave, 1)
        except RuntimeError:
            dual = False
    if dual:
        ffmpeg("-i", system_wave, "-c:a", "aac", "-b:a", "96k", directory / "system.m4a")
        ffmpeg("-i", mic_wave, "-c:a", "aac", "-b:a", "96k", directory / "microphone.m4a")
        ffmpeg("-i", system_wave, "-i", mic_wave, "-filter_complex",
               "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95:latency=1[a]",
               "-map", "[a]", "-c:a", "libmp3lame", "-b:a", "128k", output)
    else:
        ffmpeg("-i", source, "-vn", "-c:a", "libmp3lame", "-b:a", "128k", output)
    if meta.get("hasVideo", False):
        progress("Сохраняю лёгкое видео MP4…")
        ffmpeg("-i", source, "-i", output, "-map", "0:v:0", "-map", "1:a:0",
               "-c:v", "copy", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", directory / "video.mp4")
    meta["source"] = "recording.mp3"
    meta["recordingTracks"] = dual
    atomic(directory / "meta.json", meta)
    # Both final outputs are saved; the temporary capture container can be removed.
    source.unlink(missing_ok=True)


def read_wave(path: Path):
    import numpy as np
    with wave.open(str(path)) as f:
        if f.getframerate() != 16000 or f.getnchannels() != 1:
            raise ValueError("Ожидается монофайл 16 кГц")
        return np.frombuffer(f.readframes(f.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0


def diarize(path: Path, root: Path, count: int):
    import sherpa_onnx
    segmentation, embedding = speaker_models(root)
    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(segmentation), window_shift_ratio=0.1),
            num_threads=4,
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(embedding), num_threads=4),
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=-1, threshold=DIARIZATION_THRESHOLD),
        min_duration_on=0.3, min_duration_off=0.5,
    )
    if not config.validate():
        raise RuntimeError("Модели собеседников повреждены. Повторите установку в настройках.")
    model = sherpa_onnx.OfflineSpeakerDiarization(config)
    previous, attempt = -1, 0
    samples = read_wave(path)

    def callback(done, total):
        nonlocal previous
        percent = int(100 * done / max(total, 1))
        if percent != previous:
            previous = percent
            message = (f"Уточняю голоса · проверка {attempt} из 4 · {percent}%" if count > 0
                       else f"Разделяю собеседников · {percent}%")
            fraction = 0.60 + (((attempt - 1) + percent / 100) / 4 * 0.35 if count > 0 else percent * 0.0035)
            progress(message, fraction)
        return 0

    def process(clusters):
        nonlocal previous, attempt
        previous, attempt = -1, attempt + 1
        config.clustering.num_clusters = clusters if clusters > 0 else -1
        model.set_config(config)
        return model.process(samples, callback=callback).sort_by_start_time()

    return counted_speaker_turns(process, count)


def counted_speaker_turns(process, count: int):
    """Match audible people, not raw embedding clusters, in at most four passes.

    Sherpa clusters short/noisy window embeddings before voting on actual speech
    frames. Some clusters disappear during that vote. Asking for four embedding
    clusters can therefore merge two real people and produce only three audible
    speakers. Start with automatic output; when a known count needs correction,
    test bounded cluster counts and inspect the final turns after every pass.
    No fabricated identities, forced splitting or hidden truncation is used.
    """
    automatic = process(0)
    identities = {turn.speaker for turn in automatic}
    if count == 0 or len(identities) == count or count == 1:
        return normalized_speaker_turns(automatic, count)
    # Native cluster IDs are zero-based and strictly below the embedding-row
    # count. This observed bound prevents native cutree_k(k > rows), including
    # requests for 100 people on a tiny or silent recording.
    upper = max(identities, default=-1) + 1
    if count > upper:
        return normalized_speaker_turns(automatic, count)
    best = automatic if len(identities) < count else None
    best_count = len(identities) if best is not None else -1
    internal = count
    for _ in range(3):
        candidate = process(internal)
        actual = len({turn.speaker for turn in candidate})
        if actual == count:
            return normalized_speaker_turns(candidate, count)
        if best_count < actual < count:
            best, best_count = candidate, actual
        if actual > count:
            break  # Single-window native path ignores clustering altogether.
        following = min(upper, internal + max(1, count - actual))
        if following <= internal:
            break
        internal = following
    if best is None:
        raise RuntimeError("Модель не смогла соблюсти указанное число участников. Предыдущая транскрипция сохранена; попробуйте более длинную запись.")
    return normalized_speaker_turns(best, count)


def normalized_speaker_turns(turns, count: int):
    """Validate native results, including Sherpa's short-audio special case.

    Sherpa skips clustering for a single segmentation window. For an explicitly
    single speaker, all local slots must still refer to that one identity. For
    larger exact counts, reject an over-count rather than write invented people.
    """
    names = {}
    result = []
    for turn in turns:
        start, end = float(turn.start), float(turn.end)
        if not math.isfinite(start) or not math.isfinite(end) or start < 0 or end <= start:
            raise RuntimeError("Модель собеседников вернула некорректные временные метки.")
        identity = 0 if count == 1 else turn.speaker
        key = names.setdefault(identity, f"speaker_{len(names) + 1}")
        result.append({"start": start, "end": end, "speaker": key})
    if count > 0 and len(names) > count:
        raise RuntimeError("Модель не смогла соблюсти указанное число участников. Предыдущая транскрипция сохранена; попробуйте более длинную запись.")
    return sorted(result, key=lambda turn: (turn["start"], turn["end"]))


def remote_speaker_count(total: int, has_self: bool):
    """The UI specifies all participants; a separately recorded mic is one."""
    return max(1, total - int(has_self)) if total > 0 else 0


def meeting_speaker_turns(path: Path, root: Path, count: int, has_self: bool):
    turns = diarize(path, root, remote_speaker_count(count, has_self))
    if count == 1 and has_self:
        return [dict(turn, speaker="self") for turn in turns]
    return turns


def speaker_diagnostics(segments: list[dict], turns: list[dict], requested: int, enabled: bool = True):
    identities = {segment["speaker"] for segment in segments if segment["speaker"] != "unknown"}
    durations = defaultdict(float)
    for turn in turns:
        durations[turn["speaker"]] += max(0.0, turn["end"] - turn["start"])
    voiced_duration = sum(durations.values())
    short = sum(value < max(3.0, voiced_duration * 0.01) for value in durations.values())
    diagnostics = {"version": 2, "mode": "exact" if requested > 0 else "auto",
                   "requestedCount": requested, "detectedCount": len(identities),
                   "clusteringThreshold": DIARIZATION_THRESHOLD, "shortVoiceCount": short,
                   "enabled": enabled}
    warnings = []
    if enabled and requested == 0 and (len(durations) >= 12 or short >= max(3, math.ceil(len(durations) * 0.4))):
        warnings.append(DIARIZATION_WARNING + f"автоопределение выделило {len(identities)} голосов. Короткие реплики или шум могут разделить одного человека на несколько. Укажите известное число участников кнопкой «Собеседники».")
    if enabled and requested > 0 and len(identities) < requested:
        warnings.append(DIARIZATION_WARNING + f"указано участников: {requested}, в тексте различимо голосов: {len(identities)}. Некоторые участники могли не говорить; проверьте короткие и одновременные реплики.")
    return diagnostics, warnings


def _regular_bytes(path: Path):
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("Данные встречи должны храниться в обычных файлах.")
    return path.read_bytes()


def rediarize(directory: Path, root: Path, count: int):
    """Correct identities without ASR; preserve every evidence ID, time and word."""
    transcript_path, meta_path = directory / "transcript.json", directory / "meta.json"
    original_bytes = _regular_bytes(transcript_path)
    original = json.loads(original_bytes)
    segments = original.get("segments")
    if not isinstance(segments, list) or not segments:
        raise RuntimeError("Сначала создайте транскрипцию этой встречи.")
    meta = json.loads(_regular_bytes(meta_path))
    has_self = bool(meta.get("recordingTracks", False)) and any(segment.get("speaker") == "self" for segment in segments)
    wav = directory / "audio.wav"
    if wav.is_symlink():
        raise RuntimeError("Звуковая дорожка не должна быть символической ссылкой.")
    if not wav.is_file():
        source = directory / ("system.m4a" if meta.get("recordingTracks", False) and (directory / "system.m4a").is_file() else meta["source"])
        if source.parent != directory or source.is_symlink() or not source.is_file():
            raise RuntimeError("Исходная звуковая дорожка не найдена. Предыдущая транскрипция сохранена.")
        progress("Подготавливаю звуковую дорожку…", 0.02)
        audio_wave(source, wav)
    progress("Заново разделяю собеседников…", 0.60)
    turns = meeting_speaker_turns(wav, root, count, has_self)
    if not turns and any(not has_self or segment.get("speaker") != "self" for segment in segments):
        raise RuntimeError("Модель не обнаружила голоса на звуковой дорожке. Предыдущая транскрипция сохранена.")
    updated = dict(original)
    updated_segments = []
    for segment in segments:
        revised = dict(segment)
        if has_self and segment.get("speaker") == "self":
            revised["speaker"], revised["overlap"] = "self", False
        else:
            revised["speaker"], revised["overlap"] = assign_speaker(float(segment["start"]), float(segment["end"]), turns)
        updated_segments.append(revised)
    diagnostics, warnings = speaker_diagnostics(updated_segments, turns, count)
    diagnostics["preservedSegmentBoundaries"] = True
    updated["segments"], updated["diarization"] = updated_segments, diagnostics
    updated["warnings"] = [value for value in original.get("warnings", []) if not value.startswith(DIARIZATION_WARNING) and not value.startswith("Речь сохранена, но разделить собеседников")]
    updated["warnings"].extend(warnings)
    # Old long segments may cross newly discovered turns. Keep existing source
    # links valid rather than inventing word times or silently changing their IDs.
    updated["warnings"].append(DIARIZATION_WARNING + "текст, время и ссылки сохранены. Длинная реплика может содержать несколько голосов; для новых границ реплик создайте транскрипцию заново.")
    if count > 0 and diagnostics["detectedCount"] > count:
        raise RuntimeError("Не удалось соблюсти указанное число участников. Предыдущая транскрипция сохранена.")
    lock_path = directory / ".posle-storage.lock"
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "r+b") as lock:
        # Matches Rust File::lock(), so speaker renames and metadata edits do not
        # race this read-modify-write transaction in a second app window.
        fcntl.flock(lock, fcntl.LOCK_EX)
        if _regular_bytes(transcript_path) != original_bytes:
            raise RuntimeError("Транскрипция изменилась во время обработки. Повторите разделение собеседников.")
        current_meta = json.loads(_regular_bytes(meta_path))
        backup = directory / "diarization-history" / f"{time.time_ns()}-{hashlib.sha256(original_bytes).hexdigest()[:12]}.json"
        if backup.parent.is_symlink():
            raise RuntimeError("Папка истории не должна быть символической ссылкой.")
        atomic(backup, {"transcript": original, "speakerNames": current_meta.get("speakerNames", {})})
        os.chmod(backup.parent, 0o700)
        revised_meta = dict(current_meta)
        revised_meta["speakerNames"] = {key: value for key, value in current_meta.get("speakerNames", {}).items() if key == "self"}
        # Clear old names first: interruption can leave anonymous old labels,
        # but can never falsely attach an old person's name to a new identity.
        atomic(meta_path, revised_meta)
        try:
            atomic(transcript_path, updated)
        except BaseException:
            atomic(meta_path, current_meta)
            raise
    progress("Собеседники обновлены", 1)
    emit("done", speakerCount=diagnostics["detectedCount"], requestedSpeakerCount=count, backup=str(backup))


def assign_speaker(start: float, end: float, turns: list[dict]):
    scores = defaultdict(float)
    for turn in turns:
        if turn["start"] >= end:
            break
        overlap = min(end, turn["end"]) - max(start, turn["start"])
        if overlap > 0:
            scores[turn["speaker"]] += overlap
    ranked = sorted(scores.items(), key=lambda v: v[1], reverse=True)
    if not ranked:
        return "unknown", False
    # Overlap remains visible instead of presenting a guessed identity as certain.
    ambiguous = len(ranked) > 1 and ranked[1][1] > ranked[0][1] * 0.55
    return ("unknown" if ambiguous else ranked[0][0]), ambiguous


def group_tokens(tokens: list[dict], turns: list[dict], fixed_speaker: str | None = None):
    # Assign whole words, not BPE pieces, to avoid midword speaker switches.
    words = []
    for token in tokens:
        if not words or token["text"].startswith(" "):
            words.append(dict(token))
        else:
            words[-1]["text"] += token["text"]
            words[-1]["end"] = token["end"]
    result = []
    for word in words:
        speaker, overlap = (fixed_speaker, False) if fixed_speaker else assign_speaker(word["start"], word["end"], turns)
        if not word["text"].strip():
            continue
        if (result and result[-1]["speaker"] == speaker and result[-1]["overlap"] == overlap
                and word["start"] - result[-1]["end"] < 1.8 and word["end"] - result[-1]["start"] < 18
                and len(result[-1]["text"]) < 430):
            result[-1]["text"] += word["text"]
            result[-1]["end"] = word["end"]
        else:
            result.append({"id": 0, "start": word["start"], "end": word["end"], "speaker": speaker,
                           "overlap": overlap, "text": word["text"]})
    for segment in result:
        segment["text"] = segment["text"].strip()
    return result


def chunk_windows(duration: float, length: float = 20, overlap: float = 2):
    """Overlapping, bounded ONNX chunks with disjoint ownership of timestamps."""
    spans = []
    start = 0.0
    while start < duration:
        end = min(start + length, duration)
        spans.append((start, end))
        if end >= duration:
            break
        start += length - overlap
    return [(start, end,
             0.0 if index == 0 else (spans[index - 1][1] + start) / 2,
             duration if index == len(spans) - 1 else (end + spans[index + 1][0]) / 2)
            for index, (start, end) in enumerate(spans)]


def timestamp_tokens(texts, timestamps, duration: float, durations=None):
    """Keep runtime token starts; derive bounded, approximate token ends."""
    if not texts:
        return []
    if timestamps is None or len(texts) != len(timestamps):
        raise RuntimeError("ONNX-модель не вернула временные метки токенов")
    starts = [float(value) for value in timestamps]
    if any(not math.isfinite(value) or value < 0 or value > duration + 0.5 for value in starts):
        raise RuntimeError("ONNX-модель вернула некорректные временные метки")
    if starts != sorted(starts):
        raise RuntimeError("ONNX-модель вернула несогласованные временные метки")
    durations = list(durations) if durations is not None else []
    exact_durations = len(durations) == len(texts) and all(math.isfinite(float(value)) and float(value) >= 0 for value in durations)
    result = []
    for index, (text, start) in enumerate(zip(texts, starts)):
        start = min(start, duration)
        next_start = next((value for value in starts[index + 1:] if value > start), start + 0.16)
        end = (min(duration, start + float(durations[index])) if exact_durations
               else min(duration, start + 0.8, max(start + 0.08, next_start)))
        result.append({"text": str(text).replace("▁", " "), "start": start, "end": max(start, end)})
    return result


def owned_chunk_words(tokens, offset: float, left: float, right: float, final: bool):
    """Ownership applies to whole words, so BPE pieces do not duplicate at joins."""
    words = []
    for token in tokens:
        token = dict(token)
        token["start"] += offset
        token["end"] += offset
        if not words or token["text"].startswith(" "):
            words.append(token)
        else:
            words[-1]["text"] += token["text"]
            words[-1]["end"] = max(words[-1]["end"], token["end"])
    kept = []
    for word in words:
        center = (word["start"] + word["end"]) / 2
        if center >= left and (center < right or final and center <= right):
            # Every item is a complete word; retain an explicit word boundary for
            # group_tokens, including the first word of a following chunk.
            word["text"] = " " + word["text"].lstrip()
            kept.append(word)
    return kept


class ASRAdapter:
    """MLX, Sherpa transducer, or maintained onnx-asr for Meetily NeMo TDT."""
    def __init__(self, selected: dict, root: Path):
        self.selected = selected
        self.model = None
        self.wrapper = None
        self.mx = None
        files = selected["files"]
        if selected["layout"] == "mlx":
            import mlx.core as mx
            from parakeet_mlx import from_pretrained
            self.mx = mx
            # An absolute local directory makes from_pretrained bypass HF lookup.
            self.model = from_pretrained(selected["path"])
        elif selected["layout"] == "sherpa-onnx":
            import sherpa_onnx
            self.model = sherpa_onnx.OfflineRecognizer.from_transducer(
                encoder=files["encoder"], decoder=files["decoder"], joiner=files["joiner"],
                tokens=files["tokens"], num_threads=4, sample_rate=16000, feature_dim=128,
                model_type="nemo_transducer", provider="cpu", decoding_method="greedy_search")
        else:
            try:
                import onnx_asr
                import onnxruntime
            except ImportError as exc:
                raise RuntimeError("Для модели ONNX обновите среду кнопкой «Подготовить распознавание» в настройках. Веса Parakeet повторно скачиваться не будут.") from exc
            # Meetily omits onnx-asr's tiny config.json. Supply a private wrapper
            # with symlinks to original weights; do not edit or copy their GB data.
            wrapper_parent = root / "cache/model-config"
            wrapper_parent.mkdir(parents=True, exist_ok=True)
            self.wrapper = tempfile.TemporaryDirectory(prefix="parakeet-", dir=wrapper_parent)
            directory = Path(self.wrapper.name)
            for key, name in (("encoder", "encoder-model.onnx"), ("decoder", "decoder_joint-model.onnx"), ("tokens", "vocab.txt")):
                (directory / name).symlink_to(Path(files[key]).absolute())
            for model_file in (Path(files["encoder"]), Path(files["decoder"])):
                for suffix in (".data", "_data"):
                    data = model_file.with_name(model_file.name + suffix)
                    if data.is_file():
                        (directory / data.name).symlink_to(data.absolute())
            atomic(directory / "config.json", {"model_type": "nemo-conformer-tdt", "features_size": 128,
                                               "subsampling_factor": 8, "max_tokens_per_step": 3})
            options = onnxruntime.SessionOptions()
            options.intra_op_num_threads = 4
            options.inter_op_num_threads = 1
            options.enable_cpu_mem_arena = False
            # The model type has no remote repository and the existing local path
            # forces Resolver.offline=True in onnx-asr. No network fallback.
            self.model = onnx_asr.load_model("nemo-conformer-tdt", path=directory,
                                            sess_options=options, providers=["CPUExecutionProvider"],
                                            preprocessor_config={"use_numpy_preprocessors": True}).with_timestamps()

    def transcribe(self, path: Path, callback):
        if self.selected["layout"] == "mlx":
            from parakeet_mlx.parakeet import DecodingConfig
            from parakeet_mlx.alignment import SentenceConfig
            result = self.model.transcribe(path, chunk_duration=120, overlap_duration=15, chunk_callback=callback,
                                           decoding_config=DecodingConfig(sentence=SentenceConfig(max_duration=15, silence_gap=1.2)))
            return [{"text": token.text, "start": float(token.start), "end": float(token.end)} for token in result.tokens]
        import numpy as np
        all_tokens = []
        with wave.open(str(path)) as source:
            rate = source.getframerate()
            if rate != 16000 or source.getnchannels() != 1 or source.getsampwidth() != 2:
                raise RuntimeError("ONNX ожидает PCM 16 бит, моно 16 кГц")
            duration = source.getnframes() / rate
            windows = chunk_windows(duration)
            for index, (start, end, left, right) in enumerate(windows):
                source.setpos(round(start * rate))
                audio = np.frombuffer(source.readframes(round((end - start) * rate)), dtype=np.int16).astype(np.float32) / 32768.0
                if self.selected["layout"] == "sherpa-onnx":
                    stream = self.model.create_stream()
                    stream.accept_waveform(rate, audio)
                    self.model.decode_stream(stream)
                    result = stream.result
                else:
                    result = self.model.recognize(audio, sample_rate=rate)
                tokens = timestamp_tokens(result.tokens, result.timestamps, len(audio) / rate, getattr(result, "durations", None))
                if result.text.strip() and not tokens:
                    raise RuntimeError("ONNX распознала текст без токенов и временных меток")
                all_tokens.extend(owned_chunk_words(tokens, start, left, right, index == len(windows) - 1))
                callback(index + 1, len(windows))
        return all_tokens

    def close(self):
        self.model = None
        gc.collect()
        if self.mx is not None:
            self.mx.clear_cache()
        if self.wrapper is not None:
            self.wrapper.cleanup()
            self.wrapper = None


def transcribe(directory: Path, root: Path, count: int, use_diarization: bool):
    finalize_recording(directory)
    meta = load(directory / "meta.json")
    source = directory / meta["source"]
    wav = directory / "audio.wav"
    progress("Подготавливаю звуковую дорожку…", 0.02)
    multitrack = meta.get("recordingTracks", False) and (directory / "system.m4a").exists()
    audio_wave(directory / "system.m4a" if multitrack else source, wav)
    tracks = [wav]
    if multitrack:
        mic = directory / "microphone.wav"
        try:
            audio_wave(directory / "microphone.m4a", mic)
            tracks.append(mic)
        except RuntimeError:
            multitrack = False
    if source.name != "recording.mp3":
        if source.suffix.lower() == ".mp3":
            ffmpeg("-i", source, "-vn", "-c:a", "copy", directory / "playback.mp3")
        else:
            ffmpeg("-i", wav, "-c:a", "libmp3lame", "-b:a", "128k", directory / "playback.mp3")
    duration = 0.0
    for track in tracks:
        with wave.open(str(track)) as f:
            duration = max(duration, f.getnframes() / f.getframerate())
    if duration < 0.2:
        raise RuntimeError("Запись слишком короткая. Добавьте файл с речью.")
    selected = resolve_asr(root)
    progress(f"Загружаю выбранный Parakeet · {selected['format'].upper()}…", 0.06)
    with contextlib.redirect_stdout(sys.stderr):
        adapter = ASRAdapter(selected, root)
    all_tokens = []
    warnings = []
    if "v2" in selected["path"].lower():
        warnings.append("Выбран Parakeet v2: эта модель поддерживает только английский. Для русского выберите v3.")
    if selected["format"] == "onnx":
        warnings.append("ONNX возвращает начала токенов; время окончания слов приблизительное.")
    try:
        for index, path in enumerate(tracks):
            def callback(done, total):
                fraction = (index + min(done / max(total, 1), 1)) / len(tracks)
                progress(f"Распознаю речь · {int(100 * fraction)}%", 0.08 + 0.50 * fraction)
            progress("Распознаю речь…", 0.08 + 0.50 * index / len(tracks))
            with contextlib.redirect_stdout(sys.stderr):
                all_tokens.append(adapter.transcribe(path, callback))
    finally:
        adapter.close()
    turns = []
    if use_diarization:
        progress("Разделяю собеседников…", 0.60)
        try:
            turns = meeting_speaker_turns(wav, root, count, multitrack and bool(all_tokens[1]))
        except Exception as exc:
            warnings.append(f"Речь сохранена, но разделить собеседников не удалось: {exc}")
    segments = group_tokens(all_tokens[0], turns)
    if multitrack:
        segments += group_tokens(all_tokens[1], [], fixed_speaker="self")
    segments.sort(key=lambda s: (s["start"], s["end"]))
    for index, segment in enumerate(segments):
        segment["id"] = index
    if not segments:
        warnings.append("Речь не обнаружена. Проверьте источник звука или выберите другой участок записи.")
    diagnostics, speaker_warnings = speaker_diagnostics(segments, turns, count, enabled=use_diarization)
    warnings.extend(speaker_warnings)
    transcript = {"duration": duration, "segments": segments, "warnings": warnings, "diarization": diagnostics, "model": selected["name"],
                  "modelFormat": selected["format"], "modelPath": selected["path"]}
    atomic(directory / "transcript.json", transcript)
    # A re-transcription invalidates old evidence IDs; preserve existing review history.
    (directory / "summary.json").unlink(missing_ok=True)
    progress("Транскрипция сохранена", 1)
    emit("done", count=len(segments), duration=duration)


WORKER_COMMANDS = ("prepare", "install-local", "finalize", "transcribe", "diarize", "discover-models")


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description="Local ASR and audio processing worker")
    parser.add_argument("command", choices=WORKER_COMMANDS)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--meeting", type=Path)
    parser.add_argument("--speakers", type=int, default=0)
    parser.add_argument("--no-diarization", action="store_true")
    args = parser.parse_args(argv)
    if not args.root.is_absolute():
        parser.error("--root must be an absolute path")
    if args.command in ("finalize", "transcribe", "diarize") and args.meeting is None:
        parser.error("this command requires --meeting")
    if args.meeting is not None and not args.meeting.is_absolute():
        parser.error("--meeting must be an absolute path")
    if not 0 <= args.speakers <= 100:
        parser.error("--speakers must be between 0 (automatic) and 100")
    return args


def main():
    args = parse_arguments()
    os.umask(0o077)
    os.environ.setdefault("HF_HOME", str(args.root / "cache" / "huggingface"))
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    if args.command in ("prepare", "transcribe", "finalize", "diarize"):
        from media_runtime import configure
        configure(args.root)
    if args.command == "prepare":
        prepare(args.root)
    elif args.command == "install-local":
        install_local(args.root)
    elif args.command == "finalize":
        finalize_recording(args.meeting)
        emit("done")
    elif args.command == "transcribe":
        transcribe(args.meeting, args.root, args.speakers, not args.no_diarization)
    elif args.command == "diarize":
        rediarize(args.meeting, args.root, args.speakers)
    elif args.command == "discover-models":
        found, notes = local_models.discover_asr(args.root)
        emit("done", asrModels=[local_models.public_model(model) for model in found], notes=notes)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        emit("error", message="Обработка остановлена. Исходная запись сохранена.")
        sys.exit(130)
    except Exception as exc:
        message = str(exc)
        emit("error", message=message[:2000])
        sys.exit(1)
