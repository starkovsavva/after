#!/usr/bin/env python3
"""Exercise the real Sparkle installer on disposable, signed localhost fixtures.

Requires a graphical macOS login and Sparkle 2.10's official SwiftPM artifact.
No production application, feed, signing key, or recordings are accessed.
"""
from __future__ import annotations

import argparse
import base64
import datetime
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from xml.sax.saxutils import escape

PROJECT = Path(__file__).resolve().parent.parent
SUCCESS_SCENARIOS = ("valid", "deferred", "late-busy")
SCENARIOS = (*SUCCESS_SCENARIOS, "bad-archive-signature", "tampered-archive", "bad-feed-signature")


def run(command, *, env=None):
    result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=120)
    if result.returncode:
        raise RuntimeError(f"{Path(str(command[0])).name} failed ({result.returncode}):\n"
                           + result.stderr[-6000:] + result.stdout[-2000:])
    return result.stdout.strip()


def files(root):
    result = {}
    for item in root.rglob("*"):
        name = str(item.relative_to(root))
        if item.is_symlink():
            result[name] = ["link", os.readlink(item)]
        elif item.is_file():
            result[name] = ["file", hashlib.sha256(item.read_bytes()).hexdigest(), item.stat().st_mode & 0o777]
    return result


def events(path):
    if not path.exists():
        return []
    result = []
    for line in path.read_text().splitlines():
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass  # Another process may still be appending the final line.
    return result


def terminate_fixture(root, process=None):
    """Only stop test processes whose executable command names this unique root."""
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
    for line in run(["ps", "-axo", "pid=,command="]).splitlines():
        split = line.strip().split(maxsplit=1)
        if len(split) != 2 or str(root) not in split[1]:
            continue
        pid = int(split[0])
        if pid != os.getpid():
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass


def clean_fixture_preferences(identifier):
    # Sparkle's XPC installer can use the actual login user's caches even when
    # the fixture process has CFFIXED_USER_HOME set. Remove only this run's
    # freshly generated, exact UUID namespace; never use a wildcard here.
    if not re.fullmatch(r"app\.posle\.updaterfixture\.[0-9a-f]{32}", identifier):
        raise AssertionError("Refusing to clean a non-fixture preferences domain")
    subprocess.run(["defaults", "delete", identifier], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=10, check=False)
    login_home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    # defaults may leave a zero-entry plist after deleting the domain.
    (login_home / "Library/Preferences" / (identifier + ".plist")).unlink(missing_ok=True)
    cache = login_home / "Library/Caches" / identifier
    if cache.is_symlink():
        cache.unlink()
    elif cache.exists():
        shutil.rmtree(cache)
    if cache.exists() or (login_home / "Library/Preferences" / (identifier + ".plist")).exists():
        raise AssertionError("Fixture preferences cleanup did not finish")


def make_app(destination, binary, framework, *, identifier, build, scenario, feed, public):
    contents = destination / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Frameworks").mkdir()
    (contents / "Resources").mkdir()
    shutil.copy2(binary, contents / "MacOS/UpdateFixture")
    run(["ditto", "--noextattr", "--norsrc", "--noqtn", str(framework), str(contents / "Frameworks/Sparkle.framework")])
    info = {
        "CFBundleIdentifier": identifier, "CFBundleExecutable": "UpdateFixture",
        "CFBundleName": "UpdateFixture", "CFBundlePackageType": "APPL",
        "CFBundleVersion": str(build), "CFBundleShortVersionString": f"0.0.{build}",
        "LSMinimumSystemVersion": "15.0", "LSUIElement": True,
        "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
        "FixtureRoot": str(scenario.parent), "FixtureLog": str(scenario / "events.jsonl"), "FixtureScenario": scenario.name,
        "SUFeedURL": feed, "SUPublicEDKey": public,
        "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
        "SUAllowsAutomaticUpdates": False, "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True, "SUSignedFeedFailureExpirationInterval": 0, "SUShowReleaseNotes": False,
    }
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=False)
    (contents / "Resources" / ("obsolete.txt" if build == 1 else "new.txt")).write_text(f"build {build}")
    run(["codesign", "--force", "--sign", "-", str(destination)])
    run(["codesign", "--verify", "--deep", "--strict", str(destination)])


def exercise(root, web, framework, binary, sign_update, private, public, port, name, requests):
    started = time.monotonic()
    scenario = root / name
    scenario.mkdir()
    old = scenario / "installed/UpdateFixture.app"
    new = scenario / "source/UpdateFixture.app"
    identifier = "app.posle.updaterfixture." + uuid.uuid4().hex
    (scenario / "identifier.txt").write_text(identifier)
    target = web / name
    target.mkdir()
    feed_url = f"http://127.0.0.1:{port}/{name}/feed.xml"
    for build, destination in ((1, old), (2, new)):
        make_app(destination, binary, framework, identifier=identifier, build=build,
                 scenario=scenario, feed=feed_url, public=public)
    library = scenario / "library.json"
    library.write_text('{"notes":["fixture note"],"models":["fixture model"]}')
    library_digest = hashlib.sha256(library.read_bytes()).digest()
    before = files(old)
    archive = target / "update.zip"
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(new), str(archive)])
    signature = run([str(sign_update), "--ed-key-file", str(private), "-p", str(archive)])
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise AssertionError("The fixture archive signature is invalid")
    if name == "bad-archive-signature":
        raw = bytearray(base64.b64decode(signature)); raw[0] ^= 1
        signature = base64.b64encode(raw).decode()
    if name == "tampered-archive":
        raw = bytearray(archive.read_bytes()); raw[len(raw) // 2] ^= 1
        archive.write_bytes(raw)
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S %z")
    feed = target / "feed.xml"
    feed.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Fixture updates</title><item><title>Fixture update</title>
<pubDate>{date}</pubDate><sparkle:version>2</sparkle:version>
<sparkle:shortVersionString>0.0.2</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>15.0.0</sparkle:minimumSystemVersion>
<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<enclosure url="http://127.0.0.1:{port}/{escape(name)}/update.zip"
 sparkle:edSignature="{signature}" length="{archive.stat().st_size}" type="application/octet-stream"/>
</item></channel></rss>
''')
    run([str(sign_update), "--ed-key-file", str(private), str(feed)])
    if name == "bad-feed-signature":
        text = feed.read_text()
        assert "<title>Fixture update</title>" in text
        feed.write_text(text.replace("<title>Fixture update</title>", "<title>Altered update</title>"))
    home = root / "home"
    home.mkdir(exist_ok=True)
    (root / "tmp").mkdir(exist_ok=True)
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith("DYLD_") and not any(word in k.upper() for word in ("KEY", "TOKEN", "SECRET", "PASSWORD", "COOKIE", "CREDENTIAL"))}
    environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(root / "tmp") + "/")
    log_path = scenario / "events.jsonl"
    process = None
    try:
        with (scenario / "process.log").open("w") as output:
            process = subprocess.Popen([str(old / "Contents/MacOS/UpdateFixture")], env=environment,
                                       stdout=output, stderr=output, start_new_session=True)
            deadline = time.monotonic() + 65
            observed = []
            while time.monotonic() < deadline:
                observed = events(log_path)
                if name in SUCCESS_SCENARIOS and any(e["event"] == "relaunched" for e in observed):
                    break
                if name not in SUCCESS_SCENARIOS and any(e["event"] == "error" for e in observed) and process.poll() is not None:
                    time.sleep(0.5)
                    break
                if any(e["event"] in ("timeout", "configuration-error", "not-found") for e in observed):
                    raise AssertionError("Unexpected fixture result: " + json.dumps(observed[-5:]))
                if process.poll() is not None and not observed:
                    raise AssertionError(f"Fixture exited without initializing (exit {process.returncode})")
                time.sleep(0.1)
            else:
                raise AssertionError("Timed out waiting for the real Sparkle installer: " + json.dumps(observed[-10:]))
        observed = events(log_path)
        with (old / "Contents/Info.plist").open("rb") as stream:
            actual_version = plistlib.load(stream)["CFBundleVersion"]
        if name in SUCCESS_SCENARIOS:
            assert actual_version == "2", "Sparkle did not replace build 1"
            assert any(e["event"] == "ready" for e in observed), "Installer was never ready"
            assert any(e["event"] == "relaunched" and e["build"] == "2" for e in observed), "Build 2 was not actually relaunched"
            assert not (old / "Contents/Resources/obsolete.txt").exists(), "Obsolete bundled files survived replacement"
            assert (old / "Contents/Resources/new.txt").read_text() == "build 2"
            run(["codesign", "--verify", "--deep", "--strict", str(old)])
            if name == "deferred":
                assert len([e for e in observed if e["event"] == "deferred"]) == 1
                held = [e for e in observed if e["event"] == "deferred-held"]
                assert len(held) == 1 and held[0]["buildOnDisk"] == "1", "Postponement did not preserve the old installed bundle"
            if name == "late-busy":
                sequence = [e["event"] for e in observed]
                assert sequence.count("termination-blocked") == 1 and sequence.count("termination-retried") == 1
                assert sequence.index("termination-blocked") < sequence.index("termination-retried") < sequence.index("terminate"), "Late-busy termination was not safely retried"
        else:
            assert actual_version == "1" and files(old) == before, "Rejected update modified the installed fixture"
            assert not any(e["event"] in ("ready", "relaunched") for e in observed), "Invalid update reached installation"
            errors = [entry for e in observed for entry in e.get("errors", [])]
            assert any(e["domain"] == "SUSparkleErrorDomain" and e["code"] in (1000, 1002, 3001, 3002, 4005)
                       for e in errors), "No Sparkle validation error was observed"
            assert any("sign" in e["description"].lower() for e in errors), "Failure was not signature validation"
            requested_zip = any(path.startswith(f"/{name}/update.zip") for path in requests)
            assert requested_zip == (name != "bad-feed-signature"), "Signed-feed rejection happened at the wrong phase"
        assert hashlib.sha256(library.read_bytes()).digest() == library_digest, "External library was modified"
        return {"scenario": name, "passed": True, "installedBuild": actual_version,
                "relaunched": any(e["event"] == "relaunched" for e in observed),
                "seconds": round(time.monotonic() - started, 2)}
    finally:
        terminate_fixture(root, process)
        clean_fixture_preferences(identifier)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sparkle-root", type=Path, required=True,
                        help="Official SwiftPM artifact directory containing Sparkle.xcframework and bin/")
    parser.add_argument("--keep", action="store_true", help="Keep fixture apps/logs/receipt; ephemeral private key is always deleted")
    options = parser.parse_args()
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        parser.error("This fixture currently requires an Apple Silicon Mac")
    sdk = options.sparkle_root.resolve()
    framework = sdk / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    sign_update = sdk / "bin/sign_update"
    with (framework / "Resources/Info.plist").open("rb") as stream:
        if plistlib.load(stream).get("CFBundleShortVersionString") != "2.10.0":
            parser.error("Use the pinned official Sparkle 2.10.0 artifact")
    run(["codesign", "--verify", "--deep", "--strict", str(framework)])
    root = Path(tempfile.mkdtemp(prefix="posle-updater-e2e-", dir="/private/tmp")).resolve()
    private = root / "ephemeral-private.key"
    succeeded = False
    server = None
    try:
        binary = root / "UpdateFixture"
        run(["swiftc", "-parse-as-library", "-swift-version", "5", "-target", "arm64-apple-macosx15.0",
             "-F", str(framework.parent), "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker",
             "@executable_path/../Frameworks",
             str(PROJECT / "Tests/UpdateFixture.swift"), "-o", str(binary)])
        public_file = root / "ephemeral-public.txt"
        run([str(binary), "--generate-key", str(private), str(public_file)],
            env={**os.environ, "DYLD_FRAMEWORK_PATH": str(framework.parent)})
        public = public_file.read_text()
        web = root / "web"; web.mkdir()
        requests = []
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *_args):
                pass
            def do_GET(self):
                requests.append(self.path)
                super().do_GET()
            def end_headers(self):
                self.send_header("Cache-Control", "no-store")
                super().end_headers()
        handler = functools.partial(Handler, directory=str(web))
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        results = []
        for name in SCENARIOS:
            result = exercise(root, web, framework, binary, sign_update, private, public,
                              server.server_address[1], name, requests)
            results.append(result)
            print("PASS:", name, f"({result['seconds']}s)", flush=True)
        receipt = {"framework": "2.10.0", "fixtureRoot": str(root), "results": results,
                   "requests": requests, "productionResourcesUsed": False}
        (root / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(f"{len(SCENARIOS)} real Sparkle E2E scenarios passed")
        if options.keep:
            print("Fixture receipt:", root / "receipt.json")
        succeeded = True
    except Exception:
        print("Fixture diagnostics retained at", root, file=sys.stderr)
        for log in root.glob("*/process.log"):
            print(log.parent.name + ":\n" + log.read_text()[-6000:], file=sys.stderr)
        raise
    finally:
        if server:
            server.shutdown(); server.server_close()
        terminate_fixture(root)
        private.unlink(missing_ok=True)
        if succeeded and not options.keep:
            shutil.rmtree(root)


if __name__ == "__main__":
    main()
