"""Failure-path regressions using disposable models, PCM and real worker signals."""
import fcntl
import io
import json
import os
import shutil
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import time
import types
import unittest
import wave
import zipfile
from unittest.mock import patch

import embedded_bridge
import engine
import models


class MalformedModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="posle-malformed-model-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def model(self, name):
        directory = self.root / name
        directory.mkdir()
        (directory / "config.json").write_text(json.dumps({"encoder": {}, "joint": {"vocabulary": ["a"]},
            "model_defaults": {"tdt_durations": [0, 1]}}))
        self.weights(directory, {"weight": {"data_offsets": [0, 1024]}})
        return directory

    def weights(self, directory, header):
        encoded = json.dumps(header).encode()
        (directory / "model.safetensors").write_bytes(struct.pack("<Q", len(encoded)) + encoded + bytes(1024))

    def test_one_malformed_model_does_not_abort_discovery_of_other_models(self):
        valid = self.model("parakeet-valid")
        malformed = []
        for name, header in (("parakeet-header-list", []), ("parakeet-tensor-null", {"weight": None})):
            directory = self.model(name)
            self.weights(directory, header)
            malformed.append(directory)
        directory = self.model("parakeet-defaults-list")
        (directory / "config.json").write_text(json.dumps({"encoder": {}, "joint": {"vocabulary": ["a"]}, "model_defaults": []}))
        malformed.append(directory)
        directory = self.model("parakeet-index-null")
        (directory / "model.safetensors.index.json").write_text('{"weight_map":null}')
        malformed.append(directory)
        found, _ = models.discover_asr(self.root, roots=[(self.root, "Synthetic")])
        by_path = {item["path"]: item for item in found}
        self.assertTrue(by_path[str(valid)]["compatible"])
        for directory in malformed:
            self.assertFalse(by_path[str(directory)]["compatible"])
            self.assertTrue(by_path[str(directory)]["reason"])

    def test_whisper_rejected_format_is_never_reported_compatible_or_selected(self):
        directory = self.root / "whisper-small"; directory.mkdir()
        config = dict.fromkeys(("n_mels", "n_audio_ctx", "n_audio_state", "n_audio_head", "n_audio_layer", "n_vocab",
                                "n_text_ctx", "n_text_state", "n_text_head", "n_text_layer"), 1)
        (directory / "config.json").write_text(json.dumps(config))
        with zipfile.ZipFile(directory / "weights.npz", "w") as archive:
            archive.writestr("synthetic.npy", bytes(1024))
        self.assertTrue(models.inspect_model(directory, requested_format="mlx")["compatible"])
        rejected = models.inspect_model(directory, requested_format="onnx")
        self.assertFalse(rejected["compatible"])
        self.assertIn("ONNX", rejected["reason"])
        (self.root / "settings.json").write_text(json.dumps({"asrModelPath": str(directory), "asrModelFormat": "onnx"}))
        with self.assertRaisesRegex(RuntimeError, "Повторная загрузка не выполнялась"):
            models.selected_asr(self.root)


class TruncatedPCMTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="posle-truncated-pcm-")
        self.path = Path(self.temp.name) / "synthetic.wav"
        with wave.open(str(self.path), "wb") as output:
            output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            output.writeframes(bytes(32000))
        # A valid WAV header declares one second, but its payload has been lost.
        self.path.write_bytes(self.path.read_bytes()[:244])

    def tearDown(self):
        self.temp.cleanup()

    def test_diarization_and_embedded_parakeet_reject_truncated_pcm(self):
        for reader in (engine.read_wave, embedded_bridge._pcm_numpy_audio):
            with self.subTest(reader=reader.__name__), self.assertRaisesRegex(RuntimeError, "повреждена|обрезана"):
                reader(self.path)

    def test_whisper_and_onnx_never_decode_incomplete_pcm_window(self):
        for layout in ("whisper-mlx", "meetily-onnx"):
            calls = []
            def decode(*args, **kwargs):
                calls.append(True)
                return {"segments": []} if layout == "whisper-mlx" else types.SimpleNamespace(tokens=[], timestamps=[], text="")
            adapter = object.__new__(engine.ASRAdapter)
            adapter.selected = {"layout": layout, "path": "/synthetic/model"}
            adapter.model = types.SimpleNamespace(transcribe=decode, recognize=decode)
            with self.subTest(layout=layout), self.assertRaisesRegex(RuntimeError, "повреждена|обрезана"):
                adapter.transcribe(self.path, lambda *_: None)
            self.assertEqual(calls, [])


    def test_truncated_source_cannot_replace_transcript_or_invalidate_summary(self):
        directory = self.path.parent
        source_bytes = self.path.read_bytes()
        engine.atomic(directory / "meta.json", {"source": self.path.name})
        transcript = directory / "transcript.json"; transcript.write_bytes(b'{"previous":true}')
        summary = directory / "summary.json"; summary.write_bytes(b'{"previous-summary":true}')
        selected = {"layout": "whisper-mlx", "name": "Synthetic", "path": "/synthetic/model", "format": "mlx"}
        adapter = object.__new__(engine.ASRAdapter); adapter.selected = selected
        adapter.model = types.SimpleNamespace(transcribe=lambda *_args, **_kwargs: {"segments": []})
        closed = []; adapter.close = lambda: closed.append(True)
        with patch.object(engine, "PROTOCOL", io.StringIO()), \
                patch.object(engine, "ffmpeg", side_effect=lambda *a: Path(a[-1]).write_bytes(b"synthetic playback")), \
                patch.object(engine, "audio_wave", side_effect=lambda source, target, *a: shutil.copyfile(source, target)), \
                patch.object(engine, "resolve_asr", return_value=selected), patch.object(engine, "ASRAdapter", return_value=adapter), \
                self.assertRaisesRegex(RuntimeError, "повреждена|обрезана"):
            engine.transcribe(directory, directory, 0, False)
        self.assertEqual(transcript.read_bytes(), b'{"previous":true}')
        self.assertEqual(summary.read_bytes(), b'{"previous-summary":true}')
        self.assertEqual(self.path.read_bytes(), source_bytes)
        self.assertEqual(closed, [True])


class WorkerTerminationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="posle-worker-signal-")
        self.root = Path(self.temp.name)
        self.meeting = self.root / "meetings" / "synthetic"; self.meeting.mkdir(parents=True)
        for name in ("synthetic.wav", "audio.wav"):
            with wave.open(str(self.meeting / name), "wb") as output:
                output.setparams((1, 2, 16000, 0, "NONE", "not compressed")); output.writeframes(bytes(32000))
        engine.atomic(self.meeting / "meta.json", {"source": "synthetic.wav"})
        engine.atomic(self.root / "settings.json", {"speechMode": "cloud", "speechCloudProvider": "custom",
            "speechCloudEndpoint": "https://synthetic.invalid/v1", "speechCloudModel": "synthetic", "speechResponseFormat": "verbose_json"})
        self.previous = {"transcript.json": b'{"previous":true}', "summary.json": b'{"previous-summary":true}',
                         "synthetic.wav": (self.meeting / "synthetic.wav").read_bytes()}
        for name, contents in self.previous.items():
            (self.meeting / name).write_bytes(contents)

    def tearDown(self):
        self.temp.cleanup()

    def child(self, scenario):
        script = r'''
import os, signal, sys, time
from pathlib import Path
import engine, cloud_speech, media_runtime
root, scenario = Path(sys.argv[1]), sys.argv[2]
meeting = root / "meetings/synthetic"
media_runtime.configure = lambda *_: None
engine.audio_wave = lambda *_: None
engine.ffmpeg = lambda *args: Path(args[-1]).write_bytes(b"synthetic playback")
original_atomic = engine.atomic
def atomic(path, data):
    original_atomic(path, data)
    if scenario == "publication" and path.name == "transcript.json":
        os.kill(os.getpid(), signal.SIGTERM)
engine.atomic = atomic
def upload(path, settings, key):
    assert path.is_file()
    if scenario in ("upload", "lock"):
        (root / "ready").touch()
    if scenario == "upload":
        time.sleep(60)
    if scenario == "lock":
        deadline = time.monotonic() + 10
        while not (root / "allow-upload").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert (root / "allow-upload").exists(), "parent did not release synthetic uploader"
    return {"text": "Synthetic words", "segments": [{"start": 0.1, "end": 0.9, "text": "Synthetic words"}]}
cloud_speech.upload = upload
sys.argv = [engine.__file__, "transcribe", "--root", str(root), "--meeting", str(meeting), "--no-diarization"]
if hasattr(engine, "worker_main"):
    sys.exit(engine.worker_main())
engine.main()
'''
        env = {"PATH": "/usr/bin:/bin", "PYTHONPATH": str(Path(engine.__file__).parent), "PYTHONDONTWRITEBYTECODE": "1",
               "POSLE_SPEECH_API_KEY": "synthetic"}
        return subprocess.Popen([sys.executable, "-c", script, str(self.root), scenario], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_sigterm_during_upload_removes_private_chunks_and_preserves_old_results(self):
        process = self.child("upload")
        try:
            deadline = time.monotonic() + 10
            while not (self.root / "ready").exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.root / "ready").exists(), "synthetic uploader did not start")
            self.assertTrue(list((self.root / "cache").glob("speech-upload-*/chunk-*.wav")))
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 130, (stdout, stderr))
            self.assertFalse(list((self.root / "cache").iterdir()))
            for name, contents in self.previous.items():
                self.assertEqual((self.meeting / name).read_bytes(), contents)
            retry = self.child("retry")
            try:
                retry_stdout, retry_stderr = retry.communicate(timeout=10)
                self.assertEqual(retry.returncode, 0, (retry_stdout, retry_stderr))
                self.assertIn(b'"event": "done"', retry_stdout)
                self.assertEqual(engine.load(self.meeting / "transcript.json")["segments"][0]["text"], "Synthetic words")
                self.assertFalse((self.meeting / "summary.json").exists())
                self.assertFalse(list((self.root / "cache").iterdir()))
            finally:
                if retry.poll() is None:
                    retry.kill(); retry.communicate(timeout=5)
        finally:
            if process.poll() is None:
                process.kill(); process.communicate(timeout=5)

    def test_transcript_commit_waits_for_other_process_holding_meeting_lock(self):
        process = self.child("lock")
        try:
            deadline = time.monotonic() + 10
            while not (self.root / "ready").exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.root / "ready").exists(), "synthetic uploader did not start")
            with (self.meeting / ".posle-storage.lock").open("a+b") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                (self.root / "allow-upload").touch()
                with self.assertRaises(subprocess.TimeoutExpired):
                    process.wait(timeout=0.1)
                for name, contents in self.previous.items():
                    self.assertEqual((self.meeting / name).read_bytes(), contents)
                fcntl.flock(lock, fcntl.LOCK_UN)
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, (stdout, stderr))
            self.assertIn(b'"event": "done"', stdout)
            self.assertFalse((self.meeting / "summary.json").exists())
        finally:
            if process is not None and process.poll() is None:
                process.kill(); process.communicate(timeout=5)

    def test_sigterm_after_transcript_replacement_finishes_summary_invalidation(self):
        process = self.child("publication")
        try:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, (stdout, stderr))
            self.assertIn(b'"event": "done"', stdout)
            self.assertEqual(engine.load(self.meeting / "transcript.json")["segments"][0]["text"], "Synthetic words")
            self.assertFalse((self.meeting / "summary.json").exists())
            self.assertEqual((self.meeting / "synthetic.wav").read_bytes(), self.previous["synthetic.wav"])
            self.assertFalse(list((self.root / "cache").iterdir()))
        finally:
            if process.poll() is None:
                process.kill(); process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
