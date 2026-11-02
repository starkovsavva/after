#!/usr/bin/env python3
"""Exercise pinned CPU wheels and generation rollback; no speech models/personal data."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sources = parser.add_mutually_exclusive_group(required=True)
    sources.add_argument('--archive', type=Path)
    sources.add_argument('--download', action='store_true')
    parser.add_argument('--wheelhouse', type=Path)
    parser.add_argument('--engine', type=Path, default=PROJECT / '.build/rust/debug/posle-engine')
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('Linux x86_64 GNU is required')
    engine = args.engine.resolve(strict=True)
    source = ['--archive', str(args.archive.resolve(strict=True))] if args.archive else ['--download']
    cache = ['--wheelhouse', str(args.wheelhouse.resolve(strict=True))] if args.wheelhouse else []
    policy = json.loads((PROJECT / 'backend/python-wheels-linux-x86_64.json').read_text())
    with tempfile.TemporaryDirectory(prefix='after-cpu-speech-') as folder:
        root = Path(folder)
        library = root / 'CPU library с пробелами'
        library.mkdir(mode=0o700)
        env = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'TMPDIR': folder}
        def install(extra, expected=True):
            result = subprocess.run([str(engine), '--posle-install-python-runtime', '--root', str(library), *source, *extra],
                                    env=env, capture_output=True, text=True, timeout=1500)
            if (result.returncode == 0) != expected:
                raise RuntimeError('CPU profile installation returned an unexpected result: ' + result.stderr[-2000:])
            return json.loads(result.stdout) if expected else None
        previous = install([])
        active = library / 'runtime/linux-python/active.json'
        before = active.read_bytes()
        entries = set(active.parent.iterdir())
        broken = root / 'corrupted-wheelhouse'
        broken.mkdir(mode=0o700)
        # A named package with wrong bytes must fail before pip or activation.
        first = policy['packages'][0]
        (broken / first['filename']).write_bytes(b'not the pinned wheel')
        install(['--profile', 'linux-cpu', '--wheelhouse', str(broken)], expected=False)
        if active.read_bytes() != before or set(active.parent.iterdir()) != entries:
            raise RuntimeError('Failed CPU preparation changed activation or leaked its candidate')
        installed = install(['--profile', 'linux-cpu', *cache])
        if json.loads(active.read_bytes()) != installed or installed['generation'] == previous['generation']:
            raise RuntimeError('CPU generation publication failed')
        if not Path(previous['interpreter']).is_file():
            raise RuntimeError('Previous generation was removed')
        generation = Path(installed['interpreter']).parent.parent.parent
        report = json.loads((generation / 'cpu-probe-result.json').read_text())
        if report != {'cpuInferenceVerified': True, 'bundledFfmpegVerified': True, 'modelsInstalled': False}:
            raise RuntimeError('CPU inference/media probe did not pass')
        checked = subprocess.run([str(engine), '--posle-check-python-runtime', '--root', str(library)],
                                 env=env, capture_output=True, text=True, timeout=30, check=True)
        if json.loads(checked.stdout) != installed:
            raise RuntimeError('Published generation did not pass active-runtime verification')
        if (library / 'runtime/ready-v2').exists():
            raise RuntimeError('Dependencies must not claim full speech/model readiness')
        print(json.dumps({'passed': True, 'pinnedWheels': len(policy['packages']), **report,
                          'corruptWheelPreservedActive': True, 'previousGenerationPreserved': True}, indent=2))


if __name__ == '__main__':
    main()
