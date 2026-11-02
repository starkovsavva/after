#!/usr/bin/env python3
"""Check a Linux CPU wheelhouse against the reviewed lock; refresh from PyPI only explicitly."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.request

PROJECT = Path(__file__).resolve().parents[1]
POLICY = PROJECT / 'backend/python-wheels-linux-x86_64.json'


def refresh(wheelhouse):
    packages = []
    for path in sorted(wheelhouse.glob('*.whl')):
        if path.is_symlink() or not path.is_file():
            raise ValueError('Wheel must be an ordinary file')
        name, version = path.name.split('-')[:2]
        name = re.sub(r'[-_.]+', '-', name).lower()
        with urllib.request.urlopen(f'https://pypi.org/pypi/{name}/{version}/json', timeout=30) as response:
            metadata = json.load(response)
        file = next(item for item in metadata['urls'] if item['filename'] == path.name)
        if file['packagetype'] != 'bdist_wheel' or not file['url'].startswith('https://files.pythonhosted.org/'):
            raise ValueError('Only official PyPI wheel assets are supported')
        with path.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if digest != file['digests']['sha256'] or path.stat().st_size != file['size']:
            raise ValueError('Wheel bytes differ from official PyPI metadata')
        packages.append(dict(name=name, version=version, filename=path.name, url=file['url'], sha256=digest, size=file['size']))
    if not packages:
        raise ValueError('No wheels found')
    return dict(schemaVersion=1, target='x86_64-unknown-linux-gnu', python='cp312', packages=packages)


def check(wheelhouse, policy):
    expected = {item['filename'] for item in policy['packages']}
    if {path.name for path in wheelhouse.glob('*.whl')} != expected:
        raise ValueError('Wheelhouse differs from the complete pinned package set')
    for item in policy['packages']:
        path = wheelhouse / item['filename']
        if path.is_symlink() or not path.is_file() or path.stat().st_size != item['size']:
            raise ValueError('Pinned wheel size/type mismatch')
        with path.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != item['sha256']:
                raise ValueError('Pinned wheel SHA256 mismatch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wheelhouse', type=Path, required=True)
    parser.add_argument('--refresh', action='store_true', help='Explicitly read official PyPI release metadata and replace the lock')
    args = parser.parse_args()
    if args.refresh:
        policy = refresh(args.wheelhouse)
        POLICY.write_text(json.dumps(policy, indent=2) + '\n')
    else:
        policy = json.loads(POLICY.read_text())
    check(args.wheelhouse, policy)
    print(f"Verified {len(policy['packages'])} pinned Linux CPU wheels")


if __name__ == '__main__':
    main()
