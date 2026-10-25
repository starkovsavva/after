#!/usr/bin/env python3
"""Verify native names and safe migration of the app-owned model runtime.

Uses only signed temporary copies of system tools; no models, network, user
process enumeration, Application Support changes, microphone, or recording.
"""
from __future__ import annotations

import ctypes
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[1]
SERVER = "После ИИ"
MODEL = "После Модель"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def seed(source, destination):
    shutil.copyfile(source, destination)
    destination.chmod(0o700)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(destination)],
                   check=True, capture_output=True)


def main():
    with tempfile.TemporaryDirectory(prefix="posle-managed-identity-") as temporary:
        directory = Path(temporary).resolve()
        source = (PROJECT / "Sources/PosleApp/Services.swift").read_text()
        start = source.index("enum ManagedModelRuntime {")
        end = source.index("@MainActor\nfinal class LocalModelService", start)
        swift = directory / "check.swift"
        swift.write_text("import Foundation\nimport Darwin\n"
                         "enum AppError: Error { case message(String) }\n" + source[start:end] +
                         '\nprint(try ManagedModelRuntime.brandedExecutable(root: '
                         'URL(fileURLWithPath: CommandLine.arguments[1])).path)\n')
        checker = directory / "check"
        subprocess.run(["swiftc", "-module-cache-path", str(directory / "module-cache"),
                        str(swift), "-o", str(checker)], check=True)

        def prepare(root, succeeds=True):
            result = subprocess.run([str(checker), str(root)], capture_output=True, text=True)
            assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
            return result.stdout.strip()

        def fixture(label, bin_layout=False):
            root = directory / label
            base = root / "runtime/ollama"
            binary = base / "bin" if bin_layout else base
            binary.mkdir(parents=True)
            for name in ("ollama", "llama-server"):
                seed("/bin/sleep", binary / name)
            return root, binary

        root, binary = fixture("Папка с пробелами")
        original = {name: digest(binary / name) for name in ("ollama", "llama-server")}
        assert prepare(root) == str(binary / SERVER)
        for old, display in (("ollama", SERVER), ("llama-server", MODEL)):
            assert (binary / old).is_symlink()
            assert os.readlink(binary / old) == display
            assert digest(binary / display) == original[old]
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary / display)], check=True)
        identity = {name: (binary / name).stat() for name in (SERVER, MODEL)}
        prepare(root)
        for name, before in identity.items():
            after = (binary / name).stat()
            assert (before.st_ino, before.st_mtime_ns) == (after.st_ino, after.st_mtime_ns)

        library = ctypes.CDLL("/usr/lib/libproc.dylib")
        library.proc_name.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        for old, display in (("ollama", SERVER), ("llama-server", MODEL)):
            process = subprocess.Popen([str(binary / old), "5"])
            try:
                time.sleep(0.1)
                assert process.poll() is None
                buffer = ctypes.create_string_buffer(4096)
                assert library.proc_name(process.pid, buffer, len(buffer)) > 0
                assert buffer.value.decode() == display, buffer.value
                assert library.proc_pidpath(process.pid, buffer, len(buffer)) > 0
                assert Path(buffer.value.decode()) == binary / display
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait()
        print("PASS: actual kernel process names and paths are После ИИ / После Модель")

        # An interrupted rename recovers; a freshly extracted update replaces the
        # previous executable without rewriting or re-signing its verified bytes.
        (binary / "ollama").unlink()
        prepare(root)
        (binary / "llama-server").unlink()
        seed("/bin/cat", binary / "llama-server")
        updated = digest(binary / "llama-server")
        prepare(root)
        assert digest(binary / MODEL) == updated
        other, other_binary = fixture("bin layout", True)
        assert prepare(other) == str(other_binary / SERVER)
        print("PASS: repeat launch, interrupted migration, runtime update and bin layout")

        # No foreign runtime, compatibility link, lock file, or branded target is
        # followed or overwritten, including a link that points to a real binary.
        outside = directory / "external-model"
        seed("/bin/sleep", outside)
        expected = digest(outside)
        bad, bad_binary = fixture("bad compatibility link")
        (bad_binary / "llama-server").unlink()
        (bad_binary / "llama-server").symlink_to(outside)
        prepare(bad, False)
        bad, bad_binary = fixture("bad branded target")
        (bad_binary / SERVER).symlink_to(outside)
        prepare(bad, False)
        bad, bad_binary = fixture("bad lock")
        (bad_binary / ".posle-identity.lock").symlink_to(outside)
        prepare(bad, False)
        bad = directory / "bad runtime directory"
        (bad / "runtime").mkdir(parents=True)
        (bad / "runtime/ollama").symlink_to(binary, target_is_directory=True)
        prepare(bad, False)
        assert digest(outside) == expected
        bad, bad_binary = fixture("contended lock")
        with (bad_binary / ".posle-identity.lock").open("w") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            started = time.monotonic()
            prepare(bad, False)
            assert time.monotonic() - started < 2, "UI must not block behind another migration"
        print("PASS: symlink escapes, unsafe targets and lock contention rejected; external binary unchanged")


if __name__ == "__main__":
    main()
