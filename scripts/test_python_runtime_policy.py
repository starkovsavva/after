import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

import pin_python_runtime as pin


class PinnedPythonPolicyTests(unittest.TestCase):
    def archive(self, root, extra=()):
        archive = root / "python.tar.gz"
        with tarfile.open(archive, "w:gz") as package:
            for name in ("bin/python3.12", "lib/libpython3.12.dylib", "lib/python3.12/encodings/__init__.py"):
                content = b"synthetic executable bytes, never executed: " + name.encode()
                item = tarfile.TarInfo("python/" + name); item.size = len(content)
                package.addfile(item, io.BytesIO(content))
            for item, content in extra:
                package.addfile(item, io.BytesIO(content) if content is not None else None)
        policy = {"schemaVersion": 1, "version": "3.12.16", "directory": "cpython-3.12.16+20261026-aarch64-apple-darwin",
                  "archive_url": "https://github.com/astral-sh/python-build-standalone/releases/download/fixture/python.tar.gz",
                  "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(), "archive_size": archive.stat().st_size}
        return archive, policy

    def test_inventory_is_derived_from_verified_archive_and_deterministic(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            alias = tarfile.TarInfo("python/bin/python"); alias.type = tarfile.SYMTYPE; alias.linkname = "python3.12"
            empty = tarfile.TarInfo("python/share/empty"); empty.type = tarfile.DIRTYPE
            archive, policy = self.archive(root, [(alias, None), (empty, None)])
            actual = pin.inventory(archive, policy)
            self.assertEqual(actual['links'], [{'path': 'bin/python', 'target': 'python3.12'}])
            self.assertIn('share/empty', actual['directories'])
            self.assertEqual(len(actual['files']), 3)
            self.assertEqual(pin.render(actual), pin.render(pin.inventory(archive, policy)))
            self.assertEqual(json.loads(pin.render(actual)), actual)
            for item in actual['files']:
                expected = b"synthetic executable bytes, never executed: " + item['path'].encode()
                self.assertEqual(item['sha256'], hashlib.sha256(expected).hexdigest())

    def test_size_or_hash_mismatch_never_opens_archive(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temporary:
            archive, policy = self.archive(Path(temporary))
            for changed in ({'archive_size': 1}, {'archive_sha256': '0' * 64}):
                with self.subTest(changed=changed), patch.object(pin.tarfile, 'open') as parse:
                    with self.assertRaises(ValueError): pin.inventory(archive, policy | changed)
                    parse.assert_not_called()
            alias = Path(temporary) / 'archive-alias'; alias.symlink_to(archive)
            with self.assertRaises(ValueError): pin.inventory(alias, policy)

    def test_ambiguous_paths_and_unsafe_aliases_never_become_trusted_inventory(self):
        cases = []
        for name in ('python/../outside', '/python/outside', 'outside/file', 'python/bin/python3.12', 'python/BIN/PYTHON3.12'):
            item = tarfile.TarInfo(name); item.size = 1; cases.append((item, b'x'))
        for target in ('/outside', '../../outside', 'missing', 'python'):
            item = tarfile.TarInfo('python/bin/python'); item.type = tarfile.SYMTYPE; item.linkname = target; cases.append((item, None))
        item = tarfile.TarInfo('python/fifo'); item.type = tarfile.FIFOTYPE; cases.append((item, None))
        with tempfile.TemporaryDirectory() as temporary:
            for item, content in cases:
                with self.subTest(name=item.name, target=item.linkname):
                    archive, policy = self.archive(Path(temporary), [(item, content)])
                    with self.assertRaises(ValueError): pin.inventory(archive, policy)

    def test_committed_policy_pins_required_files_and_only_declared_internal_aliases(self):
        policy = json.loads(pin.POLICY.read_text())
        self.assertEqual(policy['schemaVersion'], 1)
        files = {entry['path']: entry for entry in policy['files']}
        self.assertTrue({'bin/python3.12', 'lib/libpython3.12.dylib', 'lib/python3.12/encodings/__init__.py'} <= files.keys())
        self.assertGreater(len(files), 1000)
        self.assertEqual(len(files), len(policy['files']))
        self.assertEqual(len({key.casefold() for key in files}), len(files))
        self.assertEqual(policy['archive_sha256'], '353d5f1b4fd2715e7053f12f068435d5bbad16b91e057006b5d01e0925709a7e')
        self.assertEqual(policy['version'], '3.12.16')
        for entry in policy['links']:
            self.assertFalse(entry['target'].startswith('/'))


if __name__ == '__main__':
    unittest.main()
