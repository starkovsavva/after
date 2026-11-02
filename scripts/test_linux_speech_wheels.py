import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import pin_linux_speech_wheels as pin


class LinuxWheelPolicyTests(unittest.TestCase):
    def test_exact_inventory_hash_size_and_no_linked_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            wheel = root / 'fixture-1-py3-none-any.whl'
            wheel.write_bytes(b'fixture only; never parsed or executed')
            policy = {'packages': [{'filename': wheel.name, 'size': wheel.stat().st_size,
                                    'sha256': hashlib.sha256(wheel.read_bytes()).hexdigest()}]}
            pin.check(root, policy)
            wheel.write_bytes(b'changed')
            with self.assertRaises(ValueError):
                pin.check(root, policy)
            content = b'fixture only; never parsed or executed'
            wheel.write_bytes(bytes([content[0] ^ 1]) + content[1:])
            with self.assertRaisesRegex(ValueError, 'SHA256'):
                pin.check(root, policy)
            wheel.unlink()
            outside = root / 'outside'
            outside.write_bytes(b'x')
            wheel.symlink_to(outside)
            with self.assertRaises(ValueError):
                pin.check(root, policy)

    def test_compiled_profile_keeps_direct_pins_and_has_no_apple_or_gpu_packages(self):
        policy = json.loads(pin.POLICY.read_text())
        names = {item['name']: item for item in policy['packages']}
        self.assertEqual(len(names), len(policy['packages']))
        self.assertEqual((policy['target'], policy['python']), ('x86_64-unknown-linux-gnu', 'cp312'))
        for line in (pin.PROJECT / 'backend/requirements-linux-cpu.txt').read_text().splitlines():
            if line and not line.startswith('#'):
                name, version = line.split('==')
                self.assertEqual(names[name]['version'], version)
        for name, item in names.items():
            self.assertFalse(any(part in name for part in ('mlx', 'torch', 'gpu')))
            self.assertTrue(item['url'].startswith('https://files.pythonhosted.org/'))
            self.assertEqual(len(item['sha256']), 64)
