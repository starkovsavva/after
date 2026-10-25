#!/usr/bin/env python3
"""Exercise recording finalization using generated media only.

Run with the backend Python environment (imageio-ffmpeg and numpy installed):
    python scripts/check_media.py
    python scripts/check_media.py --work-dir /tmp/posle-media-check

Each run creates its own directory, keeps its synthetic artifacts and writes
results.json. No microphone, screen, network, ASR model or user media is used.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import imageio_ffmpeg
import numpy as np


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class MediaCheck:
    def __init__(self, engine_path: Path, directory: Path):
        spec = importlib.util.spec_from_file_location("posle_media_check_engine", engine_path)
        require(spec is not None and spec.loader is not None, "Cannot load backend engine")
        self.engine = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.engine)
        self.engine.PROTOCOL = sys.stderr
        self.directory = directory
        self.ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()

    def run(self, *arguments):
        command = [self.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", *map(str, arguments)]
        result = subprocess.run(command, capture_output=True, text=True)
        require(result.returncode == 0, result.stderr[-1800:])

    def make(self, name, system_seconds, microphone_seconds=None, video_seconds=None, microphone_offset=0):
        directory = self.directory / name
        directory.mkdir()
        arguments = []
        if video_seconds is not None:
            arguments += ["-f", "lavfi", "-i", f"testsrc2=size=1280x720:rate=30:duration={video_seconds}"]
        arguments += ["-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={system_seconds}"]
        if microphone_seconds is not None:
            if microphone_offset:
                arguments += ["-itsoffset", str(microphone_offset)]
            arguments += ["-f", "lavfi", "-i", f"sine=frequency=880:sample_rate=48000:duration={microphone_seconds}"]
        first_audio = 1 if video_seconds is not None else 0
        if video_seconds is not None:
            arguments += ["-map", "0:v:0"]
        arguments += ["-map", f"{first_audio}:a:0"]
        if microphone_seconds is not None:
            arguments += ["-map", f"{first_audio + 1}:a:0"]
        if video_seconds is not None:
            arguments += ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "32", "-pix_fmt", "yuv420p"]
        arguments += ["-c:a", "aac", "-b:a", "128k", directory / "recording.mov"]
        self.run(*arguments)
        meta = {"id": name, "title": name, "source": "recording.mov",
                "hasVideo": video_seconds is not None, "recordingTracks": microphone_seconds is not None}
        (directory / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
        return directory

    def samples(self, path):
        result = subprocess.run([self.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(path),
                                 "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-f", "f32le", "pipe:1"],
                                capture_output=True)
        require(result.returncode == 0, result.stderr.decode(errors="replace")[-1800:])
        return np.frombuffer(result.stdout, dtype=np.float32)

    @staticmethod
    def tone_db(samples, frequency):
        times = np.arange(len(samples)) / 16000
        amplitude = abs(np.sum(samples * np.exp(-2j * np.pi * frequency * times))) * 2 / max(len(samples), 1)
        return round(20 * math.log10(max(float(amplitude), 1e-12)), 1)

    def inspect(self, path):
        samples = self.samples(path)
        result = subprocess.run([self.ffmpeg, "-hide_banner", "-i", str(path)], capture_output=True, text=True)
        return {"seconds": round(len(samples) / 16000, 3), "440dB": self.tone_db(samples, 440),
                "880dB": self.tone_db(samples, 880),
                "streams": [line.strip() for line in result.stderr.splitlines() if "Stream #" in line]}

    def finalize(self, directory):
        self.engine.finalize_recording(directory)
        meta = json.loads((directory / "meta.json").read_text())
        require(meta["source"] == "recording.mp3", "Final source was not committed to metadata")
        require(not (directory / "recording.mov").exists(), "Successful finalization left temporary MOV")
        result = {"meta": meta, "sourceRemoved": True, "mp3": self.inspect(directory / "recording.mp3")}
        if meta["hasVideo"]:
            result["video"] = self.inspect(directory / "video.mp4")
            video_streams = [s for s in result["video"]["streams"] if "Video:" in s]
            require(any("h264" in s and "1280x720" in s and re.search(r"\b30 fps", s) for s in video_streams),
                    "Video codec, size or frame rate changed")
        if meta["recordingTracks"]:
            result["system"] = self.inspect(directory / "system.m4a")
            result["microphone"] = self.inspect(directory / "microphone.m4a")
            require(result["system"]["440dB"] > -40 and result["system"]["880dB"] < -60,
                    "System audio contains incorrect tones")
            require(result["microphone"]["880dB"] > -40 and result["microphone"]["440dB"] < -60,
                    "Microphone audio contains incorrect tones")
        return result

    def check_dual_video(self):
        result = self.finalize(self.make("dual-video", 4, 4, 4))
        for key in ("mp3", "video"):
            require(result[key]["440dB"] > -40 and result[key]["880dB"] > -40, f"{key} lost an audio track")
            require(result[key]["seconds"] > 3.8, f"{key} was truncated")
        return result

    def check_microphone_only(self):
        result = self.finalize(self.make("microphone-only", 3))
        require(not result["meta"]["recordingTracks"], "Single track incorrectly marked as dual")
        require(result["mp3"]["seconds"] > 2.8 and result["mp3"]["440dB"] > -40, "Microphone-only MP3 failed")
        return result

    def check_long_microphone(self):
        directory = self.make("long-microphone", 2, 4, 4)
        result = self.finalize(directory)
        for key, filename in (("mp3", "recording.mp3"), ("video", "video.mp4")):
            require(result[key]["seconds"] > 3.8, f"{key} truncated the longer microphone")
            tail = self.samples(directory / filename)[40000:56000]
            result[key]["tail880dB"] = self.tone_db(tail, 880)
            require(result[key]["tail880dB"] > -40, f"{key} lost microphone tail")
        return result

    def check_offset(self):
        directory = self.make("microphone-offset", 5, 3, 5, microphone_offset=1)
        result = self.finalize(directory)
        microphone = self.samples(directory / "microphone.m4a")
        result["initialMicrophoneRMS"] = float(np.sqrt(np.mean(microphone[:8000] ** 2)))
        require(result["initialMicrophoneRMS"] < 0.001, "Microphone lost its initial delay")
        mixed = self.samples(directory / "recording.mp3")
        result["early880dB"] = self.tone_db(mixed[:8000], 880)
        result["later880dB"] = self.tone_db(mixed[24000:32000], 880)
        require(result["early880dB"] < -60 and result["later880dB"] > -40, "Mixed timeline is misaligned")
        return result

    def check_idle_video(self):
        # ScreenCaptureKit can stop producing frames when a screen is static.
        directory = self.make("idle-video", 10, 10, 1)
        result = self.finalize(directory)
        require(result["video"]["seconds"] > 9.8, "MP4 audio was cut to the final video frame")
        tail = self.samples(directory / "video.mp4")[int(8.5 * 16000):int(9.5 * 16000)]
        result["tail440dB"] = self.tone_db(tail, 440)
        result["tail880dB"] = self.tone_db(tail, 880)
        require(result["tail440dB"] > -40 and result["tail880dB"] > -40, "MP4 lost audio after the last video frame")
        return result

    def check_failure(self):
        directory = self.make("failure-preserves-source", 3, 3)
        meta = json.loads((directory / "meta.json").read_text())
        meta["hasVideo"] = True  # Deliberately invalid: audio-only source, requested video export.
        (directory / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
        try:
            self.engine.finalize_recording(directory)
        except RuntimeError as error:
            require((directory / "recording.mov").exists(), "Failure removed the recoverable source")
            require(json.loads((directory / "meta.json").read_text())["source"] == "recording.mov",
                    "Failure committed incomplete metadata")
            return {"sourcePreserved": True, "metadataPreserved": True, "expectedError": str(error)}
        raise AssertionError("Expected missing-video failure did not happen")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, default=Path(__file__).resolve().parents[1] / "backend" / "engine.py")
    parser.add_argument("--work-dir", type=Path, help="Parent for a new unique directory of synthetic artifacts")
    args = parser.parse_args()
    if args.work_dir:
        args.work_dir.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="posle-media-", dir=args.work_dir))
    check = MediaCheck(args.engine, directory)
    results = {}
    for name in ("dual_video", "microphone_only", "long_microphone", "offset", "idle_video", "failure"):
        try:
            results[name] = {"passed": True, **getattr(check, "check_" + name)()}
            print(f"PASS {name}")
        except Exception as error:
            results[name] = {"passed": False, "error": str(error)}
            print(f"FAIL {name}: {error}", file=sys.stderr)
    report = directory / "results.json"
    report.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Synthetic media and report: {report}")
    return 0 if all(result["passed"] for result in results.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
