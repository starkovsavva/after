#!/usr/bin/env python3
"""Regenerate the CPython inventory from its already pinned, verified archive.

Metadata in backend/python-runtime.json is the reviewed trust root. This tool
never runs Python from the archive and never derives trust from installed files.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import posixpath
import re
import tarfile

POLICY = Path(__file__).resolve().parents[1] / "backend/python-runtime.json"


def normalized(name: str) -> str:
    path = PurePosixPath(name)
    if (not name or path.is_absolute() or any(part in ("", ".", "..") for part in name.split("/"))
            or "\\" in name or any(ord(character) < 32 for character in name)):
        raise ValueError("Unsafe archive path: " + name)
    return path.as_posix()


def inventory(archive: Path, policy: dict) -> dict:
    if (policy.get("schemaVersion") != 1 or not re.fullmatch(r"3\.12\.[0-9]+", policy.get("version", ""))
            or not re.fullmatch(r"[0-9a-f]{64}", policy.get("archive_sha256", ""))
            or not re.fullmatch(r"cpython-[A-Za-z0-9.+-]+", policy.get("directory", ""))
            or not policy.get("archive_url", "").startswith("https://github.com/astral-sh/python-build-standalone/releases/download/")):
        raise ValueError("Invalid pinned CPython policy")
    if archive.is_symlink() or not archive.is_file() or archive.stat().st_size != policy["archive_size"]:
        raise ValueError("Pinned CPython archive size mismatch")
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != policy["archive_sha256"]:
            raise ValueError("Pinned CPython archive SHA256 mismatch")
    files, links, directories, names, folded = [], [], set(), set(), set()
    with tarfile.open(archive, "r:gz") as package:
        for member in package:
            name = normalized(member.name.rstrip("/") if member.isdir() else member.name)
            parts = PurePosixPath(name).parts
            if parts[0] != "python":
                raise ValueError("Archive must contain only python/")
            if len(parts) == 1:
                if not member.isdir():
                    raise ValueError("Invalid archive root")
                continue
            relative = "/".join(parts[1:])
            if relative in names or relative.casefold() in folded:
                raise ValueError("Duplicate or ambiguous archive path: " + relative)
            names.add(relative); folded.add(relative.casefold())
            parent = PurePosixPath(relative).parent
            while parent != PurePosixPath("."):
                directories.add(parent.as_posix()); parent = parent.parent
            if member.isdir():
                directories.add(relative)
            elif member.isfile():
                with package.extractfile(member) as stream:
                    digest = hashlib.file_digest(stream, "sha256").hexdigest()
                files.append({"path": relative, "sha256": digest, "size": member.size})
            elif member.issym():
                target = member.linkname
                if not target or target.startswith("/") or "\\" in target or any(ord(c) < 32 for c in target):
                    raise ValueError("Unsafe archive alias: " + relative)
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(relative), target))
                if resolved == ".." or resolved.startswith("../"):
                    raise ValueError("Archive alias escapes CPython: " + relative)
                links.append({"path": relative, "target": target})
            else:
                raise ValueError("Unsupported archive entry: " + relative)
    regular = {entry["path"] for entry in files}
    aliases = {entry["path"]: entry["target"] for entry in links}
    if directories & (regular | aliases.keys()):
        raise ValueError("Archive path is both a file/alias and a parent directory")
    for alias in aliases:
        current, visited = alias, set()
        while current in aliases:
            if current in visited:
                raise ValueError("Cyclic archive alias: " + alias)
            visited.add(current)
            current = posixpath.normpath(posixpath.join(posixpath.dirname(current), aliases[current]))
        if current not in regular | directories:
            raise ValueError("Dangling archive alias: " + alias)
    for required in ("bin/python3.12", "lib/libpython3.12.dylib", "lib/python3.12/encodings/__init__.py"):
        if required not in regular:
            raise ValueError("Missing required CPython file: " + required)
    result = {key: policy[key] for key in ("schemaVersion", "version", "directory", "archive_url", "archive_sha256", "archive_size")}
    result.update(directories=sorted(directories), files=sorted(files, key=lambda entry: entry["path"]), links=sorted(links, key=lambda entry: entry["path"]))
    return result


def render(policy: dict) -> str:
    # One inventory entry per line keeps a large generated policy reviewable.
    lines = ["{"]
    for key in ("schemaVersion", "version", "directory", "archive_url", "archive_sha256", "archive_size"):
        lines.append("  " + json.dumps(key) + ": " + json.dumps(policy[key]) + ",")
    for key in ("directories", "files", "links"):
        lines.append("  " + json.dumps(key) + ": [")
        entries = policy[key]
        for index, entry in enumerate(entries):
            lines.append("    " + json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + ("," if index + 1 < len(entries) else ""))
        lines.append("  ]" + ("," if key != "links" else ""))
    return "\n".join(lines + ["}", ""])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--check", action="store_true", help="Fail if the committed inventory differs; never write")
    args = parser.parse_args()
    expected = render(inventory(args.archive, json.loads(POLICY.read_text())))
    if args.check:
        if POLICY.read_text() != expected:
            raise SystemExit("Committed CPython inventory differs from the verified archive")
    else:
        POLICY.write_text(expected)
    print("Verified pinned CPython archive and complete inventory")


if __name__ == "__main__":
    main()
