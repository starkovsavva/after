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
app, source, component, version_file = map(Path, sys.argv[1:])
with (app / "Contents/Info.plist").open("rb") as stream:
    actual = plistlib.load(stream)
with source.open("rb") as stream:
    expected = plistlib.load(stream)
identifier = "app.posle.meetings"
if actual.get("CFBundleIdentifier") != identifier or expected.get("CFBundleIdentifier") != identifier:
    raise SystemExit("The app identifier must remain app.posle.meetings across updates")
for key in ("CFBundleShortVersionString", "CFBundleVersion"):
    if actual.get(key) != expected.get(key):
        raise SystemExit("The app bundle is from another version; rebuild it")
version = actual["CFBundleShortVersionString"]
if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version):
    raise SystemExit("The installer version must have two or three numeric components")
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
# Launch Services can attach Finder metadata after a local preview run. Strip
# attributes only from our disposable copy, so pkgbuild cannot synthesize an
# AppleDouble file beside the app in /Applications.
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
python3 - "$STAGING" "$VERSION" <<'PYVERIFY'
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
for line in (staging / "payload-files").read_text().splitlines():
    name = unicodedata.normalize("NFC", line)
    path = PurePosixPath(name)
    parts = tuple(part for part in path.parts if part != ".")
    if name in (".", "./"):
        continue
    if name.startswith("/") or ".." in parts or not parts or parts[0] != "После.app":
        raise SystemExit("Installer payload escapes the application: " + name)
print("Verified: /Applications/После.app; nonrelocatable; no install scripts or user data")
PYVERIFY
# Produce both files from exactly the verified bundle, even after --skip-build.
# Rename only completed artifacts so a failed packaging command preserves them.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/Posle-Mac-AppleSilicon.zip"
mv -f "$STAGING/Posle-Mac-AppleSilicon.pkg" "$PROJECT/dist/Posle-Mac-AppleSilicon.pkg"
mv -f "$STAGING/Posle-Mac-AppleSilicon.zip" "$PROJECT/dist/Posle-Mac-AppleSilicon.zip"
echo "Готово: $PROJECT/dist/Posle-Mac-AppleSilicon.pkg"
