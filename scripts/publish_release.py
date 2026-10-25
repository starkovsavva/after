#!/usr/bin/env python3
"""Build and publish a private GitHub release that always includes the Mac app.

Developer helper; no scheduler, daemon, CI runner, or model installation.
"""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
ASSETS = ("Posle-Mac-AppleSilicon.zip", "Posle-Source.zip", "SHA256SUMS")


def run(arguments, capture=False):
    result = subprocess.run(arguments, cwd=PROJECT, text=True, capture_output=capture, check=True)
    return result.stdout.strip() if capture else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="starkovsavva/posle")
    parser.add_argument("--notes-file", type=Path, required=True)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--check-only", action="store_true", help="Verify local release files; do not contact GitHub or publish")
    parser.add_argument("--stable", action="store_true", help="Mark the release as stable instead of a prerelease")
    args = parser.parse_args()
    if not args.notes_file.is_file():
        raise RuntimeError("Provide an existing release notes file")
    if run(["git", "status", "--porcelain"], capture=True):
        raise RuntimeError("Commit the release sources before packaging them")
    revision = run(["git", "rev-parse", "HEAD"], capture=True)
    with (PROJECT / "packaging/Info.plist").open("rb") as stream:
        version = plistlib.load(stream)["CFBundleShortVersionString"]
    tag = "v" + version
    if not args.skip_build and not args.check_only:
        run(["bash", "scripts/build.sh"])
    app = PROJECT / "dist/После.app"
    with (app / "Contents/Info.plist").open("rb") as stream:
        if plistlib.load(stream)["CFBundleShortVersionString"] != version:
            raise RuntimeError("The app bundle is from another version; rebuild it")
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    # Always package the verified bundle; a previous valid ZIP may be stale.
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app),
         str(PROJECT / "dist/Posle-Mac-AppleSilicon.zip")])
    run(["git", "archive", "--format=zip", "--prefix=posle/", "--output=dist/Posle-Source.zip", revision])
    for name in ASSETS[:2]:
        with zipfile.ZipFile(PROJECT / "dist" / name) as archive:
            if archive.testzip() is not None:
                raise RuntimeError("Damaged archive: " + name)
    sums = "".join(hashlib.sha256((PROJECT / "dist" / name).read_bytes()).hexdigest() + "  " + name + "\n" for name in ASSETS[:2])
    (PROJECT / "dist/SHA256SUMS").write_text(sums)
    if args.check_only:
        print(json.dumps({"tag": tag, "revision": revision, "assets": ASSETS, "ready": True}))
        return
    gh = shutil.which("gh") or str(PROJECT / ".toolchain/github/gh")
    if not Path(gh).is_file():
        raise RuntimeError("Install the official GitHub CLI and run gh auth login")

    def api(endpoint):
        return json.loads(run([gh, "api", endpoint], capture=True))

    def release_for_tag():
        # GitHub's releases/tags endpoint can return 404 for drafts without a
        # Git tag. Authenticated release listings include those drafts by ID.
        page = 1
        while True:
            releases = api("repos/" + args.repo + "/releases?per_page=100&page=" + str(page))
            for candidate in releases:
                if candidate["tag_name"] == tag:
                    return candidate
            if len(releases) < 100:
                return None
            page += 1

    repo = api("repos/" + args.repo)
    if not repo["private"]:
        raise RuntimeError("This personal project's release helper expects a private repository")
    remote_revision = api("repos/" + args.repo + "/commits/main")["sha"]
    if remote_revision != revision:
        raise RuntimeError("Push the release commit to main before publishing")
    existing_tag = subprocess.run([gh, "api", "repos/" + args.repo + "/git/ref/tags/" + tag], cwd=PROJECT, text=True, capture_output=True)
    if existing_tag.returncode == 0 and json.loads(existing_tag.stdout)["object"]["sha"] != revision:
        raise RuntimeError("The existing version tag points to different sources; choose a new version")
    if existing_tag.returncode != 0 and "404" not in existing_tag.stderr:
        raise RuntimeError("Could not inspect the version tag: " + existing_tag.stderr)
    release = release_for_tag()
    if release is not None:
        if not release["draft"]:
            raise RuntimeError("This version is already published; choose a new version")
        run([gh, "release", "edit", tag, "--repo", args.repo, "--target", revision,
             "--title", "После " + version, "--notes-file", str(args.notes_file.resolve())])
        run([gh, "release", "upload", tag, *[str(PROJECT / "dist" / name) for name in ASSETS], "--repo", args.repo, "--clobber"])
    else:
        run([gh, "release", "create", tag, *[str(PROJECT / "dist" / name) for name in ASSETS],
             "--repo", args.repo, "--draft", "--target", revision, "--title", "После " + version,
             "--notes-file", str(args.notes_file.resolve())])
    release = release_for_tag()
    if release is None:
        raise RuntimeError("GitHub did not return the prepared draft release")
    uploaded = {asset["name"]: asset for asset in release["assets"]}
    for name in ASSETS:
        local = PROJECT / "dist" / name
        asset = uploaded.get(name, {})
        expected = "sha256:" + hashlib.sha256(local.read_bytes()).hexdigest()
        if asset.get("state") != "uploaded" or asset.get("size") != local.stat().st_size or asset.get("digest") != expected:
            raise RuntimeError("Uploaded asset verification failed; release remains a draft: " + name)
    run([gh, "release", "edit", tag, "--repo", args.repo, "--draft=false",
         "--prerelease=" + str(not args.stable).lower(), "--latest=" + str(args.stable).lower()])
    release = api("repos/" + args.repo + "/releases/" + str(release["id"]))
    if release["draft"]:
        raise RuntimeError("GitHub did not confirm publication")
    tag_info = api("repos/" + args.repo + "/git/ref/tags/" + tag)
    if tag_info["object"]["sha"] != revision:
        raise RuntimeError("The release tag does not match the packaged source revision")
    print(release["html_url"])


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as exc:
        print("Release not completed: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
