#!/usr/bin/env python3
"""Publish verified Mac artifacts, then announce their signed Sparkle update.

A failed feed promotion can be resumed without modifying the published release.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import zipfile

import update_feed as updates

PROJECT = Path(__file__).resolve().parent.parent
PACKAGED_ASSETS = (updates.PKG, updates.ZIP, updates.SOURCE)
ASSETS = updates.ASSETS


def run(arguments, capture=False):
    result = subprocess.run(arguments, cwd=PROJECT, text=True, capture_output=capture, check=True)
    return result.stdout.strip() if capture else None


def unchanged_revision(revision):
    if run(["git", "rev-parse", "HEAD"], capture=True) != revision or run(["git", "status", "--porcelain"], capture=True):
        raise RuntimeError("Release sources changed while packaging; commit and rebuild before publishing")


def sparkle_tool(directory):
    candidates = []
    if directory is not None:
        candidates.append(directory / "sign_update")
    elif os.environ.get("POSLE_SPARKLE_BIN_DIR"):
        candidates.append(Path(os.environ["POSLE_SPARKLE_BIN_DIR"]) / "sign_update")
    else:
        roots = [PROJECT / ".build/artifacts"]
        if os.environ.get("POSLE_BUILD_DIR"):
            roots.append(Path(os.environ["POSLE_BUILD_DIR"]) / "artifacts")
        for root in roots:
            if root.is_dir():
                candidates.extend(root.glob("*/Sparkle/bin/sign_update"))
    tools = {path.resolve() for path in candidates if path.is_file() and os.access(path, os.X_OK)}
    if len(tools) != 1:
        raise RuntimeError("Specify the pinned Sparkle SDK bin folder with --sparkle-bin-dir (or POSLE_SPARKLE_BIN_DIR)")
    return str(tools.pop())


def signing_files(release, repo, notes, tool, verifier):
    files = {name: PROJECT / "dist" / name for name in PACKAGED_ASSETS}
    signature = run([tool, "--account", updates.ACCOUNT, "-p", str(files[updates.ZIP])], capture=True)
    updates.decode64(signature, 64, "archive signature")
    verifier.verify(files[updates.ZIP], signature, release.public_key)
    feed = PROJECT / "dist" / updates.FEED
    feed.write_bytes(updates.make_appcast(release, repo, signature, files, notes))
    # XML is signed in place by Sparkle; do not change a byte afterwards.
    run([tool, "--account", updates.ACCOUNT, "--disable-signing-warning", str(feed)], capture=True)
    verifier.verify_feed(feed, release.public_key)
    parsed = updates.parse_feed(feed.read_bytes(), repo)
    if parsed["version"] != release.version or parsed["revision"] != release.revision or parsed["build"] != release.build:
        raise RuntimeError("Signed feed does not match this build")
    files[updates.FEED] = feed
    sums = PROJECT / "dist/SHA256SUMS"
    sums.write_text("".join(updates.digest(files[name]) + "  " + name + "\n" for name in updates.CHECKSUMMED))
    files["SHA256SUMS"] = sums
    updates.verify_checksums(PROJECT / "dist")
    return files


def resume(args, github, verifier):
    with (PROJECT / "packaging/Info.plist").open("rb") as stream:
        source = plistlib.load(stream)
    public_key = source.get("SUPublicEDKey", "")
    updates.decode64(public_key, 32, "update public key")
    tag = args.tag or "v" + updates.product_version(source)
    github.guard_visibility(args.expected_visibility)
    release = github.release(tag)
    if release is None:
        raise RuntimeError("Published release not found")
    verified = updates.verify_public_release(github, release, public_key, verifier)
    changed = updates.promote_feed(github, verified, verifier)
    print(json.dumps({"tag": tag, "feed": updates.feed_url(args.repo), "advanced": changed}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="starkovsavva/posle")
    parser.add_argument("--notes-file", type=Path)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--check-only", action="store_true", help="Verify and sign local release files; do not contact GitHub or publish")
    parser.add_argument("--expected-visibility", choices=("public", "private"), default="public")
    parser.add_argument("--stable", action="store_true", help="Mark the GitHub release as stable; the signed feed accepts approved prereleases too")
    parser.add_argument("--sparkle-bin-dir", type=Path, help="bin folder from the pinned official Sparkle SDK")
    parser.add_argument("--resume-feed", action="store_true", help="Verify published immutable assets and only advance the feed; never edit the release")
    parser.add_argument("--tag", help="Published tag for --resume-feed (defaults to the current source version)")
    args = parser.parse_args()
    updates.validate_repo(args.repo)
    if args.resume_feed and (args.check_only or args.skip_build or args.stable or args.notes_file):
        parser.error("--resume-feed cannot be combined with build, notes or publication options")
    if args.tag and not args.resume_feed:
        parser.error("--tag is only used with --resume-feed")
    if not args.resume_feed and (args.notes_file is None or not args.notes_file.is_file()):
        raise RuntimeError("Provide an existing release notes file")
    github = None if args.check_only else updates.GitHub(args.repo, updates.find_gh())
    if args.resume_feed:
        verifier = updates.PublicVerifier()
        try:
            resume(args, github, verifier)
        finally:
            verifier.close()
        return
    if run(["git", "status", "--porcelain"], capture=True):
        raise RuntimeError("Commit the release sources before packaging them")
    revision = run(["git", "rev-parse", "HEAD"], capture=True)
    with (PROJECT / "packaging/Info.plist").open("rb") as stream:
        source_info = plistlib.load(stream)
    expected = updates.identity(dict(source_info, PosleSourceRevision=revision), args.repo, revision)
    tag = expected.tag
    if github is not None:
        github.guard_visibility(args.expected_visibility)
        if github.api("commits/main")["sha"] != revision:
            raise RuntimeError("Push the release commit to main before publishing")
        existing = github.release(tag)
        if existing is not None and not existing["draft"]:
            raise RuntimeError("This version is already published; use --resume-feed or choose a new version")
        existing_tag = github.tag_revision(tag)
        if existing_tag is not None and existing_tag != revision:
            raise RuntimeError("The existing version tag points to different sources; choose a new version")
    if not args.skip_build and not args.check_only:
        run(["bash", "scripts/build.sh"])
    app = PROJECT / "dist" / updates.APP
    actual = updates.read_identity(app, args.repo, revision)
    if actual != expected:
        raise RuntimeError("The signed app differs from release metadata; rebuild it")
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    # Regenerate packages before signing: ZIP bytes must never change afterwards.
    run(["bash", "scripts/package.sh"])
    run(["git", "archive", "--format=zip", "--prefix=posle/", "--output=dist/" + updates.SOURCE, revision])
    for name in (updates.ZIP, updates.SOURCE):
        with zipfile.ZipFile(PROJECT / "dist" / name) as archive:
            if archive.testzip() is not None:
                raise RuntimeError("Damaged archive: " + name)
    # Validate extraction and every source blob while everything is still local.
    # A malformed archive must never become a published-but-uninstallable release.
    updates.verify_local_artifacts(app, PROJECT / "dist" / updates.SOURCE, actual, args.repo)
    verifier = updates.PublicVerifier()
    published = False
    try:
        files = signing_files(actual, args.repo, args.notes_file.read_text(), sparkle_tool(args.sparkle_bin_dir), verifier)
        unchanged_revision(revision)
        if args.check_only:
            print(json.dumps({"tag": tag, "revision": revision, "assets": ASSETS, "ready": True, "signed": True}))
            return
        if github.api("commits/main")["sha"] != revision:
            raise RuntimeError("Remote main changed while packaging; release was not published")
        release = github.release(tag)
        if release is not None and not release["draft"]:
            raise RuntimeError("This version was already published; no assets will be replaced")
        gh = github.executable
        base_assets = [str(files[name]) for name in PACKAGED_ASSETS]
        if release is None:
            run([gh, "release", "create", tag, *base_assets, "--repo", args.repo, "--draft", "--target", revision,
                 "--title", "После " + actual.version, "--notes-file", str(args.notes_file.resolve())])
        else:
            run([gh, "release", "edit", tag, "--repo", args.repo, "--target", revision,
                 "--title", "После " + actual.version, "--notes-file", str(args.notes_file.resolve())])
            run([gh, "release", "upload", tag, *base_assets, "--repo", args.repo, "--clobber"])
        release = github.release(tag)
        if release is None or not release["draft"]:
            raise RuntimeError("Expected an unpublished draft; signed feed was not uploaded")
        updates.uploaded_assets(release, {name: files[name] for name in PACKAGED_ASSETS})
        # Do not expose even the draft appcast until binary upload is verified.
        run([gh, "release", "upload", tag, str(files[updates.FEED]), str(files["SHA256SUMS"]), "--repo", args.repo, "--clobber"])
        release = github.release(tag)
        if release is None or not release["draft"]:
            raise RuntimeError("Draft state changed before final verification")
        updates.uploaded_assets(release, files, require_exact=True)
        unchanged_revision(revision)
        if github.api("commits/main")["sha"] != revision:
            raise RuntimeError("Remote source revision changed; release remains a draft")
        existing_tag = github.tag_revision(tag)
        if existing_tag is not None and existing_tag != revision:
            raise RuntimeError("Version tag moved; release remains a draft")
        run([gh, "release", "edit", tag, "--repo", args.repo, "--draft=false",
             "--prerelease=" + str(not args.stable).lower(), "--latest=" + str(args.stable).lower()])
        published = True
        release = github.api("releases/" + str(release["id"]))
        verified = updates.verify_public_release(github, release, actual.public_key, verifier)
        if verified.identity != actual:
            raise RuntimeError("Published update differs from this release build")
        updates.promote_feed(github, verified, verifier)
        print(release["html_url"])
    except Exception as error:
        if published:
            raise RuntimeError(str(error) + f". The release is published; the feed may still be unchanged. Resume safely with: python3 scripts/publish_release.py --repo {args.repo} --resume-feed --tag {tag}") from error
        raise
    finally:
        verifier.close()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, KeyError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print("Release not completed: " + str(error), file=sys.stderr)
        raise SystemExit(1)
