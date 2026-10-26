#!/usr/bin/env python3
"""Verify an immutable GitHub release, then atomically advance its signed feed.

No private keys are read by this module's verification or feed-promotion path.
The update branch contains only appcast.xml and never changes source main/HEAD.
"""
from __future__ import annotations

import argparse
import base64
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
from urllib.parse import quote, urljoin, urlsplit
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

PROJECT = Path(__file__).resolve().parent.parent
ACCOUNT = "app.posle.meetings.updates"
BRANCH = "updates"
APP = "После.app"
ZIP = "Posle-Mac-AppleSilicon.zip"
PKG = "Posle-Mac-AppleSilicon.pkg"
SOURCE = "Posle-Source.zip"
FEED = "appcast.xml"
CHECKSUMMED = (PKG, ZIP, SOURCE, FEED)
ASSETS = (*CHECKSUMMED, "SHA256SUMS")
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
POSLE = "https://posle.app/xml-namespaces/release"
MAX_FEED = 2 * 1024 * 1024
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("posle", POSLE)


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate_repo(repo: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise RuntimeError("Expected a GitHub owner/repository")
    return repo


def feed_url(repo: str) -> str:
    return f"https://raw.githubusercontent.com/{validate_repo(repo)}/{BRANCH}/{FEED}"


def asset_url(repo: str, tag: str, name: str) -> str:
    return f"https://github.com/{validate_repo(repo)}/releases/download/{quote(tag, safe='')}/{quote(name, safe='')}"


def decode64(value: str, size: int, label: str) -> bytes:
    try:
        result = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as error:
        raise RuntimeError(f"Invalid {label}") from error
    if len(result) != size:
        raise RuntimeError(f"Invalid {label} length")
    return result


@dataclass(frozen=True)
class Identity:
    version: str
    build: int
    revision: str
    public_key: str
    minimum_os: str = "15.0"

    @property
    def tag(self) -> str:
        return "v" + self.version


def identity(info: dict, repo: str, revision: str | None = None) -> Identity:
    version, build = str(info.get("CFBundleShortVersionString", "")), str(info.get("CFBundleVersion", ""))
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise RuntimeError("Release requires a numeric version and strictly positive integer build number")
    if info.get("CFBundleIdentifier") != "app.posle.meetings":
        raise RuntimeError("Unexpected app bundle identifier")
    if info.get("SUFeedURL") != feed_url(repo):
        raise RuntimeError("The app update feed must use this repository's updates branch")
    if info.get("SURequireSignedFeed") is not True or info.get("SUVerifyUpdateBeforeExtraction") is not True or info.get("SUSignedFeedFailureExpirationInterval") != 0:
        raise RuntimeError("Signed feeds, verification before extraction, and zero signature-failure expiration are required")
    public_key = info.get("SUPublicEDKey", "")
    decode64(public_key, 32, "update public key")
    source_revision = info.get("PosleSourceRevision", "")
    if not re.fullmatch(r"[0-9a-f]{40}", source_revision) or revision is not None and source_revision != revision:
        raise RuntimeError("The signed app does not match the release source revision; rebuild it")
    minimum_os = str(info.get("LSMinimumSystemVersion", ""))
    if minimum_os != "15.0":
        raise RuntimeError("Unexpected app minimum macOS version")
    return Identity(version, int(build), source_revision, public_key, minimum_os)


def read_identity(app: Path, repo: str, revision: str | None = None) -> Identity:
    with (app / "Contents/Info.plist").open("rb") as stream:
        return identity(plistlib.load(stream), repo, revision)


def make_appcast(release: Identity, repo: str, signature: str, files: dict[str, Path], notes: str) -> bytes:
    decode64(signature, 64, "archive signature")
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "После"
    ET.SubElement(channel, "link").text = f"https://github.com/{repo}/releases"
    ET.SubElement(channel, "description").text = "Обновления После для macOS"
    ET.SubElement(channel, "language").text = "ru"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "После " + release.version
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = str(release.build)
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = release.version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = release.minimum_os
    ET.SubElement(item, f"{{{SPARKLE}}}hardwareRequirements").text = "arm64"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc), usegmt=True)
    # Sparkle 2.10 renders this Markdown natively; its exact text is signed.
    ET.SubElement(item, "description", {f"{{{SPARKLE}}}format": "markdown"}).text = notes
    ET.SubElement(item, f"{{{POSLE}}}sourceRevision").text = release.revision
    for name, field in ((ZIP, "archiveSHA256"), (SOURCE, "sourceSHA256"), (PKG, "packageSHA256")):
        ET.SubElement(item, f"{{{POSLE}}}{field}").text = digest(files[name])
    ET.SubElement(item, "enclosure", {
        "url": asset_url(repo, release.tag, ZIP),
        f"{{{SPARKLE}}}edSignature": signature,
        "length": str(files[ZIP].stat().st_size), "type": "application/octet-stream",
    })
    ET.indent(rss)
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n"


def feed_signature(data: bytes) -> tuple[bytes, str]:
    # Sparkle 2.10.0 common_cli/Signing.swift appends this block to the exact bytes
    # it signs. Never parse/re-serialize signed XML before verification.
    if len(data) > MAX_FEED:
        raise RuntimeError("Update feed is too large")
    marker = b"<!-- sparkle-signatures:\n"
    offset = data.rfind(marker)
    match = re.fullmatch(rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]+={0,2})\nlength: ([0-9]+)\n-->\n?", data[offset:]) if offset >= 0 else None
    if match is None or int(match[2]) != offset or marker in data[:offset]:
        raise RuntimeError("Missing or invalid Sparkle signed-feed block")
    signature = match[1].decode("ascii")
    decode64(signature, 64, "feed signature")
    return data[:offset], signature


_SWIFT_VERIFY = r'''
import Foundation
import CryptoKit
let args = CommandLine.arguments
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
guard let signature = Data(base64Encoded: args[2]), let key = Data(base64Encoded: args[3]),
      let length = Int(args[4]), length >= 0, length <= data.count else { exit(2) }
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
guard publicKey.isValidSignature(signature, for: data.prefix(length)) else { exit(1) }
'''


class PublicVerifier:
    """Independent CryptoKit verification; never accesses the private Keychain."""
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="posle-update-verify-")
        root = Path(self.temporary.name)
        source = root / "Verify.swift"
        source.write_text(_SWIFT_VERIFY)
        self.executable = root / "verify"
        environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(root / "cache"), SWIFT_MODULECACHE_PATH=str(root / "cache"))
        subprocess.run(["/usr/bin/swiftc", str(source), "-o", str(self.executable)], env=environment,
                       check=True, capture_output=True, text=True)

    def close(self):
        self.temporary.cleanup()

    def verify(self, path: Path, signature: str, public_key: str, length: int | None = None):
        decode64(signature, 64, "signature")
        decode64(public_key, 32, "update public key")
        result = subprocess.run([str(self.executable), str(path), signature, public_key,
                                 str(path.stat().st_size if length is None else length)], capture_output=True)
        if result.returncode:
            raise RuntimeError("EdDSA signature does not match the app's public key: " + path.name)

    def verify_feed(self, path: Path, public_key: str):
        content, signature = feed_signature(path.read_bytes())
        self.verify(path, signature, public_key, len(content))


def parse_feed(data: bytes, repo: str) -> dict:
    feed_signature(data)
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise RuntimeError("Malformed update feed") from error
    items = root.findall("channel/item")
    if root.tag != "rss" or len(items) != 1:
        raise RuntimeError("Expected exactly one current macOS update in the feed")
    item = items[0]
    def field(namespace, name):
        value = item.findtext(f"{{{namespace}}}{name}", "")
        if not value:
            raise RuntimeError("Missing feed property: " + name)
        return value
    version, build = field(SPARKLE, "shortVersionString"), field(SPARKLE, "version")
    revision = field(POSLE, "sourceRevision")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version) or not re.fullmatch(r"[1-9][0-9]*", build) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError("Invalid feed version or source revision")
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        raise RuntimeError("Expected one update archive")
    enclosure = enclosures[0]
    if enclosure.get("url") != asset_url(repo, "v" + version, ZIP) or not re.fullmatch(r"[1-9][0-9]*", enclosure.get("length", "")):
        raise RuntimeError("Update archive must use its immutable release URL and exact length")
    signature = enclosure.get(f"{{{SPARKLE}}}edSignature", "")
    decode64(signature, 64, "archive signature")
    hashes = {name: field(POSLE, prop) for name, prop in ((ZIP, "archiveSHA256"), (SOURCE, "sourceSHA256"), (PKG, "packageSHA256"))}
    if any(not re.fullmatch(r"[0-9a-f]{64}", value) for value in hashes.values()):
        raise RuntimeError("Invalid authenticated release checksum")
    if field(SPARKLE, "hardwareRequirements") != "arm64":
        raise RuntimeError("Update must require Apple silicon hardware")
    if field(SPARKLE, "minimumSystemVersion") != "15.0":
        raise RuntimeError("Unexpected update minimum macOS version")
    return {"version": version, "build": int(build), "revision": revision, "tag": "v" + version,
            "signature": signature, "length": int(enclosure.get("length")), "hashes": hashes}


class GitHub:
    def __init__(self, repo: str, executable: str):
        self.repo = validate_repo(repo)
        self.executable = executable

    def api(self, route: str, method: str = "GET", body: dict | None = None, missing_ok=False):
        endpoint = f"repos/{self.repo}" + ("/" + route if route else "")
        command = [self.executable, "api", "--method", method, endpoint]
        if body is not None:
            command += ["--input", "-"]
        result = subprocess.run(command, input=json.dumps(body) if body is not None else None, text=True, capture_output=True)
        if result.returncode:
            if missing_ok and "HTTP 404" in result.stderr:
                return None
            raise RuntimeError(f"GitHub {method} {route} failed (HTTP/API error); no feed change confirmed")
        return json.loads(result.stdout)

    def release(self, tag: str):
        page = 1
        while True:
            releases = self.api(f"releases?per_page=100&page={page}")
            for release in releases:
                if release["tag_name"] == tag:
                    return release
            if len(releases) < 100:
                return None
            page += 1

    def tag_revision(self, tag: str) -> str | None:
        ref = self.api("git/ref/tags/" + quote(tag, safe=""), missing_ok=True)
        if ref is None:
            return None
        obj = ref["object"]
        for _ in range(5):
            if obj["type"] == "commit":
                return obj["sha"]
            if obj["type"] != "tag":
                break
            obj = self.api("git/tags/" + obj["sha"])["object"]
        raise RuntimeError("Version tag does not resolve to a commit")

    def guard_visibility(self, expected="public"):
        repo = self.api("")
        actual = "private" if repo["private"] else "public"
        if actual != expected or actual != "public":
            raise RuntimeError("Signed public updates require the expected public repository visibility")


def uploaded_assets(release: dict, files: dict[str, Path], require_exact=False):
    assets = release.get("assets", [])
    if len({asset["name"] for asset in assets}) != len(assets):
        raise RuntimeError("Duplicate release asset names")
    by_name = {asset["name"]: asset for asset in assets}
    if require_exact and set(by_name) != set(files):
        raise RuntimeError("Draft contains unexpected release assets; it must remain unpublished")
    for name, local in files.items():
        remote = by_name.get(name, {})
        if remote.get("state") != "uploaded" or remote.get("size") != local.stat().st_size or remote.get("digest") != "sha256:" + digest(local):
            raise RuntimeError("Uploaded asset verification failed: " + name)


class _HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        parsed = urlsplit(urljoin(request.full_url, newurl))
        host = parsed.hostname or ""
        if parsed.scheme != "https" or parsed.username or parsed.password or not (host == "github.com" or host.endswith(".githubusercontent.com")):
            raise RuntimeError("Refusing an unexpected release download redirect")
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def anonymous_download(url: str, path: Path, expected_size: int):
    if not 0 < expected_size <= 1024 * 1024 * 1024:
        raise RuntimeError("Unexpected release asset size")
    # This opener has no credentials, cookies, proxy credentials or gh auth.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _HTTPSRedirect())
    request = urllib.request.Request(url, headers={"User-Agent": "Posle-release-verifier", "Accept": "application/octet-stream"})
    with opener.open(request, timeout=30) as response, path.open("wb") as output:
        if response.status != 200:
            raise RuntimeError("Public release download did not return HTTP 200")
        total = 0
        while block := response.read(256 * 1024):
            total += len(block)
            if total > expected_size:
                raise RuntimeError("Public release asset is larger than expected")
            output.write(block)
    if total != expected_size:
        raise RuntimeError("Public release asset is truncated")


def verify_checksums(directory: Path):
    lines = (directory / "SHA256SUMS").read_text().splitlines()
    if len(lines) != len(CHECKSUMMED):
        raise RuntimeError("Unexpected release checksum manifest")
    expected = {}
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9.-]+)", line)
        if match is None or match[2] not in CHECKSUMMED or match[2] in expected:
            raise RuntimeError("Invalid release checksum manifest")
        expected[match[2]] = match[1]
    for name in CHECKSUMMED:
        if expected.get(name) != digest(directory / name):
            raise RuntimeError("Public release checksum mismatch: " + name)


def verify_zip(path: Path, expected: Identity, repo: str):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(set(names)) != len(names) or archive.testzip() is not None:
            raise RuntimeError("Damaged or ambiguous update ZIP")
        for entry in archive.infolist():
            name = PurePosixPath(entry.filename)
            if name.is_absolute() or ".." in name.parts or not name.parts or name.parts[0] not in (APP, "__MACOSX"):
                raise RuntimeError("Update ZIP contains paths outside the app")
            if stat.S_ISLNK(entry.external_attr >> 16):
                target = archive.read(entry).decode("utf-8")
                normalized = os.path.normpath(str(name.parent / target))
                if target.startswith("/") or not (normalized == APP or normalized.startswith(APP + "/")):
                    raise RuntimeError("Update ZIP contains an escaping symbolic link")
        actual = identity(plistlib.loads(archive.read(APP + "/Contents/Info.plist")), repo, expected.revision)
        if actual != expected:
            raise RuntimeError("Downloaded app identity differs from the signed update")
    with tempfile.TemporaryDirectory(prefix="posle-update-unpack-") as temporary:
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(path), temporary], check=True, capture_output=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(Path(temporary) / APP)], check=True, capture_output=True)


def verify_source(path: Path, expected: Identity, repo: str):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise RuntimeError("Damaged public source archive")
        info = plistlib.loads(archive.read("posle/packaging/Info.plist"))
        for field, value in (("CFBundleShortVersionString", expected.version), ("CFBundleVersion", str(expected.build)),
                             ("SUPublicEDKey", expected.public_key), ("SUFeedURL", feed_url(repo))):
            if info.get(field) != value:
                raise RuntimeError("Published source archive differs from the app: " + field)


@dataclass(frozen=True)
class VerifiedRelease:
    identity: Identity
    appcast: bytes


def verify_public_release(github: GitHub, release: dict, public_key: str, verifier: PublicVerifier) -> VerifiedRelease:
    if release.get("draft") or not release.get("published_at"):
        raise RuntimeError("Feed promotion requires a published release")
    tag = release["tag_name"]
    assets = release.get("assets", [])
    by_name = {asset["name"]: asset for asset in assets}
    if len(by_name) != len(assets) or set(by_name) != set(ASSETS):
        raise RuntimeError("Published release must contain exactly the verified release assets")
    with tempfile.TemporaryDirectory(prefix="posle-public-release-") as temporary:
        directory = Path(temporary)
        for name in ASSETS:
            asset = by_name[name]
            limit = {FEED: MAX_FEED, "SHA256SUMS": 16 * 1024, SOURCE: 256 * 1024 * 1024}.get(name, 1024 * 1024 * 1024)
            if not isinstance(asset.get("size"), int) or not 0 < asset["size"] <= limit:
                raise RuntimeError("Unexpected public release asset size: " + name)
            expected_url = asset_url(github.repo, tag, name)
            if asset.get("state") != "uploaded" or asset.get("browser_download_url") != expected_url or not isinstance(asset.get("size"), int):
                raise RuntimeError("Invalid public release asset: " + name)
            anonymous_download(expected_url, directory / name, asset["size"])
            if asset.get("digest") != "sha256:" + digest(directory / name):
                raise RuntimeError("Public release asset digest mismatch: " + name)
        verify_checksums(directory)
        appcast = (directory / FEED).read_bytes()
        verifier.verify_feed(directory / FEED, public_key)
        parsed = parse_feed(appcast, github.repo)
        if parsed["tag"] != tag or github.tag_revision(tag) != parsed["revision"]:
            raise RuntimeError("Published tag differs from the authenticated source revision")
        expected = Identity(parsed["version"], parsed["build"], parsed["revision"], public_key)
        for name, expected_hash in parsed["hashes"].items():
            if digest(directory / name) != expected_hash:
                raise RuntimeError("Authenticated release digest mismatch: " + name)
        if (directory / ZIP).stat().st_size != parsed["length"]:
            raise RuntimeError("Authenticated update archive length mismatch")
        verifier.verify(directory / ZIP, parsed["signature"], public_key)
        verify_zip(directory / ZIP, expected, github.repo)
        verify_source(directory / SOURCE, expected, github.repo)
        return VerifiedRelease(expected, appcast)


def promote_feed(github: GitHub, verified: VerifiedRelease, verifier: PublicVerifier) -> bool:
    reference = github.api("git/ref/heads/" + BRANCH, missing_ok=True)
    parent = reference["object"]["sha"] if reference else None
    if parent:
        commit = github.api("git/commits/" + parent)
        tree = github.api("git/trees/" + commit["tree"]["sha"])
        entries = tree.get("tree", [])
        if tree.get("truncated") or len(entries) != 1 or entries[0].get("path") != FEED or entries[0].get("type") != "blob" or entries[0].get("mode") != "100644":
            raise RuntimeError("The updates branch must contain only a regular appcast.xml")
        blob = github.api("git/blobs/" + entries[0]["sha"])
        if blob.get("encoding") != "base64" or blob.get("size", MAX_FEED + 1) > MAX_FEED:
            raise RuntimeError("Invalid existing update feed blob")
        old = base64.b64decode(blob["content"])
        with tempfile.TemporaryDirectory(prefix="posle-existing-feed-") as temporary:
            path = Path(temporary) / FEED
            path.write_bytes(old)
            verifier.verify_feed(path, verified.identity.public_key)
        previous = parse_feed(old, github.repo)
        if previous["build"] >= verified.identity.build:
            if old == verified.appcast:
                return False  # Safe, idempotent resume; never rewrite a published build.
            raise RuntimeError("Refusing to replace an already announced build or roll the feed back")
    tree = github.api("git/trees", "POST", {"tree": [{"path": FEED, "mode": "100644", "type": "blob", "content": verified.appcast.decode("utf-8")}]})
    commit = github.api("git/commits", "POST", {"message": f"Publish {verified.identity.tag} update feed", "tree": tree["sha"], "parents": [parent] if parent else []})
    if parent:
        # Commit parent plus force=false is compare-and-swap: a concurrent new
        # feed commit makes this divergent and GitHub rejects the update.
        github.api("git/refs/heads/" + BRANCH, "PATCH", {"sha": commit["sha"], "force": False})
    else:
        github.api("git/refs", "POST", {"ref": "refs/heads/" + BRANCH, "sha": commit["sha"]})
    confirmed = github.api("git/ref/heads/" + BRANCH)
    if confirmed["object"]["sha"] != commit["sha"]:
        raise RuntimeError("Feed branch moved concurrently; publication needs inspection")
    return True


def find_gh() -> str:
    executable = shutil.which("gh") or str(PROJECT / ".toolchain/github/gh")
    if not Path(executable).is_file():
        raise RuntimeError("Install the official GitHub CLI and run gh auth login")
    return executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="starkovsavva/posle")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--info-plist", type=Path, default=PROJECT / "packaging/Info.plist", help="Trusted local app metadata supplying the update public key")
    args = parser.parse_args()
    with args.info_plist.open("rb") as stream:
        public_key = plistlib.load(stream).get("SUPublicEDKey", "")
    decode64(public_key, 32, "update public key")
    github = GitHub(args.repo, find_gh())
    github.guard_visibility()
    release = github.release(args.tag)
    if release is None:
        raise RuntimeError("Published release not found")
    verifier = PublicVerifier()
    try:
        verified = verify_public_release(github, release, public_key, verifier)
        changed = promote_feed(github, verified, verifier)
    finally:
        verifier.close()
    print(json.dumps({"tag": args.tag, "feed": feed_url(args.repo), "advanced": changed}))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, KeyError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print("Update feed not completed: " + str(error), file=__import__("sys").stderr)
        raise SystemExit(1)
