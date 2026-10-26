#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/posle-check.XXXXXX")"
swiftc -parse-as-library "$PROJECT/Sources/PosleCore/"*.swift "$PROJECT/Tests/CoreChecks.swift" -o "$CHECK_DIR/core-checks"
"$CHECK_DIR/core-checks"
swiftc -parse-as-library "$PROJECT/Sources/PosleCore/"*.swift "$PROJECT/Tests/CalendarLayoutChecks.swift" -o "$CHECK_DIR/calendar-checks"
"$CHECK_DIR/calendar-checks"
PYTHON="${POSLE_PYTHON:-$HOME/Library/Application Support/Posle/runtime/venv/bin/python}"
"$PYTHON" -m unittest discover -s "$PROJECT/backend" -v
python3 -m unittest discover -s "$PROJECT/scripts" -p "test_*.py" -v

if [[ -n "${POSLE_CARGO_HOME:-}" ]]; then
    export CARGO_HOME="$POSLE_CARGO_HOME"
    export RUSTUP_HOME="${POSLE_RUSTUP_HOME:-$PROJECT/.toolchain/rustup}"
    CARGO="$CARGO_HOME/bin/cargo"
elif command -v cargo >/dev/null 2>&1; then
    CARGO="$(command -v cargo)"
elif [[ -x "$PROJECT/.toolchain/cargo/bin/cargo" ]]; then
    export CARGO_HOME="$PROJECT/.toolchain/cargo"
    export RUSTUP_HOME="$PROJECT/.toolchain/rustup"
    CARGO="$CARGO_HOME/bin/cargo"
else
    echo "Не найден Cargo. Выполните scripts/setup-rust.sh." >&2
    exit 1
fi
"$CARGO" test --manifest-path "$PROJECT/rust-core/Cargo.toml" --locked \
    --target-dir "${POSLE_RUST_TARGET_DIR:-$PROJECT/.build/rust}"
