#!/usr/bin/env python3
"""Check imported listening/export audio with generated media and real FFmpeg.

Run with the backend check environment:
    .test-data/checks/bin/python scripts/check_import_playback.py

Only neural inference is replaced. The real engine prepares ASR PCM, creates
playback MP3 and publishes a transcript. No model, network, microphone, screen
or user media is used. Synthetic inputs and results.json remain for inspection.
"""
from __future__ import annotations

import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from unittest.mock import patch
import wave

import imageio_ffmpeg

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "backend"))
import engine


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class SyntheticASR:
    def __init__(self, *_):
        pass

    def transcribe(self, path, callback):
        with wave.open(str(path)) as audio:
            require((audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) == (16000, 1, 2),
                    "Listening quality changes must leave ASR at 16 kHz mono PCM16")
            duration = audio.getnframes() / audio.getframerate()
        callback(1, 1)
        return [{"text": " Synthetic words", "start": 0.1, "end": min(1.5, duration)}]

    def close(self):
        pass


class PlaybackCheck:
    def __init__(self, root, binary):
        self.root, self.binary = root, binary

    def media(self, *arguments, binary=False):
        result = subprocess.run([str(self.binary), "-nostdin", "-hide_banner", "-loglevel", "error", "-y", *map(str, arguments)],
                                capture_output=True, text=not binary, timeout=30)
        require(result.returncode == 0, str(result.stderr)[-1800:])
        return result.stdout

    def samples(self, path, channel=0):
        data = self.media("-i", path, "-map", "0:a:0", "-vn", "-af", f"pan=mono|c0=c{channel}",
                          "-ar", "48000", "-f", "f32le", "pipe:1", binary=True)
        values = array.array("f"); values.frombytes(data)
        if sys.byteorder != "little":
            values.byteswap()
        return values

    @staticmethod
    def tone(samples, frequency, start=0.2, duration=1):
        samples = samples[round(start * 48000):round((start + duration) * 48000)]
        real = sum(value * math.cos(2 * math.pi * frequency * index / 48000) for index, value in enumerate(samples))
        imaginary = sum(value * math.sin(2 * math.pi * frequency * index / 48000) for index, value in enumerate(samples))
        amplitude = 2 * math.hypot(real, imaginary) / max(1, len(samples))
        return round(20 * math.log10(max(amplitude, 1e-12)), 2)

    def check(self, name, extension, rate, stereo, video=False, audio_offset=0):
        meeting = self.root / name; meeting.mkdir()
        source = meeting / ("source." + extension)
        left = "0.10*sin(2*PI*440*t)+0.08*sin(2*PI*12000*t)"
        right = "0.10*sin(2*PI*660*t)+0.08*sin(2*PI*14000*t)"
        tones = left + ("|" + right if stereo else "")
        arguments = (["-itsoffset", str(audio_offset)] if audio_offset else [])
        arguments += ["-f", "lavfi", "-i", f"aevalsrc={tones}:s={rate}:d=2"]
        if video:
            arguments += ["-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=2",
                          "-f", "lavfi", "-i", f"color=black:size=32x32:rate=10:duration={2 + audio_offset}",
                          "-map", "2:v:0", "-map", "0:a:0", "-map", "1:a:0",
                          "-c:v", "libx264", "-preset", "ultrafast"]
        codec = "pcm_s16le" if extension == "wav" else "libmp3lame" if extension == "mp3" else "aac"
        self.media(*arguments, "-c:a", codec, *([] if extension == "wav" else ["-b:a", "256k"]), source)
        original = hashlib.sha256(source.read_bytes()).hexdigest()
        metadata = {"source": source.name, "title": "Synthetic imported playback"}
        (meeting / "meta.json").write_text(json.dumps(metadata))
        selected = {"name": "Synthetic ASR", "format": "synthetic", "path": ""}
        with patch.object(engine, "ASRAdapter", SyntheticASR), patch.object(engine, "resolve_asr", return_value=selected):
            engine.transcribe(meeting, self.root, 0, False)
        playback = meeting / "playback.mp3"
        inspection = subprocess.run([str(self.binary), "-hide_banner", "-i", str(playback)], capture_output=True, text=True, timeout=30)
        stream = next(line for line in inspection.stderr.splitlines() if "Audio:" in line)
        require(re.search(rf"\b{rate} Hz, {'stereo' if stereo else 'mono'}\b", stream), "Imported listening audio lost its sample rate/channel layout: " + stream)
        left_samples = self.samples(playback)
        duration = len(left_samples) / 48000
        require(abs(duration - (2 + audio_offset)) < 0.06, "Imported listening duration/timeline changed")
        levels = {"left440dB": self.tone(left_samples, 440), "left12kHzdB": self.tone(left_samples, 12000)}
        require(levels["left440dB"] > -40 and levels["left12kHzdB"] > -40, "Imported listening lost original full-rate detail")
        if stereo:
            right_samples = self.samples(playback, 1)
            levels.update(right660dB=self.tone(right_samples, 660), right14kHzdB=self.tone(right_samples, 14000))
            require(levels["right660dB"] > -40 and levels["right14kHzdB"] > -40, "Imported right channel lost its detail")
            require(self.tone(left_samples, 660) < -55 and self.tone(right_samples, 440) < -55, "Imported stereo channels were mixed")
        if video:
            require(self.tone(left_samples, 880) < -55, "Playback selected an audio stream other than the first")
        if audio_offset:
            levels["initial440dB"] = self.tone(left_samples, 440, start=0.1, duration=0.2)
            require(levels["initial440dB"] < -60 and self.tone(left_samples, 440, start=0.8) > -40,
                    "Imported audio lost its leading delay relative to ASR timestamps")
        if extension == "mp3":
            packet_hash = lambda path: self.media("-i", path, "-map", "0:a:0", "-vn", "-c:a", "copy", "-f", "hash", "-hash", "sha256", "pipe:1")
            require(packet_hash(source) == packet_hash(playback), "Imported MP3 was re-encoded")
        require(hashlib.sha256(source.read_bytes()).hexdigest() == original, "Imported source was modified")
        require(json.loads((meeting / "meta.json").read_text()) == metadata, "Imported metadata changed")
        transcript = json.loads((meeting / "transcript.json").read_text())
        require(transcript["segments"], "Synthetic transcription did not complete")
        require(abs(transcript["duration"] - duration) < 0.02, "Listening and ASR timelines disagree")
        require(not list(meeting.glob(".posle-playback-*")), "Playback staging was not removed")
        return {"sampleRate": rate, "channels": 2 if stereo else 1, "seconds": duration, **levels}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", type=Path)
    args = parser.parse_args()
    binary = (args.ffmpeg or Path(imageio_ffmpeg.get_ffmpeg_exe())).resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="posle-native-check-import-playback-", dir="/private/tmp"))
    (root / "settings.json").write_text("{}")
    engine.PROTOCOL = sys.stderr
    check = PlaybackCheck(root, binary)
    cases = [("wav-stereo", "wav", 48000, True, False), ("m4a-stereo", "m4a", 44100, True, False),
             ("wav-mono", "wav", 44100, False, False), ("video-first-track", "mov", 48000, True, True),
             ("video-audio-delay", "mov", 48000, True, True, 0.6),
             ("mp3-packet-copy", "mp3", 44100, True, False)]
    results = {}
    with patch.object(imageio_ffmpeg, "get_ffmpeg_exe", return_value=str(binary)):
        for case in cases:
            results[case[0]] = check.check(*case)
            print("PASS:", case[0], json.dumps(results[case[0]]))
    report = root / "results.json"
    report.write_text(json.dumps(results, indent=2))
    print("Generated media and results:", report)


if __name__ == "__main__":
    main()
