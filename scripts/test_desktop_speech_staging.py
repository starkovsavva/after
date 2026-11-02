"""Staging contracts use synthetic source bytes and never execute a backend."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('desktop_stage', Path(__file__).with_name('stage-desktop-engine.py'))
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class SpeechStagingTests(unittest.TestCase):
    def fixture(self, root):
        backend = root / 'backend'
        backend.mkdir()
        (backend / 'desktop-speech-files.json').write_text(json.dumps(['engine.py']))
        (backend / 'engine.py').write_bytes(b'# synthetic; never executed\n')
        target = root / 'binaries'
        target.mkdir()
        return backend, target

    def test_restage_replaces_generated_source_and_failure_preserves_previous_stage(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            backend, target = self.fixture(root)
            stage.stage_backend(root, target)
            destination = target / 'speech-backend/engine.py'
            previous = destination.read_bytes()
            (backend / 'desktop-speech-files.json').write_text(json.dumps(['engine.py', 'missing.py']))
            with self.assertRaises(FileNotFoundError):
                stage.stage_backend(root, target)
            self.assertEqual(destination.read_bytes(), previous)
            (backend / 'desktop-speech-files.json').write_text(json.dumps(['engine.py']))
            (backend / 'engine.py').write_bytes(b'# next approved source\n')
            stage.stage_backend(root, target)
            self.assertEqual(destination.read_bytes(), b'# next approved source\n')
            self.assertEqual(list(target.iterdir()), [target / 'speech-backend'])

    def test_catalog_traversal_and_aliases_never_replace_staged_data(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            backend, target = self.fixture(root)
            stage.stage_backend(root, target)
            for names in [['../outside.py'], ['engine.py', 'engine.py'], []]:
                (backend / 'desktop-speech-files.json').write_text(json.dumps(names))
                with self.assertRaises(ValueError):
                    stage.stage_backend(root, target)
            self.assertEqual((target / 'speech-backend/engine.py').read_bytes(), b'# synthetic; never executed\n')
