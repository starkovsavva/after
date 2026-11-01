#!/usr/bin/env python3
"""Sign owned application code with an explicitly selected Apple identity."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys


@dataclass(frozen=True)
class Identity:
    fingerprint: str
    developer_id: bool = False


def selected_identity(value: str | None) -> Identity:
    # Never select a certificate from the keychain automatically. The default
    # remains an ad-hoc development build, without a persistent Apple identity.
    if value in (None, ""):
        return Identity("-")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", value):
        raise RuntimeError("POSLE_CODESIGN_IDENTITY must be a 40-character certificate fingerprint")
    fingerprint = value.upper()
    result = subprocess.run(
        ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise RuntimeError("Could not check available code-signing identities")
    entries = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"\r\n]+)"\s*$', result.stdout, re.MULTILINE)
    matches = [name for digest, name in entries if digest.upper() == fingerprint]
    if len(matches) != 1:
        raise RuntimeError("Selected code-signing identity is not available as a valid identity")
    name = matches[0]
    if name.startswith("Developer ID Application:"):
        return Identity(fingerprint, developer_id=True)
    if name.startswith("Apple Development:"):
        return Identity(fingerprint)
    raise RuntimeError("Select a Developer ID Application or Apple Development identity")


def core_digest(library: Path) -> str:
    if not library.is_file() or library.is_symlink():
        raise RuntimeError("Expected a regular Rust core library")
    digest = hashlib.sha256()
    with library.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_core_digest(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise RuntimeError("Expected a regular Rust core digest file")
    value = path.read_bytes()
    if not re.fullmatch(rb"[0-9a-f]{64}", value):
        raise RuntimeError("Expected exactly 64 lowercase hexadecimal Rust core digest bytes")
    return value.decode("ascii")


def sign_core_library(library: Path, identity: Identity) -> str:
    # The digest must cover the final install name AND final code signature.
    core_digest(library)  # Reject missing/symlink inputs before signing.
    command = ["/usr/bin/codesign", "--force", "--sign", identity.fingerprint]
    if identity.developer_id:
        command.append("--timestamp")
    subprocess.run(command + [str(library)], check=True)
    verify_core_library(library, identity)
    return core_digest(library)


def verify_core_library(library: Path, identity: Identity) -> None:
    command = ["/usr/bin/codesign", "--verify", "--strict"]
    if identity.fingerprint != "-":
        command.extend(["-R", "=anchor apple generic"])
    subprocess.run(command + [str(library)], check=True)


def sign_application(app: Path, entitlements: Path, identity: Identity, *, presigned_core_sha256: str | None = None) -> None:
    # Explicitly sign inside out. Sparkle's framework and helper signatures are
    # preserved; --deep signing and hand-written designated requirements are
    # deliberately absent. Apple identities use codesign's normal stable DR.
    owned = (
        app / "Contents/Frameworks/libposle_core.dylib",
        app / "Contents/MacOS/After Engine",
        app / "Contents/MacOS/posle-engine",
        app / "Contents/Helpers/После Распознавание.app",
        app / "Contents/Helpers/После Обработка.app",
        app,
    )
    if not entitlements.is_file() or entitlements.is_symlink():
        raise RuntimeError("Expected a regular entitlements file")
    if any(not path.exists() or path.is_symlink() for path in owned):
        raise RuntimeError("Expected regular owned application components")
    core = owned[0]
    if presigned_core_sha256 is not None:
        if not re.fullmatch(r"[0-9a-f]{64}", presigned_core_sha256) or core_digest(core) != presigned_core_sha256:
            raise RuntimeError("Pre-signed Rust core digest does not match the staged library")
        verify_core_library(core, identity)
        owned = owned[1:]
    for target in owned:
        command = ["/usr/bin/codesign", "--force", "--sign", identity.fingerprint]
        if identity.developer_id:
            command.append("--timestamp")
        if target == app:
            command.extend(["--entitlements", str(entitlements)])
        command.append(str(target))
        subprocess.run(command, check=True)
        if identity.fingerprint != "-":
            # Display names are not proof of the issuer. Test Apple's chain
            # without replacing the component's designated requirement.
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=anchor apple generic", str(target)], check=True)
    if presigned_core_sha256 is not None:
        if core_digest(core) != presigned_core_sha256:
            raise RuntimeError("Signing changed the trusted Rust core library")
        verify_core_library(core, identity)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate selection before building")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--entitlements", type=Path)
    parser.add_argument("--library", type=Path, help="Pre-sign the staged Rust library before linking Swift")
    parser.add_argument("--digest-file", type=Path, help="Write the final signed library SHA-256 for __TEXT linking")
    parser.add_argument("--presigned-core-sha256", type=Path, help="Verify this digest and preserve the already signed Rust library")
    args = parser.parse_args()
    if args.check:
        if any(value is not None for value in (args.app, args.entitlements, args.library, args.digest_file, args.presigned_core_sha256)):
            parser.error("--check cannot be combined with signing arguments")
    elif args.library is not None:
        if args.digest_file is None or any(value is not None for value in (args.app, args.entitlements, args.presigned_core_sha256)):
            parser.error("--library requires only --digest-file")
        if args.digest_file.is_symlink():
            parser.error("Expected a regular digest output path")
    elif args.app is None or args.entitlements is None or args.digest_file is not None:
        parser.error("--app and --entitlements are required for signing")
    identity = selected_identity(os.environ.get("POSLE_CODESIGN_IDENTITY"))
    if args.library is not None:
        args.digest_file.write_text(sign_core_library(args.library, identity), encoding="ascii")
    elif not args.check:
        expected = read_core_digest(args.presigned_core_sha256) if args.presigned_core_sha256 is not None else None
        sign_application(args.app, args.entitlements, identity, presigned_core_sha256=expected)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Signing failed: {error}", file=sys.stderr)
        raise SystemExit(1)
