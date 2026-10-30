"""Offline contracts for renamed-app verification; no SDK, signing or GUI."""
from pathlib import Path
import plistlib
import tempfile
import unittest

import e2e_updates
import e2e_updates as fixture
import shutil
from unittest import mock


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



class BrandRenameFixtureTests(unittest.TestCase):
    def test_only_the_explicit_rename_scenario_changes_bundle_names(self):
        self.assertIn("brand-rename", fixture.SUCCESS_SCENARIOS)
        self.assertEqual(fixture.application_names("brand-rename"), ("После.app", "After.app"))
        for scenario in fixture.SCENARIOS:
            if scenario not in ("brand-rename", "renamed-app"):
                self.assertEqual(fixture.application_names(scenario), ("UpdateFixture.app", "UpdateFixture.app"))

    def test_renamed_candidate_preserves_identity_and_replaces_nested_owned_bytes(self):
        with tempfile.TemporaryDirectory(prefix="after-update-contract-") as temporary:
            root = Path(temporary)
            scenario = root / "brand-rename"
            binary = root / "UpdateFixture"
            binary.write_bytes(b"synthetic never-executed fixture")
            framework = root / "Sparkle.framework"
            framework.mkdir()
            (framework / "synthetic-resource").write_text("copied unchanged")
            components = {}
            for build in (1, 2):
                worker, core = root / f"worker-{build}", root / f"core-{build}.dylib"
                worker.write_bytes(f"synthetic worker {build}".encode())
                core.write_bytes(f"synthetic library {build}".encode())
                components[build] = worker, core
            def run(command, **_):
                if command[0] == "ditto":
                    shutil.copytree(command[-2], command[-1])
                else:
                    self.assertEqual(command[0], "codesign")
                    if "--sign" in command:
                        self.assertEqual(command[command.index("--sign") + 1], "-")
                return ""
            identifier = "app.posle.updaterfixture." + "a" * 32
            old_name, new_name = fixture.application_names("brand-rename")
            old, new = scenario / "installed" / old_name, scenario / "source" / new_name
            with mock.patch.object(fixture, "run", side_effect=run):
                for build, destination in ((1, old), (2, new)):
                    fixture.make_app(destination, binary, framework, components, identifier=identifier,
                                     build=build, scenario=scenario, feed="http://127.0.0.1:12345/brand-rename/feed.xml", public="synthetic")
            for path, display, version in ((old, "После", "1"), (new, "After", "2")):
                info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
                self.assertEqual(info["CFBundleIdentifier"], identifier)
                self.assertEqual(info["CFBundleName"], info["CFBundleDisplayName"])
                self.assertEqual(info["CFBundleDisplayName"], display)
                self.assertEqual(info["CFBundleVersion"], version)
                self.assertEqual(info["CFBundleExecutable"], "UpdateFixture")
            old_files, new_files = fixture.files(old), fixture.files(new)
            for owned in ("Contents/MacOS/FixtureWorker", "Contents/Frameworks/libFixtureCore.dylib",
                          "Contents/Helpers/FixtureWorker.app/Contents/MacOS/FixtureWorker"):
                self.assertNotEqual(old_files[owned], new_files[owned])
            self.assertFalse((old.parent / new_name).exists(), "Preparing the archive must not add another installed app")


if __name__ == "__main__":
    unittest.main()
