"""Control-path checks; all inference/media is replaced by synthetic fixtures."""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import embedded_bridge


class EmbeddedBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="posle-embedded-control-")
        self.root = Path(self.temp.name)
        self.meeting = self.root / "meetings" / "synthetic"
        self.meeting.mkdir(parents=True)
        (self.meeting / "meta.json").write_text(json.dumps({"source": "synthetic.wav"}))
        (self.meeting / "synthetic.wav").write_bytes(b"synthetic-not-a-real-recording")
        self.events = []
        self.stop = False
        self.callback = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_void_p)(lambda data, _: self.events.append(json.loads(data)))
        self.cancel = ctypes.CFUNCTYPE(ctypes.c_int)(lambda: int(self.stop))
        self.request = {"root": str(self.root), "meeting": str(self.meeting), "command": "transcribe",
                        "eventCallback": ctypes.cast(self.callback, ctypes.c_void_p).value,
                        "cancelCallback": ctypes.cast(self.cancel, ctypes.c_void_p).value}
        self.engine = SimpleNamespace(ffmpeg=lambda *a: None, emit=lambda *a, **kw: None,
            contextlib=object(), atomic=lambda path, data: path.write_text(json.dumps(data)),
            resolve_asr=lambda root, allow_download=False: {"layout": "onnx"},
            speaker_models=lambda root: (), speaker_models_installed=lambda root: True,
            load=lambda path, default: {})

    def tearDown(self):
        self.temp.cleanup()

    def run_bridge(self):
        with patch.dict(sys.modules, {"engine": self.engine}), patch.object(embedded_bridge, "_media", return_value=Path("/usr/bin/true")):
            return json.loads(embedded_bridge.run(json.dumps(self.request)))

    def test_repeated_calls_restore_app_stdio_environment_and_subprocess(self):
        stdout, stderr, popen, environment = sys.stdout, sys.stderr, subprocess.Popen, dict(os.environ)
        original_emit, original_context = self.engine.emit, self.engine.contextlib
        def transcribe(meeting, root, speakers, diarization):
            self.engine.emit("progress", message="synthetic", fraction=0.5)
            self.engine.atomic(meeting / "transcript.json", {"synthetic": True})
            self.engine.emit("done", count=1)
        self.engine.transcribe = transcribe
        for _ in range(3):
            self.assertTrue(self.run_bridge()["ok"])
            self.assertIs(sys.stdout, stdout); self.assertIs(sys.stderr, stderr)
            self.assertIs(subprocess.Popen, popen)
            self.assertIs(self.engine.emit, original_emit); self.assertIs(self.engine.contextlib, original_context)
            self.assertEqual(dict(os.environ), environment)
        self.assertEqual(len(self.events), 6)

    def test_cooperative_cancel_cannot_replace_previous_transcript(self):
        original = b'{"previous":true}'
        path = self.meeting / "transcript.json"; path.write_bytes(original)
        def transcribe(meeting, root, speakers, diarization):
            self.engine.emit("progress", message="synthetic", fraction=0.2)
            self.stop = True
            self.engine.atomic(path, {"must-not-commit": True})
        self.engine.transcribe = transcribe
        result = self.run_bridge()
        self.assertFalse(result["ok"]); self.assertTrue(result["cancelled"])
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(len(self.events), 1)

    def test_cancel_during_publication_does_not_split_metadata_transaction(self):
        self.request["command"] = "diarize"
        def rediarize(meeting, root, speakers):
            self.engine.atomic(meeting / "meta.json", {"source": "synthetic.wav", "speakerNames": {}})
            self.stop = True
            self.engine.atomic(meeting / "transcript.json", {"revised": True})
            self.engine.emit("done", count=1)
        self.engine.rediarize = rediarize
        result = self.run_bridge()
        self.assertTrue(result["ok"])
        self.assertTrue(json.loads((self.meeting / "transcript.json").read_text())["revised"])

    def test_local_errors_do_not_echo_ambient_keys(self):
        def transcribe(*args):
            raise RuntimeError("synthetic-private-key")
        self.engine.transcribe = transcribe
        with patch.dict(os.environ, {"SYNTHETIC_API_KEY": "synthetic-private-key"}):
            result = self.run_bridge()
        self.assertFalse(result["ok"])
        self.assertNotIn("synthetic-private-key", result["error"])
        self.assertIn("[hidden]", result["error"])

    def test_short_speech_credentials_are_redacted_from_errors(self):
        for key in ("Q", "xy", "abc"):
            def transcribe(*args):
                raise RuntimeError("upstream value=" + key)
            self.engine.transcribe = transcribe
            with patch.dict(os.environ, {"POSLE_SPEECH_API_KEY": key}):
                result = self.run_bridge()
            self.assertFalse(result["ok"])
            self.assertNotIn(key, result["error"])
            self.assertIn("[hidden]", result["error"])

    def test_no_foreign_paths_or_implicit_install_commands(self):
        self.request["command"] = "prepare"
        self.assertFalse(self.run_bridge()["ok"])
        self.request["command"] = "transcribe"
        self.request["meeting"] = str(self.root / "outside")
        self.assertFalse(self.run_bridge()["ok"])

    def test_fixed_recording_outputs_cannot_follow_foreign_symlinks(self):
        self.request["command"] = "finalize"
        (self.meeting / "meta.json").write_text(json.dumps({"source": "recording.mov", "hasVideo": True}))
        victim = self.root / "must-not-change"; victim.write_bytes(b"original")
        for output in ("recording.mp3", "video.mp4"):
            link = self.meeting / output; link.symlink_to(victim)
            self.assertFalse(self.run_bridge()["ok"])
            self.assertEqual(victim.read_bytes(), b"original")
            link.unlink()

    def test_subprocess_environment_excludes_credentials_and_python_overrides(self):
        safe = embedded_bridge._safe_environment({"PATH": "/usr/bin", "OPENAI_API_KEY": "secret", "HF_TOKEN": "secret", "PYTHONPATH": "outside"})
        self.assertEqual(safe, {"PATH": "/usr/bin"})


if __name__ == "__main__":
    unittest.main()
