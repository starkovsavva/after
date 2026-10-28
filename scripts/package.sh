#!/bin/bash
# Package the verified app as both a ZIP and a normal in-place Mac installer.
# There are no install scripts: the payload is only /Applications/После.app.
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJECT/dist/После.app"
STAGING="$(mktemp -d "${TMPDIR:-/private/tmp}/posle-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cd "$PROJECT"

codesign --verify --deep --strict "$APP"
python3 - "$APP" "$PROJECT/packaging/Info.plist" "$STAGING/components.plist" "$STAGING/version" <<'PYINFO'
import plistlib
import re
import sys
from pathlib import Path
sys.path.insert(0, str(Path.cwd() / "scripts"))
from update_feed import product_version
app, source, component, version_file = map(Path, sys.argv[1:])
with (app / "Contents/Info.plist").open("rb") as stream:
    actual = plistlib.load(stream)
with source.open("rb") as stream:
    expected = plistlib.load(stream)
identifier = "app.posle.meetings"
if actual.get("CFBundleIdentifier") != identifier or expected.get("CFBundleIdentifier") != identifier:
    raise SystemExit("The app identifier must remain app.posle.meetings across updates")
for key in ("CFBundleShortVersionString", "CFBundleVersion", "PosleProductVersion"):
    if actual.get(key) != expected.get(key):
        raise SystemExit("The app bundle is from another version; rebuild it")
product_version(actual)
product_version(expected)
# Receipts use the monotonic build number, including hotfixes sharing a bundle
# short version. Sparkle and the installer therefore agree on upgrade ordering.
version = actual["CFBundleVersion"]
if not isinstance(version, str) or not re.fullmatch(r"[1-9][0-9]*", version):
    raise SystemExit("The installer version must be a strictly positive integer build number")
if app.is_symlink() or not app.is_dir():
    raise SystemExit("Expected a regular app bundle")
# Use pkgbuild's documented 'upgrade' action: replace the complete old bundle
# atomically, including removal of obsolete bundled files. Never relocate by ID
# to an arbitrary Downloads copy. Version checking prevents an accidental downgrade.
with component.open("wb") as stream:
    plistlib.dump([{
        "RootRelativeBundlePath": "После.app",
        "BundleIsRelocatable": False,
        "BundleIsVersionChecked": True,
        "BundleHasStrictIdentifier": True,
        "BundleOverwriteAction": "upgrade",
    }], stream)
version_file.write_text(version)
PYINFO
VERSION="$(cat "$STAGING/version")"
mkdir "$STAGING/root"
ditto --noextattr --norsrc --noqtn "$APP" "$STAGING/root/После.app"
# Strip removable metadata only from our disposable copy. macOS may retain
# protected provenance, which pkgbuild serializes as AppleDouble metadata. The
# verifier below checks these companions and the fully extracted logical payload.
xattr -cr "$STAGING/root"
codesign --verify --deep --strict "$STAGING/root/После.app"
pkgbuild --root "$STAGING/root" --component-plist "$STAGING/components.plist" \
    --identifier app.posle.meetings.pkg --version "$VERSION" \
    --install-location /Applications --ownership recommended \
    "$STAGING/Posle-Mac-AppleSilicon.pkg"
# Inspect, never install: publication must fail if another payload or install
# script accidentally makes its way into this personal app package.
pkgutil --expand "$STAGING/Posle-Mac-AppleSilicon.pkg" "$STAGING/expanded"
pkgutil --payload-files "$STAGING/Posle-Mac-AppleSilicon.pkg" > "$STAGING/payload-files"
pkgutil --expand-full "$STAGING/Posle-Mac-AppleSilicon.pkg" "$STAGING/expanded-full"
python3 - "$STAGING" "$VERSION" <<'PYVERIFY'
import hashlib
import os
import struct
import subprocess
import sys
import unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath
staging, version = Path(sys.argv[1]), sys.argv[2]
package = ET.parse(staging / "expanded/PackageInfo").getroot()
if (package.get("identifier"), package.get("version"), package.get("install-location")) != (
    "app.posle.meetings.pkg", version, "/Applications"
):
    raise SystemExit("Unexpected installer identity, version or destination")
if (staging / "expanded/Scripts").exists() or package.find("scripts") is not None:
    raise SystemExit("This installer must contain no installation scripts")
if package.get("relocatable") != "false" or len(package.findall("relocate/bundle")) != 0:
    raise SystemExit("Application relocation must stay disabled")
bundles = package.findall("bundle")
if len(bundles) != 1 or bundles[0].get("id") != "app.posle.meetings" or bundles[0].get("path") != "./После.app":
    raise SystemExit("Unexpected app bundle in installer")
for policy in ("upgrade-bundle", "strict-identifier", "bundle-version"):
    entries = package.findall(policy + "/bundle")
    if len(entries) != 1 or entries[0].get("id") != "app.posle.meetings":
        raise SystemExit("Missing installer upgrade policy: " + policy)
metadata_companions = 0
for line in (staging / "payload-files").read_text().splitlines():
    name = unicodedata.normalize("NFC", line)
    path = PurePosixPath(name)
    parts = tuple(part for part in path.parts if part != ".")
    if name in (".", "./"):
        continue
    if name.startswith("/") or ".." in parts or not parts:
        raise SystemExit("Installer payload escapes the application: " + name)
    if parts[-1].startswith("._"):
        # pkgutil lists serialized xattrs as AppleDouble entries, including a
        # root ._После.app companion. They are merged into the real app during
        # extraction/installation, not installed as neighboring user files.
        companion = (*parts[:-1], parts[-1][2:])
        if (not companion[-1] or companion[0] != "После.app"
                or any(part.startswith("._") for part in companion)
                or not staging.joinpath("root", *companion).exists()):
            raise SystemExit("Unexpected metadata companion: " + name)
        raw = subprocess.check_output(["tar", "-xOf", str(staging / "expanded/Payload"), "--", line])
        if len(raw) < 26:
            raise SystemExit("Truncated AppleDouble metadata: " + name)
        magic, format_version, _, count = struct.unpack(">II16sH", raw[:26])
        if magic != 0x00051607 or format_version != 0x00020000 or not 1 <= count <= 16 or len(raw) < 26 + 12 * count:
            raise SystemExit("Invalid AppleDouble metadata: " + name)
        entries = [struct.unpack(">III", raw[26 + 12*i:38 + 12*i]) for i in range(count)]
        if (len({entry[0] for entry in entries}) != count
                or not any(entry[0] == 9 for entry in entries)
                or any(kind not in (2, 9) or offset < 26 + 12*count or offset + size > len(raw)
                       or (kind == 2 and size != 0) for kind, offset, size in entries)):
            raise SystemExit("Unexpected AppleDouble entry or resource data: " + name)
        metadata_companions += 1
        continue
    if parts[0] != "После.app":
        raise SystemExit("Installer payload escapes the application: " + name)

# Verify the same extraction path macOS provides for flat installer packages.
# All metadata companions must disappear into xattrs; the sole installed path
# is the app, with identical normal files and no scripts or user-data folders.
logical = staging / "expanded-full/Payload"
if {child.name for child in logical.iterdir()} != {"После.app"}:
    raise SystemExit("Extracted installer contains a path outside the app")
def contents(root):
    result = {}
    for item in root.rglob("*"):
        relative = unicodedata.normalize("NFC", str(item.relative_to(root)))
        if any(part.startswith("._") for part in Path(relative).parts):
            raise SystemExit("A metadata companion became an installed file: " + relative)
        if item.is_symlink():
            value = ("link", os.readlink(item))
        elif item.is_file():
            value = ("file", hashlib.sha256(item.read_bytes()).hexdigest(), item.stat().st_mode & 0o777)
        elif item.is_dir():
            value = ("directory",)
        else:
            raise SystemExit("Unexpected installer file type: " + relative)
        result[relative] = value
    return result
if contents(staging / "root") != contents(logical):
    raise SystemExit("Installer extraction differs from the verified app")
print(f"Verified: /Applications/После.app; {metadata_companions} validated metadata companions; no extra installed files or scripts")
PYVERIFY
codesign --verify --deep --strict "$STAGING/expanded-full/Payload/После.app"
# Produce both files from exactly the verified bundle, even after --skip-build.
# Rename only completed artifacts so a failed packaging command preserves them.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/Posle-Mac-AppleSilicon.zip"
mv -f "$STAGING/Posle-Mac-AppleSilicon.pkg" "$PROJECT/dist/Posle-Mac-AppleSilicon.pkg"
mv -f "$STAGING/Posle-Mac-AppleSilicon.zip" "$PROJECT/dist/Posle-Mac-AppleSilicon.zip"
echo "Готово: $PROJECT/dist/Posle-Mac-AppleSilicon.pkg"
