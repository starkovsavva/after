import os
import hashlib
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import signing


FINGERPRINT = 'A1' * 20
OTHER = 'B2' * 20


def identity_listing(name, *, fingerprint=FINGERPRINT):
    return subprocess.CompletedProcess([], 0, stdout=f'  1) {fingerprint} "{name}"\n     1 valid identities found\n', stderr='')


class SigningSelectionTests(unittest.TestCase):
    def test_default_is_ad_hoc_without_reading_keychain(self):
        with mock.patch.object(signing.subprocess, 'run') as run:
            self.assertEqual(signing.selected_identity(None), signing.Identity('-'))
            self.assertEqual(signing.selected_identity(''), signing.Identity('-'))
        run.assert_not_called()

    def test_selection_requires_exact_fingerprint_before_reading_keychain(self):
        for value in ('-', 'Developer ID Application: Fixture', 'A1' * 19, 'A1' * 21, ' ' + FINGERPRINT):
            with self.subTest(value=value), mock.patch.object(signing.subprocess, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, '40-character'):
                    signing.selected_identity(value)
                run.assert_not_called()

    def test_developer_id_and_development_use_only_explicit_valid_selection(self):
        for name, timestamp in (('Developer ID Application: Fixture (TEST)', True), ('Apple Development: Fixture (TEST)', False)):
            with self.subTest(name=name), mock.patch.object(signing.subprocess, 'run', return_value=identity_listing(name)) as run:
                self.assertEqual(signing.selected_identity(FINGERPRINT.lower()), signing.Identity(FINGERPRINT, timestamp))
                self.assertEqual(run.call_args.args[0], ['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])
                self.assertTrue(run.call_args.kwargs['capture_output'])

    def test_available_other_certificate_is_never_chosen_automatically(self):
        with mock.patch.object(signing.subprocess, 'run', return_value=identity_listing('Developer ID Application: Fixture (TEST)', fingerprint=OTHER)):
            with self.assertRaisesRegex(RuntimeError, 'not available'):
                signing.selected_identity(FINGERPRINT)

    def test_unavailable_expired_or_duplicate_identity_fails_closed(self):
        listings = ('  0 valid identities found\n', f'1) {FINGERPRINT} "Apple Development: Fixture"\n2) {FINGERPRINT} "Apple Development: Other"\n')
        for listing in listings:
            with self.subTest(listing=listing), mock.patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=listing, stderr='')):
                with self.assertRaisesRegex(RuntimeError, 'not available'):
                    signing.selected_identity(FINGERPRINT)

    def test_other_identity_classes_and_keychain_errors_do_not_leak_names(self):
        for name in ('Fixture Self-signed Certificate', 'Developer ID Installer: Fixture', 'Apple Distribution: Fixture'):
            with self.subTest(name=name), mock.patch.object(signing.subprocess, 'run', return_value=identity_listing(name)):
                with self.assertRaisesRegex(RuntimeError, 'Developer ID Application or Apple Development') as error:
                    signing.selected_identity(FINGERPRINT)
                self.assertNotIn(name, str(error.exception))
        with mock.patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, stdout='', stderr='private fixture diagnostic')):
            with self.assertRaises(RuntimeError) as error:
                signing.selected_identity(FINGERPRINT)
            self.assertNotIn('private fixture', str(error.exception))

    def test_preflight_invalid_selection_never_signs_or_builds(self):
        with mock.patch.dict(os.environ, {'POSLE_CODESIGN_IDENTITY': 'invalid'}), mock.patch.object(sys, 'argv', ['signing.py', '--check']), mock.patch.object(signing, 'sign_application') as sign:
            with self.assertRaises(RuntimeError):
                signing.main()
            sign.assert_not_called()


class SigningCommandsTests(unittest.TestCase):
    def test_sign_owned_components_inside_out_preserving_sparkle_and_default_requirements(self):
        with tempfile.TemporaryDirectory(prefix='posle-sign-commands-', dir='/private/tmp') as temporary:
            root = Path(temporary)
            app = root / 'После.app'
            relative = ('Contents/Frameworks/libposle_core.dylib', 'Contents/MacOS/posle-engine', 'Contents/Helpers/После Распознавание.app', 'Contents/Helpers/После Обработка.app')
            for name in relative:
                path = app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.mkdir() if name.endswith('.app') else path.write_bytes(b'fixture')
            entitlements = root / 'entitlements.plist'
            entitlements.write_text('fixture')
            for identity in (signing.Identity('-'), signing.Identity(FINGERPRINT), signing.Identity(FINGERPRINT, True)):
                with self.subTest(identity=identity), mock.patch.object(signing.subprocess, 'run') as run:
                    signing.sign_application(app, entitlements, identity)
                    all_commands = [call.args[0] for call in run.call_args_list]
                    if identity.fingerprint == '-':
                        self.assertEqual(len(all_commands), 5)
                        commands = all_commands
                    else:
                        self.assertEqual(len(all_commands), 10)
                        commands = all_commands[::2]
                        self.assertEqual(all_commands[1::2], [['/usr/bin/codesign', '--verify', '--strict', '-R', '=anchor apple generic', str(app / name)] for name in relative] + [['/usr/bin/codesign', '--verify', '--strict', '-R', '=anchor apple generic', str(app)]])
                    self.assertEqual([command[-1] for command in commands], [str(app / name) for name in relative] + [str(app)])
                    for command in commands:
                        self.assertEqual(command[:4], ['/usr/bin/codesign', '--force', '--sign', identity.fingerprint])
                        self.assertEqual('--timestamp' in command, identity.developer_id)
                        self.assertFalse(any(flag in command for flag in ('--deep', '--requirements', '-r', '--options')))
                        self.assertFalse(any('Sparkle' in item for item in command))
                    self.assertTrue(all('--entitlements' not in command for command in commands[:-1]))
                    self.assertEqual(commands[-1][-3:-1], ['--entitlements', str(entitlements)])

    def test_apple_display_name_does_not_bypass_chain_verification(self):
        with tempfile.TemporaryDirectory(prefix='posle-sign-chain-', dir='/private/tmp') as temporary:
            root = Path(temporary)
            app = root / 'После.app'
            components = ('Contents/Frameworks/libposle_core.dylib', 'Contents/MacOS/posle-engine', 'Contents/Helpers/После Распознавание.app', 'Contents/Helpers/После Обработка.app')
            for name in components:
                path = app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.mkdir() if name.endswith('.app') else path.write_bytes(b'fixture')
            entitlements = root / 'entitlements.plist'
            entitlements.write_text('fixture')
            def reject_chain(command, **kwargs):
                if '--verify' in command:
                    raise subprocess.CalledProcessError(3, command)
                return subprocess.CompletedProcess(command, 0)
            with mock.patch.object(signing.subprocess, 'run', side_effect=reject_chain) as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    signing.sign_application(app, entitlements, signing.Identity(FINGERPRINT))
                # Stop on the first failed component; never sign/publish the app.
                self.assertEqual(run.call_count, 2)
                self.assertEqual(run.call_args.args[0][-1], str(app / components[0]))

    def test_missing_component_fails_before_any_signing(self):
        with tempfile.TemporaryDirectory(prefix='posle-sign-missing-', dir='/private/tmp') as temporary:
            root = Path(temporary)
            entitlement = root / 'entitlements.plist'
            entitlement.write_text('fixture')
            with mock.patch.object(signing.subprocess, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'owned application'):
                    signing.sign_application(root / 'missing.app', entitlement, signing.Identity('-'))
                run.assert_not_called()

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'Requires macOS codesign and compiler')
    def test_real_ad_hoc_rebuild_changes_designated_requirement(self):
        # Disposable native executables only: no certificates, keychain, TCC,
        # installed applications, microphone or screen are touched.
        with tempfile.TemporaryDirectory(prefix='posle-sign-adhoc-', dir='/private/tmp') as temporary:
            root = Path(temporary)
            source = root / 'fixture.c'
            requirements = []
            for value in (1, 2):
                source.write_text(f'int main(void) {{ return {value}; }}\n')
                executable = root / f'fixture-{value}'
                subprocess.run(['clang', str(source), '-o', str(executable)], check=True, capture_output=True)
                subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'app.posle.signing-fixture', str(executable)], check=True, capture_output=True)
                subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(executable)], check=True, capture_output=True)
                result = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(executable)], check=True, capture_output=True, text=True)
                requirement = re.search(r'designated => [^\r\n]+', result.stdout + result.stderr).group(0)
                self.assertIn('cdhash', requirement)
                requirements.append(requirement)
            self.assertNotEqual(*requirements)


class CoreIntegritySigningTests(unittest.TestCase):
    def fixture(self, root):
        app = root / 'После.app'
        for name in ('Contents/Frameworks/libposle_core.dylib', 'Contents/MacOS/posle-engine', 'Contents/Helpers/После Распознавание.app', 'Contents/Helpers/После Обработка.app'):
            path = app / name; path.parent.mkdir(parents=True, exist_ok=True)
            path.mkdir() if name.endswith('.app') else path.write_bytes(b'fixture')
        entitlement = root / 'entitlements.plist'; entitlement.write_text('fixture')
        return app, entitlement, app / 'Contents/Frameworks/libposle_core.dylib'

    def test_presign_digest_covers_final_signature_bytes(self):
        with tempfile.TemporaryDirectory(prefix='posle-core-sign-', dir='/private/tmp') as temporary:
            library = Path(temporary) / 'core.dylib'; library.write_bytes(b'unsigned')
            def sign(command, **kwargs):
                if '--force' in command: library.write_bytes(b'final signed bytes')
                return subprocess.CompletedProcess(command, 0)
            with mock.patch.object(signing.subprocess, 'run', side_effect=sign) as run:
                digest = signing.sign_core_library(library, signing.Identity(FINGERPRINT, True))
            self.assertEqual(digest, hashlib.sha256(b'final signed bytes').hexdigest())
            self.assertEqual(run.call_args_list[0].args[0], ['/usr/bin/codesign', '--force', '--sign', FINGERPRINT, '--timestamp', str(library)])
            self.assertEqual(run.call_args_list[1].args[0], ['/usr/bin/codesign', '--verify', '--strict', '-R', '=anchor apple generic', str(library)])

    def test_final_app_signing_verifies_but_never_resigns_pinned_core(self):
        with tempfile.TemporaryDirectory(prefix='posle-core-preserve-', dir='/private/tmp') as temporary:
            app, entitlement, library = self.fixture(Path(temporary))
            expected = signing.core_digest(library)
            with mock.patch.object(signing.subprocess, 'run') as run:
                signing.sign_application(app, entitlement, signing.Identity('-'), presigned_core_sha256=expected)
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(commands[0], ['/usr/bin/codesign', '--verify', '--strict', str(library)])
            self.assertEqual(commands[-1], commands[0])
            self.assertTrue(all(command[-1] != str(library) for command in commands if '--force' in command))
            self.assertEqual(len([command for command in commands if '--force' in command]), 4)
            self.assertEqual(signing.core_digest(library), expected)

    def test_bad_pinned_digest_fails_before_any_signing(self):
        with tempfile.TemporaryDirectory(prefix='posle-core-mismatch-', dir='/private/tmp') as temporary:
            app, entitlement, _ = self.fixture(Path(temporary))
            for expected in ('0' * 64, 'A' * 64, 'short'):
                with self.subTest(expected=expected), mock.patch.object(signing.subprocess, 'run') as run:
                    with self.assertRaisesRegex(RuntimeError, 'digest does not match'):
                        signing.sign_application(app, entitlement, signing.Identity('-'), presigned_core_sha256=expected)
                    run.assert_not_called()

    def test_mutation_during_app_signing_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix='posle-core-sign-mutation-', dir='/private/tmp') as temporary:
            app, entitlement, library = self.fixture(Path(temporary))
            expected = signing.core_digest(library)
            def mutate(command, **kwargs):
                if command[-1] == str(app) and '--force' in command: library.write_bytes(b'modified after linking')
                return subprocess.CompletedProcess(command, 0)
            with mock.patch.object(signing.subprocess, 'run', side_effect=mutate):
                with self.assertRaisesRegex(RuntimeError, 'Signing changed'):
                    signing.sign_application(app, entitlement, signing.Identity('-'), presigned_core_sha256=expected)

    def test_digest_file_has_exact_format_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory(prefix='posle-core-digest-', dir='/private/tmp') as temporary:
            path = Path(temporary) / 'core.sha256'
            for value in ('a' * 64 + '\n', 'A' * 64, 'a' * 63, 'z' * 64):
                path.write_text(value)
                with self.assertRaisesRegex(RuntimeError, '64 lowercase'):
                    signing.read_core_digest(path)
            path.write_text('a' * 64); self.assertEqual(signing.read_core_digest(path), 'a' * 64)
            link = path.with_name('symlink'); link.symlink_to(path)
            with self.assertRaisesRegex(RuntimeError, 'regular'):
                signing.read_core_digest(link)

    def test_library_cli_writes_exact_digest_and_never_signs_app(self):
        with tempfile.TemporaryDirectory(prefix='posle-core-cli-', dir='/private/tmp') as temporary:
            root = Path(temporary); digest = root / 'core.sha256'; library = root / 'core.dylib'
            with mock.patch.dict(os.environ, {'POSLE_CODESIGN_IDENTITY': ''}), mock.patch.object(sys, 'argv', ['signing.py', '--library', str(library), '--digest-file', str(digest)]), mock.patch.object(signing, 'sign_core_library', return_value='a' * 64) as sign, mock.patch.object(signing, 'sign_application') as application:
                signing.main()
            self.assertEqual(digest.read_bytes(), b'a' * 64)
            sign.assert_called_once_with(library, signing.Identity('-'))
            application.assert_not_called()


if __name__ == '__main__':
    unittest.main()
