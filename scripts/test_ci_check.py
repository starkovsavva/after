import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

PATH = Path(__file__).with_name('run-ci-check.py')
spec = importlib.util.spec_from_file_location('ci_check', PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CILogChecks(unittest.TestCase):
    def test_failure_keeps_exit_code_and_escapes_workflow_annotation(self):
        result = subprocess.run([sys.executable, str(PATH), '--', sys.executable, '-c',
                                 'print("error: failed 10%\\nnext line");raise SystemExit(7)'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 7)
        annotation = [line for line in result.stdout.splitlines() if line.startswith('::error ')][0]
        self.assertIn('10%25%0A', annotation)

    def test_success_does_not_emit_error_annotation(self):
        result = subprocess.run([sys.executable, str(PATH), '--', sys.executable, '-c', 'print("passed")'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertNotIn('::error', result.stdout)
