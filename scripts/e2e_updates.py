#!/usr/bin/env python3
"""Exercise the real Sparkle installer on disposable, signed localhost fixtures.

Requires a graphical macOS login and Sparkle 2.10.1's official SwiftPM artifact.
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
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from xml.sax.saxutils import escape

PROJECT = Path(__file__).resolve().parent.parent
DEFERRED_SCENARIOS = ("deferred", "nfc-deferred")
SUCCESS_SCENARIOS = ("valid", "hotfix", "renamed-app", *DEFERRED_SCENARIOS, "late-busy")
REPLAY_SCENARIOS = ("same-build", "downgrade")
SCENARIOS = (*SUCCESS_SCENARIOS, "bad-archive-signature", "tampered-archive", "bad-feed-signature",
             "truncated-archive", *REPLAY_SCENARIOS)


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


def make_components(root):
    """Real, versioned owned Mach-O code; never loaded by a production app."""
    root.mkdir()
    result = {}
    for build in (1, 2, 3):
        worker_source = root / f"worker-{build}.c"
        worker_source.write_text(f'#include <stdio.h>\nint main(void) {{ puts("FixtureWorker {build}"); return 0; }}\n')
        worker = root / f"worker-{build}"
        run(["clang", "-target", "arm64-apple-macos15.0", str(worker_source), "-o", str(worker)])
        core_source = root / f"core-{build}.c"
        core_source.write_text(f"int fixture_build(void) {{ return {build}; }}\n")
        core = root / f"core-{build}.dylib"
        run(["clang", "-target", "arm64-apple-macos15.0", "-dynamiclib", str(core_source),
             "-install_name", "@rpath/libFixtureCore.dylib", "-o", str(core)])
        result[build] = (worker, core)
    return result


def make_app(destination, binary, framework, components, *, identifier, build, scenario, feed, public):
    contents = destination / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Frameworks").mkdir()
    (contents / "Resources").mkdir()
    shutil.copy2(binary, contents / "MacOS/UpdateFixture")
    run(["ditto", "--noextattr", "--norsrc", "--noqtn", str(framework), str(contents / "Frameworks/Sparkle.framework")])
    hotfix = scenario.name == "hotfix"
    bundle_build = build + 28 if hotfix else build
    bundle_version = "0.17.6" if hotfix else f"0.0.{build}"
    info = {
        "CFBundleIdentifier": identifier, "CFBundleExecutable": "UpdateFixture",
        "CFBundleName": "UpdateFixture", "CFBundlePackageType": "APPL",
        "CFBundleVersion": str(bundle_build), "CFBundleShortVersionString": bundle_version,
        "LSMinimumSystemVersion": "15.0", "LSUIElement": True,
        "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
        "FixtureRoot": str(scenario.parent), "FixtureLog": str(scenario / "events.jsonl"), "FixtureScenario": scenario.name,
        "SUFeedURL": feed, "SUPublicEDKey": public,
        "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
        "SUAllowsAutomaticUpdates": False, "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True, "SUSignedFeedFailureExpirationInterval": 0, "SUShowReleaseNotes": False,
    }
    if hotfix and build == 2:
        info["PosleProductVersion"] = "0.17.6.1"
    if scenario.name == "renamed-app":
        info["CFBundleName"] = destination.stem
        info["CFBundleDisplayName"] = destination.stem
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=False)
    (contents / "Resources" / ("obsolete.txt" if build == 1 else "new.txt")).write_text(f"build {build}")
    worker, core = components[build]
    cli = contents / "MacOS/FixtureWorker"
    library = contents / "Frameworks/libFixtureCore.dylib"
    helper = contents / "Helpers/FixtureWorker.app"
    (helper / "Contents/MacOS").mkdir(parents=True)
    (helper / "Contents/Resources").mkdir()
    shutil.copy2(worker, cli)
    shutil.copy2(worker, helper / "Contents/MacOS/FixtureWorker")
    shutil.copy2(core, library)
    with (helper / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": identifier + ".worker", "CFBundleExecutable": "FixtureWorker",
                      "CFBundleName": "FixtureWorker", "CFBundlePackageType": "APPL",
                      "CFBundleVersion": str(bundle_build), "CFBundleShortVersionString": bundle_version,
                      "LSBackgroundOnly": True, "LSMinimumSystemVersion": "15.0"}, stream)
    (helper / "Contents/Resources" / ("obsolete-helper.txt" if build == 1 else "new-helper.txt")).write_text(f"build {build}")
    for owned in (cli, library, helper):
        run(["codesign", "--force", "--sign", "-", str(owned)])
    run(["codesign", "--force", "--sign", "-", str(destination)])
    run(["codesign", "--verify", "--deep", "--strict", str(destination)])


def verify_renamed_install(installed, identifier, observed):
    """The new name must replace the old host, not create another installation."""
    with (installed / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    assert info["CFBundleIdentifier"] == identifier, "Renaming changed the fixture identity"
    assert info["CFBundleName"] == info["CFBundleDisplayName"] == "After", "The installed host kept its old display name"
    assert {path.name for path in installed.parent.iterdir() if path.suffix == ".app"} == {installed.name}, "Renaming left a second installed app"
    starts = [event for event in observed if event["event"] == "started" and event["build"] == "2"]
    assert len(starts) == 1 and Path(starts[0]["bundle"]).resolve() == installed.resolve(), "The renamed candidate did not relaunch from the original host path"


def exercise(root, web, framework, binary, components, sign_update, private, public, port, name, requests):
    started = time.monotonic()
    scenario = root / name
    scenario.mkdir()
    # APFS preserves these NFC filename bytes, unlike Foundation's potentially
    # decomposed NSRunningApplication path. This exercises Sparkle #2943.
    installed_parent = scenario / "installed"
    if name == "nfc-deferred":
        installed_parent = installed_parent / "Caf\u00e9"
        assert os.fsencode(installed_parent.name) == b"Caf\xc3\xa9"
    # Sparkle identifies the candidate by bundle ID. Without normalization it
    # replaces the original host path even when the archive has a new app name.
    old = installed_parent / ("После.app" if name == "renamed-app" else "UpdateFixture.app")
    new = scenario / "source" / ("After.app" if name == "renamed-app" else "UpdateFixture.app")
    identifier = "app.posle.updaterfixture." + uuid.uuid4().hex
    (scenario / "identifier.txt").write_text(identifier)
    target = web / name
    target.mkdir()
    feed_url = f"http://127.0.0.1:{port}/{name}/feed.xml"
    installed_build = 3 if name == "downgrade" else 1
    candidate_build = 1 if name == "same-build" else 2
    candidate_bundle_build = candidate_build + 28 if name == "hotfix" else candidate_build
    candidate_display_version = "0.17.6.1" if name == "hotfix" else f"0.0.{candidate_build}"
    for build, destination in ((installed_build, old), (candidate_build, new)):
        make_app(destination, binary, framework, components, identifier=identifier, build=build,
                 scenario=scenario, feed=feed_url, public=public)
    if name == "nfc-deferred":
        assert "Caf\u00e9" in os.listdir(scenario / "installed"), "The on-disk fixture folder must preserve NFC encoding"
    library = scenario / "library.json"
    library.write_text('{"notes":["fixture note"],"models":["fixture model"]}')
    library_digest = hashlib.sha256(library.read_bytes()).digest()
    before = files(old)
    candidate_files = files(new)
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
<pubDate>{date}</pubDate><sparkle:version>{candidate_bundle_build}</sparkle:version>
<sparkle:shortVersionString>{candidate_display_version}</sparkle:shortVersionString>
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
                failure_event = "not-found" if name in REPLAY_SCENARIOS else "error"
                if name not in SUCCESS_SCENARIOS and any(e["event"] == failure_event for e in observed) and process.poll() is not None:
                    time.sleep(0.5)
                    break
                unexpected = ("timeout", "configuration-error") if name in REPLAY_SCENARIOS else ("timeout", "configuration-error", "not-found")
                if any(e["event"] in unexpected for e in observed):
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
            assert actual_version == str(candidate_bundle_build), "Sparkle did not replace the installed build"
            assert any(e["event"] == "ready" for e in observed), "Installer was never ready"
            assert any(e["event"] == "relaunched" and e["build"] == str(candidate_bundle_build) for e in observed), "The candidate build was not actually relaunched"
            if name == "hotfix":
                with (old / "Contents/Info.plist").open("rb") as stream:
                    installed_info = plistlib.load(stream)
                assert installed_info["CFBundleShortVersionString"] == "0.17.6"
                assert installed_info["PosleProductVersion"] == "0.17.6.1"
                assert any(e["event"] == "started" and e["build"] == "29" for e in observed)
                assert any(e["event"] == "found" and e["version"] == "30" and e["displayVersion"] == "0.17.6.1" for e in observed), "Sparkle must present the public hotfix label"
            assert not (old / "Contents/Resources/obsolete.txt").exists(), "Obsolete bundled files survived replacement"
            assert (old / "Contents/Resources/new.txt").read_text() == "build 2"
            # Verify the complete candidate, not just the outer app's Info.plist.
            # A stale nested helper, CLI, core, signature or removed resource must
            # fail even when the outer version and successful relaunch look right.
            assert files(old) == candidate_files, "Installed bundle differs from the complete signed candidate"
            helper = old / "Contents/Helpers/FixtureWorker.app"
            with (helper / "Contents/Info.plist").open("rb") as stream:
                assert plistlib.load(stream)["CFBundleVersion"] == str(candidate_bundle_build), "A stale helper survived the update"
            for worker in (old / "Contents/MacOS/FixtureWorker", helper / "Contents/MacOS/FixtureWorker"):
                assert run([str(worker), "--version"]) == "FixtureWorker 2", "A stale worker executable survived the update"
            assert not (helper / "Contents/Resources/obsolete-helper.txt").exists(), "Obsolete nested helper files survived replacement"
            run(["codesign", "--verify", "--deep", "--strict", str(old)])
            if name == "renamed-app":
                verify_renamed_install(old, identifier, observed)
            if name in DEFERRED_SCENARIOS:
                assert len([e for e in observed if e["event"] == "deferred"]) == 1
                held = [e for e in observed if e["event"] == "deferred-held"]
                assert len(held) == 1 and held[0]["buildOnDisk"] == "1", "Postponement did not preserve the old installed bundle"
            if name in ("late-busy", "nfc-deferred"):
                sequence = [e["event"] for e in observed]
                assert sequence.count("termination-blocked") == 1 and sequence.count("termination-retried") == 1
                assert sequence.index("termination-blocked") < sequence.index("termination-retried") < sequence.index("terminate"), "Late-busy termination was not safely retried"
            if name == "nfc-deferred":
                sequence = [e["event"] for e in observed]
                checkpoints = ("deferred", "deferred-held", "installation-resumed", "termination-blocked",
                               "termination-held", "termination-retried", "terminate", "relaunched")
                positions = [sequence.index(event) for event in checkpoints]
                assert positions == sorted(positions), "The NFC path bypassed deferred installation or termination waiting"
                held = [e for e in observed if e["event"] in ("deferred-held", "termination-held")]
                assert len(held) == 2 and all(e["build"] == "1" and e["buildOnDisk"] == "1"
                                            and e["obsoleteExists"] and not e["newExists"] for e in held), "The NFC bundle changed while its old host was still running"
                old_pid = next(e["pid"] for e in observed if e["event"] == "started" and e["build"] == "1")
                assert all(e["pid"] == old_pid for e in held), "The held NFC checkpoints must be emitted by the original running host"
                relaunched = next(e for e in observed if e["event"] == "relaunched")
                assert relaunched["pid"] != old_pid, "The new build must relaunch in a new process"
        else:
            assert actual_version == str(installed_build) and files(old) == before, "Rejected update modified the installed fixture"
            assert not any(e["event"] in ("ready", "installing", "installed", "relaunched") for e in observed), "Invalid update reached installation"
            errors = [entry for e in observed for entry in e.get("errors", [])]
            requested_zip = any(path.startswith(f"/{name}/update.zip") for path in requests)
            if name in REPLAY_SCENARIOS:
                assert any(e["event"] == "not-found" for e in observed), "A signed non-newer release was not rejected"
                assert any(e["domain"] == "SUSparkleErrorDomain" and e["code"] == 1001 for e in errors), "Expected Sparkle no-update result"
                assert not requested_zip, "A non-newer signed release must be rejected before archive download"
                assert not any(e["event"] in ("found", "downloading", "extracting") for e in observed), "A replayed release entered the update pipeline"
            elif name == "truncated-archive":
                assert requested_zip, "The interrupted download scenario never requested its archive"
                assert any(e["domain"] == "SUSparkleErrorDomain" and e["code"] == 2001 for e in errors), "The interrupted response must fail as a Sparkle download error"
                assert not any(e["event"] == "extracting" for e in observed), "An incomplete download reached extraction"
            else:
                assert any(e["domain"] == "SUSparkleErrorDomain" and e["code"] in (1000, 1002, 3001, 3002, 4005)
                           for e in errors), "No Sparkle validation error was observed"
                assert any("sign" in e["description"].lower() for e in errors), "Failure was not signature validation"
                assert requested_zip == (name != "bad-feed-signature"), "Signed-feed rejection happened at the wrong phase"
        assert hashlib.sha256(library.read_bytes()).digest() == library_digest, "External library was modified"
        return {"scenario": name, "passed": True, "installedBuild": actual_version, "installedBundleName": old.name,
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
        if plistlib.load(stream).get("CFBundleShortVersionString") != "2.10.1":
            parser.error("Use the pinned official Sparkle 2.10.1 artifact")
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
        components = make_components(root / "components")
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
                if self.path == "/truncated-archive/update.zip":
                    # Advertise the complete signed archive, then interrupt its
                    # transport halfway through; do not substitute a new ZIP or
                    # change its feed signature. NSURLSession must reject this
                    # response before extraction or installation can begin.
                    archive = web / "truncated-archive/update.zip"
                    size = archive.stat().st_size
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(size))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    with archive.open("rb") as stream:
                        self.wfile.write(stream.read(size // 2))
                    self.wfile.flush()
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_WR)
                    return
                super().do_GET()
            def end_headers(self):
                self.send_header("Cache-Control", "no-store")
                super().end_headers()
        handler = functools.partial(Handler, directory=str(web))
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        results = []
        for name in SCENARIOS:
            result = exercise(root, web, framework, binary, components, sign_update, private, public,
                              server.server_address[1], name, requests)
            results.append(result)
            print("PASS:", name, f"({result['seconds']}s)", flush=True)
        receipt = {"framework": "2.10.1", "fixtureRoot": str(root), "results": results,
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
