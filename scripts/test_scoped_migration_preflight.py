import os
from pathlib import Path
import tempfile
import unittest

from scoped_migration_preflight import _WRITERS, inspect_disposable_fixture


class ScopedMigrationPreflightTests(unittest.TestCase):
    def test_known_fixture_with_all_writers_stopped_is_still_blocked(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "settings.json").write_text('{"password":"fixture secret"}')
            (root / "core.sqlite").write_bytes(b"synthetic")
            (root / "core.sqlite-wal").write_bytes(b"synthetic WAL")
            (root / "meetings").mkdir()
            result = inspect_disposable_fixture(root, observed_writers={w: "stopped" for w in _WRITERS})
            self.assertEqual(result["status"], "blocked")
            self.assertIn("no-consistent-snapshot", result["reasons"])
            self.assertIn("no-quiescence-barrier", result["reasons"])
            self.assertIn("recursive-inventory-not-implemented", result["reasons"])
            self.assertEqual(result["counts"]["workspace"], 2)
            self.assertNotIn("fixture secret", str(result))

    def test_unknown_live_or_unreported_writer_and_formats_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp) / "unrecognized-secret-name").write_text("not inspected")
            result = inspect_disposable_fixture(temp, observed_writers={"native-app": "live", "unexpected": "stopped"})
            self.assertEqual(result["status"], "blocked")
            self.assertIn("writer-live-or-unknown", result["reasons"])
            self.assertIn("unknown-writer-class", result["reasons"])
            self.assertIn("unknown-format", result["reasons"])
            self.assertNotIn("unrecognized-secret-name", str(result))
            self.assertEqual(result["writerStates"]["python-workers"], "unknown")

    def test_symlinks_hardlinks_and_unreadable_root_are_never_success(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "original").write_text("private")
            os.link(root / "original", root / "settings.json")
            (root / "notes").symlink_to(root / "original")
            result = inspect_disposable_fixture(root)
            self.assertEqual(result["status"], "blocked")
            self.assertIn("symlink-present", result["reasons"])
            self.assertIn("unexpected-entry-type", result["reasons"])
            self.assertIn("root-unreadable", inspect_disposable_fixture(root / "notes")["reasons"])


if __name__ == "__main__":
    unittest.main()
