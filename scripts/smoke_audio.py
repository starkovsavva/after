"""Exercise the actual ASR/diarization worker on a bounded real audio excerpt."""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--source", required=True, type=Path)
parser.add_argument("--root", required=True, type=Path)
parser.add_argument("--seconds", type=int, default=75)
parser.add_argument("--offset", type=int, default=340)
args = parser.parse_args()
project = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(project / "backend"))
import engine

directory = args.root / "meetings" / "smoke-audio"
directory.mkdir(parents=True, exist_ok=True)
engine.ffmpeg("-ss", args.offset, "-i", args.source, "-t", args.seconds, "-vn", "-c:a", "libmp3lame", "-b:a", "128k", directory / "source.mp3")
engine.atomic(directory / "meta.json", {"id": "smoke-audio", "title": "Проверка реального аудио", "createdAt": time.time(),
    "source": "source.mp3", "status": "imported", "duration": 0, "speakerNames": {}, "completedTasks": [], "focus": "",
    "recordingTracks": False, "hasVideo": False})
command = [sys.executable, str(project / "backend" / "engine.py"), "transcribe", "--root", str(args.root), "--meeting", str(directory), "--speakers", "2"]
subprocess.run(command, check=True)
transcript = engine.load(directory / "transcript.json")
assert transcript["segments"], "No speech detected"
assert not transcript["warnings"], transcript["warnings"]
assert len(transcript["segments"]) == len({s["id"] for s in transcript["segments"]})
assert all(s["start"] >= 0 and s["end"] >= s["start"] for s in transcript["segments"])
assert (directory / "playback.mp3").stat().st_size > 1000
engine.atomic(args.root / "smoke-report.json", {"duration": transcript["duration"], "segments": len(transcript["segments"]),
    "speakers": sorted({s["speaker"] for s in transcript["segments"]}), "mp3": True, "warnings": transcript["warnings"]})
print((args.root / "smoke-report.json").read_text())
