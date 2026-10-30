"""Offline contracts for renamed-app verification; no SDK, signing or GUI."""
from pathlib import Path
import plistlib
import tempfile
import unittest

import e2e_updates


class RenamedInstallChecks(unittest.TestCase):
    def fixture(self, parent):
        installed = parent / 'После.app'
        contents = installed / 'Contents'
        contents.mkdir(parents=True)
        identifier = 'app.posle.updaterfixture.' + '1' * 32
        info = {'CFBundleIdentifier': identifier, 'CFBundleName': 'After', 'CFBundleDisplayName': 'After'}
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        observed = [{'event': 'started', 'build': '1', 'bundle': str(installed)},
                    {'event': 'started', 'build': '2', 'bundle': str(installed)}]
        return installed, identifier, observed

    def test_changed_name_must_relaunch_from_old_host_without_second_installation(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            installed, identifier, observed = self.fixture(parent)
            e2e_updates.verify_renamed_install(installed, identifier, observed)
            (parent / 'After.app').mkdir()
            with self.assertRaisesRegex(AssertionError, 'second installed app'):
                e2e_updates.verify_renamed_install(installed, identifier, observed)

    def test_candidate_started_from_source_copy_does_not_count_as_updated_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            installed, identifier, observed = self.fixture(parent)
            observed[-1]['bundle'] = str(parent / 'source/After.app')
            with self.assertRaisesRegex(AssertionError, 'original host path'):
                e2e_updates.verify_renamed_install(installed, identifier, observed)

    def test_display_name_alone_does_not_allow_a_different_bundle_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            installed, identifier, observed = self.fixture(Path(temporary))
            with self.assertRaisesRegex(AssertionError, 'fixture identity'):
                e2e_updates.verify_renamed_install(installed, identifier + '.foreign', observed)


if __name__ == '__main__':
    unittest.main()
