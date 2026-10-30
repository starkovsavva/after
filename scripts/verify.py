#!/usr/bin/env python3
"""One entry point for isolated checks. No publishing or production accounts."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
PROFILES = {
    "quick": "Swift build/core tests, Python contracts and Rust unit tests",
    "integration": "Rust CLI/FFI/HTTP, generated media, search and runtime migration",
    "native": "Sequential SwiftUI/NSApplication scenarios in disposable libraries",
    "release": "All profiles plus the real Sparkle SDK on signed disposable fixtures",
}
NATIVE = (
    "folders", "localization", "folder-jobs", "meeting-rename", "responsiveness", "contexts", "feature-ui", "pipeline", "chatgpt-auth", "chatgpt-ui", "recording", "recording-start", "recording-sessions", "corrections", "tasks", "task-workspace", "integrations", "trash", "themes", "typography", "guidance", "voice", "bug-report", "copy-transcript", "updates",
    "release-notes", "calendar", "calendar-workspace", "notes", "overview", "jobs", "navigation", "cards", "queue", "source-playback", "source-popover",
)


class Verification:
    def __init__(self, args):
        self.args = args
        self.swift = args.swift_build_dir.resolve()
        self.rust = args.rust_target_dir.resolve()
        self.python = str(args.python.absolute())
        if not args.python.is_file():
            raise RuntimeError("Test Python not found. Set POSLE_PYTHON or --python to an existing isolated test environment.")
        self.env = os.environ.copy()
        # Every scenario below supplies its own data root. Never inherit a real
        # library override or accidental provider credentials from the shell.
        for key in list(self.env):
            if any(word in key.upper() for word in ("API_KEY", "ACCESS_TOKEN", "SECRET", "PASSWORD", "CREDENTIAL")):
                self.env.pop(key, None)
        for key in ("POSLE_DATA_DIR", "POSLE_JOB_SETTINGS", "POSLE_RUST_LIBRARY", "POSLE_RUST_ENGINE", "POSLE_UNVERIFIED_PYTHON_RUNTIME_FOR_TESTS"):
            self.env.pop(key, None)
        for key in ("PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP"):
            self.env.pop(key, None)
        self.cargo = self.find_cargo()
        self.built_swift = False
        self.built_rust = False

    def find_cargo(self):
        if self.env.get("POSLE_CARGO_HOME"):
            self.env["CARGO_HOME"] = self.env["POSLE_CARGO_HOME"]
            self.env["RUSTUP_HOME"] = self.env.get("POSLE_RUSTUP_HOME", str(PROJECT / ".toolchain/rustup"))
            return str(Path(self.env["CARGO_HOME"]) / "bin/cargo")
        if shutil.which("cargo"):
            return shutil.which("cargo")
        private = PROJECT / ".toolchain/cargo/bin/cargo"
        if private.is_file():
            self.env["CARGO_HOME"] = str(PROJECT / ".toolchain/cargo")
            self.env["RUSTUP_HOME"] = self.env.get("POSLE_RUSTUP_HOME", str(PROJECT / ".toolchain/rustup"))
            return str(private)
        raise RuntimeError("Cargo not found. Run bash scripts/setup-rust.sh first.")

    def run(self, label, command, *, env=None, timeout=1200):
        print(f"\n→ {label}", flush=True)
        subprocess.run(list(map(str, command)), cwd=PROJECT, env=env or self.env, check=True, timeout=timeout)

    def cargo_command(self, action):
        return [self.cargo, action, "--manifest-path", PROJECT / "rust-core/Cargo.toml", "--locked", "--target-dir", self.rust]

    def swift_command(self, action):
        return ["swift", action, "--scratch-path", self.swift, "--disable-automatic-resolution"]

    def build_swift(self):
        if not self.built_swift:
            self.run("Swift application build", self.swift_command("build"))
            self.built_swift = True

    def build_rust(self):
        if not self.built_rust:
            # cargo test does not rebuild the top-level CLI/CDylib artifacts.
            self.run("Rust debug CLI and C ABI", self.cargo_command("build"))
            self.built_rust = True

    def quick(self):
        self.build_swift()
        self.core_tests()
        self.run("Python backend contracts", [self.python, "-m", "unittest", "discover", "-s", "backend", "-v"])
        self.run("Release tooling contracts", [self.python, "-m", "unittest", "discover", "-s", "scripts", "-p", "test_*.py", "-v"])
        self.run("Rust domain contracts", self.cargo_command("test"))

    def core_tests(self):
        probe = subprocess.run(["xcrun", "--find", "xctest"], capture_output=True, check=False)
        if probe.returncode == 0:
            self.run("SwiftPM core contracts", self.swift_command("test"))
            return
        # Command Line Tools can build the application but does not ship XCTest.
        # Compile the same contracts, rather than silently skipping core tests.
        with tempfile.TemporaryDirectory(prefix="posle-core-check-", dir="/private/tmp") as temporary:
            root = Path(temporary)
            sources = sorted((PROJECT / "Sources/PosleCore").glob("*.swift"))
            for name in ("CoreChecks", "CalendarLayoutChecks", "TaskDueDateChecks"):
                output = root / name
                self.run("Standalone " + name, ["swiftc", "-module-cache-path", root / "module-cache",
                    "-parse-as-library", *sources, PROJECT / "Tests" / (name + ".swift"), "-o", output])
                self.run(name, [output])

    @property
    def engine(self):
        return self.rust / "debug/posle-engine"

    @property
    def library(self):
        return self.rust / "debug/libposle_core.dylib"

    def integration(self):
        self.build_rust()
        self.run("CLI, C ABI and localhost HTTP", [self.python, "scripts/e2e.py", "--engine", self.engine, "--library", self.library])
        self.run("MCP task lifecycle over stdio", [self.python, "scripts/check_mcp.py", "--engine", self.engine, "--library", self.library])
        self.run("Recording through native worker", [self.python, "scripts/e2e_media.py", "--python", self.python, "--engine", self.engine],
                 env=self.env | {"POSLE_UNVERIFIED_PYTHON_RUNTIME_FOR_TESTS": "1"})
        self.run("Long, delayed and idle recording tracks", [self.python, "scripts/check_media.py"],
                 env=self.env | {"PYTHONPATH": str(PROJECT / "backend")})
        self.run("Imported listening quality and source timeline", [self.python, "scripts/check_import_playback.py"])
        self.run("Search corpus and index rebuild", [self.python, "scripts/check_search.py", "--library", self.library])
        self.run("Owned model runtime migration", [self.python, "scripts/check_managed_identity.py"])
        self.run("Native library integrity before constructors", [self.python, "scripts/check_native_integrity.py"])

    def native(self):
        self.build_swift()
        self.build_rust()
        binary = self.swift / "debug/Posle"
        for scenario in NATIVE:
            with tempfile.TemporaryDirectory(prefix="posle-native-check-", dir="/private/tmp") as fixture:
                if scenario not in ("folders", "folder-jobs", "meeting-rename", "responsiveness", "contexts", "feature-ui", "recording"):
                    # Existing scenarios exercise optional workflows deliberately.
                    Path(fixture, "settings.json").write_text(json.dumps({"features": {key: True for key in ("cards", "tasks", "calendar", "assistant", "semanticSearch")}}))
                env = self.env | {"POSLE_DATA_DIR": fixture, "POSLE_RUST_ENGINE": str(self.engine), "POSLE_RUST_LIBRARY": str(self.library),
                                  "POSLE_UNVERIFIED_PYTHON_RUNTIME_FOR_TESTS": "1"}
                self.run(f"Native {scenario}", [binary, "--preview", "--check-" + scenario], env=env, timeout=240)
                if scenario == "recording-sessions":
                    self.run("Native capture writer through real finalize", [self.python, "scripts/e2e_media.py",
                        "--python", self.python, "--engine", self.engine, "--native-capture",
                        Path(fixture) / "capture-writer/static"], env=self.env | {"POSLE_UNVERIFIED_PYTHON_RUNTIME_FOR_TESTS": "1"}, timeout=240)
        with tempfile.TemporaryDirectory(prefix="posle-ui-check-", dir="/private/tmp") as fixture:
            self.run("Synthetic UI fixture", [self.python, "scripts/preview.py", fixture])
            env = self.env | {"POSLE_DATA_DIR": fixture, "POSLE_RUST_ENGINE": str(self.engine), "POSLE_RUST_LIBRARY": str(self.library),
                                  "POSLE_UNVERIFIED_PYTHON_RUNTIME_FOR_TESTS": "1"}
            self.run("UI geometry and interactions", [binary, "--preview", "--check-ui-consistency"], env=env, timeout=300)

    def release(self):
        self.quick()
        self.integration()
        self.native()
        sparkle = self.args.sparkle_root or self.swift / "artifacts/sparkle/Sparkle"
        self.run("Real Sparkle installer, isolated signed fixtures", [self.python, "scripts/e2e_updates.py", "--sparkle-root", sparkle], timeout=1200)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=PROFILES, nargs="?", default="quick")
    parser.add_argument("--list", action="store_true", help="Describe profiles without running or initializing tools")
    parser.add_argument("--python", type=Path, default=Path(os.environ.get("POSLE_PYTHON", sys.executable)))
    parser.add_argument("--swift-build-dir", type=Path, default=Path(os.environ.get("POSLE_BUILD_DIR", PROJECT / ".build")))
    parser.add_argument("--rust-target-dir", type=Path, default=Path(os.environ.get("POSLE_RUST_TARGET_DIR", PROJECT / ".build/rust")))
    parser.add_argument("--sparkle-root", type=Path)
    args = parser.parse_args()
    if args.list:
        for name, description in PROFILES.items():
            print(f"{name}: {description}")
        return
    verification = Verification(args)
    getattr(verification, args.profile)()
    print(f"\nPASS: {args.profile}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"Verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
