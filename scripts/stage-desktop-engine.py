#!/usr/bin/env python3
"""Stage a locally built engine for the Tauri shell; never alter a live installation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile


def stage_backend(repo, destination):
    names = json.loads((repo / "backend/desktop-speech-files.json").read_text())
    if not names or len(names) != len(set(names)) or any(not re.fullmatch(r"[a-z_]+\.py", name) for name in names):
        raise ValueError("Invalid desktop speech source catalog")
    destination = destination / "speech-backend"
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        raise ValueError("Refusing an invalid backend staging directory")
    candidate = Path(tempfile.mkdtemp(prefix=".speech-backend-", dir=destination.parent))
    retired = None
    try:
        for name in names:
            source = repo / "backend" / name
            if source.is_symlink() or not stat.S_ISREG(source.lstat().st_mode):
                raise ValueError("Backend source must be an ordinary file")
            with source.open("rb") as src, (candidate / name).open("xb") as out:
                shutil.copyfileobj(src, out)
                out.flush()
                os.fsync(out.fileno())
            (candidate / name).chmod(0o644)
        candidate.chmod(0o755)
        if destination.exists():
            retired = Path(tempfile.mkdtemp(prefix=".old-speech-backend-", dir=destination.parent))
            retired.rmdir()
            os.replace(destination, retired)
        try:
            os.replace(candidate, destination)
        except BaseException:
            if retired is not None:
                os.replace(retired, destination)
                retired = None
            raise
        if retired is not None:
            shutil.rmtree(retired)
        print(f"Staged {len(names)} speech backend modules")
    finally:
        if candidate.exists():
            shutil.rmtree(candidate)


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, help="Canonical engine built from this checkout")
    parser.add_argument("--target", help="Rust target triple; defaults to rustc host")
    args = parser.parse_args()
    target = args.target
    if target is None:
        version = subprocess.run(["rustc", "-vV"], check=True, capture_output=True, text=True).stdout
        target = next(line.removeprefix("host: ") for line in version.splitlines() if line.startswith("host: "))
    if not re.fullmatch(r"[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+){2,4}", target):
        parser.error("Invalid Rust target triple")
    suffix = ".exe" if "windows" in target else ""
    source = args.engine or repo / ".build" / "rust" / "debug" / f"posle-engine{suffix}"
    source = source.absolute()
    if not source.exists() or source.is_symlink() or not stat.S_ISREG(source.lstat().st_mode):
        parser.error("Engine must exist and be a regular non-symlink file; build rust-core first")
    if "windows" in target:
        import importlib.util
        spec = importlib.util.spec_from_file_location("windows_pe", repo / "scripts/check-windows-pe.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        try:
            module.inspect(source)
        except (ValueError, OSError) as error:
            parser.error(str(error))
    destination = repo / "desktop" / "src-tauri" / "binaries" / f"posle-engine-{target}{suffix}"
    if destination.parent.is_symlink() or destination.is_symlink():
        parser.error("Refusing a symlink in the staging destination")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        fd, name = tempfile.mkstemp(prefix=".engine-", dir=destination.parent)
        temporary = Path(name)
        with os.fdopen(fd, "wb") as out, source.open("rb") as source_file:
            shutil.copyfileobj(source_file, out)
            out.flush()
            os.fsync(out.fileno())
        temporary.chmod(0o755)
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    stage_backend(repo, destination.parent)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    print(f"Staged {destination.relative_to(repo)}")
    print(f"SHA-256 {digest}")
    print("Rebuild the Tauri host to embed this digest. This is integrity checking, not publisher signing.")


if __name__ == "__main__":
    main()
