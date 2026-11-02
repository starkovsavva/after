#!/usr/bin/env python3
"""Reproduce a reviewed model inventory from its pinned archive; never load a graph."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile

PROJECT = Path(__file__).resolve().parents[1]
POLICY = PROJECT / 'backend/asr-model-parakeet-v3-int8.json'
REQUIRED = {'encoder.int8.onnx', 'decoder.int8.onnx', 'joiner.int8.onnx', 'tokens.txt'}


def inventory(archive, policy):
    if policy['schemaVersion'] != 1 or policy['id'] != 'parakeet-v3-int8':
        raise ValueError('Unsupported model policy')
    prefix = policy['directory']
    if not prefix or '/' in prefix or prefix in ('.', '..'):
        raise ValueError('Invalid model directory')
    if archive.is_symlink() or not archive.is_file() or archive.stat().st_size != policy['archive_size']:
        raise ValueError('Pinned model archive size/type mismatch')
    with archive.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != policy['archive_sha256']:
            raise ValueError('Pinned model archive SHA256 mismatch')
    files, directories, seen = [], [], set()
    with tarfile.open(archive, 'r:bz2') as package:
        for item in package:
            name = item.name.rstrip('/') if item.isdir() else item.name
            path = PurePosixPath(name)
            if path.is_absolute() or any(part in ('', '.', '..') for part in name.split('/')) or '\\' in name:
                raise ValueError('Unsafe model archive path')
            if path.parts[0] != prefix or any(ord(c) < 32 for c in name):
                raise ValueError('Model archive root mismatch')
            if len(path.parts) == 1:
                if not item.isdir(): raise ValueError('Invalid model root')
                continue
            relative = '/'.join(path.parts[1:])
            if relative in seen: raise ValueError('Duplicate model entry')
            seen.add(relative)
            if item.isdir(): directories.append(relative)
            elif item.isfile():
                with package.extractfile(item) as stream:
                    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                files.append({'path': relative, 'size': item.size, 'sha256': digest})
            else: raise ValueError('Model aliases and special files are not supported')
    if not REQUIRED <= {item['path'] for item in files}:
        raise ValueError('Missing required model files')
    result = {key: policy[key] for key in ('schemaVersion', 'id', 'version', 'directory', 'archive_url', 'archive_sha256', 'archive_size')}
    result.update(directories=sorted(directories), files=sorted(files,key=lambda item:item['path']), links=[])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    expected = json.dumps(inventory(args.archive, json.loads(POLICY.read_text())), indent=2) + '\n'
    if args.check:
        if POLICY.read_text() != expected: raise SystemExit('Committed model inventory differs from pinned bytes')
    else: POLICY.write_text(expected)
    print('Verified complete pinned Parakeet model inventory')


if __name__ == '__main__': main()
