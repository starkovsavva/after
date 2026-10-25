#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${POSLE_BUILD_DIR:-$PROJECT/.build}"
APP="$PROJECT/dist/После.app"
cd "$PROJECT"

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
swift build --scratch-path "$BUILD" -c release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/backend"
cp "$BUILD/release/Posle" "$APP/Contents/MacOS/Posle"
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
cp "$PROJECT/packaging/Info.plist" "$APP/Contents/Info.plist"
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
bash "$PROJECT/scripts/package.sh"
echo "Готово: $APP"
