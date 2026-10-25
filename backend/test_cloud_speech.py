import contextlib
import io
import json
import os
import struct
import tempfile
import types
import unittest
import urllib.error
import urllib.request
import urllib.response
from email.message import Message
import wave
from pathlib import Path
from unittest.mock import patch

import cloud_speech
import engine
import models


def audio(path, frames=16_000, pcm=None):
    with wave.open(str(path), "wb") as target:
        target.setparams((1, 2, 16_000, 0, "NONE", "not compressed"))
        target.writeframes(pcm if pcm is not None else b"\0\0" * frames)


class CloudSpeechTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.wav = self.root / "audio.wav"
        audio(self.wav)
        self.settings = {"speechCloudProvider": "custom", "speechCloudEndpoint": "https://speech.example/v1", "speechCloudModel": "test-asr", "speechResponseFormat": "verbose_json"}

    def tearDown(self): self.temp.cleanup()

    def test_endpoint_routes_and_rejects_credentials_in_url(self):
        self.assertEqual(cloud_speech.endpoint({}), "https://api.openai.com/v1/audio/transcriptions")
        self.assertEqual(cloud_speech.endpoint(self.settings), "https://speech.example/v1/audio/transcriptions")
        for address in ("http://speech.example/v1", "https://key@host/v1", "https://host/v1?k=secret", "https://host/v1#token"):
            with self.subTest(address=address), self.assertRaises(RuntimeError):
                cloud_speech.endpoint(dict(self.settings, speechCloudEndpoint=address))
        self.assertEqual(cloud_speech.endpoint(dict(self.settings, speechCloudEndpoint="http://127.0.0.1:8000/v1")), "http://127.0.0.1:8000/v1/audio/transcriptions")

    def test_multipart_contains_actual_audio_and_selected_model(self):
        captures = []
        class Opener:
            def open(_, request, timeout):
                captures.append(request)
                return contextlib.closing(io.BytesIO(b'{"text":"hello"}'))
        result = cloud_speech.upload(self.wav, self.settings, "test-secret", Opener())
        self.assertEqual(result["text"], "hello")
        request = captures[0]
        self.assertEqual(request.full_url, "https://speech.example/v1/audio/transcriptions")
        self.assertEqual(request.get_header("Authorization"), "Bearer test-secret")
        self.assertIn(b'name="file"; filename="audio.wav"', request.data)
        self.assertIn(self.wav.read_bytes(), request.data)
        self.assertIn(b"test-asr", request.data)
        self.assertNotIn(b"test-secret", request.data)

    def test_loopback_upload_bypasses_ambient_proxy_without_network(self):
        captures = []
        class CaptureHTTP(urllib.request.BaseHandler):
            handler_order = 400
            def http_open(_, request):
                captures.append((request.host, request.get_header("Authorization")))
                response = urllib.response.addinfourl(io.BytesIO(b'{"text":"hello"}'), Message(), request.full_url, code=200)
                response.msg = "OK"
                return response
            https_open = http_open
        original = urllib.request.build_opener
        def opener(*handlers): return original(*handlers, CaptureHTTP())
        environment = {"http_proxy": "http://proxy.invalid:3128", "https_proxy": "http://proxy.invalid:3128"}
        with patch.dict(os.environ, environment, clear=True), patch.object(urllib.request, "proxy_bypass", return_value=False), patch.object(urllib.request, "build_opener", side_effect=opener):
            for address, expected_host in (("http://localhost:8000/v1", "localhost:8000"),
                                           ("http://127.0.0.1:8000/v1", "127.0.0.1:8000"),
                                           ("http://[::1]:8000/v1", "[::1]:8000"),
                                           ("https://localhost:8000/v1", "localhost:8000")):
                with self.subTest(address=address):
                    result = cloud_speech.upload(self.wav, dict(self.settings, speechCloudEndpoint=address), "test-secret")
                    self.assertEqual(result["text"], "hello")
                    self.assertEqual(captures[-1], (expected_host, "Bearer test-secret"))
            # The control proves this fixture would observe a proxy rewrite.
            cloud_speech.upload(self.wav, self.settings, "test-secret")
            self.assertEqual(captures[-1][0], "proxy.invalid:3128")

    def test_diarized_fields_and_new_model_language_contract(self):
        settings = dict(self.settings, speechCloudModel="gpt-4o-transcribe-diarize", speechResponseFormat="diarized_json")
        fields = dict(cloud_speech.request_fields(settings))
        self.assertEqual(fields["chunking_strategy"], "auto")
        self.assertNotIn("timestamp_granularities[]", fields)
        fields = dict(cloud_speech.request_fields({"speechCloudModel": "gpt-transcribe", "speechLanguage": "ru"}))
        self.assertEqual(fields["languages[]"], "ru")
        self.assertNotIn("language", fields)

    def test_http_errors_do_not_echo_provider_keys_or_audio(self):
        class Opener:
            def open(_, request, timeout):
                raise urllib.error.HTTPError(request.full_url, 401, "test-secret", {}, io.BytesIO(b"test-secret"))
        with self.assertRaises(RuntimeError) as error:
            cloud_speech.upload(self.wav, self.settings, "test-secret", Opener())
        self.assertNotIn("test-secret", str(error.exception))
        self.assertIn("Ключ", str(error.exception))

    def test_chunk_frames_are_contiguous_and_include_final_tail(self):
        pcm = b"".join(struct.pack("<h", n % 30000) for n in range(48_017))
        audio(self.wav, pcm=pcm)
        chunks, spans = [], []
        for path, start, length, _ in cloud_speech.pcm_chunks(self.wav, self.root, seconds=1):
            with wave.open(str(path)) as source: chunks.append(source.readframes(source.getnframes()))
            spans.append((start, length))
        self.assertEqual(b"".join(chunks), pcm)
        self.assertEqual(len(chunks), 4)
        self.assertEqual(spans[-1], (3.0, 17 / 16000))
        self.assertFalse(list(self.root.glob("chunk-*.wav")))

    def test_parse_preserves_full_text_and_absolute_timestamps(self):
        response = {"text": "Привет мир", "segments": [{"start": 0.2, "end": 0.7, "text": "Привет", "speaker": "A"}, {"start": 0.7, "end": 1, "text": "мир", "speaker": "B"}]}
        segments, approximate = cloud_speech.parse_response(response, 600, 1)
        self.assertEqual([s["text"] for s in segments], ["Привет", "мир"])
        self.assertEqual(segments[-1]["end"], 601)
        self.assertFalse(approximate)
        with self.assertRaises(RuntimeError): cloud_speech.parse_response(dict(response, text="Привет мир и потерянный хвост"), 0, 1)

    def test_diarized_top_level_speaker_annotations_are_not_lost_words(self):
        result = {"text": "Agent: Hello.\n A: Hi.", "segments": [{"start": 0, "end": 0.5, "text": "Hello.", "speaker": "agent"}, {"start": 0.5, "end": 1, "text": "Hi.", "speaker": "A"}]}
        segments, _ = cloud_speech.parse_response(result, 0, 1)
        self.assertEqual([s["text"] for s in segments], ["Hello.", "Hi."])

    def test_invalid_timestamps_and_truncated_segments_fail(self):
        for start, end in ((float("nan"), 1), (0, float("inf")), (-1, 1), (0, 9), (1, 0)):
            with self.subTest(start=start, end=end), self.assertRaises(RuntimeError):
                cloud_speech.parse_response({"segments": [{"start": start, "end": end, "text": "hello"}]}, 0, 1)
        with self.assertRaises(RuntimeError): cloud_speech.parse_response({"text": "lost", "segments": []}, 0, 1)

    def test_json_only_uses_honest_fragment_boundaries(self):
        segments, approximate = cloud_speech.parse_response({"text": "Whole text"}, 120, 17.4)
        self.assertTrue(approximate)
        self.assertEqual([(s["start"], s["end"]) for s in segments], [(120, 137.4)])
        self.assertEqual(segments[0]["text"], "Whole text")

    def test_json_only_fragment_retains_approximate_timing_for_speaker_assignment(self):
        segments, _, labels = cloud_speech.transcribe(self.wav, self.root, dict(self.settings, speechResponseFormat="json"), lambda *_: None,
                                                      key="test", uploader=lambda *_: {"text": "Whole text"})
        self.assertTrue(segments[0]["_approximateTiming"])
        self.assertFalse(labels)

    def test_untimed_cloud_text_never_inherits_one_speaker_or_false_overlap(self):
        meeting = self.root / "meeting"; meeting.mkdir()
        audio(meeting / "recording.mp3")
        audio(meeting / "audio.wav", frames=65 * 16_000)
        engine.atomic(meeting / "meta.json", {"source": "recording.mp3"})
        engine.atomic(self.root / "settings.json", dict(self.settings, speechMode="cloud"))
        for switch in (30, 45):
            with self.subTest(switch=switch):
                response = ([{"start": 0, "end": 60, "text": "Two speakers in one untimed fragment", "speaker": "unknown", "overlap": False, "_approximateTiming": True},
                             {"start": 60, "end": 65, "text": "Exactly timed sentence", "speaker": "unknown", "overlap": False}], [], False)
                turns = [{"start": 0, "end": switch, "speaker": "speaker_1"}, {"start": switch, "end": 65, "speaker": "speaker_2"}]
                with patch.object(engine, "PROTOCOL", io.StringIO()), patch.object(engine, "audio_wave"), patch.object(cloud_speech, "transcribe", return_value=response), patch.object(engine, "speaker_models_installed", return_value=True), patch.object(engine, "meeting_speaker_turns", return_value=turns):
                    engine.transcribe(meeting, self.root, 0, True)
                result = engine.load(meeting / "transcript.json")
                self.assertEqual(result["segments"][0]["speaker"], "unknown")
                self.assertFalse(result["segments"][0]["overlap"])
                self.assertEqual(result["segments"][1]["speaker"], "speaker_2")
                self.assertFalse(any("_approximateTiming" in segment for segment in result["segments"]))
                self.assertTrue(any("Собеседники в таких аудиофрагментах не определены" in warning for warning in result["warnings"]))
                self.assertTrue(result["segments"][0]["timingApproximate"])
                with patch.object(engine, "PROTOCOL", io.StringIO()), patch.object(engine, "meeting_speaker_turns", return_value=turns):
                    engine.rediarize(meeting, self.root, 2)
                recalculated = engine.load(meeting / "transcript.json")
                self.assertEqual(recalculated["segments"], result["segments"])
                self.assertTrue(any("Собеседники в таких аудиофрагментах не определены" in warning for warning in recalculated["warnings"]))

    def test_untimed_only_response_skips_useless_local_diarization(self):
        meeting = self.root / "meeting"; meeting.mkdir()
        audio(meeting / "recording.mp3")
        audio(meeting / "audio.wav", frames=16_000)
        engine.atomic(meeting / "meta.json", {"source": "recording.mp3"})
        engine.atomic(self.root / "settings.json", dict(self.settings, speechMode="cloud"))
        response = ([{"start": 0, "end": 1, "text": "Untimed cloud text", "speaker": "unknown", "overlap": False, "_approximateTiming": True}], [], False)
        with patch.object(engine, "PROTOCOL", io.StringIO()), patch.object(engine, "audio_wave"), patch.object(cloud_speech, "transcribe", return_value=response), patch.object(engine, "meeting_speaker_turns") as split:
            engine.transcribe(meeting, self.root, 0, True)
        split.assert_not_called()
        result = engine.load(meeting / "transcript.json")
        self.assertEqual(result["segments"][0]["speaker"], "unknown")
        self.assertTrue(result["segments"][0]["timingApproximate"])

    def test_long_calls_do_not_invent_cross_chunk_speaker_identities(self):
        # Small PCM and one-second test chunks exercise the same real frame loop.
        audio(self.wav, frames=32_017)
        def uploader(path, settings, key):
            with wave.open(str(path)) as source: duration = source.getnframes() / source.getframerate()
            return {"text": "hello", "segments": [{"start": 0, "end": duration, "text": "hello", "speaker": "A"}]}
        original = cloud_speech.pcm_chunks
        def chunks(path, output, seconds): return original(path, output, seconds=1)
        with patch.object(cloud_speech, "pcm_chunks", side_effect=chunks):
            segments, warnings, labels = cloud_speech.transcribe(self.wav, self.root, dict(self.settings, speechResponseFormat="diarized_json"), lambda *_: None, key="test", uploader=uploader)
        self.assertFalse(labels)
        self.assertEqual({s["speaker"] for s in segments}, {"unknown"})
        self.assertEqual(len(segments), 3)
        self.assertEqual(segments[-1]["end"], 32_017 / 16000)
        self.assertTrue(warnings)
        self.assertEqual(list((self.root / "cache").iterdir()), [])

    def test_one_cloud_request_preserves_provided_speaker_labels(self):
        def uploader(*_): return {"text": "hello", "segments": [{"start": 0, "end": 1, "text": "hello", "speaker": "A"}]}
        segments, _, labels = cloud_speech.transcribe(self.wav, self.root, self.settings, lambda *_: None, key="test", uploader=uploader)
        self.assertTrue(labels)
        self.assertEqual(segments[0]["speaker"], "speaker_1")

    def test_failed_upload_removes_private_chunks(self):
        def uploader(*_): raise RuntimeError("network unavailable")
        with self.assertRaises(RuntimeError):
            cloud_speech.transcribe(self.wav, self.root, self.settings, lambda *_: None, key="test", uploader=uploader)
        self.assertEqual(list((self.root / "cache").iterdir()), [])
        self.assertTrue(self.wav.exists())

    def test_no_key_means_no_upload(self):
        with patch.object(cloud_speech, "upload") as uploader, self.assertRaises(RuntimeError):
            cloud_speech.transcribe(self.wav, self.root, self.settings, lambda *_: None, key="")
        uploader.assert_not_called()

    def test_cloud_engine_dispatch_does_not_load_local_asr_or_download_speakers(self):
        meeting = self.root / "meeting"; meeting.mkdir()
        audio(meeting / "recording.mp3")  # No decoding: audio_wave is stubbed below.
        audio(meeting / "audio.wav")
        engine.atomic(meeting / "meta.json", {"source": "recording.mp3"})
        engine.atomic(self.root / "settings.json", dict(self.settings, speechMode="cloud"))
        response = ([{"start": 0.1, "end": 0.8, "text": "Привет", "speaker": "unknown", "overlap": False}], [], False)
        with patch.object(engine, "PROTOCOL", io.StringIO()), patch.object(engine, "audio_wave"), patch.object(engine, "resolve_asr") as local, patch.object(cloud_speech, "transcribe", return_value=response), patch.object(engine, "speaker_models") as download:
            engine.transcribe(meeting, self.root, 0, True)
        local.assert_not_called(); download.assert_not_called()
        result = engine.load(meeting / "transcript.json")
        self.assertEqual(result["modelFormat"], "cloud")
        self.assertEqual(result["segments"][0]["id"], 0)
        self.assertEqual(result["segments"][0]["text"], "Привет")
        self.assertEqual(result["segments"][0]["speaker"], "unknown")
        self.assertTrue(result["warnings"])

    def test_whisper_adapter_preserves_word_times_and_rejects_missing_words(self):
        adapter = object.__new__(engine.ASRAdapter)
        adapter.selected = {"layout": "whisper-mlx", "path": "/validated/local/whisper"}
        calls = []
        def transcribe(path, **options):
            calls.append(options)
            return {"segments": [{"text": "Hello world", "words": [{"word": "Hello", "start": 0.1, "end": 0.4}, {"word": " world", "start": 0.5, "end": 0.9}]}]}
        adapter.model = types.SimpleNamespace(transcribe=transcribe)
        tokens = adapter.transcribe(self.wav, lambda *_: None)
        self.assertEqual(tokens, [{"text": " Hello", "start": 0.1, "end": 0.4}, {"text": " world", "start": 0.5, "end": 0.9}])
        self.assertEqual(calls[0]["path_or_hf_repo"], "/validated/local/whisper")
        self.assertTrue(calls[0]["word_timestamps"])
        adapter.model = types.SimpleNamespace(transcribe=lambda *_args, **_kwargs: {"segments": [{"text": "lost timing"}]})
        with self.assertRaises(RuntimeError): adapter.transcribe(self.wav, lambda *_: None)

    def test_catalog_selection_is_pinned_and_not_an_arbitrary_repository(self):
        for model in models.ASR_CATALOG.values():
            self.assertEqual(len(model["revision"]), 40)
        with self.assertRaises(RuntimeError): models.catalog_model({"speechLocalModel": "random/repository"})
        whisper = {"compatible": True, "format": "mlx", "layout": "whisper-mlx", "name": "mlx-community/whisper-large-v3-turbo", "path": "/tmp/whisper"}
        parakeet = {"compatible": True, "format": "mlx", "layout": "mlx", "name": "parakeet", "path": "/tmp/parakeet"}
        engine.atomic(self.root / "settings.json", {"speechLocalModel": "whisper-turbo"})
        with patch.object(models, "discover_asr", return_value=([parakeet, whisper], [])):
            self.assertEqual(models.selected_asr(self.root), whisper)
        engine.atomic(self.root / "settings.json", {"speechLocalModel": "parakeet-v3"})
        with patch.object(models, "discover_asr", return_value=([whisper, parakeet], [])):
            self.assertEqual(models.selected_asr(self.root), parakeet)


if __name__ == "__main__": unittest.main()
