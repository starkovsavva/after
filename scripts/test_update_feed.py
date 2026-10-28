"""Offline release/feed tests. Optional real Sparkle tests use only a public test key.

No GitHub writes, production Keychain reads, microphone or personal files.
"""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile
import xml.etree.ElementTree as ET

import update_feed as u
import publish_release as publisher

REPO = "example/posle"
REVISION = "a" * 40
PUBLIC = base64.b64encode(bytes(range(32))).decode()
SIGNATURE = base64.b64encode(bytes(range(64))).decode()


def info(build=9, public=PUBLIC):
    return {"CFBundleIdentifier": "app.posle.meetings", "CFBundleShortVersionString": "0.8.0", "CFBundleVersion": str(build),
            "PosleSourceRevision": REVISION, "SUPublicEDKey": public, "SUFeedURL": u.feed_url(REPO),
            "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True, "SUSignedFeedFailureExpirationInterval": 0, "LSMinimumSystemVersion": "15.0"}


def signed(data):
    return data + f"<!-- sparkle-signatures:\nedSignature: {SIGNATURE}\nlength: {len(data)}\n-->\n".encode()


class Verifier:
    def __init__(self): self.calls = []
    def verify(self, path, signature, public, length=None): self.calls.append((Path(path).name, signature, public, length))
    def verify_feed(self, path, public):
        u.feed_signature(Path(path).read_bytes())
        self.calls.append((u.FEED, public))


class Fixture:
    def __init__(self, root, public=PUBLIC):
        self.root = Path(root)
        self.identity = u.identity(info(public=public), REPO)
        self.files = {name: self.root / name for name in u.ASSETS}
        self.files[u.PKG].write_bytes(b"synthetic pkg fixture")
        with zipfile.ZipFile(self.files[u.ZIP], "w") as z:
            z.writestr(u.APP + "/Contents/Info.plist", plistlib.dumps(info(public=public)))
        with zipfile.ZipFile(self.files[u.SOURCE], "w") as z:
            z.writestr("posle/packaging/Info.plist", plistlib.dumps(info(public=public)))
        self.files[u.FEED].write_bytes(signed(u.make_appcast(self.identity, REPO, SIGNATURE, self.files, "Synthetic release notes")))
        self.files["SHA256SUMS"].write_text("".join(u.digest(self.files[name]) + "  " + name + "\n" for name in u.CHECKSUMMED))
        self.release = {"draft": False, "published_at": "2026-10-26T00:00:00Z", "tag_name": self.identity.tag, "assets": [
            {"name": name, "state": "uploaded", "size": path.stat().st_size, "digest": "sha256:" + u.digest(path),
             "browser_download_url": u.asset_url(REPO, self.identity.tag, name)} for name, path in self.files.items()]}

    def download(self, url, path, expected_size):
        name = next(name for name in self.files if url == u.asset_url(REPO, self.identity.tag, name))
        shutil.copy2(self.files[name], path)
        if Path(path).stat().st_size != expected_size: raise RuntimeError("wrong synthetic size")


class GitHubFixture:
    repo = REPO
    def __init__(self, previous=None, race=False):
        self.previous = previous
        self.head = "old" if previous else None
        self.race = race
        self.calls = []
        self.new_content = None
        self.created_parents = None
    def tag_revision(self, tag): return REVISION
    def api(self, route, method="GET", body=None, missing_ok=False):
        self.calls.append((route, method, body))
        if route == "git/ref/heads/updates": return {"object": {"sha": self.head}} if self.head else None
        if route == "git/commits/" + REVISION: return {"tree": {"sha": "1" * 40}}
        if route == "git/trees/" + "1" * 40 + "?recursive=1":
            content = plistlib.dumps(info())
            sha = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
            return {"tree": [{"path": "packaging/Info.plist", "mode": "100644", "type": "blob", "sha": sha}]}
        if route == "git/commits/old": return {"tree": {"sha": "oldtree"}}
        if route == "git/trees/oldtree": return {"tree": [{"path": u.FEED, "mode": "100644", "type": "blob", "sha": "oldblob"}]}
        if route == "git/blobs/oldblob": return {"encoding": "base64", "size": len(self.previous), "content": base64.b64encode(self.previous).decode()}
        if route == "git/trees" and method == "POST":
            self.new_content = body["tree"][0]["content"].encode(); return {"sha": "newtree"}
        if route == "git/commits" and method == "POST":
            self.created_parents = body["parents"]; return {"sha": "newcommit"}
        if route == "git/refs" and method == "POST":
            if self.head: raise RuntimeError("concurrent branch creation")
            self.head = body["sha"]; return {}
        if route == "git/refs/heads/updates" and method == "PATCH":
            if body.get("force") is not False: raise AssertionError("force update forbidden")
            if self.race:
                self.head = "concurrent"; raise RuntimeError("not fast forward")
            self.head = body["sha"]; return {}
        raise AssertionError((route, method, body))


class FeedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="posle-feed-test-")
        self.addCleanup(self.temporary.cleanup)
        self.fixture = Fixture(self.temporary.name)
        self.verifier = Verifier()
        self.verified = u.VerifiedRelease(self.fixture.identity, self.fixture.files[u.FEED].read_bytes())

    def older(self):
        identity = u.identity(info(build=8), REPO)
        return signed(u.make_appcast(identity, REPO, SIGNATURE, self.fixture.files, "Old notes"))

    def test_repository_metadata_endpoint_has_no_trailing_slash(self):
        response = subprocess.CompletedProcess([], 0, '{"private": false}', "")
        with mock.patch.object(u.subprocess, "run", return_value=response) as command:
            u.GitHub(REPO, "gh").guard_visibility()
        self.assertEqual(command.call_args.args[0], ["gh", "api", "--method", "GET", "repos/" + REPO])

    def test_release_redirects_reject_untrusted_transport_credentials_and_hosts(self):
        request = u.urllib.request.Request(u.asset_url(REPO, "v0.8.0", u.ZIP))
        handler = u._HTTPSRedirect()
        for target in ("http://github.com/file.zip", "https://example.com/file.zip",
                       "https://github.com.example.com/file.zip", "https://objects.githubusercontent.com.example.com/file.zip",
                       "https://user:password@github.com/file.zip", "ftp://github.com/file.zip", "file:///tmp/file.zip",
                       "//example.com/file.zip"):
            with self.subTest(target=target), self.assertRaisesRegex(RuntimeError, "unexpected release download redirect"):
                handler.redirect_request(request, None, 302, "Found", {}, target)
        for target in ("https://github.com/file.zip", "https://release-assets.githubusercontent.com/file.zip",
                       "https://objects.githubusercontent.com/file.zip"):
            with self.subTest(target=target):
                redirected = handler.redirect_request(request, None, 302, "Found", {}, target)
                self.assertIsNotNone(redirected)

    def test_anonymous_download_rejects_incomplete_oversize_and_non_200_responses(self):
        class Response(io.BytesIO):
            def __init__(self, content, status=200):
                super().__init__(content)
                self.status = status
        destination = Path(self.temporary.name) / "download.zip"
        url = u.asset_url(REPO, "v0.8.0", u.ZIP)
        for body, expected_size, status, message in ((b"short", 6, 200, "truncated"),
                                                    (b"too long", 4, 200, "larger than expected"),
                                                    (b"exact", 5, 206, "HTTP 200")):
            opener = mock.Mock()
            opener.open.return_value = Response(body, status)
            with self.subTest(body=body, status=status), mock.patch.object(u.urllib.request, "build_opener", return_value=opener), \
                 self.assertRaisesRegex(RuntimeError, message):
                u.anonymous_download(url, destination, expected_size)
        opener = mock.Mock()
        opener.open.return_value = Response(b"exact")
        with mock.patch.object(u.urllib.request, "build_opener", return_value=opener) as build:
            u.anonymous_download(url, destination, 5)
        self.assertEqual(destination.read_bytes(), b"exact")
        self.assertEqual(build.call_args.args[0].proxies, {})
        self.assertIsInstance(build.call_args.args[1], u._HTTPSRedirect)
        headers = {name.casefold(): value for name, value in opener.open.call_args.args[0].header_items()}
        self.assertFalse(set(headers) & {"authorization", "cookie", "proxy-authorization"})
        for size in (0, -1, 1024 ** 3 + 1):
            with self.subTest(size=size), mock.patch.object(u.urllib.request, "build_opener") as build:
                with self.assertRaisesRegex(RuntimeError, "asset size"):
                    u.anonymous_download(url, destination, size)
                build.assert_not_called()

    def test_identity_requires_signed_head_provenance(self):
        self.assertEqual(u.identity(info(), REPO, REVISION).build, 9)
        for changes in ({"PosleSourceRevision": "b" * 40}, {"SURequireSignedFeed": False}, {"SUPublicEDKey": "missing"},
                        {"SUFeedURL": "https://github.com/example/posle/releases/latest/download/appcast.xml"}):
            with self.subTest(changes=changes), self.assertRaises(RuntimeError): u.identity(dict(info(), **changes), REPO, REVISION)

    def test_feed_preserves_exact_bytes_and_authenticated_hashes(self):
        data = self.verified.appcast
        content, signature = u.feed_signature(data)
        self.assertEqual(data[:len(content)], content)
        self.assertEqual(signature, SIGNATURE)
        parsed = u.parse_feed(data, REPO)
        self.assertEqual(parsed["revision"], REVISION)
        self.assertEqual(parsed["length"], self.fixture.files[u.ZIP].stat().st_size)
        self.assertEqual(parsed["hashes"][u.SOURCE], u.digest(self.fixture.files[u.SOURCE]))
        for changed in (data + b"extra", data.replace(b"length: ", b"length: 99", 1), content):
            with self.assertRaises(RuntimeError): u.feed_signature(changed)

    def test_markdown_release_notes_and_arm64_requirement_use_official_elements(self):
        notes = "## Новое\n\n- **Карточки** и заметки\n- Поиск & ссылки"
        data = u.make_appcast(self.fixture.identity, REPO, SIGNATURE, self.fixture.files, notes)
        root = ET.fromstring(data)
        description = root.find("channel/item/description")
        self.assertEqual(description.get(f"{{{u.SPARKLE}}}format"), "markdown")
        self.assertEqual(description.text, notes)
        self.assertEqual(root.findtext(f"channel/item/{{{u.SPARKLE}}}hardwareRequirements"), "arm64")

    def test_initial_feed_is_one_file_orphan_and_never_touches_main(self):
        github = GitHubFixture()
        self.assertTrue(u.promote_feed(github, self.verified, self.verifier))
        self.assertEqual(github.created_parents, [])
        self.assertEqual(github.new_content, self.verified.appcast)
        self.assertFalse(any("main" in route for route, _, _ in github.calls))
        tree_body = next(body for route, method, body in github.calls if route == "git/trees" and method == "POST")
        self.assertEqual([entry["path"] for entry in tree_body["tree"]], [u.FEED])
        self.assertNotIn("base_tree", tree_body)

    def test_following_feed_appends_parent_and_uses_nonforce_cas(self):
        github = GitHubFixture(self.older())
        self.assertTrue(u.promote_feed(github, self.verified, self.verifier))
        self.assertEqual(github.created_parents, ["old"])
        mutation = next(body for _, method, body in github.calls if method == "PATCH")
        self.assertIs(mutation["force"], False)

    def test_concurrent_feed_advance_is_not_overwritten(self):
        github = GitHubFixture(self.older(), race=True)
        with self.assertRaisesRegex(RuntimeError, "fast forward"):
            u.promote_feed(github, self.verified, self.verifier)
        self.assertEqual(github.head, "concurrent")

    def test_resume_is_idempotent_and_issued_build_cannot_be_replaced(self):
        github = GitHubFixture(self.verified.appcast)
        self.assertFalse(u.promote_feed(github, self.verified, self.verifier))
        self.assertTrue(all(method == "GET" for _, method, _ in github.calls))
        github = GitHubFixture(self.verified.appcast)
        other = u.VerifiedRelease(self.fixture.identity, self.verified.appcast.replace(b"Synthetic release", b"Different release"))
        with self.assertRaisesRegex(RuntimeError, "already announced"):
            u.promote_feed(github, other, self.verifier)
        self.assertTrue(all(method == "GET" for _, method, _ in github.calls))

    def test_lower_build_and_unrelated_branch_contents_fail_before_mutation(self):
        github = GitHubFixture(self.verified.appcast)
        older = u.VerifiedRelease(u.identity(info(build=8), REPO), self.older())
        with self.assertRaises(RuntimeError): u.promote_feed(github, older, self.verifier)
        self.assertTrue(all(method == "GET" for _, method, _ in github.calls))
        original = github.api
        def api(route, method="GET", body=None, missing_ok=False):
            if route == "git/trees/oldtree": return {"tree": [{"path": "README.md"}]}
            return original(route, method, body, missing_ok)
        github.api = api
        with self.assertRaisesRegex(RuntimeError, "only a regular appcast"):
            u.promote_feed(github, self.verified, self.verifier)

    def test_public_pipeline_checks_every_download_before_returning_verified(self):
        github = GitHubFixture()
        with mock.patch.object(u, "anonymous_download", side_effect=self.fixture.download) as download, mock.patch.object(u, "verify_zip") as unzip:
            verified = u.verify_public_release(github, self.fixture.release, PUBLIC, self.verifier)
        self.assertEqual(verified, self.verified)
        self.assertEqual(download.call_count, 5)
        unzip.assert_called_once()
        self.assertTrue(any(call[0] == u.ZIP for call in self.verifier.calls))
        self.assertFalse(any(method != "GET" for _, method, _ in github.calls))

    def test_public_corruption_never_reaches_zip_extraction_or_feed(self):
        github = GitHubFixture()
        def corrupt(url, path, size):
            self.fixture.download(url, path, size)
            if Path(path).name == u.ZIP: Path(path).write_bytes(b"tampered")
        with mock.patch.object(u, "anonymous_download", side_effect=corrupt), mock.patch.object(u, "verify_zip") as unzip:
            with self.assertRaisesRegex(RuntimeError, "digest mismatch"):
                u.verify_public_release(github, self.fixture.release, PUBLIC, self.verifier)
        unzip.assert_not_called()
        self.assertFalse(any(method != "GET" for _, method, _ in github.calls))

    def test_final_draft_check_rejects_extra_or_duplicate_assets(self):
        u.uploaded_assets(self.fixture.release, self.fixture.files, require_exact=True)
        for assets in (self.fixture.release["assets"] + [{"name": "obsolete.zip"}],
                       self.fixture.release["assets"] + [self.fixture.release["assets"][0]]):
            with self.assertRaises(RuntimeError):
                u.uploaded_assets(dict(self.fixture.release, assets=assets), self.fixture.files, require_exact=True)
        # Partial checks intentionally allow the appcast/manifest to be uploaded later.
        u.uploaded_assets(self.fixture.release, {u.ZIP: self.fixture.files[u.ZIP]})

    def test_draft_and_missing_asset_are_rejected_before_download(self):
        for change in ({"draft": True}, {"assets": self.fixture.release["assets"][:-1]}):
            with mock.patch.object(u, "anonymous_download") as download, self.assertRaises(RuntimeError):
                u.verify_public_release(GitHubFixture(), dict(self.fixture.release, **change), PUBLIC, self.verifier)
            download.assert_not_called()

    def test_ditto_utf8_names_without_utf8_flag_pass_identity_and_path_checks(self):
        path = self.fixture.files[u.ZIP]
        data = bytearray(path.read_bytes())
        end = data.rfind(b"PK\x05\x06")
        self.assertGreaterEqual(end, 0)
        count = struct.unpack_from("<H", data, end + 10)[0]
        central = struct.unpack_from("<I", data, end + 16)[0]
        for _ in range(count):
            self.assertEqual(data[central:central + 4], b"PK\x01\x02")
            flags = struct.unpack_from("<H", data, central + 8)[0]
            local = struct.unpack_from("<I", data, central + 42)[0]
            self.assertEqual(data[local:local + 4], b"PK\x03\x04")
            struct.pack_into("<H", data, central + 8, flags & ~0x800)
            local_flags = struct.unpack_from("<H", data, local + 6)[0]
            struct.pack_into("<H", data, local + 6, local_flags & ~0x800)
            name_length, extra_length, comment_length = struct.unpack_from("<HHH", data, central + 28)
            central += 46 + name_length + extra_length + comment_length
        path.write_bytes(data)
        with zipfile.ZipFile(path) as default_decoder:
            self.assertNotEqual(default_decoder.namelist()[0], u.APP + "/Contents/Info.plist")
        with mock.patch.object(u.subprocess, "run") as command:
            u.verify_zip(path, self.fixture.identity, REPO)
        self.assertEqual(command.call_count, 2)
        self.assertEqual(command.call_args_list[0].args[0][:3], ["/usr/bin/ditto", "-x", "-k"])
        self.assertEqual(command.call_args_list[1].args[0][:4], ["/usr/bin/codesign", "--verify", "--deep", "--strict"])
        self.assertTrue(command.call_args_list[1].args[0][-1].endswith("/" + u.APP))

    def test_source_mismatch_and_zip_path_escape_are_rejected(self):
        with zipfile.ZipFile(self.fixture.files[u.SOURCE], "w") as z:
            z.writestr("posle/packaging/Info.plist", plistlib.dumps(dict(info(), CFBundleVersion="8")))
        with self.assertRaisesRegex(RuntimeError, "source archive differs"):
            u.verify_source(self.fixture.files[u.SOURCE], self.fixture.identity, REPO, tree={})
        for filename, target in (("../outside", None), (u.APP + "/Contents/evil", "../../../../outside")):
            with zipfile.ZipFile(self.fixture.files[u.ZIP], "w") as z:
                z.writestr(u.APP + "/Contents/Info.plist", plistlib.dumps(info()))
                entry = zipfile.ZipInfo(filename)
                if target: entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(entry, target or "outside")
            with mock.patch.object(u.subprocess, "run") as command, self.assertRaises(RuntimeError):
                u.verify_zip(self.fixture.files[u.ZIP], self.fixture.identity, REPO)
            command.assert_not_called()

    def test_zip_aliases_and_symlink_ancestors_fail_before_extraction(self):
        for entries in (
            [(u.APP + "/alias", "."), (u.APP + "/alias/link", "../outside")],
            [(u.APP + "/Contents/Info.PLIST", "ordinary")],
            [(u.APP + "/Contents/Ресурсы/cafe\u0301.txt", "ordinary"),
             (u.APP + "/Contents/Ресурсы/café.txt", "ordinary")],
            [(u.APP + "/Contents//duplicate", "ordinary")],
        ):
            path = self.fixture.files[u.ZIP]
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr(u.APP + "/Contents/Info.plist", plistlib.dumps(info()))
                for name, value in entries:
                    entry = zipfile.ZipInfo(name)
                    if value in (".", "../outside"):
                        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(entry, value)
            with self.subTest(entries=entries), mock.patch.object(u.subprocess, "run") as command:
                with self.assertRaises(RuntimeError):
                    u.verify_zip(path, self.fixture.identity, REPO)
                command.assert_not_called()

    def test_authenticated_source_metadata_cannot_substitute_for_the_exact_commit(self):
        with zipfile.ZipFile(self.fixture.files[u.SOURCE], "a") as archive:
            archive.writestr("posle/untracked.txt", "Extra unpublished code")
        feed = signed(u.make_appcast(self.fixture.identity, REPO, SIGNATURE, self.fixture.files, "Fixture"))
        self.fixture.files[u.FEED].write_bytes(feed)
        self.fixture.files["SHA256SUMS"].write_text("".join(u.digest(self.fixture.files[name]) + "  " + name + "\n" for name in u.CHECKSUMMED))
        release = dict(self.fixture.release, assets=[dict(asset, size=self.fixture.files[asset["name"]].stat().st_size,
                      digest="sha256:" + u.digest(self.fixture.files[asset["name"]])) for asset in self.fixture.release["assets"]])
        github = GitHubFixture()
        with mock.patch.object(u, "anonymous_download", side_effect=self.fixture.download), mock.patch.object(u, "verify_zip"):
            with self.assertRaisesRegex(RuntimeError, "exact source commit"):
                u.verify_public_release(github, release, PUBLIC, self.verifier)
        self.assertFalse(any(method != "GET" for _, method, _ in github.calls))

    def test_source_archive_matches_every_blob_and_executable_mode(self):
        content = plistlib.dumps(info())
        sha = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
        tree = {"packaging/Info.plist": ("100644", sha)}
        u.verify_source(self.fixture.files[u.SOURCE], self.fixture.identity, REPO, tree=tree)
        for changed in ({"packaging/Info.plist": ("100755", sha)},
                        {"packaging/Info.plist": ("100644", "b" * 40)},
                        dict(tree, **{"unexpected.txt": ("100644", sha)})):
            with self.assertRaisesRegex(RuntimeError, "exact source commit"):
                u.verify_source(self.fixture.files[u.SOURCE], self.fixture.identity, REPO, tree=changed)
        with zipfile.ZipFile(self.fixture.files[u.SOURCE], "a") as archive:
            archive.writestr("posle/untracked.txt", "must never ship")
        with self.assertRaisesRegex(RuntimeError, "exact source commit"):
            u.verify_source(self.fixture.files[u.SOURCE], self.fixture.identity, REPO, tree=tree)

    def test_dirty_build_rejected_even_when_source_head_matches(self):
        app = Path(self.temporary.name) / u.APP
        (app / "Contents").mkdir(parents=True)
        for value in (False, None):
            metadata = dict(info(), PosleSourceClean=value)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata) if value is not None else plistlib.dumps(info()))
            with mock.patch.object(u, "verify_zip") as unpack, self.assertRaisesRegex(RuntimeError, "uncommitted"):
                u.verify_local_artifacts(app, self.fixture.files[u.SOURCE], self.fixture.identity, REPO)
            unpack.assert_not_called()

    def test_invalid_local_archive_never_reaches_signing_or_publication(self):
        root = Path(self.temporary.name)
        (root / "packaging").mkdir(); (root / "dist").mkdir()
        app = root / "dist" / u.APP; (app / "Contents").mkdir(parents=True)
        (root / "packaging/Info.plist").write_bytes(plistlib.dumps(info()))
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(info(), PosleSourceClean=True)))
        for name in (u.ZIP, u.SOURCE): shutil.copy2(self.fixture.files[name], root / "dist" / name)
        notes = root / "notes.txt"; notes.write_text("Fixture")
        github = mock.Mock(repo=REPO, executable="fixture-gh")
        github.api.return_value = {"sha": REVISION}; github.release.return_value = None; github.tag_revision.return_value = None
        commands = []
        def run(arguments, capture=False):
            commands.append(arguments)
            if arguments[:3] == ["git", "rev-parse", "HEAD"]: return REVISION
            return "" if capture else None
        with mock.patch.object(publisher, "PROJECT", root), mock.patch.object(publisher, "run", side_effect=run), \
             mock.patch.object(u, "GitHub", return_value=github), mock.patch.object(u, "find_gh", return_value="fixture-gh"), \
             mock.patch.object(u, "verify_local_artifacts", side_effect=RuntimeError("invalid fixture archive")), \
             mock.patch.object(publisher, "sparkle_tool") as signing_tool, \
             mock.patch("sys.argv", ["publish_release.py", "--repo", REPO, "--skip-build", "--notes-file", str(notes)]):
            with self.assertRaisesRegex(RuntimeError, "invalid fixture archive"): publisher.main()
        signing_tool.assert_not_called()
        self.assertFalse(any(command[0] == "fixture-gh" for command in commands))
        self.assertTrue(all(call.args[0] == "commits/main" for call in github.api.call_args_list))

    def test_resume_only_verifies_and_promotes_never_signs_or_edits_release(self):
        github = mock.Mock(repo=REPO)
        github.release.return_value = self.fixture.release
        args = argparse.Namespace(tag="v0.8.0", expected_visibility="public", repo=REPO)
        packaging = Path(self.temporary.name) / "packaging"
        packaging.mkdir()
        (packaging / "Info.plist").write_bytes(plistlib.dumps(info()))
        with mock.patch.object(publisher, "PROJECT", Path(self.temporary.name)), mock.patch.object(publisher, "run") as run, \
             mock.patch.object(u, "verify_public_release", return_value=self.verified) as verify, \
             mock.patch.object(u, "promote_feed", return_value=True) as promote, mock.patch("builtins.print"):
            publisher.resume(args, github, self.verifier)
        run.assert_not_called()
        verify.assert_called_once()
        promote.assert_called_once()
        github.api.assert_not_called()


class RealSparkleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tool = Path(os.environ.get("POSLE_TEST_SPARKLE_BIN_DIR", "/private/tmp/posle-sparkle-build/artifacts/sparkle/Sparkle/bin")) / "sign_update"
        if not cls.tool.is_file() or not Path("/usr/bin/swiftc").is_file():
            raise unittest.SkipTest("Pinned Sparkle SDK + Swift required for real signature interoperability tests")
        # Public, deterministic TEST seed. This is never a production key, never
        # touches Keychain, and is supplied to sign_update only via stdin.
        code = '''import Foundation\nimport CryptoKit\nlet k = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))\nprint(k.rawRepresentation.base64EncodedString())\nprint(k.publicKey.rawRepresentation.base64EncodedString())'''
        result = subprocess.run(["/usr/bin/swift", "-e", code], capture_output=True, text=True, check=True)
        cls.test_key, cls.public = result.stdout.splitlines()
        cls.verifier = u.PublicVerifier()

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "verifier"): cls.verifier.close()

    def sign(self, path, *arguments):
        result = subprocess.run([str(self.tool), "--ed-key-file", "-", *arguments, str(path)],
                                input=self.test_key + "\n", capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def test_official_sparkle_archive_and_xml_verify_with_only_public_key(self):
        with tempfile.TemporaryDirectory(prefix="posle-sparkle-test-") as temporary:
            fixture = Fixture(temporary)
            signature = self.sign(fixture.files[u.ZIP], "-p")
            self.verifier.verify(fixture.files[u.ZIP], signature, self.public)
            release = u.Identity("0.8.0", 9, REVISION, self.public)
            feed = fixture.files[u.FEED]
            feed.write_bytes(u.make_appcast(release, REPO, signature, fixture.files, "Notes <must> stay signed & safe"))
            self.sign(feed, "--disable-signing-warning")
            self.verifier.verify_feed(feed, self.public)
            self.assertEqual(u.parse_feed(feed.read_bytes(), REPO)["build"], 9)
            data = feed.read_bytes()
            feed.write_bytes(data.replace(b"stay signed", b"stay forged"))
            with self.assertRaisesRegex(RuntimeError, "EdDSA"): self.verifier.verify_feed(feed, self.public)
            fixture.files[u.ZIP].write_bytes(fixture.files[u.ZIP].read_bytes() + b"tampered")
            with self.assertRaisesRegex(RuntimeError, "EdDSA"): self.verifier.verify(fixture.files[u.ZIP], signature, self.public)

    def test_complete_publisher_signing_wrapper_uses_only_expected_account(self):
        with tempfile.TemporaryDirectory(prefix="posle-signing-test-") as temporary:
            root = Path(temporary); (root / "dist").mkdir()
            fixture = Fixture(root / "dist", public=self.public)
            commands = []
            def test_run(arguments, capture=False):
                commands.append(arguments)
                self.assertEqual(arguments[1:3], ["--account", u.ACCOUNT])
                return self.sign(Path(arguments[-1]), *arguments[3:-1])
            with mock.patch.object(publisher, "PROJECT", root), mock.patch.object(publisher, "run", side_effect=test_run):
                files = publisher.signing_files(fixture.identity, REPO, "## New\n- Useful notes", str(self.tool), self.verifier)
            self.assertEqual(set(files), set(u.ASSETS))
            self.assertEqual(len(commands), 2)
            self.verifier.verify_feed(files[u.FEED], self.public)
            u.verify_checksums(root / "dist")
            self.assertEqual(u.parse_feed(files[u.FEED].read_bytes(), REPO)["build"], 9)

    def test_production_signing_flow_public_key_mismatch_fails_before_feed(self):
        with tempfile.TemporaryDirectory(prefix="posle-signing-test-") as temporary:
            root = Path(temporary); (root / "dist").mkdir()
            fixture = Fixture(root / "dist")
            fixture.files[u.FEED].unlink(); fixture.files["SHA256SUMS"].unlink()
            def test_run(arguments, capture=False):
                self.assertEqual(arguments[1:3], ["--account", u.ACCOUNT])
                path = Path(arguments[-1])
                return self.sign(path, *arguments[3:-1])
            with mock.patch.object(publisher, "PROJECT", root), mock.patch.object(publisher, "run", side_effect=test_run):
                with self.assertRaisesRegex(RuntimeError, "public key"):
                    publisher.signing_files(fixture.identity, REPO, "Test", str(self.tool), self.verifier)
            self.assertFalse(fixture.files[u.FEED].exists())
            self.assertFalse(fixture.files["SHA256SUMS"].exists())


if __name__ == "__main__":
    unittest.main()
