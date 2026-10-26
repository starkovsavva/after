"""Exercise the real installer shell with a synthetic pinned archive and verifier.

Only curl is replaced in a disposable copy. System tar/shasum/plutil/lockf run
normally; fixture interpreters model venv/pip without loading Python packages,
models, credentials, user runtimes, or any network endpoint.
"""
from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
DIRECTORY = "cpython-3.12.16+20261026-aarch64-apple-darwin"
URL = "https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.12.16%2B20261026-aarch64-apple-darwin-install_only_stripped.tar.gz"
SHA = "353d5f1b4fd2715e7053f12f068435d5bbad16b91e057006b5d01e0925709a7e"


@unittest.skipUnless(sys.platform == "darwin", "Installer uses macOS native tools")
class PythonRuntimeSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="posle-python-installer-", dir="/private/tmp")
        self.work = Path(self.temporary.name)
        self.root = self.work / "Данные с пробелами"
        self.backend = self.work / "signed backend"
        self.backend.mkdir()
        self.trace = self.work / "trace.jsonl"
        self.executed_old = self.work / "UNVERIFIED-EXECUTED"
        self.base = self.root / "runtime/python" / DIRECTORY
        self.venv = self.root / "runtime/venv"
        self.archive = self.work / "fixture.tar.gz"
        self._create_fixture()

    def tearDown(self):
        for current, _, _ in os.walk(self.work):
            os.chmod(current, 0o700)
        self.temporary.cleanup()

    def executable(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!{sys.executable} -I\n" + body)
        path.chmod(0o700)

    def _create_fixture(self):
        self.payload = (f"#!{sys.executable} -I\n" + f'''
import json, os, pathlib, sys
root = pathlib.Path({str(self.root)!r})
trace = pathlib.Path({str(self.trace)!r})
args = sys.argv[1:]
with trace.open("a") as out: out.write(json.dumps({{"event": "python", "argv": args, "executable": sys.argv[0]}}) + "\\n")
assert args[:2] == ["-B", "-I"], "runtime execution must ignore ambient Python config and bytecode"
if args[2:4] == ["-m", "venv"]:
    assert "--symlinks" in args and "--without-pip" in args
    venv = pathlib.Path(args[-1]); (venv / "bin").mkdir(parents=True)
    (venv / "pyvenv.cfg").write_text("home = " + str(pathlib.Path(__file__).resolve().parent) + "\\n")
    (venv / "bin/python3.12").symlink_to(pathlib.Path(__file__).resolve())
    (venv / "bin/python3").symlink_to("python3.12")
    (venv / "bin/python").symlink_to("python3")
elif args[2:4] == ["-m", "ensurepip"]:
    if (root / ".fail-ensurepip").exists(): sys.exit(21)
elif args[2:4] == ["-m", "pip"]:
    assert "--isolated" in args and "--no-compile" in args
    assert pathlib.Path(sys.argv[0]).parent.parent == root / "runtime/venv", "pip must use its final venv path"
    if (root / ".fail-pip").exists(): sys.exit(22)
    packages = root / "runtime/venv/lib/python3.12/site-packages"
    packages.mkdir(parents=True, exist_ok=True); (packages / "fixture-dependencies").write_text("installed")
elif args[2] == "-":
    sys.stdin.read()
    settings = root / "settings.json"
    print(json.loads(settings.read_text()).get("speechLocalModel", "parakeet-v3") if settings.exists() else "parakeet-v3")
else: raise RuntimeError("Unexpected fixture interpreter call")
''').encode()
        files = {
            "bin/python3.12": self.payload,
            "lib/libpython3.12.dylib": b"synthetic library; never dynamically loaded",
            "lib/python3.12/encodings/__init__.py": b"# synthetic stdlib\n",
        }
        self.files = files
        directories = set()
        for name in files:
            directories.update(str(parent) for parent in Path(name).parents if str(parent) != ".")
        with tarfile.open(self.archive, "w:gz") as archive:
            for name in ["python", *["python/" + name for name in sorted(directories)]]:
                info = tarfile.TarInfo(name); info.type = tarfile.DIRTYPE; info.mode = 0o700
                archive.addfile(info)
            for name, body in files.items():
                info = tarfile.TarInfo("python/" + name); info.mode = 0o700 if name.startswith("bin/") else 0o600; info.size = len(body)
                archive.addfile(info, io.BytesIO(body))
        policy = {"schemaVersion": 1, "version": "3.12.16", "directory": DIRECTORY,
                  "archive_url": URL, "archive_sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
                  "archive_size": self.archive.stat().st_size,
                  "files": [{"path": name, "sha256": hashlib.sha256(body).hexdigest(), "size": len(body)} for name, body in files.items()],
                  "directories": sorted(directories), "links": []}
        (self.backend / "python-runtime.json").write_text(json.dumps(policy))
        (self.backend / "requirements.txt").write_text("synthetic-package==1\n")
        (self.backend / "engine.py").write_text("raise RuntimeError('fixture backend must not execute')\n")
        self.curl = self.work / "synthetic-curl"
        self.executable(self.curl, f'''
import json, pathlib, shutil, sys
with pathlib.Path({str(self.trace)!r}).open("a") as out: out.write(json.dumps({{"event": "download", "argv": sys.argv[1:]}}) + "\\n")
assert {URL!r} in sys.argv
shutil.copyfile({str(self.archive)!r}, sys.argv[sys.argv.index("-o") + 1])
''')
        source = (PROJECT / "backend/setup.sh").read_text()
        assert source.count("/usr/bin/curl") == 1
        self.setup = self.backend / "setup.sh"
        self.setup.write_text(source.replace("/usr/bin/curl", shlex.quote(str(self.curl))))
        self.host = self.work / "synthetic-native-host"
        expected = {name: hashlib.sha256(body).hexdigest() for name, body in files.items()}
        self.executable(self.host, f'''
import hashlib, json, os, pathlib, stat, sys
root = pathlib.Path({str(self.root)!r}); trace = pathlib.Path({str(self.trace)!r})
args = sys.argv[1:]
with trace.open("a") as out: out.write(json.dumps({{"event": "verify" if args[0] == "--posle-verify-python-runtime" else "prepare", "argv": args}}) + "\\n")
if args[0] == "--posle-verify-python-runtime":
    assert len(args) == 2
    base = pathlib.Path(args[1]); expected = {expected!r}; directories = {sorted(directories)!r}
    if base == pathlib.Path({str(self.base)!r}) and (root / ".reject-final").exists(): sys.exit(23)
    assert base.is_dir() and not base.is_symlink()
    assert {{str(p.relative_to(base)) for p in base.rglob("*")}} == set(expected) | set(directories)
    for name, digest in expected.items():
        path = base / name; info = path.lstat()
        assert stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o022
        assert hashlib.sha256(path.read_bytes()).hexdigest() == digest
elif args[0] == "--posle-python-host":
    assert args[1:] == [str(root / "runtime/venv/bin/python"), {str(self.backend / 'engine.py')!r}, "prepare", "--root", str(root)]
    assert pathlib.Path(args[1]).resolve() == pathlib.Path({str(self.base / 'bin/python3.12')!r})
    if (root / ".fail-prepare").exists(): sys.exit(24)
else: raise RuntimeError("Unexpected native host command")
''')

    def records(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def run_setup(self, succeeds=True, host=None):
        environment = {name: value for name, value in os.environ.items()
                       if not name.startswith(("PYTHON", "POSLE_", "UV_", "DYLD_", "PIP_"))
                       and not any(word in name.upper() for word in ("KEY", "TOKEN", "SECRET", "PASSWORD", "COOKIE", "CREDENTIAL"))}
        result = subprocess.run(["/bin/bash", str(self.setup), str(self.root), str(host or self.host)],
                                capture_output=True, text=True, env=environment, timeout=30)
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
        self.assertFalse(self.executed_old.exists(), "An unverified previous runtime executed")
        self.assertFalse(any(path.is_dir() for path in (self.root / "runtime").glob(".python-setup.*")), "Installer left staging or rollback data")
        return result

    def seed_old(self):
        old = b"#!/bin/bash\n/usr/bin/touch " + shlex.quote(str(self.executed_old)).encode() + b"\nexit 77\n"
        for path in [self.venv / "bin/python", self.root / "runtime/uv", self.base / "bin/python3.12"]:
            path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(old); path.chmod(0o700)
        (self.venv / "pyvenv.cfg").write_text("untrusted old venv\n")
        (self.root / "runtime/ready-v2").touch()
        self.weights = self.root / "cache/ollama-models/blobs/existing"
        self.weights.parent.mkdir(parents=True, exist_ok=True); self.weights.write_bytes(b"existing downloaded model weights")
        return old

    def assert_weights(self):
        self.assertEqual(self.weights.read_bytes(), b"existing downloaded model weights")

    def test_policy_pins_reviewed_archive_and_installer_has_no_uv_or_python_fallback(self):
        policy = json.loads((PROJECT / "backend/python-runtime.json").read_text())
        self.assertEqual((policy["version"], policy["directory"], policy["archive_url"], policy["archive_sha256"], policy["archive_size"]),
                         ("3.12.16", DIRECTORY, URL, SHA, 25035343))
        source = (PROJECT / "backend/setup.sh").read_text()
        self.assertNotIn('"$UV"', source)
        self.assertNotIn('UV_PYTHON_INSTALL_DIR', source)
        self.assertNotIn('"$VENV/bin/python" -B -u', source)
        self.assertIn('--posle-verify-python-runtime', source)

    def test_rebuild_never_executes_old_python_uv_or_ready_marker_and_preserves_weights(self):
        self.seed_old()
        self.run_setup()
        records = self.records()
        first_python = next(index for index, item in enumerate(records) if item["event"] == "python")
        self.assertTrue(any(item["event"] == "verify" and item["argv"][1] == str(self.base) for item in records[:first_python]))
        self.assertEqual(self.venv.joinpath("bin/python").resolve(), self.base / "bin/python3.12")
        self.assertTrue((self.root / "runtime/ready-v2").is_file())
        self.assertEqual(self.base.joinpath("bin/python3.12").read_bytes(), self.payload)
        self.assertFalse(self.base.stat().st_mode & 0o222)
        self.assert_weights()

    def test_archive_tampering_fails_before_extract_verify_or_python_execution(self):
        self.seed_old()
        shutil.rmtree(self.base)
        body = bytearray(self.archive.read_bytes()); body[-1] ^= 1; self.archive.write_bytes(body)
        result = self.run_setup(succeeds=False)
        self.assertIn("Проверка среды Python не прошла", result.stderr)
        self.assertEqual([item["event"] for item in self.records()], ["download"])
        self.assertFalse((self.root / "runtime/ready-v2").exists())
        self.assert_weights()

    def test_failed_dependency_or_prepare_stage_restores_previous_runtime_and_venv(self):
        for failure in (".fail-ensurepip", ".fail-pip", ".fail-prepare"):
            with self.subTest(failure=failure):
                old = self.seed_old(); (self.root / failure).touch()
                self.run_setup(succeeds=False)
                self.assertEqual((self.venv / "bin/python").read_bytes(), old)
                self.assertEqual((self.base / "bin/python3.12").read_bytes(), old)
                self.assertFalse((self.root / "runtime/ready-v2").exists())
                self.assert_weights(); (self.root / failure).unlink()

    def test_failed_final_publication_verification_restores_old_base_before_any_python_exec(self):
        old = self.seed_old(); (self.root / ".reject-final").touch()
        self.run_setup(succeeds=False)
        self.assertEqual((self.base / "bin/python3.12").read_bytes(), old)
        self.assertEqual((self.venv / "bin/python").read_bytes(), old)
        self.assertFalse(any(item["event"] == "python" for item in self.records()))
        self.assertFalse((self.root / "runtime/ready-v2").exists())
        self.assert_weights()

    def test_failed_atomic_rename_or_backup_preserves_previous_runtime_and_venv(self):
        original_source = self.setup.read_text()
        wrapper = self.work / "synthetic-mv-failure"
        for phase in ("base-backup", "base-publish", "venv-backup", "venv-publish"):
            with self.subTest(phase=phase):
                old = self.seed_old()
                self.executable(wrapper, f'''
import os, sys
args = sys.argv[1:]
phase = {phase!r}
source, target = args[-2:]
blocked = (phase == "base-backup" and target.endswith("/previous-python") or
           phase == "base-publish" and source.endswith("/extracted/python") or
           phase == "venv-backup" and target.endswith("/previous-venv") or
           phase == "venv-publish" and source.endswith("/new-venv"))
if blocked: sys.exit(25)
os.execv("/bin/mv", ["/bin/mv", *args])
''')
                self.setup.write_text(original_source.replace("/bin/mv", shlex.quote(str(wrapper))))
                self.run_setup(succeeds=False)
                self.assertEqual((self.base / "bin/python3.12").read_bytes(), old)
                self.assertEqual((self.venv / "bin/python").read_bytes(), old)
                self.assertFalse((self.root / "runtime/ready-v2").exists())
                self.assert_weights()
        self.setup.write_text(original_source)

    def test_existing_verified_base_is_reused_but_venv_is_still_rebuilt(self):
        self.run_setup()
        self.trace.unlink()
        self.run_setup()
        self.assertNotIn("download", [item["event"] for item in self.records()])
        self.assertTrue(any(item["event"] == "python" and item["argv"][2:4] == ["-m", "venv"] for item in self.records()))

    def test_symlink_venv_and_missing_host_fail_closed_without_execution(self):
        self.seed_old(); outside = self.work / "outside"; outside.mkdir(); sentinel = outside / "untouched"; sentinel.write_text("preserve")
        shutil.rmtree(self.venv); self.venv.symlink_to(outside, target_is_directory=True)
        self.run_setup(succeeds=False)
        self.assertEqual(sentinel.read_text(), "preserve")
        self.assertEqual(self.records(), [])
        self.venv.unlink()
        self.run_setup(succeeds=False, host=self.work / "missing-native-host")
        self.assertEqual(self.records(), [])


if __name__ == "__main__":
    unittest.main()
