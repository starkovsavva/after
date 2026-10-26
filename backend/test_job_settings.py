"""A queued operation keeps its destination/model without rewriting app Settings."""
import contextvars
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import engine
import models


class JobSettingsTests(unittest.TestCase):
    def test_process_snapshot_wins_without_mutating_settings(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "settings.json"
            path.write_text('{"mode":"local","cloudEndpoint":"https://old.example"}')
            original = path.read_bytes()
            snapshot = {"mode": "cloud", "cloudEndpoint": "https://selected.example", "cloudModel": "selected"}
            with patch.dict(os.environ, {"POSLE_JOB_SETTINGS": json.dumps(snapshot)}):
                self.assertEqual(engine.load(path), snapshot)
                self.assertEqual(models._json(path), snapshot)
                self.assertEqual(engine.load(path.parent / "meta.json", {}), {})
            self.assertEqual(path.read_bytes(), original)

    def test_snapshot_validation_and_bound(self):
        with patch.dict(os.environ, {"POSLE_JOB_SETTINGS": '[]'}):
            with self.assertRaises(RuntimeError):
                engine.load(Path("settings.json"))
            with self.assertRaises(ValueError):
                models._json(Path("settings.json"))
        with patch.dict(os.environ, {"POSLE_JOB_SETTINGS": 'x' * 262145}):
            with self.assertRaises(RuntimeError):
                engine.load(Path("settings.json"))

    def test_embedded_selection_context_does_not_leak_to_next_operation(self):
        first = {"asrModelFormat": "invalid-first"}
        second = {"asrModelFormat": "invalid-second"}
        token = models.SETTINGS_OVERRIDE.set(first)
        try:
            isolated = contextvars.copy_context()
            isolated.run(models.SETTINGS_OVERRIDE.set, second)
            self.assertEqual(isolated.run(models.SETTINGS_OVERRIDE.get), second)
            self.assertEqual(models.SETTINGS_OVERRIDE.get(), first)
        finally:
            models.SETTINGS_OVERRIDE.reset(token)
        self.assertIsNone(models.SETTINGS_OVERRIDE.get())

    def test_missing_settings_file_still_uses_explicit_model_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            token = models.SETTINGS_OVERRIDE.set({"asrModelFormat": "not-a-format"})
            try:
                with self.assertRaisesRegex(RuntimeError, "формат"):
                    models.selected_asr(root)
            finally:
                models.SETTINGS_OVERRIDE.reset(token)
            self.assertFalse((root / "settings.json").exists())


if __name__ == "__main__":
    unittest.main()
