import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import engine


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
        for command in ("prepare", "install-local", "finalize", "transcribe"):
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


if __name__ == "__main__":
    unittest.main()
