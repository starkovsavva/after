#!/bin/bash
# Self-contained runtime; no Homebrew, administrator access, or shell profile changes.
set -euo pipefail
ROOT="${1:?Specify the application support directory}"
HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="${2:-}"
umask 077
mkdir -p "$ROOT/runtime" "$ROOT/cache"
if [ "$(uname -m)" != arm64 ]; then
  echo 'После требует Mac с Apple Silicon.' >&2
  exit 1
fi
export UV_CACHE_DIR="$ROOT/cache/uv"
export UV_PYTHON_INSTALL_DIR="$ROOT/runtime/python"
export UV_PYTHON_BIN_DIR="$ROOT/runtime/bin"
export UV_NO_MODIFY_PATH=1
export UV_LINK_MODE=copy
UV="$ROOT/runtime/uv"
if [ ! -x "$UV" ]; then
  echo 'Загружаю среду для моделей…'
  VERSION=0.9.7
  ASSET=uv-aarch64-apple-darwin.tar.gz
  BASE="https://github.com/astral-sh/uv/releases/download/$VERSION"
  /usr/bin/curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$BASE/$ASSET" -o "$ROOT/runtime/$ASSET"
  /usr/bin/curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$BASE/$ASSET.sha256" -o "$ROOT/runtime/$ASSET.sha256"
  (cd "$ROOT/runtime" && /usr/bin/shasum -a 256 -c "$ASSET.sha256")
  /usr/bin/tar -xzf "$ROOT/runtime/$ASSET" -C "$ROOT/runtime" --strip-components=1 uv-aarch64-apple-darwin/uv
fi
echo 'Устанавливаю Python и распознавание речи…'
"$UV" venv --python 3.12 --python-preference only-managed "$ROOT/runtime/venv" --allow-existing
"$UV" pip install --python "$ROOT/runtime/venv/bin/python" -r "$HERE/requirements.txt"
export PATH="$ROOT/runtime/venv/bin:$PATH"
echo 'Проверяю скачанные модели Parakeet и готовлю разделение собеседников…'
export HF_HOME="$ROOT/cache/huggingface"
export HF_HUB_DISABLE_TELEMETRY=1
if [[ -n "$HOST" && -x "$HOST" ]]; then
  "$HOST" --posle-python-host "$ROOT/runtime/venv/bin/python" "$HERE/engine.py" prepare --root "$ROOT"
else
  "$ROOT/runtime/venv/bin/python" -B -u -E -s "$HERE/engine.py" prepare --root "$ROOT"
fi
touch "$ROOT/runtime/ready-v2"
echo 'Готово. Можно добавить первую встречу.'
