#!/usr/bin/env python3
"""Real CLI media finalization, using generated tones/video and an owned runtime.

    python3 scripts/e2e_media.py --python .test-data/runtime/venv/bin/python \
        --engine /private/tmp/posle-rust-build/debug/posle-engine --keep

No microphone, screen, user media, network, model, Keychain or TCC access. The
provided Python is queried read-only for its base and bundled imageio-ffmpeg.
A minimal runtime is copied into a newly created fixture; foreign symlinks and
writes to the donor runtime/settings are forbidden. No backend implementation is
imported or patched: conversion runs through the actual posle-engine CLI.
"""
from __future__ import annotations

import argparse
import array
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import wave

PROJECT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def clean_environment():
    secrets = ("API_KEY", "ACCESS_KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "COOKIE")
    overrides = {"PYTHONHOME", "PYTHONPATH", "PYTHONEXECUTABLE", "__PYVENV_LAUNCHER__", "IMAGEIO_FFMPEG_EXE"}
    return {key: value for key, value in os.environ.items()
            if key not in overrides and not any(part in key.upper() for part in secrets)}


def run(arguments, *, expected_ok=True, text=True, timeout=90):
    result = subprocess.run(list(map(str, arguments)), capture_output=True, text=text,
                            env=clean_environment(), timeout=timeout)
    if expected_ok:
        message = result.stderr if text else result.stderr.decode(errors="replace")
        require(result.returncode == 0, message[-3000:])
    return result


def copy_file(source, target):
    """APFS clone when available, otherwise an independent ordinary file copy."""
    if sys.platform == "darwin":
        clone = ctypes.CDLL(None).clonefile
        clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
        clone.restype = ctypes.c_int
        if clone(os.fsencode(source), os.fsencode(target), 0) == 0:
            shutil.copystat(source, target)
            return str(target)
    return shutil.copy2(source, target)


def copy_owned_tree(source, target):
    source = source.resolve(strict=True)
    # A standalone runtime may contain relative aliases, but never escape it.
    aliases = []
    for item in source.rglob("*"):
        if item.is_symlink():
            resolved = item.resolve(strict=True)
            require(resolved.is_relative_to(source), "Donor runtime has a foreign symlink: " + str(item))
            aliases.append((item.relative_to(source), resolved.relative_to(source)))
    shutil.copytree(source, target, symlinks=True, copy_function=copy_file,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    for relative, destination in aliases:
        alias = target / relative
        alias.unlink()
        alias.symlink_to(os.path.relpath(target / destination, alias.parent))


def prepare_runtime(python, root):
    query = """import imageio_ffmpeg,json,pathlib,sys
print(json.dumps({'base':sys.base_prefix,'version':list(sys.version_info[:2]),
'package':str(pathlib.Path(imageio_ffmpeg.__file__).parent),
'ffmpeg':imageio_ffmpeg.get_ffmpeg_exe()}))"""
    info = json.loads(run([python, "-B", "-E", "-s", "-c", query]).stdout)
    require(info["version"] == [3, 12], "The native speech helper requires a private CPython 3.12 runtime")
    runtime = root / "runtime"
    base = runtime / "python"
    runtime.mkdir(mode=0o700)
    copy_owned_tree(Path(info["base"]), base)
    venv = runtime / "venv"
    binary = venv / "bin"
    site = venv / "lib/python3.12/site-packages"
    binary.mkdir(parents=True, mode=0o700)
    site.mkdir(parents=True, mode=0o700)
    for name in ("python", "python3", "python3.12"):
        (binary / name).symlink_to(os.path.relpath(base / "bin/python3.12", binary))
    (venv / "pyvenv.cfg").write_text(
        "home = " + str(base / "bin") + "\ninclude-system-site-packages = false\nversion = 3.12\n", encoding="utf-8")
    copy_owned_tree(Path(info["package"]), site / "imageio_ffmpeg")
    for item in runtime.rglob("*"):
        if item.is_symlink():
            require(item.resolve(strict=True).is_relative_to(runtime), "Copied runtime retains a foreign symlink")
    private_python = binary / "python"
    private_info = json.loads(run([private_python, "-B", "-E", "-s", "-c", query]).stdout)
    ffmpeg = Path(private_info["ffmpeg"])
    require(ffmpeg.resolve().is_relative_to(venv), "FFmpeg came from outside the isolated runtime")
    require(Path(private_info["base"]).resolve() == base.resolve(), "Python did not select the copied base")
    return ffmpeg


class MediaE2E:
    def __init__(self, engine, backend, root, ffmpeg):
        self.engine, self.backend, self.root, self.ffmpeg = engine, backend, root, ffmpeg
        self.calls = 0
        self.inputs = root / "synthetic-inputs"
        self.inputs.mkdir(mode=0o700)
        (root / "meetings").mkdir(mode=0o700)

    def media(self, *arguments):
        return run([self.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", *arguments])

    def fixture(self, name, *, video=False, dual=False, size="1280x720", quality=None, high_frequency=False, microphone_delay=0, stereo=False):
        external = self.inputs / (name + ".mov")
        args = []
        if video:
            args += ["-f", "lavfi", "-i", f"testsrc2=size={size}:rate=30:duration=3"]
        system_audio = ("aevalsrc=0.10*sin(2*PI*440*t)+0.08*sin(2*PI*12000*t):s=48000:d=3"
                        if high_frequency else "sine=frequency=440:sample_rate=48000:duration=3")
        if stereo:
            system_audio = ("aevalsrc=0.10*sin(2*PI*440*t)+0.08*sin(2*PI*12000*t)|"
                            "0.10*sin(2*PI*660*t)+0.08*sin(2*PI*14000*t):s=48000:d=3")
        args += ["-f", "lavfi", "-i", system_audio]
        if dual:
            args += (["-itsoffset", str(microphone_delay)] if microphone_delay else [])
            args += ["-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=3"]
        audio_index = int(video)
        if video:
            args += ["-map", "0:v:0", "-c:v", "libx264", "-preset", "fast", "-b:v", "1000k",
                     "-maxrate", "1000k", "-bufsize", "2000k", "-pix_fmt", "yuv420p"]
        args += ["-map", f"{audio_index}:a:0"]
        if dual:
            args += ["-map", f"{audio_index + 1}:a:0"]
        args += ["-c:a", "aac", "-b:a", "256k" if high_frequency else "96k", external]
        self.media(*args)
        identifier = str(uuid.uuid4())
        meeting = self.root / "meetings" / identifier
        meeting.mkdir(mode=0o700)
        copy_file(external, meeting / "recording.mov")
        meta = {"id": identifier, "title": "Синтетический тест · " + name,
                "createdAt": 1700000000, "source": "recording.mov", "status": "recording", "duration": 0,
                "speakerNames": {}, "completedTasks": [], "focus": "synthetic media only",
                "recordingTracks": dual, "hasVideo": video}
        if quality is not None:
            meta["recordingAudioQuality"] = quality
        # Simulate changing preferences after capture. Finalization must use
        # only the snapshot on this meeting, including legacy recordings.
        (self.root / "settings.json").write_text(json.dumps({
            "recordAudioQuality": "compact" if quality == "high" else "high"
        }), encoding="utf-8")
        (meeting / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
        return meeting, external, meta

    def cli(self, meeting, *, expected_ok=True):
        self.calls += 1
        result = run([self.engine, "finalize", "--root", self.root, "--backend", self.backend,
                      "--meeting", meeting], expected_ok=expected_ok)
        events = []
        for line in result.stdout.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                raise AssertionError("Native engine emitted a non-protocol stdout line") from None
        (meeting / ("worker-error.json" if not expected_ok else "worker-events.json")).write_text(
            json.dumps(events, ensure_ascii=False, indent=2), encoding="utf-8")
        require(result.returncode != 0 if not expected_ok else any(e.get("event") == "done" for e in events),
                "Native finalization did not report its expected outcome")
        return events

    def samples(self, path, sample_rate=16000, channel=None):
        channel_options = ["-af", f"pan=mono|c0=c{channel}"] if channel is not None else []
        result = run([self.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-i", path,
                      "-map", "0:a:0", "-vn", *channel_options, "-ac", "1", "-ar", str(sample_rate), "-f", "f32le", "pipe:1"], text=False)
        require(len(result.stdout) < 16 * 1024 * 1024, "Synthetic output audio unexpectedly large")
        values = array.array("f"); values.frombytes(result.stdout)
        if sys.byteorder != "little": values.byteswap()
        return values

    def video_packets(self, path):
        result = run([self.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-i", path,
                      "-map", "0:v:0", "-c:v", "copy", "-bsf:v", "h264_mp4toannexb", "-f", "h264", "pipe:1"], text=False)
        return hashlib.sha256(result.stdout).hexdigest()

    @staticmethod
    def tone(samples, frequency, sample_rate=16000, start=0.5, duration=1):
        # An exact second away from codec padding gives stable orthogonal tones.
        section = samples[round(start * sample_rate):round((start + duration) * sample_rate)]
        require(len(section) == round(duration * sample_rate), "Output audio was truncated")
        real = sum(value * math.cos(2 * math.pi * frequency * i / sample_rate) for i, value in enumerate(section))
        imag = sum(value * math.sin(2 * math.pi * frequency * i / sample_rate) for i, value in enumerate(section))
        amplitude = 2 * math.hypot(real, imag) / len(section)
        return round(20 * math.log10(max(amplitude, 1e-12)), 2)

    def inspect(self, path):
        description = run([self.ffmpeg, "-nostdin", "-hide_banner", "-i", path], expected_ok=False).stderr
        samples = self.samples(path)
        return {"bytes": path.stat().st_size, "seconds": round(len(samples) / 16000, 4),
                "tone440dB": self.tone(samples, 440), "tone880dB": self.tone(samples, 880),
                "streams": [line.strip() for line in description.splitlines() if "Stream #" in line]}

    def successful(self, name, *, video=False, dual=False, size="1280x720", quality=None, high_frequency=False,
                   microphone_delay=0, stereo=False):
        meeting, external, meta = self.fixture(name, video=video, dual=dual, size=size, quality=quality,
                                               high_frequency=high_frequency, microphone_delay=microphone_delay, stereo=stereo)
        expected_seconds = 3 + microphone_delay if dual else 3
        source_hash = digest(external)
        settings_hash = digest(self.root / "settings.json")
        packets = self.video_packets(external) if video else None
        self.cli(meeting)
        saved = json.loads((meeting / "meta.json").read_text())
        require(saved == dict(meta, source="recording.mp3"), "Finalization changed unrelated metadata")
        require(digest(self.root / "settings.json") == settings_hash, "Finalization rewrote current capture preferences")
        require(not (meeting / "recording.mov").exists(), "Successful conversion did not retire the temporary capture container")
        require(digest(external) == source_hash, "Finalization changed the external original source")
        mp3 = self.inspect(meeting / "recording.mp3")
        require(any("Audio: mp3" in line for line in mp3["streams"]), "Final audio is not MP3")
        require(expected_seconds - 0.1 <= mp3["seconds"] <= expected_seconds + 0.2 and mp3["tone440dB"] > -40, "MP3 lost duration or primary audio")
        result = {"id": saved["id"], "externalSourcePreserved": True, "metadataPreserved": True,
                  "temporaryCaptureRetired": True, "preferencesSnapshotPreserved": True, "mp3": mp3}
        if video:
            clip = self.inspect(meeting / "video.mp4")
            streams = [line for line in clip["streams"] if "Video:" in line]
            require(any("h264" in line and size in line and re.search(r"\b30 fps\b", line) for line in streams),
                    "MP4 lost H264, its complete frame dimensions or 30 fps")
            require(0 < clip["bytes"] < 2_000_000, "Three-second video exceeds the bounded test size")
            require(self.video_packets(meeting / "video.mp4") == packets, "Finalization re-encoded or lost original H264 packets")
            require(expected_seconds - 0.1 <= clip["seconds"] <= expected_seconds + 0.2 and clip["tone440dB"] > -40, "MP4 audio was truncated")
            result["video"] = clip
        else:
            require(not (meeting / "video.mp4").exists(), "Audio-only capture unexpectedly produced video")
        if dual:
            system = self.inspect(meeting / "system.m4a")
            microphone = self.inspect(meeting / "microphone.m4a")
            require(system["tone440dB"] > -40 and system["tone880dB"] < -55, "System track is not isolated")
            require(microphone["tone880dB"] > -40 and microphone["tone440dB"] < -55, "Microphone track is not isolated")
            require(mp3["tone880dB"] > -40 and result["video"]["tone880dB"] > -40, "Mix lost microphone audio")
            result.update(system=system, microphone=microphone)
        else:
            require(not (meeting / "system.m4a").exists() and not (meeting / "microphone.m4a").exists(),
                    "Single-track capture fabricated separate sources")
        if quality is not None:
            expected_bitrate = {"compact": 64, "standard": 128, "high": 192}[quality]
            require(any(re.search(rf"\b{expected_bitrate} kb/s\b", line) for line in mp3["streams"]),
                    "MP3 did not retain the recording's selected quality")
            result["audioQuality"] = quality
            for media in (["video"] if video else []) + (["system", "microphone"] if dual else []):
                stream = next(line for line in result[media]["streams"] if "Audio:" in line)
                encoded = re.search(r"(\d+) kb/s", stream)
                require("48000 Hz" in stream and encoded is not None,
                        "Saved AAC audio lost its full capture sample rate or bitrate")
                # AAC may use fewer bits for simple tones; check its measured
                # rate remains consistent with the selected encoder budget.
                require(expected_bitrate * 0.55 <= int(encoded.group(1)) <= expected_bitrate * 1.25,
                        "AAC encoder ignored the recording's selected audio budget")
        if high_frequency and quality != "compact":
            # This tone is above the ASR copy's Nyquist limit. Its presence in
            # every listening format proves the pipeline never used 16 kHz ASR
            # audio as its source or merely upsampled that restricted signal.
            names = ["recording.mp3"] + (["video.mp4"] if video else []) + (["system.m4a"] if dual else [])
            result["highFrequency12kHzdB"] = {}
            for name in names:
                level = self.tone(self.samples(meeting / name, 48000), 12000, 48000)
                require(level > -40, f"Saved listening audio lost full-rate detail in {name}: {level} dB")
                result["highFrequency12kHzdB"][name] = level
        if stereo:
            for name, media in [("recording.mp3", "mp3"), ("video.mp4", "video"), ("system.m4a", "system")]:
                require(any("Audio:" in line and "stereo" in line for line in result[media]["streams"]),
                        "Full-rate listening audio lost the capture's stereo layout")
                left, right = (self.samples(meeting / name, channel=index) for index in (0, 1))
                require(self.tone(left, 440) > -40 and self.tone(left, 660) < -50,
                        "Capture's left channel leaked or disappeared")
                require(self.tone(right, 660) > -40 and self.tone(right, 440) < -50,
                        "Capture's right channel leaked or disappeared")
            result["stereoLayoutPreserved"] = True
        if microphone_delay:
            mic_samples = self.samples(meeting / "microphone.m4a")
            before = self.tone(mic_samples, 880, start=0.1, duration=0.25)
            after = self.tone(mic_samples, 880, start=0.9, duration=1)
            require(before < -60 and after > -40, "Separate microphone lost its common-timeline capture delay")
            mix_samples = self.samples(meeting / "recording.mp3")
            require(self.tone(mix_samples, 880, start=0.1, duration=0.25) < -60,
                    "Microphone shifted early in final MP3 mix")
            require(self.tone(mix_samples, 880, start=0.9) > -40, "Delayed microphone disappeared from final mix")
            result["microphoneDelayPreserved"] = True
        for name in ["audio.wav"] + (["microphone.wav"] if dual else []):
            with wave.open(str(meeting / name)) as audio:
                require((audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) == (16000, 1, 2),
                        "Finalization no longer prepared the compatible 16 kHz ASR copy")
        require(not list(meeting.glob(".posle-finalize-*")), "Full-rate private intermediates were not removed")
        outputs = {file.name: digest(file) for file in meeting.iterdir() if file.is_file() and file.name != "worker-events.json"}
        self.cli(meeting)
        require(all(digest(meeting / name) == value for name, value in outputs.items()), "Retry rewrote finalized media/metadata")
        result["idempotentRetry"] = True
        return result

    def failure(self):
        meeting, external, meta = self.fixture("failed-video-export")
        meta["hasVideo"] = True  # Deliberate mismatch exercises the real FFmpeg failure path.
        (meeting / "meta.json").write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")
        before_source = digest(meeting / "recording.mov")
        before_meta = digest(meeting / "meta.json")
        external_hash = digest(external)
        events = self.cli(meeting, expected_ok=False)
        require(digest(meeting / "recording.mov") == before_source and digest(meeting / "meta.json") == before_meta,
                "Failed conversion destroyed the recoverable capture or committed incomplete metadata")
        require(digest(external) == external_hash, "Failed conversion changed the external source")
        require(any(event.get("event") == "error" for event in events), "Failure lacked a useful worker error")
        return {"id": meta["id"], "sourcePreserved": True, "metadataPreserved": True, "reportedError": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", type=Path, default=PROJECT / ".test-data/runtime/venv/bin/python")
    parser.add_argument("--engine", type=Path, default=PROJECT / "dist/После.app/Contents/MacOS/posle-engine")
    parser.add_argument("--backend", type=Path, default=PROJECT / "backend")
    parser.add_argument("--work-dir", type=Path, help="Parent for a new unique fixture (never an existing library)")
    parser.add_argument("--keep", action="store_true", help="Retain the new isolated runtime, generated media and report")
    args = parser.parse_args()
    os.umask(0o077)
    python = args.python.absolute()  # Keep venv argv[0], not the resolved standalone executable.
    engine, backend = args.engine.resolve(), args.backend.resolve()
    require(python.is_file() and engine.is_file() and os.access(engine, os.X_OK), "Pass installed --python and built --engine")
    require((backend / "engine.py").is_file(), "Pass the packaged or source backend directory")
    if args.work_dir:
        args.work_dir.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="posle-media-e2e-", dir=args.work_dir or "/private/tmp"))
    try:
        ffmpeg = prepare_runtime(python, root)
        test = MediaE2E(engine, backend, root, ffmpeg)
        results = {"audioOnly": test.successful("audio-only"),
                   "lightVideo": test.successful("light-video", video=True),
                   "dualVideo": test.successful("dual-video", video=True, dual=True),
                   "failurePreservesSource": test.failure()}
        for quality in ("compact", "standard", "high"):
            results[quality + "1080p"] = test.successful(quality + "-1080p", video=True, dual=True,
                                                         size="1920x1080", quality=quality, high_frequency=True, stereo=quality == "high")
        results["fullFrameNonWidescreen"] = test.successful("full-frame-native-ratio", video=True, dual=True,
            size="1512x982", quality="high", high_frequency=True, microphone_delay=0.6)
        branded = root / "runtime/media/После Медиа"
        require(branded.is_file() and not branded.is_symlink(), "Real finalize did not use the owned media runtime")
        result = {"result": "PASS", "cliCommands": test.calls, "cases": results,
                  "ffmpegSHA256": digest(branded), "syntheticOnly": True}
        (root / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        for name in results:
            print("PASS:", name)
        print("PASS: real native finalize, private owned runtime, selected MP3 quality, full-rate audio, full-frame H26430 packet preservation, isolated tracks/timeline and retry")
        print(json.dumps({"result": "PASS", "cliCommands": test.calls, "report": str(root / "results.json")}, ensure_ascii=False))
    finally:
        if args.keep:
            print("Synthetic media fixture retained:", root)
        else:
            shutil.rmtree(root)


if __name__ == "__main__":
    main()
