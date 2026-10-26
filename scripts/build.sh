#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${POSLE_BUILD_DIR:-$PROJECT/.build}"
cd "$PROJECT"
SOURCE_REVISION="$(git rev-parse --verify HEAD)"
mkdir -p "$PROJECT/dist"
STAGING="$(mktemp -d "$PROJECT/dist/.posle-build.XXXXXX")"
APP="$STAGING/После.app"
trap 'rm -rf "$STAGING"' EXIT

# Rust is required only on the developer's machine; users run the bundled binary.
if [[ -n "${POSLE_CARGO_HOME:-}" ]]; then
    export CARGO_HOME="$POSLE_CARGO_HOME"
    CARGO="$CARGO_HOME/bin/cargo"
    if [[ ! -x "$CARGO" ]]; then
        echo "Не найден Cargo: $CARGO. Выполните scripts/setup-rust.sh с тем же POSLE_CARGO_HOME." >&2
        exit 1
    fi
    export RUSTUP_HOME="${POSLE_RUSTUP_HOME:-${RUSTUP_HOME:-$PROJECT/.toolchain/rustup}}"
elif command -v cargo >/dev/null 2>&1; then
    CARGO="$(command -v cargo)"
    if [[ -n "${POSLE_RUSTUP_HOME:-}" ]]; then
        export RUSTUP_HOME="$POSLE_RUSTUP_HOME"
    fi
elif [[ -x "$PROJECT/.toolchain/cargo/bin/cargo" ]]; then
    export CARGO_HOME="$PROJECT/.toolchain/cargo"
    export RUSTUP_HOME="${POSLE_RUSTUP_HOME:-$PROJECT/.toolchain/rustup}"
    CARGO="$CARGO_HOME/bin/cargo"
else
    echo "Не найден Cargo. Выполните scripts/setup-rust.sh или укажите POSLE_CARGO_HOME с установленным Cargo." >&2
    exit 1
fi
export PATH="$(dirname "$CARGO"):$PATH"
RUST_BUILD="${POSLE_RUST_TARGET_DIR:-$BUILD/rust}"
if [[ "$(uname -m)" == "arm64" ]]; then
    "$CARGO" build --manifest-path "$PROJECT/rust-core/Cargo.toml" \
        --release --locked --target-dir "$RUST_BUILD"
    RUST_RELEASE="$RUST_BUILD/release"
else
    "$CARGO" build --manifest-path "$PROJECT/rust-core/Cargo.toml" \
        --release --locked --target aarch64-apple-darwin --target-dir "$RUST_BUILD"
    RUST_RELEASE="$RUST_BUILD/aarch64-apple-darwin/release"
fi
swift build --scratch-path "$BUILD" -c release --disable-automatic-resolution
SWIFT_BIN="$(swift build --scratch-path "$BUILD" -c release --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/backend"
cp "$SWIFT_BIN/Posle" "$APP/Contents/MacOS/Posle"
cp "$RUST_RELEASE/posle-engine" "$APP/Contents/MacOS/posle-engine"
# Helpers are real native processes. The speech helper embeds the private
# CPython runtime in-process; it never execs a Python interpreter.
python3 - "$APP" "$RUST_RELEASE/posle-engine" "$PROJECT/packaging/Info.plist" <<'PYHELPERS'
import plistlib, shutil, sys
from pathlib import Path
app, engine, version_file = map(Path, sys.argv[1:])
with version_file.open("rb") as stream: version = plistlib.load(stream)
for title, executable, identifier in [
    ("После Распознавание", "После Речь", "app.posle.meetings.speech"),
    ("После Обработка", "После Обработка", "app.posle.meetings.processing"),
]:
    helper = app / "Contents/Helpers" / (title + ".app") / "Contents"
    (helper / "MacOS").mkdir(parents=True, exist_ok=True)
    shutil.copy2(engine, helper / "MacOS" / executable)
    with (helper / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleName": title, "CFBundleDisplayName": title,
                      "CFBundleExecutable": executable, "CFBundleIdentifier": identifier,
                      "CFBundlePackageType": "APPL", "CFBundleVersion": version["CFBundleVersion"],
                      "CFBundleShortVersionString": version["CFBundleShortVersionString"], "LSBackgroundOnly": True,
                      "LSMinimumSystemVersion": "15.0"}, stream, sort_keys=False)
PYHELPERS
cp "$RUST_RELEASE/libposle_core.dylib" "$APP/Contents/Frameworks/libposle_core.dylib"
# The checkout identity is embedded in the signed app, so release tooling can
# reject a stale bundle built from another commit.
python3 - "$PROJECT/packaging/Info.plist" "$APP/Contents/Info.plist" "$SOURCE_REVISION" <<'PYINFO'
import plistlib, re, sys
from pathlib import Path
source, destination = map(Path, sys.argv[1:3])
revision = sys.argv[3]
if not re.fullmatch(r"[0-9a-f]{40}", revision):
    raise SystemExit("Invalid source revision")
with source.open("rb") as stream:
    info = plistlib.load(stream)
info["PosleSourceRevision"] = revision
with destination.open("wb") as stream:
    plistlib.dump(info, stream, sort_keys=False)
PYINFO
# SwiftPM's build products contain the selected framework slice. ditto keeps
# its versioned symlinks and upstream signatures, including Sparkle's helpers.
SPARKLE="$SWIFT_BIN/Sparkle.framework"
if [[ ! -d "$SPARKLE" ]]; then
    echo "Не найден framework Sparkle в продуктах SwiftPM: $SPARKLE" >&2
    exit 1
fi
codesign --verify --deep --strict "$SPARKLE"
ditto --noextattr --norsrc --noqtn "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --verify --deep --strict "$APP/Contents/Frameworks/Sparkle.framework"
cp "$PROJECT/backend/engine.py" "$PROJECT/backend/models.py" "$PROJECT/backend/media_runtime.py" "$PROJECT/backend/cloud_speech.py" "$PROJECT/backend/embedded_bridge.py" "$PROJECT/backend/setup.sh" "$PROJECT/backend/requirements.txt" "$APP/Contents/Resources/backend/"
cp "$PROJECT/THIRD_PARTY.md" "$APP/Contents/Resources/THIRD_PARTY.md"
swift "$PROJECT/scripts/icon.swift" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
install_name_tool -id @rpath/libposle_core.dylib "$APP/Contents/Frameworks/libposle_core.dylib"
codesign --force --sign - "$APP/Contents/Frameworks/libposle_core.dylib"
codesign --force --sign - "$APP/Contents/MacOS/posle-engine"
codesign --force --sign - "$APP/Contents/Helpers/После Распознавание.app"
codesign --force --sign - "$APP/Contents/Helpers/После Обработка.app"
codesign --force --sign - --entitlements "$PROJECT/packaging/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
if [[ "$(git rev-parse --verify HEAD)" != "$SOURCE_REVISION" ]]; then
    echo "Исходный коммит изменился во время сборки; повторите сборку." >&2
    exit 1
fi
# Publish only a complete verified bundle. On macOS RENAME_SWAP atomically
# exchanges two existing directories on the same volume; the old bundle stays
# in our disposable staging folder until cleanup.
python3 - "$APP" "$PROJECT/dist/После.app" <<'PYPUBLISH'
import ctypes, os, sys
from pathlib import Path
source, destination = map(Path, sys.argv[1:])
if source.is_symlink() or not source.is_dir() or destination.is_symlink():
    raise SystemExit("Expected regular application bundle paths")
if not destination.exists():
    os.rename(source, destination)
else:
    if not destination.is_dir():
        raise SystemExit("Application destination is not a directory")
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    renamex = library.renameatx_np
    renamex.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renamex.restype = ctypes.c_int
    if renamex(-2, os.fsencode(source), -2, os.fsencode(destination), 0x00000002) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))
PYPUBLISH
APP="$PROJECT/dist/После.app"
bash "$PROJECT/scripts/package.sh"
echo "Готово: $APP"
