#!/usr/bin/env python3
"""Exercise a bundled local ASR worker with synthetic speech, fully offline.

The caller explicitly supplies a compatible model and an existing verified
Python runtime. All inputs are copied into an automatically-created temporary
library; the worker is denied network and writes outside that library. This is
an integration smoke, not a benchmark of recognition quality or a microphone
test. No existing application library or audio is read.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from check_legacy_worker_upgrade import clean_environment, confined, core, worker

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "backend"))
from models import inspect_model  # noqa: E402


def main(app: Path, model: Path, python_base: Path, site_packages: Path, library_override: Path | None = None) -> None:
    engine = app / "Contents/MacOS/After Engine"
    if not engine.is_file():
        engine = app / "Contents/MacOS/posle-engine"
    library = library_override or app / "Contents/Frameworks/libposle_core.dylib"
    assert engine.is_file() and library.is_file() and (python_base / "bin/python3.12").is_file()
    assert site_packages.is_dir() and (site_packages / "imageio_ffmpeg").is_dir()
    selected = inspect_model(model, requested_format="onnx")
    if not selected.get("compatible") or selected.get("layout") != "meetily-onnx":
        raise SystemExit("A compatible local Meetily/Parakeet ONNX model is required")
    policy = json.loads((app / "Contents/Resources/backend/python-runtime.json").read_text())
    assert python_base.name == policy["directory"], "Python version differs from bundle policy"
    with tempfile.TemporaryDirectory(prefix="after-local-asr-", dir="/private/tmp") as temporary:
        root = Path(temporary).resolve() / "data"
        root.mkdir(mode=0o700)
        outside = root.parent / "forbidden"
        probe = subprocess.run(confined(root, sys.executable, "-B", "-c",
            "import errno,pathlib,socket,sys; pathlib.Path(sys.argv[1]).write_text('ok'); "
            "exec(\"try:\\n pathlib.Path(sys.argv[2]).write_text('bad')\\nexcept PermissionError:\\n pass\\nelse:\\n raise SystemExit('write escaped')\"); "
            "exec(\"try:\\n socket.socket().connect(('127.0.0.1',9))\\nexcept OSError as e:\\n assert e.errno in (errno.EPERM,errno.EACCES), e\\nelse:\\n raise SystemExit('network allowed')\")",
            str(root / "allowed"), str(outside)), env=clean_environment(root), capture_output=True, timeout=10)
        assert probe.returncode == 0 and not outside.exists(), "Could not confine worker writes and network"
        verified = subprocess.run(confined(root, str(engine), "--posle-verify-python-runtime", str(python_base)),
            env=clean_environment(root), capture_output=True, text=True, timeout=120)
        assert verified.returncode == 0, "The selected runtime did not pass bundle verification"
        base = root / "runtime/python" / python_base.name
        base.parent.mkdir(parents=True)
        shutil.copytree(python_base, base, symlinks=True)
        venv = root / "runtime/venv"
        subprocess.run(confined(root, str(base / "bin/python3.12"), "-B", "-I", "-m", "venv", "--symlinks", "--without-pip", str(venv)),
            env=clean_environment(root), capture_output=True, check=True, timeout=120)
        shutil.copytree(site_packages, venv / "lib/python3.12/site-packages", dirs_exist_ok=True, symlinks=True)
        model_copy = root / "models/parakeet-fixture"
        model_copy.parent.mkdir(parents=True)
        shutil.copytree(model, model_copy, symlinks=False)
        # The model identity records the exact bytes used without exposing paths.
        digest = hashlib.sha256()
        for file in sorted(path for path in model_copy.rglob("*") if path.is_file()):
            digest.update(str(file.relative_to(model_copy)).encode())
            with file.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
        (root / "settings.json").write_text(json.dumps({"speechMode":"local", "asrModelPath":str(model_copy),
            "asrModelFormat":"onnx", "diarization":False, "features":{"knowledgeBase":True}}))
        note = core(library, root, "note-save", note={"id":"asr-fixture", "kind":"note",
            "text":"Тестовая заметка", "createdAt":1, "updatedAt":1, "revision":0})
        snapshot = core(library, root, "kb-snapshot", noteID=note["id"])
        worker(engine, root, "prepare", expect_success=True)
        meeting = root / "meetings/asr-synthetic"
        meeting.mkdir(parents=True)
        audio = meeting / "input.aiff"
        spoken = "Привет! Сегодня мы проверяем запись встречи и распознавание речи."
        speech = subprocess.run(confined(root, "/usr/bin/say", "-v", "Milena", "-o", str(audio), spoken),
            env=clean_environment(root), capture_output=True, text=True, timeout=60)
        assert speech.returncode == 0 and audio.is_file() and audio.stat().st_size > 1000, "Synthetic voice is unavailable"
        (meeting / "meta.json").write_text(json.dumps({"id":"asr-synthetic", "title":"Синтетическая речь",
            "source":"input.aiff", "status":"recorded", "recordingTracks":False}))
        worker(engine, root, "transcribe", "--meeting", str(meeting), "--no-diarization", expect_success=True)
        transcript = json.loads((meeting / "transcript.json").read_text())
        text = " ".join(str(row.get("text", "")) for row in transcript.get("segments", [])).strip()
        assert text and any(word in text.lower() for word in ("запис", "встреч", "реч", "распознав", "провер")), \
            "The worker did not recognize the expected synthetic speech"
        assert core(library, root, "kb-snapshot", noteID=note["id"])["libraryID"] == snapshot["libraryID"]
        print("PASS: bundled worker transcribed synthetic Russian speech offline with a real local ONNX model")
        print("Model SHA-256:", digest.hexdigest())
        print("Synthetic transcript:", text[:500])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--python-base", type=Path, required=True)
    parser.add_argument("--site-packages", type=Path, required=True)
    parser.add_argument("--core-library", type=Path, help="Optional core for a cross-version compatibility fixture")
    args = parser.parse_args()
    inputs = [value.resolve(strict=True) for value in (args.app, args.model, args.python_base, args.site_packages)]
    main(*inputs, args.core_library.resolve(strict=True) if args.core_library else None)
