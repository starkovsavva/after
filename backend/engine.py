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
import hashlib
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import wave
from collections import defaultdict
from pathlib import Path

MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
SEGMENTATION_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
EMBEDDING_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx"
PROTOCOL = sys.stdout


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


def prepare(root: Path):
    from huggingface_hub import snapshot_download
    progress("Загружаю Parakeet. При первом запуске потребуется интернет…")
    snapshot_download(MODEL, allow_patterns=["*.json", "*.safetensors"])
    speaker_models(root)
    emit("done")


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
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=count if count > 0 else -1, threshold=0.65),
        min_duration_on=0.3, min_duration_off=0.5,
    )
    if not config.validate():
        raise RuntimeError("Модели собеседников повреждены. Повторите установку в настройках.")
    model = sherpa_onnx.OfflineSpeakerDiarization(config)
    previous = -1

    def callback(done, total):
        nonlocal previous
        percent = int(100 * done / max(total, 1))
        if percent != previous:
            previous = percent
            progress(f"Разделяю собеседников · {percent}%", 0.60 + percent * 0.0035)
        return 0

    turns = model.process(read_wave(path), callback=callback).sort_by_start_time()
    names = {}
    result = []
    for turn in turns:
        key = names.setdefault(turn.speaker, f"speaker_{len(names) + 1}")
        result.append({"start": float(turn.start), "end": float(turn.end), "speaker": key})
    return result


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


def transcribe(directory: Path, root: Path, count: int, use_diarization: bool):
    import imageio_ffmpeg
    binary_dir = root / "runtime" / "bin"
    binary_dir.mkdir(parents=True, exist_ok=True)
    alias = binary_dir / "ffmpeg"
    if not alias.exists():
        alias.symlink_to(imageio_ffmpeg.get_ffmpeg_exe())
    os.environ["PATH"] = str(binary_dir) + os.pathsep + os.environ.get("PATH", "")
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
    progress("Загружаю Parakeet для русского и английского…", 0.06)
    with contextlib.redirect_stdout(sys.stderr):
        import mlx.core as mx
        from parakeet_mlx import from_pretrained
        from parakeet_mlx.parakeet import DecodingConfig
        from parakeet_mlx.alignment import SentenceConfig
        model = from_pretrained(MODEL)
    all_tokens = []
    for index, path in enumerate(tracks):
        def callback(done, total):
            fraction = (index + min(done / max(total, 1), 1)) / len(tracks)
            progress(f"Распознаю речь · {int(100 * fraction)}%", 0.08 + 0.50 * fraction)
        progress("Распознаю речь…", 0.08 + 0.50 * index / len(tracks))
        with contextlib.redirect_stdout(sys.stderr):
            result = model.transcribe(path, chunk_duration=120, overlap_duration=15, chunk_callback=callback,
                                      decoding_config=DecodingConfig(sentence=SentenceConfig(max_duration=15, silence_gap=1.2)))
        tokens = [{"text": t.text, "start": float(t.start), "end": float(t.end)} for t in result.tokens]
        all_tokens.append(tokens)
        del result
    del model
    gc.collect()
    mx.clear_cache()
    warnings = []
    turns = []
    if use_diarization:
        progress("Разделяю собеседников…", 0.60)
        try:
            turns = diarize(wav, root, count)
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
    transcript = {"duration": duration, "segments": segments, "warnings": warnings, "model": MODEL}
    atomic(directory / "transcript.json", transcript)
    # A re-transcription invalidates old evidence IDs; preserve existing review history.
    (directory / "summary.json").unlink(missing_ok=True)
    progress("Транскрипция сохранена", 1)
    emit("done", count=len(segments), duration=duration)


WORKER_COMMANDS = ("prepare", "install-local", "finalize", "transcribe")


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
    if args.command in ("finalize", "transcribe") and args.meeting is None:
        parser.error("this command requires --meeting")
    if args.meeting is not None and not args.meeting.is_absolute():
        parser.error("--meeting must be an absolute path")
    if args.speakers < 0:
        parser.error("--speakers must be nonnegative")
    return args


def main():
    args = parse_arguments()
    os.umask(0o077)
    os.environ.setdefault("HF_HOME", str(args.root / "cache" / "huggingface"))
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    if args.command == "prepare":
        prepare(args.root)
    elif args.command == "install-local":
        install_local(args.root)
    elif args.command == "finalize":
        finalize_recording(args.meeting)
        emit("done")
    elif args.command == "transcribe":
        transcribe(args.meeting, args.root, args.speakers, not args.no_diarization)


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
