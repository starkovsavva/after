import argparse
import contextlib
import io
import os
import tempfile
from pathlib import Path
import unittest
from unittest import mock

import verify


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
        with mock.patch.dict(os.environ, {'POSLE_DATA_DIR': '/fixture/private-library', 'OPENAI_API_KEY': 'not-a-real-key', 'PROVIDER_SECRET': 'not-a-real-secret', 'POSLE_JOB_SETTINGS': '{"mode":"cloud"}', 'PYTHONPATH': '/fixture/foreign-modules', 'PYTHONHOME': '/fixture/foreign-home'}):
            controller = self.controller()
        self.assertNotIn('POSLE_DATA_DIR', controller.env)
        self.assertNotIn('OPENAI_API_KEY', controller.env)
        self.assertNotIn('PROVIDER_SECRET', controller.env)
        self.assertNotIn('POSLE_JOB_SETTINGS', controller.env)
        self.assertNotIn('PYTHONPATH', controller.env)
        self.assertNotIn('PYTHONHOME', controller.env)

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
        self.assertEqual(called, {'scripts/e2e.py', 'scripts/e2e_media.py', 'scripts/check_media.py', 'scripts/check_search.py', 'scripts/check_managed_identity.py'})
        self.assertFalse(any('check_audio' in str(command) for command in commands))
        self.assertEqual(environments['scripts/check_media.py']['PYTHONPATH'], str(verify.PROJECT / 'backend'))


if __name__ == '__main__':
    unittest.main()
