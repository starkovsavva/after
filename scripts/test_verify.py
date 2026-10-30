import argparse
import contextlib
import io
import os
import tempfile
from pathlib import Path
import unittest
from unittest import mock

import verify
import e2e_media


class VerifyIsolationTests(unittest.TestCase):
    def arguments(self):
        return argparse.Namespace(
            python=Path('/usr/bin/python3'), swift_build_dir=Path('/private/tmp/posle-verify-swift'),
            rust_target_dir=Path('/private/tmp/posle-verify-rust'), sparkle_root=None,
        )

    def controller(self):
        with mock.patch.object(verify.Verification, 'find_cargo', return_value='/fixture/cargo'):
            return verify.Verification(self.arguments())

    def test_listing_does_not_require_or_initialize_tools(self):
        with mock.patch('sys.argv', ['verify.py', '--list']), mock.patch.object(verify, 'Verification') as controller, contextlib.redirect_stdout(io.StringIO()) as output:
            verify.main()
        controller.assert_not_called()
        self.assertIn('release:', output.getvalue())

    def test_child_environment_does_not_inherit_real_data_root_or_provider_keys(self):
        with mock.patch.dict(os.environ, {'POSLE_DATA_DIR': '/fixture/private-library', 'OPENAI_API_KEY': 'not-a-real-key', 'PROVIDER_SECRET': 'not-a-real-secret', 'POSLE_JOB_SETTINGS': '{"mode":"cloud"}', 'PYTHONPATH': '/fixture/foreign-modules', 'PYTHONHOME': '/fixture/foreign-home', 'POSLE_RUST_LIBRARY': '/fixture/foreign.dylib', 'POSLE_RUST_ENGINE': '/fixture/foreign-engine', 'POSLE_UNVERIFIED_PYTHON_RUNTIME_FOR_TESTS': '1'}):
            controller = self.controller()
        self.assertNotIn('POSLE_DATA_DIR', controller.env)
        self.assertNotIn('OPENAI_API_KEY', controller.env)
        self.assertNotIn('PROVIDER_SECRET', controller.env)
        self.assertNotIn('POSLE_JOB_SETTINGS', controller.env)
        self.assertNotIn('PYTHONPATH', controller.env)
        self.assertNotIn('PYTHONHOME', controller.env)
        self.assertNotIn('POSLE_RUST_LIBRARY', controller.env)
        self.assertNotIn('POSLE_RUST_ENGINE', controller.env)
        self.assertNotIn('POSLE_UNVERIFIED_PYTHON_RUNTIME_FOR_TESTS', controller.env)

    def test_python_venv_symlink_is_not_resolved_to_base_interpreter(self):
        with tempfile.TemporaryDirectory(prefix='posle-verify-python-') as temporary:
            root = Path(temporary)
            base = root / 'base-python'
            base.write_text('fixture interpreter; never executed')
            venv = root / 'venv/bin'
            venv.mkdir(parents=True)
            executable = venv / 'python'
            executable.symlink_to(base)
            args = self.arguments()
            args.python = executable
            with mock.patch.object(verify.Verification, 'find_cargo', return_value='/fixture/cargo'):
                controller = verify.Verification(args)
            self.assertEqual(controller.python, str(executable.absolute()))
            self.assertNotEqual(controller.python, str(base))

    def test_native_checks_use_unique_disposable_roots_and_explicit_binary_overrides(self):
        controller = self.controller()
        controller.build_swift = mock.Mock()
        controller.build_rust = mock.Mock()
        roots = []
        def run(label, command, *, env=None, timeout=1200):
            if env is None:
                return
            if '--preview' not in command:
                self.assertEqual(str(command[1]), 'scripts/e2e_media.py')
                self.assertEqual(env['POSLE_UNVERIFIED_PYTHON_RUNTIME_FOR_TESTS'], '1')
                self.assertNotIn('POSLE_DATA_DIR', env)
                return
            self.assertEqual(env['POSLE_UNVERIFIED_PYTHON_RUNTIME_FOR_TESTS'], '1')
            root = Path(env['POSLE_DATA_DIR'])
            self.assertTrue(root.is_dir())
            self.assertIn(root.parent.as_posix(), ['/tmp', '/private/tmp'])
            self.assertTrue(root.name.startswith(('posle-native-check-', 'posle-ui-check-')))
            self.assertEqual(env['POSLE_RUST_ENGINE'], str(controller.engine))
            self.assertEqual(env['POSLE_RUST_LIBRARY'], str(controller.library))
            self.assertIn('--preview', command)
            roots.append(root)
        controller.run = run
        controller.native()
        self.assertEqual(len(roots), len(set(roots)))
        self.assertTrue(all(not root.exists() for root in roots))

    def test_native_capture_cross_layer_check_runs_before_fixture_cleanup_once(self):
        controller = self.controller()
        controller.build_swift = mock.Mock()
        controller.build_rust = mock.Mock()
        commands = []
        capture = None
        def run(label, command, *, env=None, timeout=1200):
            nonlocal capture
            commands.append(command)
            if '--check-recording-sessions' in command:
                capture = Path(env['POSLE_DATA_DIR']) / 'capture-writer/static'
                capture.mkdir(parents=True)
                (capture / 'recording.mov').write_bytes(b'generated native writer fixture')
            if str(command[1]) == 'scripts/e2e_media.py':
                self.assertIsNotNone(capture)
                self.assertEqual(command[-2:], ['--native-capture', capture])
                self.assertTrue((capture / 'recording.mov').is_file())
                self.assertEqual(command[0], controller.python)
                self.assertEqual(command[command.index('--engine') + 1], controller.engine)
                self.assertNotIn('POSLE_DATA_DIR', controller.env)
        controller.run = run
        controller.native()
        media = [index for index, command in enumerate(commands) if str(command[1]) == 'scripts/e2e_media.py']
        self.assertEqual(len(media), 1)
        self.assertIn('--check-recording-sessions', commands[media[0] - 1])
        self.assertIn('--check-corrections', commands[media[0] + 1])
        self.assertFalse(capture.exists())

    def test_native_media_fixture_rejects_foreign_files_symlinks_and_wrong_identity(self):
        import json
        with tempfile.TemporaryDirectory(prefix='posle-native-check-', dir='/private/tmp') as temporary:
            capture = Path(temporary) / 'capture-writer/static'
            capture.mkdir(parents=True)
            recording = capture / 'recording.mov'
            recording.write_bytes(b'generated media')
            meta = {'id': 'static', 'title': 'Synthetic static screen', 'source': 'recording.mov',
                    'hasVideo': True, 'recordingTracks': False}
            metadata = capture / 'meta.json'
            metadata.write_text(json.dumps(meta))
            source, actual = e2e_media.native_capture_fixture(capture)
            self.assertEqual(source, recording)
            self.assertEqual(actual, meta)
            metadata.write_text(json.dumps(meta | {'title': 'Existing personal meeting'}))
            with self.assertRaisesRegex(AssertionError, 'generated static-screen'):
                e2e_media.native_capture_fixture(capture)
            metadata.write_text(json.dumps(meta))
            recording.unlink()
            foreign = Path(temporary) / 'outside.mov'
            foreign.write_bytes(b'outside source must remain untouched')
            recording.symlink_to(foreign)
            with self.assertRaisesRegex(AssertionError, 'ordinary generated'):
                e2e_media.native_capture_fixture(capture)
            with self.assertRaisesRegex(AssertionError, 'disposable recording-session'):
                e2e_media.native_capture_fixture(Path(temporary))
            self.assertEqual(foreign.read_bytes(), b'outside source must remain untouched')

    def test_native_media_duration_uses_video_track_instead_of_full_audio_container(self):
        import struct
        def box(kind, payload):
            return struct.pack('>I4s', len(payload) + 8, kind) + payload
        def track(kind, duration):
            header = bytes(4) + struct.pack('>IIIII', 0, 0, 1, 0, duration)
            handler = bytes(8) + kind
            return box(b'trak', box(b'tkhd', header) + box(b'mdia', box(b'hdlr', handler)))
        movie_header = bytes(4) + struct.pack('>IIII', 0, 0, 1000, 1000)
        movie = box(b'moov', box(b'mvhd', movie_header) + track(b'soun', 1000) + track(b'vide', 57))
        with tempfile.TemporaryDirectory(prefix='posle-native-duration-') as temporary:
            path = Path(temporary) / 'short-video-full-audio.mp4'
            path.write_bytes(movie)
            self.assertAlmostEqual(e2e_media.mp4_video_duration(path), 0.057)
            path.write_bytes(struct.pack('>I4s', 4096, b'moov'))
            with self.assertRaisesRegex(AssertionError, 'box bounds'):
                e2e_media.mp4_video_duration(path)

    def test_command_line_tools_runs_all_core_contracts_without_xctest(self):
        controller = self.controller()
        calls = []
        controller.run = lambda label, command, **kwargs: calls.append((label, command))
        with mock.patch.object(verify.subprocess, 'run', return_value=mock.Mock(returncode=1)):
            controller.core_tests()
        compilations = [command for _, command in calls if command[0] == 'swiftc']
        self.assertEqual(len(compilations), 3)
        for expected, command in zip(('CoreChecks', 'CalendarLayoutChecks', 'TaskDueDateChecks'), compilations):
            self.assertIn(verify.PROJECT / 'Tests' / (expected + '.swift'), command)
            self.assertIn('-module-cache-path', command)
            self.assertIn('-parse-as-library', command)
        self.assertEqual(len(calls), 6)

    def test_integration_preserves_unique_media_search_and_migration_checks(self):
        controller = self.controller()
        controller.build_rust = mock.Mock()
        commands = []
        environments = {}
        def record(label, command, **kwargs):
            commands.append(command)
            environments[str(command[1])] = kwargs.get('env', controller.env)
        controller.run = record
        controller.integration()
        called = {str(command[1]) for command in commands}
        self.assertEqual(called, {'scripts/e2e.py', 'scripts/e2e_media.py', 'scripts/check_media.py', 'scripts/check_import_playback.py', 'scripts/check_search.py', 'scripts/check_managed_identity.py', 'scripts/check_native_integrity.py', 'scripts/check_mcp.py'})
        self.assertFalse(any('check_audio' in str(command) for command in commands))
        self.assertEqual(environments['scripts/check_media.py']['PYTHONPATH'], str(verify.PROJECT / 'backend'))
        self.assertEqual(environments['scripts/e2e_media.py']['POSLE_UNVERIFIED_PYTHON_RUNTIME_FOR_TESTS'], '1')
        self.assertTrue(all('POSLE_UNVERIFIED_PYTHON_RUNTIME_FOR_TESTS' not in env for script, env in environments.items() if script != 'scripts/e2e_media.py'))


if __name__ == '__main__':
    unittest.main()
