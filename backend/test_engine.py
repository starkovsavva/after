import contextlib
import io
import importlib.util
import json
import struct
import sys
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
        for command in ("prepare", "install-local", "finalize", "transcribe", "diarize", "discover-models"):
            arguments = [command, "--root", str(self.root)]
            if command in ("finalize", "transcribe", "diarize"):
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
            ["diarize", "--root", str(self.root)],
            ["prepare", "--root", "relative"],
            ["transcribe", "--root", str(self.root), "--meeting", "relative"],
            ["transcribe", "--root", str(self.root), "--meeting", str(self.root), "--speakers", "-1"],
            ["diarize", "--root", str(self.root), "--meeting", str(self.root), "--speakers", "101"],
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
        self.assertEqual(list(self.root.glob(".posle-finalize-*")), [])


    def test_full_rate_intermediates_removed_when_finalize_is_cancelled_or_commit_fails(self):
        source = self.root / "recording.mov"
        source.write_bytes(b"original capture")
        metadata = {"source": source.name, "recordingTracks": True, "hasVideo": True,
                    "recordingAudioQuality": "high"}
        engine.atomic(self.root / "meta.json", metadata)

        def wave_copy(_source, target, *_args, **_kwargs):
            Path(target).write_bytes(b"synthetic wave")

        for failure in (KeyboardInterrupt(), OSError("metadata disk full")):
            def convert(*arguments):
                target = Path(arguments[-1])
                if isinstance(failure, KeyboardInterrupt) and target.name == "recording.mp3":
                    raise failure
                target.write_bytes(b"synthetic encoded audio")
            original_atomic = engine.atomic
            def commit(path, data):
                if isinstance(failure, OSError):
                    raise failure
                return original_atomic(path, data)
            with patch.object(engine, "audio_wave", side_effect=wave_copy), \
                    patch.object(engine, "ffmpeg", side_effect=convert), \
                    patch.object(engine, "atomic", side_effect=commit), self.assertRaises(type(failure)):
                engine.finalize_recording(self.root)
            self.assertEqual(source.read_bytes(), b"original capture")
            self.assertEqual(engine.load(self.root / "meta.json"), metadata)
            self.assertEqual(list(self.root.glob(".posle-finalize-*")), [])

    def test_unknown_recording_quality_does_not_break_recoverable_recording(self):
        source = self.root / "recording.mov"
        for quality in ("future-quality", {"invalid": True}):
            source.write_bytes(b"original capture")
            metadata = {"source": source.name, "recordingTracks": False, "recordingAudioQuality": quality}
            engine.atomic(self.root / "meta.json", metadata)
            conversions = []
            def convert(*arguments):
                conversions.append(arguments)
                Path(arguments[-1]).write_bytes(b"synthetic encoded audio")
            with patch.object(engine, "audio_wave"), patch.object(engine, "ffmpeg", side_effect=convert):
                engine.finalize_recording(self.root)
            mp3 = next(args for args in conversions if Path(args[-1]).name == "recording.mp3")
            self.assertEqual(mp3[mp3.index("-b:a") + 1], "128k")
            self.assertEqual(engine.load(self.root / "meta.json")["source"], "recording.mp3")
            self.assertFalse(source.exists())
            self.assertEqual(list(self.root.glob(".posle-finalize-*")), [])

    def test_imported_playback_failure_and_cancel_preserve_previous_audio_and_retry(self):
        source = self.root / "source.wav"; source.write_bytes(b"original imported audio")
        playback = self.root / "playback.mp3"; playback.write_bytes(b"previous complete playback")
        for failure in (RuntimeError("decode failed"), KeyboardInterrupt()):
            def convert(*arguments):
                Path(arguments[-1]).write_bytes(b"partial encoding")
                raise failure
            with patch.object(engine, "ffmpeg", side_effect=convert), self.assertRaises(type(failure)):
                engine.prepare_playback(source, self.root)
            self.assertEqual(source.read_bytes(), b"original imported audio")
            self.assertEqual(playback.read_bytes(), b"previous complete playback")
            self.assertEqual(list(self.root.glob(".posle-playback-*")), [])
        def convert(*arguments):
            Path(arguments[-1]).write_bytes(b"complete new playback")
        with patch.object(engine, "ffmpeg", side_effect=convert):
            engine.prepare_playback(source, self.root)
        self.assertEqual(source.read_bytes(), b"original imported audio")
        self.assertEqual(playback.read_bytes(), b"complete new playback")
        self.assertEqual(list(self.root.glob(".posle-playback-*")), [])

    def test_failed_imported_playback_publication_preserves_previous_audio(self):
        source = self.root / "source.mp3"; source.write_bytes(b"original imported MP3")
        playback = self.root / "playback.mp3"; playback.write_bytes(b"previous complete playback")
        def convert(*arguments):
            Path(arguments[-1]).write_bytes(b"complete new playback")
        with patch.object(engine, "ffmpeg", side_effect=convert), \
                patch.object(engine.os, "replace", side_effect=OSError("disk unavailable")), \
                self.assertRaisesRegex(OSError, "disk unavailable"):
            engine.prepare_playback(source, self.root)
        self.assertEqual(source.read_bytes(), b"original imported MP3")
        self.assertEqual(playback.read_bytes(), b"previous complete playback")
        self.assertEqual(list(self.root.glob(".posle-playback-*")), [])


class DiarizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.output = patch.object(engine, "PROTOCOL", io.StringIO())
        self.output.start()

    def tearDown(self):
        self.output.stop()
        self.temp.cleanup()

    def fixture(self, count=39, has_self=False):
        segments = [{"id": 100 + i, "start": i * 2 + 0.125, "end": i * 2 + 1.875,
                     "speaker": f"speaker_{i + 1}", "text": f"Original words {i}", "overlap": False,
                     "futureField": {"kept": True}} for i in range(count)]
        if has_self:
            segments.append({"id": 700, "start": 0.0, "end": 1.0, "speaker": "self", "text": "My own words", "overlap": False})
        original = {"duration": count * 2, "segments": segments, "warnings": ["Existing warning"], "futureTranscriptField": "kept"}
        meta = {"source": "recording.mp3", "recordingTracks": has_self,
                "speakerNames": {**{f"speaker_{i + 1}": f"Old name {i}" for i in range(count)}, "self": "Вы"},
                "title": "Keep this meeting title", "futureMetadataField": 72}
        engine.atomic(self.directory / "transcript.json", original)
        engine.atomic(self.directory / "meta.json", meta)
        (self.directory / "audio.wav").write_bytes(b"No neural/audio processing in this fixture")
        (self.directory / "summary.json").write_bytes(b'{"sources":[100,101,102]}')
        return original, meta

    def turns(self, count, remote_count=4):
        return [{"start": i * 2, "end": i * 2 + 1.99, "speaker": f"speaker_{i % remote_count + 1}"} for i in range(count)]

    def test_sparse_native_ids_are_compact_and_global_across_recurring_voices(self):
        raw = [types.SimpleNamespace(start=i, end=i + 0.8, speaker=voice) for i, voice in enumerate([0, 1, 3, 38, 0, 38])]
        normalized = engine.normalized_speaker_turns(raw, 0)
        self.assertEqual([turn["speaker"] for turn in normalized], ["speaker_1", "speaker_2", "speaker_3", "speaker_4", "speaker_1", "speaker_4"])

    def test_known_count_uses_audible_voices_not_vanishing_embedding_clusters(self):
        def raw(voices):
            return [types.SimpleNamespace(start=i, end=i + 0.8, speaker=voice) for i, voice in enumerate(voices)]
        responses = {0: raw(range(39)), 4: raw([0, 1, 3, 0, 1, 3]), 5: raw([0, 1, 3, 4, 0, 4])}
        calls = []
        def process(count):
            calls.append(count)
            return responses[count]
        result = engine.counted_speaker_turns(process, 4)
        self.assertEqual(calls, [0, 4, 5])
        self.assertEqual(len({turn["speaker"] for turn in result}), 4)

    def test_known_count_keeps_already_correct_auto_output_without_merging_real_people(self):
        raw = [types.SimpleNamespace(start=i, end=i + 0.8, speaker=voice) for i, voice in enumerate([0, 1, 3, 5, 0, 3])]
        calls = []
        def process(count):
            calls.append(count)
            return raw
        result = engine.counted_speaker_turns(process, 4)
        self.assertEqual(calls, [0])
        self.assertEqual([turn["speaker"] for turn in result], ["speaker_1", "speaker_2", "speaker_3", "speaker_4", "speaker_1", "speaker_3"])

    def test_impossible_known_count_never_requests_native_clusters_beyond_observed_rows(self):
        raw = [types.SimpleNamespace(start=0, end=2, speaker=0)]
        calls = []
        def process(count):
            calls.append(count)
            return raw
        result = engine.counted_speaker_turns(process, 100)
        self.assertEqual(calls, [0])
        self.assertEqual(len({turn["speaker"] for turn in result}), 1)
        self.assertEqual(engine.counted_speaker_turns(lambda _: [], 100), [])

    def test_count_refinement_has_bounded_cost_and_does_not_fabricate_people(self):
        calls = []
        def process(count):
            calls.append(count)
            voices = list(range(39)) if count == 0 else [0, 1, 2]
            return [types.SimpleNamespace(start=i, end=i + 0.8, speaker=voice) for i, voice in enumerate(voices)]
        result = engine.counted_speaker_turns(process, 4)
        self.assertEqual(len(calls), 4)
        self.assertEqual(len({turn["speaker"] for turn in result}), 3)
        _, warnings = engine.speaker_diagnostics([dict(turn) for turn in result], result, 4)
        self.assertIn("различимо голосов: 3", warnings[0])

    def test_exact_four_replaces_39_labels_without_changing_evidence(self):
        original, meta = self.fixture()
        summary_bytes = (self.directory / "summary.json").read_bytes()
        with patch.object(engine, "diarize", return_value=self.turns(39)) as inference, \
                patch.object(engine, "ASRAdapter", side_effect=AssertionError("must not run ASR")), \
                patch.object(engine, "audio_wave", side_effect=AssertionError("must reuse existing audio")):
            engine.rediarize(self.directory, self.directory, 4)
        inference.assert_called_once_with(self.directory / "audio.wav", self.directory, 4)
        revised = engine.load(self.directory / "transcript.json")
        self.assertEqual(len(set(segment["speaker"] for segment in revised["segments"])), 4)
        self.assertEqual(revised["diarization"]["requestedCount"], 4)
        for old, new in zip(original["segments"], revised["segments"]):
            self.assertEqual({key: value for key, value in old.items() if key not in ("speaker", "overlap")},
                             {key: value for key, value in new.items() if key not in ("speaker", "overlap")})
        self.assertEqual((self.directory / "summary.json").read_bytes(), summary_bytes)
        saved_meta = engine.load(self.directory / "meta.json")
        self.assertEqual(saved_meta, dict(meta, speakerNames={"self": "Вы"}))
        backups = list((self.directory / "diarization-history").glob("*.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(engine.load(backups[0]), {"transcript": original, "speakerNames": meta["speakerNames"]})
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(backups[0].parent.stat().st_mode & 0o777, 0o700)

    def test_four_total_includes_separate_microphone_as_one_person(self):
        original, _ = self.fixture(count=6, has_self=True)
        with patch.object(engine, "diarize", return_value=self.turns(6, remote_count=3)) as inference:
            engine.rediarize(self.directory, self.directory, 4)
        inference.assert_called_once_with(self.directory / "audio.wav", self.directory, 3)
        revised = engine.load(self.directory / "transcript.json")
        self.assertEqual({segment["speaker"] for segment in revised["segments"]}, {"self", "speaker_1", "speaker_2", "speaker_3"})
        self.assertEqual(revised["segments"][-1], original["segments"][-1])

    def test_single_total_with_separate_mic_does_not_invent_second_person(self):
        self.fixture(count=3, has_self=True)
        with patch.object(engine, "diarize", return_value=self.turns(3, remote_count=1)):
            engine.rediarize(self.directory, self.directory, 1)
        revised = engine.load(self.directory / "transcript.json")
        self.assertEqual({segment["speaker"] for segment in revised["segments"]}, {"self"})

    def test_auto_diagnostics_warn_about_fragmentation_without_hidden_speaker_cap(self):
        segments = [{"speaker": f"speaker_{i + 1}"} for i in range(39)]
        turns = self.turns(39, remote_count=39)
        diagnostics, warnings = engine.speaker_diagnostics(segments, turns, 0)
        self.assertEqual(diagnostics["detectedCount"], 39)
        self.assertEqual(len(warnings), 1)
        self.assertIn("39", warnings[0])
        self.assertIn("«Собеседники»", warnings[0])
        diagnostics, warnings = engine.speaker_diagnostics(segments[:4], turns[:4], 4)
        self.assertEqual(diagnostics["detectedCount"], 4)
        self.assertEqual(warnings, [])

    def test_short_native_single_chunk_cannot_exceed_requested_speaker_count(self):
        turns = [types.SimpleNamespace(start=i, end=i + 0.8, speaker=i) for i in range(3)]
        normalized = engine.normalized_speaker_turns(turns, 1)
        self.assertEqual({turn["speaker"] for turn in normalized}, {"speaker_1"})
        with self.assertRaisesRegex(RuntimeError, "число участников"):
            engine.normalized_speaker_turns(turns, 2)
        for value in (float("nan"), float("inf")):
            with self.assertRaisesRegex(RuntimeError, "временные метки"):
                engine.normalized_speaker_turns([types.SimpleNamespace(start=value, end=2, speaker=0)], 0)

    def test_failed_or_interrupted_inference_preserves_old_transcript_and_names(self):
        original, meta = self.fixture()
        for error in (RuntimeError("Model failure"), KeyboardInterrupt()):
            with patch.object(engine, "diarize", side_effect=error), self.assertRaises(type(error)):
                engine.rediarize(self.directory, self.directory, 4)
            self.assertEqual(engine.load(self.directory / "transcript.json"), original)
            self.assertEqual(engine.load(self.directory / "meta.json"), meta)
            self.assertFalse((self.directory / "diarization-history").exists())

    def test_missing_detected_speech_does_not_erase_existing_speaker_assignment(self):
        original, meta = self.fixture()
        with patch.object(engine, "diarize", return_value=[]), self.assertRaisesRegex(RuntimeError, "не обнаружила голоса"):
            engine.rediarize(self.directory, self.directory, 4)
        self.assertEqual(engine.load(self.directory / "transcript.json"), original)
        self.assertEqual(engine.load(self.directory / "meta.json"), meta)

    def test_failed_transcript_commit_rolls_back_speaker_names(self):
        original, meta = self.fixture()
        actual_atomic = engine.atomic
        def fail_transcript(path, data):
            if path.name == "transcript.json":
                raise OSError("disk full")
            actual_atomic(path, data)
        with patch.object(engine, "diarize", return_value=self.turns(39)), \
                patch.object(engine, "atomic", side_effect=fail_transcript), self.assertRaisesRegex(OSError, "disk full"):
            engine.rediarize(self.directory, self.directory, 4)
        self.assertEqual(engine.load(self.directory / "transcript.json"), original)
        self.assertEqual(engine.load(self.directory / "meta.json"), meta)
        self.assertEqual(len(list((self.directory / "diarization-history").glob("*.json"))), 1)

    def test_changed_transcript_during_inference_cannot_be_overwritten(self):
        original, meta = self.fixture()
        replacement = dict(original, concurrentEdit="keep this")
        def inference(*_):
            engine.atomic(self.directory / "transcript.json", replacement)
            return self.turns(39)
        with patch.object(engine, "diarize", side_effect=inference), self.assertRaisesRegex(RuntimeError, "изменилась"):
            engine.rediarize(self.directory, self.directory, 4)
        self.assertEqual(engine.load(self.directory / "transcript.json"), replacement)
        self.assertEqual(engine.load(self.directory / "meta.json"), meta)
        self.assertFalse((self.directory / "diarization-history").exists())

    def test_runtime_upgrade_only_removes_exact_owned_aliases(self):
        (self.directory / "После ИИ").write_bytes(b"owned helper")
        (self.directory / "ollama").symlink_to("После ИИ")
        outside = self.directory / "other-executable"
        outside.write_bytes(b"user binary")
        (self.directory / "llama-server").symlink_to(outside)
        engine.remove_owned_runtime_aliases(self.directory)
        self.assertFalse((self.directory / "ollama").is_symlink())
        self.assertTrue((self.directory / "После ИИ").is_file())
        self.assertTrue((self.directory / "llama-server").is_symlink())
        self.assertEqual(outside.read_bytes(), b"user binary")

    @unittest.skipUnless(importlib.util.find_spec("sherpa_onnx"), "optional Sherpa runtime API integration")
    def test_installed_sherpa_clustering_accepts_exact_total_and_existing_threshold(self):
        import sherpa_onnx
        config = sherpa_onnx.FastClusteringConfig(num_clusters=engine.remote_speaker_count(4, True), threshold=engine.DIARIZATION_THRESHOLD)
        self.assertTrue(config.validate())
        self.assertEqual(config.num_clusters, 3)
        self.assertAlmostEqual(config.threshold, 0.65, places=5)


class LocalModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_runtime_marker_repairs_missing_or_broken_executable_without_touching_model_weights(self):
        import shutil
        import tarfile
        replacement = b"\xcf\xfa\xed\xfe" + b"synthetic verified runtime"
        archive = self.root / "synthetic-runtime.tgz"
        with tarfile.open(archive, "w:gz") as package:
            info = tarfile.TarInfo("ollama"); info.mode = 0o700; info.size = len(replacement)
            package.addfile(info, io.BytesIO(replacement))
        digest = types.SimpleNamespace(update=lambda *_: None, hexdigest=lambda: "a2d1d906a2c8febd9cb18f5c183854d0a6db5dc522940d68b0c0ed048e8dfdea")
        for kind in ("missing", "dangling-owned-alias", "nonexecutable", "branded-nonexecutable", "bad-signature"):
            with self.subTest(kind=kind):
                root = self.root / kind
                directory = root / "runtime/ollama"; directory.mkdir(parents=True)
                marker = directory / "installed-v0.40.3-signed1"; marker.touch()
                original = directory / "ollama"
                if kind == "branded-nonexecutable":
                    branded = directory / "После ИИ"; branded.write_bytes(b"broken runtime"); branded.chmod(0o600)
                    original.symlink_to(branded.name)
                elif kind == "dangling-owned-alias": original.symlink_to("После ИИ")
                elif kind != "missing":
                    original.write_bytes(b"broken runtime"); original.chmod(0o700 if kind == "bad-signature" else 0o600)
                weights = root / "cache/ollama-models/blobs/existing-weights"
                weights.parent.mkdir(parents=True); weights.write_bytes(b"preserve downloaded model weights")
                def download(url, target):
                    self.assertIn("ollama-darwin", url)
                    shutil.copyfile(archive, target)
                def verify(arguments, **_):
                    self.assertEqual(arguments[:2], ["/usr/bin/codesign", "--verify"])
                    return types.SimpleNamespace(returncode=0 if Path(arguments[2]).read_bytes() == replacement else 1)
                with patch.object(engine, "download", side_effect=download) as fetched, \
                        patch.object(engine.hashlib, "sha256", return_value=digest), patch.object(engine.subprocess, "run", side_effect=verify):
                    engine.install_local(root)
                    self.assertEqual(fetched.call_count, 1)
                    self.assertEqual(original.read_bytes(), replacement)
                    self.assertTrue(marker.is_file())
                    fetched.reset_mock()
                    engine.install_local(root)
                    fetched.assert_not_called()
                self.assertEqual(weights.read_bytes(), b"preserve downloaded model weights")

    def test_signed_branded_runtime_with_owned_alias_does_not_download_again(self):
        directory = self.root / "runtime/ollama"; directory.mkdir(parents=True)
        (directory / "installed-v0.40.3-signed1").touch()
        branded = directory / "После ИИ"; branded.write_bytes(b"synthetic signed runtime"); branded.chmod(0o700)
        (directory / "ollama").symlink_to(branded.name)
        with patch.object(engine, "download") as fetched, \
                patch.object(engine.subprocess, "run", return_value=types.SimpleNamespace(returncode=0)) as verify:
            engine.install_local(self.root)
            fetched.assert_not_called()
            verify.assert_called_once_with(["/usr/bin/codesign", "--verify", str(branded)], capture_output=True)
        self.assertTrue((directory / "ollama").is_symlink())
        self.assertEqual(branded.read_bytes(), b"synthetic signed runtime")

    def test_runtime_marker_never_trusts_foreign_directory_or_executable_alias(self):
        outside = self.root / "foreign"; outside.mkdir()
        foreign = outside / "ollama"; foreign.write_bytes(b"foreign executable"); foreign.chmod(0o700)
        (outside / "installed-v0.40.3-signed1").touch()
        for directory_link in (False, True):
            with self.subTest(directory_link=directory_link):
                root = self.root / str(directory_link); (root / "runtime").mkdir(parents=True)
                directory = root / "runtime/ollama"
                if directory_link: directory.symlink_to(outside, target_is_directory=True)
                else:
                    directory.mkdir(); (directory / "installed-v0.40.3-signed1").touch()
                    (directory / "ollama").symlink_to(foreign)
                with patch.object(engine, "download") as fetched, patch.object(engine.subprocess, "run") as verify, self.assertRaises(RuntimeError):
                    engine.install_local(root)
                fetched.assert_not_called(); verify.assert_not_called()
                self.assertEqual(foreign.read_bytes(), b"foreign executable")

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


class WhisperChunkTests(unittest.TestCase):
    def setUp(self):
        import numpy as np
        import wave
        self.temp = tempfile.TemporaryDirectory(prefix="posle-whisper-owned-")
        self.root = Path(self.temp.name)
        self.directory = self.root / "meeting"; self.directory.mkdir()
        self.audio = self.directory / "synthetic.wav"
        self.samples = ((np.arange(75 * 16000, dtype=np.int32) % 32768) - 16384).astype(np.int16)
        with wave.open(str(self.audio), "wb") as out:
            out.setparams((1, 2, 16000, 0, "NONE", "not compressed")); out.writeframes(self.samples.tobytes())
        self.words = [(0.1, 0.7, "first"), (28.5, 28.8, "bridge"), (29.1, 29.4, "joined"),
                      (56.4, 56.8, "owner"), (57.4, 57.8, "action"), (74.4, 74.8, "tail")]
        self.calls = []
        self.closed = []
        self.selected = {"layout": "whisper-mlx", "path": "/models/synthetic-whisper", "name": "Synthetic Whisper", "format": "mlx"}
        self.adapter = object.__new__(engine.ASRAdapter)
        self.adapter.selected = self.selected
        self.adapter.close = lambda: self.closed.append(True)
        def decode(audio, **options):
            index = len(self.calls); start = (0, 28, 56)[index]
            self.assertEqual(len(audio), (30 if index < 2 else 19) * 16000)
            self.assertEqual(audio.dtype, np.float32)
            self.assertAlmostEqual(float(audio[0]), int(self.samples[start * 16000]) / 32768.0)
            self.assertEqual(options["path_or_hf_repo"], self.selected["path"])
            self.assertTrue(options["word_timestamps"])
            self.assertFalse(options["condition_on_previous_text"])
            self.calls.append((start, len(audio)))
            words = [{"word": word, "start": left - start, "end": right - start}
                     for left, right, word in self.words if start <= left and right <= start + len(audio) / 16000]
            return {"segments": [{"text": " ".join(word["word"] for word in words), "words": words}]}
        self.adapter.model = types.SimpleNamespace(transcribe=decode)
        engine.atomic(self.directory / "meta.json", {"source": "synthetic.wav"})
        self.output = patch.object(engine, "PROTOCOL", io.StringIO()); self.output.start()

    def tearDown(self):
        self.output.stop(); self.temp.cleanup()

    def test_whisper_windows_keep_boundary_words_once_and_preserve_final_tail_offsets(self):
        progress = []
        tokens = self.adapter.transcribe(self.audio, lambda done, total: progress.append((done, total)))
        self.assertEqual([token["text"].strip() for token in tokens], [word for _, _, word in self.words])
        self.assertEqual(len(self.calls), 3)
        for token, (start, end, _) in zip(tokens, self.words):
            self.assertAlmostEqual(token["start"], start); self.assertAlmostEqual(token["end"], end)
        self.assertEqual(progress[0], (0, 3)); self.assertEqual(progress[-1], (3, 3))
        self.assertIn((1, 3), progress); self.assertIn((2, 3), progress)

    def pipeline(self, progress):
        import shutil
        with patch.object(engine, "audio_wave", side_effect=lambda source, target, *a: shutil.copyfile(source, target)), \
                patch.object(engine, "ffmpeg", side_effect=lambda *a: Path(a[-1]).write_bytes(b"synthetic playback")), \
                patch.object(engine, "resolve_asr", return_value=self.selected), \
                patch.object(engine, "ASRAdapter", return_value=self.adapter), patch.object(engine, "progress", side_effect=progress):
            engine.transcribe(self.directory, self.root, 0, False)

    def test_full_pipeline_keeps_word_text_source_ids_and_tail(self):
        engine.atomic(self.directory / "transcript.json", {"previous-transcript": True})
        engine.atomic(self.directory / "summary.json", {"previous-summary": True})
        self.pipeline(lambda *_: None)
        transcript = engine.load(self.directory / "transcript.json")
        self.assertEqual(transcript["duration"], 75)
        self.assertEqual([segment["id"] for segment in transcript["segments"]], list(range(len(transcript["segments"]))))
        self.assertEqual(" ".join(segment["text"] for segment in transcript["segments"]), "first bridge joined owner action tail")
        self.assertAlmostEqual(transcript["segments"][-1]["end"], 74.8)
        self.assertEqual(self.closed, [True])
        self.assertFalse((self.directory / "summary.json").exists(), "An unchanged old summary must be invalidated after successful ASR")

    def test_transcription_rejects_transcript_edit_during_inference(self):
        transcript = self.directory / "transcript.json"
        summary = self.directory / "summary.json"
        transcript.write_bytes(b'{"previous-transcript":true}')
        summary.write_bytes(b'{"previous-summary":true}')
        correction = b'{"manual-transcript-edit":true}'
        changed = False
        def progress(message, fraction=-1):
            nonlocal changed
            if message == "Распознаю речь · 33%":
                # A second window uses this same lock. It must be free during
                # the model work, otherwise editing would block the main app.
                import fcntl
                with (self.directory / ".posle-storage.lock").open("r+b") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    transcript.write_bytes(correction)
                    changed = True
        with self.assertRaisesRegex(RuntimeError, "правки сохранены"):
            self.pipeline(progress)
        self.assertTrue(changed)
        self.assertEqual(transcript.read_bytes(), correction)
        self.assertEqual(summary.read_bytes(), b'{"previous-summary":true}')
        self.assertEqual(self.closed, [True])
        self.assertNotIn('"event": "done"', engine.PROTOCOL.getvalue())

    def test_transcription_rejects_summary_edit_during_inference(self):
        transcript = self.directory / "transcript.json"
        summary = self.directory / "summary.json"
        transcript.write_bytes(b'{"previous-transcript":true}')
        summary.write_bytes(b'{"previous-summary":true}')
        correction = b'{"manual-summary-edit":true}'
        def progress(message, fraction=-1):
            if message == "Распознаю речь · 33%": summary.write_bytes(correction)
        with self.assertRaisesRegex(RuntimeError, "правки сохранены"):
            self.pipeline(progress)
        self.assertEqual(transcript.read_bytes(), b'{"previous-transcript":true}')
        self.assertEqual(summary.read_bytes(), correction)
        self.assertEqual(self.closed, [True])
        self.assertNotIn('"event": "done"', engine.PROTOCOL.getvalue())

    def test_transcription_preserves_summary_created_during_inference(self):
        transcript = self.directory / "transcript.json"
        summary = self.directory / "summary.json"
        transcript.write_bytes(b'{"previous-transcript":true}')
        created = b'{"new-manual-summary":true}'
        def progress(message, fraction=-1):
            if message == "Распознаю речь · 33%": summary.write_bytes(created)
        with self.assertRaisesRegex(RuntimeError, "правки сохранены"):
            self.pipeline(progress)
        self.assertEqual(transcript.read_bytes(), b'{"previous-transcript":true}')
        self.assertEqual(summary.read_bytes(), created)
        self.assertEqual(self.closed, [True])
        self.assertNotIn('"event": "done"', engine.PROTOCOL.getvalue())

    def test_cancel_after_first_window_prevents_next_decode_and_preserves_previous_results(self):
        class SyntheticStop(BaseException): pass
        transcript = self.directory / "transcript.json"; transcript.write_bytes(b'{"previous-transcript":true}')
        summary = self.directory / "summary.json"; summary.write_bytes(b'{"previous-summary":true}')
        original_audio = self.audio.read_bytes()
        def progress(message, fraction=-1):
            if message == "Распознаю речь · 33%": raise SyntheticStop()
        with self.assertRaises(SyntheticStop): self.pipeline(progress)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.closed, [True])
        self.assertEqual(transcript.read_bytes(), b'{"previous-transcript":true}')
        self.assertEqual(summary.read_bytes(), b'{"previous-summary":true}')
        self.assertEqual(self.audio.read_bytes(), original_audio)


if __name__ == "__main__":
    unittest.main()
