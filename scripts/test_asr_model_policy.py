import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import pin_asr_model as pin


class ModelInventoryTests(unittest.TestCase):
    def fixture(self, root, extra=None):
        archive = root/'model.tar.bz2'
        with tarfile.open(archive,'w:bz2') as package:
            for name in sorted(pin.REQUIRED):
                content = b'synthetic; never loaded'
                item = tarfile.TarInfo('parakeet-fixture/'+name);item.size=len(content)
                package.addfile(item,io.BytesIO(content))
            if extra is not None: package.addfile(extra)
        return archive,dict(schemaVersion=1,id='parakeet-v3-int8',version='fixture',directory='parakeet-fixture',archive_url='https://unused.invalid/model.tar.bz2',archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),archive_size=archive.stat().st_size)
    def test_full_inventory_and_hash_guard_before_parsing(self):
        with tempfile.TemporaryDirectory() as folder:
            archive,policy=self.fixture(Path(folder))
            result=pin.inventory(archive,policy)
            self.assertEqual({v['path'] for v in result['files']},pin.REQUIRED)
            self.assertEqual(result['links'],[])
            from unittest.mock import patch
            with patch.object(pin.tarfile,'open') as parse:
                with self.assertRaises(ValueError):pin.inventory(archive,policy|{'archive_sha256':'0'*64})
                parse.assert_not_called()
    def test_traversal_alias_and_special_entries_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            for name,kind in [('parakeet-fixture/../escape',tarfile.DIRTYPE),('parakeet-fixture/alias',tarfile.SYMTYPE),('parakeet-fixture/fifo',tarfile.FIFOTYPE)]:
                entry=tarfile.TarInfo(name);entry.type=kind;entry.linkname='/outside'
                archive,policy=self.fixture(Path(folder),entry)
                with self.assertRaises(ValueError):pin.inventory(archive,policy)
    def test_committed_policy_has_expected_release_and_complete_required_files(self):
        policy=json.loads(pin.POLICY.read_text())
        self.assertTrue(pin.REQUIRED<={v['path'] for v in policy['files']})
        self.assertEqual(policy['archive_sha256'],'5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf')
        self.assertEqual(policy['archive_size'],487170055)
