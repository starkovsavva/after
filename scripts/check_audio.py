"""Exercise the actual ASR/diarization worker on a bounded real audio excerpt."""
import argparse
import subprocess
import sys
import time
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", required=True, type=Path, help="Audio file to transcribe")
parser.add_argument("--root", required=True, type=Path, help="Separate test library with a prepared speech runtime and model")
parser.add_argument("--seconds", type=int, default=75, help="Excerpt duration in seconds (default: 75)")
parser.add_argument("--offset", type=int, default=0, help="Excerpt start in seconds (default: 0)")
parser.add_argument("--speakers", type=int, default=0, help="Speaker count; 0 detects it automatically (default: 0)")
args = parser.parse_args()
if args.seconds <= 0 or args.offset < 0 or args.speakers < 0:
    parser.error("seconds must be positive; offset and speakers must be non-negative")
project = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(project / "backend"))
import engine

meeting_id = "audio-check-" + str(uuid.uuid4())
directory = args.root / "meetings" / meeting_id
directory.mkdir(parents=True, exist_ok=True)
engine.ffmpeg("-ss", args.offset, "-i", args.source, "-t", args.seconds, "-vn", "-c:a", "libmp3lame", "-b:a", "128k", directory / "source.mp3")
engine.atomic(directory / "meta.json", {"id": meeting_id, "title": "Проверка аудио", "createdAt": time.time(),
    "source": "source.mp3", "status": "imported", "duration": 0, "speakerNames": {}, "completedTasks": [], "focus": "",
    "recordingTracks": False, "hasVideo": False})
command = [sys.executable, str(project / "backend" / "engine.py"), "transcribe", "--root", str(args.root), "--meeting", str(directory), "--speakers", str(args.speakers)]
subprocess.run(command, check=True)
transcript = engine.load(directory / "transcript.json")
assert transcript["segments"], "No speech detected"
assert not transcript["warnings"], transcript["warnings"]
assert len(transcript["segments"]) == len({s["id"] for s in transcript["segments"]})
assert all(s["start"] >= 0 and s["end"] >= s["start"] for s in transcript["segments"])
assert (directory / "playback.mp3").stat().st_size > 1000
engine.atomic(args.root / "audio-check-report.json", {"duration": transcript["duration"], "segments": len(transcript["segments"]),
    "speakers": sorted({s["speaker"] for s in transcript["segments"]}), "mp3": True, "warnings": transcript["warnings"]})
print((args.root / "audio-check-report.json").read_text())
