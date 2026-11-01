#!/usr/bin/env python3
"""Run the published speech worker on an isolated v1+KB library, offline.

This copies only a *verified* Python distribution and the installed
imageio-ffmpeg package to a disposable root. It uses invented silence and no
ASR model, microphone, account, network or personal library content. The
worker is the published executable and its real bundled backend, not a mock.
It checks offline prepare and safe failure of transcription when no model is
installed; it does not claim actual recognition or long-running recording.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import wave

from check_kb_legacy_compat import WORKER


def clean_environment(root: Path):
    fragments = ("API_KEY", "ACCESS_KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "COOKIE", "PROXY")
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("POSLE_", "PYTHON", "HF_", "HUGGINGFACE_"))
           and not any(fragment in key.upper() for fragment in fragments)}
    env.update(HOME=str(root), XDG_CACHE_HOME=str(root / "cache"), HF_HOME=str(root / "cache/huggingface"))
    return env


def confined(root: Path, *command: str):
    # The only allowed write target is this synthetic fixture; all network is
    # denied even if a future worker changes its defaults. JSON quoting safely
    # encodes the generated absolute path for the sandbox profile.
    profile = (f"(version 1) (allow default) (deny network*) "
               f"(deny file-write* (require-all (require-not (subpath {json.dumps(str(root))})) "
               f"(require-not (literal \"/dev/null\"))))")
    return ["/usr/bin/sandbox-exec", "-p", profile, *command]


def core(library: Path, root: Path, command: str, **kwargs):
    payload = {"root":str(root), "command":command, **kwargs}
    result = subprocess.run(confined(root, sys.executable, "-B", "-c", WORKER, str(library)),
        input=json.dumps(payload, ensure_ascii=False), text=True, capture_output=True,
        env=clean_environment(root), timeout=60, check=True)
    envelope = json.loads(result.stdout)
    assert envelope.get("ok") is True, (command, envelope)
    return envelope["value"]


def worker(engine: Path, root: Path, command: str, *args: str, expect_success: bool):
    # sandbox-exec is required, not optional: these tests must never contact an
    # ASR service or model registry even if a future backend changes defaults.
    command_line = confined(root, str(engine), command, "--root", str(root), *args)
    result = subprocess.run(command_line, env=clean_environment(root), capture_output=True,
                            text=True, timeout=180)
    events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    if expect_success:
        assert result.returncode == 0 and events and events[-1].get("event") == "done", (result.returncode, events, result.stderr[-1500:])
    else:
        assert result.returncode != 0 and any(event.get("event") == "error" for event in events), (result.returncode, events, result.stderr[-1500:])
    return events


def main(engine: Path, old: Path, new: Path, python_base: Path, ffmpeg_package: Path):
    assert engine.is_file() and old.is_file() and new.is_file()
    assert python_base.is_dir() and (python_base / "bin/python3.12").is_file()
    assert ffmpeg_package.is_dir() and (ffmpeg_package / "__init__.py").is_file()
    assert ffmpeg_package.name == "imageio_ffmpeg" and not any(p.is_symlink() for p in ffmpeg_package.rglob("*"))
    policy = engine.parents[1] / "Resources/backend/python-runtime.json"
    expected_name = json.loads(policy.read_text())["directory"]
    assert python_base.name == expected_name, "Python distribution does not match the published worker policy"
    with tempfile.TemporaryDirectory(prefix="posle-worker-upgrade-", dir="/private/tmp") as temporary:
        parent = Path(temporary).resolve()
        root = parent / "data"
        root.mkdir(mode=0o700)
        # Prove the profile blocks sibling writes while allowing this root.
        probe = subprocess.run(confined(root, sys.executable, "-B", "-c",
            "import errno,pathlib,socket,sys; a=pathlib.Path(sys.argv[1]); b=pathlib.Path(sys.argv[2]); "
            "a.write_text('ok'); exec(\"try:\\n b.write_text('bad')\\nexcept PermissionError:\\n pass\\nelse:\\n raise SystemExit('write escaped fixture')\"); "
            "exec(\"try:\\n s=socket.socket(); s.connect(('127.0.0.1', 9))\\nexcept OSError as e:\\n assert e.errno in (errno.EPERM,errno.EACCES), e\\nelse:\\n raise SystemExit('network was not denied')\")",
            str(root / "allowed"), str(parent / "forbidden")), env=clean_environment(root), capture_output=True, text=True, timeout=10)
        assert probe.returncode == 0 and not (parent / "forbidden").exists(), "Could not confine fixture writes"
        verify = subprocess.run(confined(root, str(engine), "--posle-verify-python-runtime", str(python_base)),
                                capture_output=True, text=True, env=clean_environment(root), timeout=120)
        assert verify.returncode == 0, "Installed Python did not pass the published worker's integrity policy"
        base = root / "runtime/python" / expected_name
        base.parent.mkdir(mode=0o700, parents=True)
        shutil.copytree(python_base, base, symlinks=True)
        venv = root / "runtime/venv"
        subprocess.run(confined(root, str(base / "bin/python3.12"), "-B", "-I", "-m", "venv", "--symlinks", "--without-pip", str(venv)),
                       env=clean_environment(root), check=True, capture_output=True, timeout=120)
        package_dir = venv / "lib/python3.12/site-packages/imageio_ffmpeg"
        package_dir.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(ffmpeg_package, package_dir, symlinks=True)
        settings = root / "settings.json"
        settings.write_text(json.dumps({"speechMode": "cloud", "diarization": False,
                                        "features": {"knowledgeBase": True}}))
        old_note = core(old, root, "note-save", note={"id": "synthetic", "kind": "note",
            "text": "Тестовая заметка", "createdAt": 1, "updatedAt": 1, "revision": 0})
        snapshot = core(new, root, "kb-snapshot", noteID=old_note["id"])
        assert snapshot["kbRevision"] == 0
        worker(engine, root, "prepare", expect_success=True)
        assert (root / "runtime/media/После Медиа").is_file()
        assert core(new, root, "notes-list")["notes"][0]["text"] == old_note["text"]
        assert core(new, root, "kb-snapshot", noteID="synthetic")["libraryID"] == snapshot["libraryID"]
        print("PASS: published worker prepare runs offline after KB extension and preserves notes")

        meeting = root / "meetings/synthetic-meeting"
        meeting.mkdir(parents=True)
        (meeting / "meta.json").write_text(json.dumps({"id":"synthetic-meeting", "title":"Тестовая встреча",
            "source":"input.wav", "status":"recorded", "recordingTracks":False}))
        with wave.open(str(meeting / "input.wav"), "wb") as audio:
            audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000)
            audio.writeframes(b"\x00\x00" * 16000)
        transcript = meeting / "transcript.json"
        transcript.write_text(json.dumps({"duration":1.0,"segments":[{"id":0,"start":0,"end":1,"text":"Сохранённый текст"}]}))
        before = hashlib.sha256(transcript.read_bytes()).digest()
        settings.write_text(json.dumps({"speechMode":"local", "asrModelPath":str(root / "not-installed"), "diarization":False,
                                        "features":{"knowledgeBase":True}}))
        events = worker(engine, root, "transcribe", "--meeting", str(meeting), "--no-diarization", expect_success=False)
        assert any("модел" in str(event.get("message", "")).lower() for event in events), events
        assert hashlib.sha256(transcript.read_bytes()).digest() == before
        assert (meeting / "input.wav").is_file()
        assert core(new, root, "kb-snapshot", noteID="synthetic")["libraryID"] == snapshot["libraryID"]
        print("PASS: published worker handles missing ASR model offline without overwriting an existing transcript")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old-engine", type=Path, required=True)
    parser.add_argument("--old-library", type=Path, required=True)
    parser.add_argument("--new-library", type=Path, required=True)
    parser.add_argument("--python-base", type=Path, required=True)
    parser.add_argument("--ffmpeg-package", type=Path, required=True)
    args = parser.parse_args()
    main(*(path.resolve(strict=True) for path in (args.old_engine, args.old_library, args.new_library,
                                                   args.python_base, args.ffmpeg_package)))
