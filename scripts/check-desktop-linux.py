#!/usr/bin/env python3
"""Smoke the actual Linux WebView against a fresh, disposable library."""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    if not sys.platform.startswith("linux"):
        parser.error("This check requires Linux")
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        parser.error("An active graphical session is required")
    app = args.app.absolute()
    if app.is_symlink() or not app.is_file() or not os.access(app, os.X_OK):
        parser.error("--app must be a regular executable built with the custom protocol")
    with tempfile.TemporaryDirectory(prefix="after-linux-smoke-") as temporary:
        root = Path(temporary)
        library = root / "library"
        env = os.environ.copy()
        # Never select a personal library or override the bundled engine.
        env.pop("AFTER_ENGINE_PATH", None)
        env["AFTER_DATA_DIR"] = str(library)
        env["AFTER_WEBVIEW_DIAGNOSTICS"] = "1"
        with (root / "process.log").open("w+") as log:
            child = subprocess.Popen([str(app), "--check-linux-smoke"], env=env, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 30
                database = library / "core.sqlite"
                ready = False
                while not ready:
                    if child.poll() is not None or time.monotonic() >= deadline:
                        log.seek(0)
                        raise RuntimeError(f"WebView did not initialise the canonical library (exit={child.poll()}, libraryExists={library.exists()}, files={[str(p.relative_to(root)) for p in root.rglob("*")]}):\n" + log.read()[-6000:])
                    if database.is_file():
                        try:
                            with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=0.2) as connection:
                                ready = connection.execute("SELECT count(*) FROM workspace_state").fetchone() == (1,)
                                if ready:
                                    assert connection.execute("PRAGMA integrity_check").fetchone() == ("ok",)
                        except sqlite3.OperationalError:
                            pass  # The first engine call may still be committing.
                    if not ready:
                        time.sleep(0.1)
                # Root creation alone happens before the WebView exists. The
                # workspace row is created by React -> IPC -> bundled engine.
                result = {"passed": True, "platform": "linux", "app": str(app),
                          "realWebView": True, "canonicalLibraryCreated": True,
                          "personalLibraryUsed": False, "normalWindowCloseTested": False}
                if args.receipt:
                    args.receipt.parent.mkdir(parents=True, exist_ok=True)
                    args.receipt.write_text(json.dumps(result, indent=2) + "\n")
                print(json.dumps(result, indent=2))
            finally:
                if child.poll() is None:
                    child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()


if __name__ == "__main__":
    main()
