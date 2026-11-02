#!/usr/bin/env python3
"""Verify and execute the pinned Linux CPython in a disposable, offline fixture.

Pass an already downloaded archive. No downloaded code runs until both its pinned
archive digest and the native engine's complete file inventory have passed.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

from pin_python_runtime import inventory, render

PROJECT = Path(__file__).resolve().parents[1]
POLICY = PROJECT / 'backend/python-runtime-linux-x86_64.json'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    archive_source = parser.add_mutually_exclusive_group(required=True)
    archive_source.add_argument('--archive', type=Path)
    archive_source.add_argument('--download', action='store_true', help='Download only the committed pinned HTTPS archive')
    parser.add_argument('--engine', type=Path, default=PROJECT / '.build/rust/debug/posle-engine')
    args = parser.parse_args()
    if sys.platform != 'linux' or os.uname().machine != 'x86_64':
        parser.error('This pinned fixture requires Linux x86_64 GNU')
    engine = args.engine.resolve(strict=True)
    policy = json.loads(POLICY.read_text())
    with tempfile.TemporaryDirectory(prefix='after-linux-python-') as folder:
        root = Path(folder)
        archive = args.archive
        if args.download:
            archive = root / 'runtime.tar.gz'
            subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location',
                            '--proto', '=https', '--proto-redir', '=https', '--max-time', '120',
                            '--max-filesize', str(policy['archive_size']), policy['archive_url'], '-o', str(archive)],
                           check=True, timeout=125)
        if render(inventory(archive, policy)) != POLICY.read_text():
            raise RuntimeError('Archive inventory differs from the committed policy')
        # A fresh private directory; tar's data filter rejects escape
        # paths/special files as well as the inventory generator's earlier checks.
        with tarfile.open(archive, 'r:gz') as package:
            package.extractall(root, filter='data')
        base = root / 'python'
        runtime_env = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'TMPDIR': folder}

        def verify(expected=True):
            result = subprocess.run([str(engine), '--posle-verify-python-runtime', str(base)],
                                    env=runtime_env, capture_output=True, text=True, timeout=30)
            if (result.returncode == 0) != expected:
                raise RuntimeError('Native runtime verification returned an unexpected result: ' + result.stderr[-2000:])

        verify()
        interpreter = base / 'bin/python3.12'
        probe = subprocess.run([str(interpreter), '-B', '-I', '-c',
                                'import json,ssl,sys; print(json.dumps({"version":sys.version.split()[0],"base":sys.base_prefix}))'],
                               env=runtime_env, capture_output=True, text=True, check=True, timeout=15)
        actual = json.loads(probe.stdout)
        if actual != {'version': policy['version'], 'base': str(base)}:
            raise RuntimeError('Pinned CPython version/prefix mismatch')
        venv = root / 'venv'
        subprocess.run([str(interpreter), '-B', '-I', '-m', 'venv', '--symlinks', '--without-pip', str(venv)],
                       env=runtime_env, capture_output=True, text=True, check=True, timeout=30)
        probe = subprocess.run([str(venv / 'bin/python'), '-B', '-I', '-c',
                                'import json,sys; print(json.dumps({"base":sys.base_prefix,"venv":sys.prefix}))'],
                               env=runtime_env, capture_output=True, text=True, check=True, timeout=15)
        if json.loads(probe.stdout) != {'base': str(base), 'venv': str(venv)}:
            raise RuntimeError('Venv escaped the pinned distribution')
        verify()
        library = root / 'disposable-library с пробелами'
        library.mkdir(mode=0o700)
        def install(arguments, expected=True):
            result = subprocess.run([str(engine), '--posle-install-python-runtime', '--root', str(library), *arguments],
                                    env=runtime_env, capture_output=True, text=True, timeout=180)
            if (result.returncode == 0) != expected:
                raise RuntimeError('Native installation returned an unexpected result: ' + result.stderr[-2000:])
            return json.loads(result.stdout) if expected else None
        first = install(['--archive', str(archive.resolve())])
        active = library / 'runtime/linux-python/active.json'
        first_bytes = active.read_bytes()
        if json.loads(first_bytes) != first:
            raise RuntimeError('Installation receipt does not match atomic activation')
        abandoned = active.parent / 'abandoned-fixture'
        abandoned.mkdir(mode=0o700)
        (abandoned / 'keep').write_bytes(b'unreferenced generation; preserve for inspection')
        bad_archive = root / 'invalid-runtime.tar.gz'
        bad_archive.write_bytes(b'not a trusted CPython archive')
        before = set(active.parent.iterdir())
        install(['--archive', str(bad_archive)], expected=False)
        if active.read_bytes() != first_bytes or set(active.parent.iterdir()) != before:
            raise RuntimeError('Failed installation changed the active runtime or leaked its candidate')
        second = install(['--download'] if args.download else ['--archive', str(archive.resolve())])
        if second['generation'] == first['generation'] or json.loads(active.read_bytes()) != second:
            raise RuntimeError('Replacement did not publish a separate generation')
        if (abandoned / 'keep').read_bytes() != b'unreferenced generation; preserve for inspection':
            raise RuntimeError('Installation altered an unrelated interrupted candidate')
        if not Path(first['interpreter']).is_file():
            raise RuntimeError('Replacement removed the previous generation')
        # Check the published environment, not only the pre-publication probe.
        for installed in (first, second):
            subprocess.run([installed['interpreter'], '-B', '-I', '-c', 'import ssl,sys; assert sys.version.split()[0] == "3.12.16"'],
                           env=runtime_env, capture_output=True, text=True, check=True, timeout=15)
        if (library / 'runtime/ready-v2').exists():
            raise RuntimeError('CPython installation must not claim speech readiness')
        # An on-disk policy cannot authorize extra code, and byte tampering is
        # rejected even when the expected file's size stays exactly the same.
        injected = base / 'python-runtime.json'
        injected.write_text('{}')
        verify(False)
        injected.unlink()
        source = base / 'lib/python3.12/encodings/__init__.py'
        content = source.read_bytes()
        source.write_bytes(bytes([content[0] ^ 1]) + content[1:])
        verify(False)
        # Do not execute the damaged tree or modify any installed runtime.
        print(json.dumps({'passed': True, 'target': policy['target'], 'version': policy['version'],
                          'archiveAndTreeVerifiedBeforeExecution': True, 'isolatedVenv': True,
                          'tamperRejected': True, 'systemPythonUsedAsRuntime': False,
                          'speechDependenciesInstalled': False, 'nativeGenerationInstall': True,
                          'failedInstallPreservedActive': True, 'previousGenerationPreserved': True}, indent=2))


if __name__ == '__main__':
    main()
