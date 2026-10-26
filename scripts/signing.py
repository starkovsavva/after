#!/usr/bin/env python3
"""Sign owned application code with an explicitly selected Apple identity."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
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


def sign_application(app: Path, entitlements: Path, identity: Identity) -> None:
    # Explicitly sign inside out. Sparkle's framework and helper signatures are
    # preserved; --deep signing and hand-written designated requirements are
    # deliberately absent. Apple identities use codesign's normal stable DR.
    owned = (
        app / "Contents/Frameworks/libposle_core.dylib",
        app / "Contents/MacOS/posle-engine",
        app / "Contents/Helpers/После Распознавание.app",
        app / "Contents/Helpers/После Обработка.app",
        app,
    )
    if not entitlements.is_file() or entitlements.is_symlink():
        raise RuntimeError("Expected a regular entitlements file")
    if any(not path.exists() or path.is_symlink() for path in owned):
        raise RuntimeError("Expected regular owned application components")
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate selection before building")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--entitlements", type=Path)
    args = parser.parse_args()
    if args.check:
        if args.app is not None or args.entitlements is not None:
            parser.error("--check cannot be combined with signing arguments")
    elif args.app is None or args.entitlements is None:
        parser.error("--app and --entitlements are required for signing")
    identity = selected_identity(os.environ.get("POSLE_CODESIGN_IDENTITY"))
    if not args.check:
        sign_application(args.app, args.entitlements, identity)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Signing failed: {error}", file=sys.stderr)
        raise SystemExit(1)
