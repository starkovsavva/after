import contextlib
import io
import importlib.util
import json
import struct
import types
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import engine
import models


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.output = patch.object(engine, "PROTOCOL", io.StringIO())
        self.output.start()

    def tearDown(self):
        self.output.stop()
        self.temp.cleanup()

    def test_speaker_is_selected_by_overlap(self):
        turns = [{"start": 0, "end": 2, "speaker": "speaker_1"}, {"start": 2, "end": 4, "speaker": "speaker_2"}]
        self.assertEqual(engine.assign_speaker(0.5, 1, turns), ("speaker_1", False))
        self.assertEqual(engine.assign_speaker(2.1, 3, turns), ("speaker_2", False))

    def test_overlapping_and_uncovered_voices_are_not_guessed(self):
        turns = [{"start": 0, "end": 3, "speaker": "speaker_1"}, {"start": 0, "end": 3, "speaker": "speaker_2"}]
        self.assertEqual(engine.assign_speaker(1, 2, turns), ("unknown", True))
        self.assertEqual(engine.assign_speaker(4, 5, turns), ("unknown", False))

    def test_bpe_tokens_never_split_a_word_between_speakers(self):
        tokens = [{"text": "Hello", "start": 0, "end": 0.5}, {"text": " world", "start": 1, "end": 1.5}, {"text": "!", "start": 1.5, "end": 1.6}]
        turns = [{"start": 0, "end": 0.8, "speaker": "speaker_1"}, {"start": 0.9, "end": 2, "speaker": "speaker_2"}]
        segments = engine.group_tokens(tokens, turns)
        self.assertEqual([s["text"] for s in segments], ["Hello", "world!"])
        self.assertEqual([s["speaker"] for s in segments], ["speaker_1", "speaker_2"])

    def test_separate_mic_track_has_fixed_self_identity(self):
        tokens = [{"text": "My answer", "start": 1, "end": 2}]
        self.assertEqual(engine.group_tokens(tokens, [], "self")[0]["speaker"], "self")

    def test_atomic_write_is_private_and_leaves_no_partial_json(self):
        destination = self.root / "notes.json"
        engine.atomic(destination, {"text": "Важная деталь"})
        self.assertEqual(engine.load(destination)["text"], "Важная деталь")
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(list(self.root.glob(".posle-*"))), 0)

    def test_failed_atomic_replace_preserves_previous_file_and_removes_partial(self):
        destination = self.root / "transcript.json"
        engine.atomic(destination, {"version": "previous"})
        before = destination.read_bytes()
        with patch.object(engine.os, "replace", side_effect=OSError("disk unavailable")):
            with self.assertRaises(OSError):
                engine.atomic(destination, {"version": "new"})
        self.assertEqual(destination.read_bytes(), before)
        self.assertEqual(list(self.root.glob(".posle-*")), [])

    def test_invalid_numbers_never_replace_valid_transcript(self):
        destination = self.root / "transcript.json"
        engine.atomic(destination, {"duration": 10})
        with self.assertRaises(ValueError):
            engine.atomic(destination, {"duration": float("nan")})
        self.assertEqual(engine.load(destination), {"duration": 10})
        self.assertEqual(list(self.root.glob(".posle-*")), [])

    def test_cli_allows_only_audio_and_model_install_commands(self):
        for command in ("prepare", "install-local", "finalize", "transcribe", "discover-models"):
            arguments = [command, "--root", str(self.root)]
            if command in ("finalize", "transcribe"):
                arguments += ["--meeting", str(self.root / "meeting")]
            self.assertEqual(engine.parse_arguments(arguments).command, command)
        for command in ("summarize", "example", "review", "check", "pull"):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                engine.parse_arguments([command, "--root", str(self.root)])
            self.assertEqual(error.exception.code, 2)

    def test_cli_rejects_missing_meeting_relative_paths_and_negative_speakers(self):
        cases = [
            ["transcribe", "--root", str(self.root)],
            ["finalize", "--root", str(self.root)],
            ["prepare", "--root", "relative"],
            ["transcribe", "--root", str(self.root), "--meeting", "relative"],
            ["transcribe", "--root", str(self.root), "--meeting", str(self.root), "--speakers", "-1"],
        ]
        for arguments in cases:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                engine.parse_arguments(arguments)
            self.assertEqual(error.exception.code, 2)

    def test_failed_video_finalize_preserves_source_for_retry(self):
        source = self.root / "recording.mov"
        source.write_bytes(b"original capture")
        metadata = {"source": source.name, "recordingTracks": False, "hasVideo": True}
        engine.atomic(self.root / "meta.json", metadata)

        def convert(*arguments):
            output = Path(arguments[-1])
            if output.name == "video.mp4":
                raise RuntimeError("video conversion interrupted")
            output.write_bytes(b"converted audio")

        with patch.object(engine, "audio_wave"), patch.object(engine, "ffmpeg", side_effect=convert):
            with self.assertRaisesRegex(RuntimeError, "interrupted"):
                engine.finalize_recording(self.root)
        self.assertEqual(source.read_bytes(), b"original capture")
        self.assertEqual(engine.load(self.root / "meta.json"), metadata)
        self.assertTrue((self.root / "recording.mp3").exists())


class LocalModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def sparse(self, path, size):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as out:
            out.truncate(size)
        return path

    def mlx(self, path):
        path.mkdir(parents=True)
        (path / "config.json").write_text(json.dumps({"encoder": {}, "joint": {"vocabulary": ["a"]},
            "model_defaults": {"tdt_durations": [0, 1, 2, 3, 4]}}))
        header = json.dumps({"encoder.weight": {"dtype": "F32", "shape": [256], "data_offsets": [0, 1024]}}).encode()
        (path / "model.safetensors").write_bytes(struct.pack("<Q", len(header)) + header + bytes(1024))
        return path

    def meetily(self, path):
        self.sparse(path / "encoder-model.int8.onnx", 100_000_000)
        self.sparse(path / "decoder_joint-model.int8.onnx", 1_000_000)
        self.sparse(path / "nemo128.onnx", 1024)
        (path / "vocab.txt").write_text("▁hello 0\n<blk> 1\n", encoding="utf-8")
        return path

    def test_hf_snapshot_is_reused_in_place_without_network_or_cache_mutation(self):
        home = self.root / "home"
        snapshot = self.mlx(home / ".cache/huggingface/hub/models--mlx-community--parakeet-tdt-0.6b-v3/snapshots/revision")
        before = {p.name: (p.stat().st_size, p.stat().st_mtime_ns, p.read_bytes()) for p in snapshot.iterdir()}
        roots = list(models.search_roots(self.root / "posle", home=home))
        found, _ = models.discover_asr(self.root, roots=roots)
        self.assertEqual([model["path"] for model in found if model["compatible"]], [str(snapshot)])
        with patch.object(models, "discover_asr", return_value=(found, [])), patch.object(engine, "speaker_models"), \
                patch.object(engine, "PROTOCOL", io.StringIO()), patch.dict("sys.modules", {"huggingface_hub": None}):
            engine.prepare(self.root / "posle")
        after = {p.name: (p.stat().st_size, p.stat().st_mtime_ns, p.read_bytes()) for p in snapshot.iterdir()}
        self.assertEqual(before, after)

    def test_meetily_exact_joint_layout_and_sherpa_layout_are_supported_separately(self):
        meetily = self.meetily(self.root / "Meetily/models/parakeet/parakeet-tdt-0.6b-v3-int8")
        first = models.inspect_model(meetily, "Meetily")
        self.assertTrue(first["compatible"], first["reason"])
        self.assertEqual(first["layout"], "meetily-onnx")
        sherpa = self.root / "sherpa-onnx-parakeet-v3"
        self.sparse(sherpa / "encoder.int8.onnx", 100_000_000)
        self.sparse(sherpa / "decoder.int8.onnx", 1_000_000)
        self.sparse(sherpa / "joiner.int8.onnx", 100_000)
        (sherpa / "tokens.txt").write_text("▁hello 0\n<blk> 1\n")
        second = models.inspect_model(sherpa)
        self.assertTrue(second["compatible"], second["reason"])
        self.assertEqual(second["layout"], "sherpa-onnx")

    def test_incomplete_mlx_and_onnx_models_are_visible_but_never_selected(self):
        mlx = self.mlx(self.root / "parakeet-mlx")
        weights = mlx / "model.safetensors"
        weights.write_bytes(weights.read_bytes()[:-10])
        onnx = self.meetily(self.root / "parakeet-onnx")
        (onnx / "decoder_joint-model.int8.onnx").unlink()
        found, _ = models.discover_asr(self.root, roots=[(self.root, "Test")])
        self.assertEqual(len(found), 2)
        self.assertFalse(any(item["compatible"] for item in found))
        self.assertIn("не полностью", models.inspect_model(mlx)["reason"])
        self.assertIn("decoder_joint", models.inspect_model(onnx)["reason"])

    def test_explicit_wrong_path_or_format_stops_without_default_download(self):
        (self.root / "settings.json").write_text(json.dumps({"asrModelPath": str(self.root / "missing")}))
        with patch.dict("sys.modules", {"huggingface_hub": None}), self.assertRaisesRegex(RuntimeError, "Повторная загрузка не выполнялась"):
            engine.resolve_asr(self.root, allow_download=True)
        onnx = self.meetily(self.root / "parakeet-v3")
        (self.root / "settings.json").write_text(json.dumps({"asrModelPath": str(onnx), "asrModelFormat": "mlx"}))
        with self.assertRaisesRegex(RuntimeError, "Выбран MLX"):
            engine.resolve_asr(self.root, allow_download=True)

    def test_fp32_external_data_and_vocabulary_are_required(self):
        model = self.meetily(self.root / "parakeet-v3")
        (model / "encoder-model.int8.onnx").unlink()
        self.sparse(model / "encoder-model.onnx", 42_000_000)
        self.assertFalse(models.inspect_model(model)["compatible"])
        self.sparse(model / "encoder-model.onnx.data", 1_000_000_000)
        self.assertTrue(models.inspect_model(model)["compatible"])
        (model / "vocab.txt").write_text("▁hello 0\nmissingblank 1\n")
        self.assertIn("<blk>", models.inspect_model(model)["reason"])

    def test_nemo_gguf_and_english_only_v2_are_not_misrepresented(self):
        directory = self.root / "parakeet-gguf"
        directory.mkdir()
        (directory / "model.gguf").write_bytes(b"GGUF")
        self.assertFalse(models.inspect_model(directory)["compatible"])
        v2 = models.inspect_model(self.meetily(self.root / "parakeet-tdt-v2-int8"))
        self.assertTrue(v2["compatible"])
        self.assertIn("только английский", v2["reason"])

    def test_discovery_never_walks_meeting_content_or_directory_symlinks(self):
        hidden = self.mlx(self.root / "meetings/parakeet-v3")
        alias = self.root / "linked-models"
        alias.symlink_to(hidden, target_is_directory=True)
        found, _ = models.discover_asr(self.root, roots=[(self.root, "Test")])
        self.assertEqual(found, [])

    def test_onnx_chunks_cover_long_audio_with_disjoint_timestamp_ownership(self):
        spans = engine.chunk_windows(75)
        self.assertEqual(len(spans), 5)
        self.assertTrue(all(end - start <= 20 for start, end, _, _ in spans))
        self.assertEqual(spans[0][2], 0)
        self.assertEqual(spans[-1][3], 75)
        for current, following in zip(spans, spans[1:]):
            self.assertEqual(current[3], following[2])
        tokens = engine.timestamp_tokens(["Hel", "lo", " world"], [0.1, 0.1, 0.7], 2)
        words = engine.owned_chunk_words(tokens, 18, 18, 19, False)
        self.assertEqual([word["text"] for word in words], [" Hello", " world"])
        self.assertAlmostEqual(words[0]["start"], 18.1)
        self.assertGreater(words[0]["end"], words[0]["start"])
        exact = engine.timestamp_tokens([" word"], [0.1], 2, durations=[0.32])
        self.assertAlmostEqual(exact[0]["end"], 0.42)
        with self.assertRaisesRegex(RuntimeError, "временные метки"):
            engine.timestamp_tokens(["hello"], None, 2)

    @unittest.skipUnless(importlib.util.find_spec("onnx_asr") and importlib.util.find_spec("onnxruntime"), "optional ONNX runtime API integration")
    def test_real_onnx_asr_public_api_with_stubbed_neural_graphs(self):
        # Exercise the installed maintained library, real NumPy preprocessing,
        # public with_timestamps/recognize API and local resolver. Only expensive
        # neural graph evaluation is stubbed, so no model download is needed.
        import numpy as np
        import onnxruntime
        import socket
        import wave
        original_session = onnxruntime.InferenceSession
        model_dir = self.meetily(self.root / "parakeet-v3")
        calls = []

        class Encoder:
            def run(self, outputs, inputs):
                assert inputs["audio_signal"].shape[1] == 128
                calls.append("encoder")
                return np.zeros((1, 1024, 4), dtype=np.float32), np.array([4], dtype=np.int64)

        class Decoder:
            count = 0

            def get_inputs(self):
                return [types.SimpleNamespace(name=name, shape=[2, 1, 640])
                        for name in ("input_states_1", "input_states_2")]

            def run(self, outputs, inputs):
                logits = np.full((1, 1, 7), -10, dtype=np.float32)
                logits[0, 0, 0 if self.count == 0 else 1] = 10
                logits[0, 0, 3] = 10  # TDT duration index 1
                self.count += 1
                return logits, inputs["input_states_1"], inputs["input_states_2"]

        def session(path, **kwargs):
            if isinstance(path, Path) and path.name == "encoder-model.onnx":
                return Encoder()
            if isinstance(path, Path) and path.name == "decoder_joint-model.onnx":
                return Decoder()
            return original_session(path, **kwargs)

        audio = self.root / "fixture.wav"
        with wave.open(str(audio), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(16000)
            out.writeframes(np.zeros(16000, dtype=np.int16).tobytes())
        with patch.object(onnxruntime, "InferenceSession", side_effect=session), \
                patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden")):
            adapter = engine.ASRAdapter(models.inspect_model(model_dir), self.root / "posle")
            try:
                tokens = adapter.transcribe(audio, lambda *_: None)
            finally:
                adapter.close()
        self.assertEqual(calls, ["encoder"])
        self.assertEqual([token["text"].strip() for token in tokens], ["hello"])
        self.assertEqual(tokens[0]["start"], 0)
        self.assertGreater(tokens[0]["end"], 0)

    def test_meetily_adapter_uses_private_local_wrapper_and_keeps_originals_unchanged(self):
        directory = self.meetily(self.root / "parakeet-v3")
        selected = models.inspect_model(directory)
        original = {p.name: (p.stat().st_size, p.stat().st_mtime_ns) for p in directory.iterdir()}
        calls = []

        def load_model(name, **kwargs):
            wrapper = kwargs["path"]
            self.assertEqual(name, "nemo-conformer-tdt")
            self.assertEqual(kwargs["providers"], ["CPUExecutionProvider"])
            self.assertEqual(engine.load(wrapper / "config.json")["features_size"], 128)
            self.assertTrue((wrapper / "encoder-model.onnx").is_symlink())
            self.assertEqual((wrapper / "encoder-model.onnx").resolve(), (directory / "encoder-model.int8.onnx").resolve())
            calls.append(wrapper)
            return types.SimpleNamespace(with_timestamps=lambda: object())

        with patch.dict("sys.modules", {"onnx_asr": types.SimpleNamespace(load_model=load_model),
                                        "onnxruntime": types.SimpleNamespace(SessionOptions=types.SimpleNamespace)}):
            adapter = engine.ASRAdapter(selected, self.root / "posle")
            adapter.close()
        self.assertEqual(len(calls), 1)
        self.assertFalse(calls[0].exists())
        self.assertEqual(original, {p.name: (p.stat().st_size, p.stat().st_mtime_ns) for p in directory.iterdir()})


if __name__ == "__main__":
    unittest.main()
