#!/bin/bash
set -euo pipefail

# Developer-only toolchain. The distributed app includes its Rust executable.
# Official manual installer/checksum: https://rust-lang.github.io/rustup/installation/other.html
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN="${POSLE_RUST_TOOLCHAIN:-stable}"
export CARGO_HOME="${POSLE_CARGO_HOME:-$PROJECT/.toolchain/cargo}"
export RUSTUP_HOME="${POSLE_RUSTUP_HOME:-$PROJECT/.toolchain/rustup}"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "Этот установщик предназначен для macOS на Apple Silicon." >&2
    exit 1
fi
for utility in curl shasum awk mktemp; do
    if ! command -v "$utility" >/dev/null 2>&1; then
        echo "Не найдена необходимая команда: $utility" >&2
        exit 1
    fi
done

INSTALL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/posle-rustup.XXXXXX")"
trap 'rm -rf "$INSTALL_DIR"' EXIT
INSTALLER_URL="https://static.rust-lang.org/rustup/dist/aarch64-apple-darwin/rustup-init"
echo "Загружаю официальный rustup-init для Apple Silicon…"
curl --proto '=https' --tlsv1.2 --fail --location --show-error --silent \
    "$INSTALLER_URL" -o "$INSTALL_DIR/rustup-init"
curl --proto '=https' --tlsv1.2 --fail --location --show-error --silent \
    "$INSTALLER_URL.sha256" -o "$INSTALL_DIR/rustup-init.sha256"
EXPECTED_SHA="$(awk 'NR == 1 { print $1 }' "$INSTALL_DIR/rustup-init.sha256")"
ACTUAL_SHA="$(shasum -a 256 "$INSTALL_DIR/rustup-init" | awk '{ print $1 }')"
if [[ ! "$EXPECTED_SHA" =~ ^[[:xdigit:]]{64}$ || "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
    echo "Проверка SHA-256 rustup-init не прошла. Установка остановлена." >&2
    exit 1
fi
chmod +x "$INSTALL_DIR/rustup-init"
"$INSTALL_DIR/rustup-init" -y --profile minimal --no-modify-path \
    --default-host aarch64-apple-darwin --default-toolchain "$TOOLCHAIN"

echo "Rust установлен в $CARGO_HOME и $RUSTUP_HOME."
echo "Профили shell и системные каталоги не изменялись."
echo "Для сборки приложения: scripts/build.sh"
if [[ -n "${POSLE_CARGO_HOME:-}" || -n "${POSLE_RUSTUP_HOME:-}" ]]; then
    echo "При сборке передайте те же POSLE_CARGO_HOME и POSLE_RUSTUP_HOME."
fi
