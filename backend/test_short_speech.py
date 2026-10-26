"""Short dictation uses owned synthetic files and mocked ASR/HTTP only."""
import ctypes
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import tempfile
from threading import Thread
import unittest
from unittest.mock import patch
import uuid
import wave

import cloud_speech
import embedded_bridge
import engine
import short_speech


class ShortSpeechTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="posle-short-speech-")
        self.root = Path(self.temporary.name)
        self.session = self.root / "voice-inputs" / str(uuid.uuid4())
        self.session.mkdir(parents=True)
        self.audio = self.session / "input.m4a"
        self.audio.write_bytes(b"synthetic-input-not-a-personal-recording")
        self.settings = {"speechMode": "local"}
        self.events = []
        self.stop = False
        self.closed = False
        self.duration = 1
        self.tokens = [{"text": " Создай", "start": 0, "end": .4}, {"text": " заметку", "start": .4, "end": .9}]
        self.callback = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_void_p)(lambda data, _: self.events.append(json.loads(data)))
        self.cancel = ctypes.CFUNCTYPE(ctypes.c_int)(lambda: int(self.stop))
        self.request = {"root": str(self.root), "command": "dictate", "audio": str(self.audio),
                        "eventCallback": ctypes.cast(self.callback, ctypes.c_void_p).value,
                        "cancelCallback": ctypes.cast(self.cancel, ctypes.c_void_p).value}
        owner = self
        class Adapter:
            def __init__(self, selected, root):
                self.selected = selected
            def transcribe(self, audio, callback):
                callback(1, 1)
                return owner.tokens
            def close(self):
                owner.closed = True
        self.adapter = Adapter

    def tearDown(self):
        self.temporary.cleanup()

    def prepare(self, *args):
        path = Path(args[-1])
        with wave.open(str(path), "wb") as target:
            target.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            target.writeframes(b"\0\0" * round(16000 * self.duration))

    def run_bridge(self):
        with patch.object(embedded_bridge, "_media", return_value=Path("/usr/bin/true")), \
             patch.object(engine, "load", return_value=self.settings), \
             patch.object(engine, "ffmpeg", side_effect=self.prepare), \
             patch.object(engine, "resolve_asr", return_value={"name": "Synthetic ASR", "layout": "onnx", "path": "owned"}), \
             patch.object(engine, "ASRAdapter", self.adapter):
            # The bridge installs its own ffmpeg wrapper; patch the shared
            # implementation immediately before the isolated dictation call.
            original = short_speech.transcribe
            def dictate(*args):
                with patch.object(engine, "ffmpeg", side_effect=self.prepare):
                    return original(*args)
            with patch.object(short_speech, "transcribe", side_effect=dictate):
                return json.loads(embedded_bridge.run(json.dumps(self.request)))

    def assert_source_and_library_unchanged(self):
        self.assertEqual(self.audio.read_bytes(), b"synthetic-input-not-a-personal-recording")
        self.assertFalse((self.root / "meetings").exists())
        self.assertEqual(list(self.session.iterdir()), [self.audio])

    def test_local_dictation_returns_text_and_closes_model_without_creating_meeting(self):
        environment = dict(os.environ)
        result = self.run_bridge()
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["value"]["text"], "Создай заметку")
        self.assertEqual(result["value"]["model"], "Synthetic ASR")
        self.assertEqual(result["value"]["segments"][0]["speaker"], "self")
        self.assertTrue(self.closed)
        self.assertEqual(dict(os.environ), environment)
        self.assert_source_and_library_unchanged()

    def test_cancel_after_asr_closes_model_and_discards_command(self):
        owner = self
        class CancelAdapter(self.adapter):
            def transcribe(self, audio, callback):
                owner.stop = True
                return owner.tokens
        self.adapter = CancelAdapter
        result = self.run_bridge()
        self.assertFalse(result["ok"])
        self.assertTrue(result["cancelled"])
        self.assertTrue(self.closed)
        self.assertNotIn("done", [event["event"] for event in self.events])
        self.assert_source_and_library_unchanged()

    def test_error_after_loading_model_closes_it_and_retry_is_possible(self):
        class ErrorAdapter(self.adapter):
            def transcribe(self, audio, callback):
                raise RuntimeError("synthetic inference error")
        original, self.adapter = self.adapter, ErrorAdapter
        result = self.run_bridge()
        self.assertFalse(result["ok"])
        self.assertIn("synthetic inference error", result["error"])
        self.assertTrue(self.closed)
        self.assert_source_and_library_unchanged()
        self.adapter = original
        self.assertTrue(self.run_bridge()["ok"])

    def test_cloud_uses_explicit_memory_key_and_existing_provider_settings(self):
        self.settings = {"speechMode": "cloud", "speechCloudProvider": "custom", "speechCloudEndpoint": "http://127.0.0.1:8080/v1", "speechCloudModel": "synthetic-cloud"}
        self.request["apiKey"] = "synthetic-memory-key"
        seen = []
        def upload(path, settings, key, timeout):
            self.assertEqual(timeout, 30)
            self.assertTrue(path.is_file())
            seen.append((settings["speechCloudModel"], key))
            return {"text": "Создай задачу"}
        with patch.object(cloud_speech, "upload", side_effect=upload):
            result = self.run_bridge()
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["value"]["text"], "Создай задачу")
        self.assertEqual(seen, [("synthetic-cloud", "synthetic-memory-key")])
        self.assertFalse(self.closed)  # No local model loaded for cloud ASR.
        self.assertNotIn("apiKey", json.dumps(result))
        self.assert_source_and_library_unchanged()

    def test_cloud_dictation_reaches_only_explicit_localhost_fixture_with_actual_multipart(self):
        seen = []
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                seen.append((self.path, self.headers.get("Authorization"), body))
                payload = json.dumps({"text": "Create a task"}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=lambda: server.serve_forever(poll_interval=.01), daemon=True)
        thread.start()
        try:
            self.settings = {"speechMode": "cloud", "speechCloudProvider": "custom",
                             "speechCloudEndpoint": f"http://127.0.0.1:{server.server_port}/v1",
                             "speechCloudModel": "fixture-only-speech"}
            self.request["apiKey"] = "fixture-only-memory-key"
            result = self.run_bridge()
            self.assertTrue(result["ok"], result)
            self.assertEqual(result["value"]["text"], "Create a task")
            self.assertEqual(len(seen), 1)
            path, authorization, body = seen[0]
            self.assertEqual(path, "/v1/audio/transcriptions")
            self.assertEqual(authorization, "Bearer fixture-only-memory-key")
            self.assertIn(b"fixture-only-speech", body)
            self.assertIn(b'filename="audio.wav"', body)
            self.assertNotIn(b"fixture-only-memory-key", body)
            self.assert_source_and_library_unchanged()
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=2)

    def test_cloud_cancel_after_response_does_not_emit_command(self):
        self.settings = {"speechMode": "cloud"}
        self.request["apiKey"] = "synthetic-memory-key"
        def upload(*args, **kwargs):
            self.stop = True
            return {"text": "Не выполнять"}
        with patch.object(cloud_speech, "upload", side_effect=upload):
            result = self.run_bridge()
        self.assertTrue(result["cancelled"])
        self.assertNotIn("done", [event["event"] for event in self.events])
        self.assert_source_and_library_unchanged()

    def test_cloud_request_key_is_redacted_even_if_short(self):
        self.settings = {"speechMode": "cloud"}
        for secret in ("xy", "synthetic-explicit-key"):
            self.request["apiKey"] = secret
            with patch.object(cloud_speech, "upload", side_effect=RuntimeError("upstream credential=" + secret)):
                result = self.run_bridge()
            self.assertFalse(result["ok"])
            self.assertNotIn(secret, result["error"])
            self.assertIn("[hidden]", result["error"])
            self.assert_source_and_library_unchanged()

    def test_silence_and_invalid_model_timestamps_are_not_successful_commands(self):
        for tokens in ([], [{"text": "bad", "start": 0, "end": float("nan")}], [{"text": "bad", "start": 0, "end": 5}]):
            self.tokens = tokens
            result = self.run_bridge()
            self.assertFalse(result["ok"])
            self.assertTrue(self.closed)
            self.assert_source_and_library_unchanged()

    def test_audio_limits_are_enforced_before_loading_asr(self):
        for duration in (.1, 180.05):
            self.duration = duration
            result = self.run_bridge()
            self.assertFalse(result["ok"])
            self.assertFalse(self.closed)
            self.assert_source_and_library_unchanged()

    def test_path_validation_refuses_foreign_links_and_traversal(self):
        self.assertEqual(short_speech.validate_input(self.root, str(self.audio)), self.audio)
        victim = self.root / "foreign.wav"
        victim.write_bytes(b"private")
        for path in (victim, self.root / "voice-inputs" / "wrong-session" / "input.wav", self.session / ".." / "input.wav"):
            with self.assertRaises(RuntimeError):
                short_speech.validate_input(self.root, str(path))
        link = self.session / "link.wav"; link.symlink_to(victim)
        with self.assertRaises(RuntimeError):
            short_speech.validate_input(self.root, str(link))
        link.unlink()
        os.link(victim, link)
        with self.assertRaises(RuntimeError):
            short_speech.validate_input(self.root, str(link))
        self.assertEqual(victim.read_bytes(), b"private")

    def test_settings_and_session_symlinks_cannot_be_followed(self):
        foreign = self.root / "outside-settings.json"; foreign.write_text("{}")
        (self.root / "settings.json").symlink_to(foreign)
        self.assertFalse(self.run_bridge()["ok"])
        (self.root / "settings.json").unlink()
        other = self.root / str(uuid.uuid4()); other.mkdir()
        (other / "input.wav").write_bytes(b"synthetic")
        session = self.root / "voice-inputs" / str(uuid.uuid4()); session.symlink_to(other)
        self.request["audio"] = str(session / "input.wav")
        self.assertFalse(self.run_bridge()["ok"])


if __name__ == "__main__":
    unittest.main()
