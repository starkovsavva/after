#!/bin/bash
# The signed app supplies the policy and native verifier; no existing interpreter
# or package installer is executed until the pinned CPython tree is verified.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077
ROOT="${1:?Specify the application support directory}"
HERE="$(cd "$(dirname "$0")" && pwd -P)"
HOST="${2:-}"
fail() { echo "$*" >&2; exit 1; }
case "$ROOT" in /*) ;; *) fail 'Нужен абсолютный путь папки данных После.' ;; esac
case "$HOST" in /*) ;; *) fail 'Не найден встроенный проверяющий движок. Переустановите После.' ;; esac
[[ -x "$HOST" && ! -L "$HOST" && -f "$HOST" ]] || fail 'Не найден встроенный проверяющий движок. Переустановите После.'
[[ "$(/usr/bin/uname -m)" == arm64 ]] || fail 'После требует Mac с Apple Silicon.'

owned_directory() {
  local path="$1" mode
  [[ ! -L "$path" ]] || fail 'Папка компонентов не должна быть символической ссылкой.'
  if [[ ! -e "$path" ]]; then /bin/mkdir -m 700 "$path"; fi
  [[ -d "$path" && "$(/usr/bin/stat -f %u "$path")" == "$(/usr/bin/id -u)" ]] || fail 'Папка компонентов должна принадлежать текущему пользователю.'
  mode="$(/usr/bin/stat -f %OLp "$path")"
  [[ "$((8#$mode & 0022))" == 0 ]] || fail 'Папка компонентов доступна для изменения другим пользователям.'
}
[[ ! -L "$ROOT" ]] || fail 'Папка данных не должна быть символической ссылкой.'
/bin/mkdir -p -m 700 "$ROOT"
ROOT="$(cd "$ROOT" && pwd -P)"
owned_directory "$ROOT"
RUNTIME="$ROOT/runtime"
owned_directory "$RUNTIME"
owned_directory "$ROOT/cache"
owned_directory "$ROOT/cache/pip"
owned_directory "$RUNTIME/python"
# The stable lock survives processes; flock is released even after a hard stop.
LOCK="$RUNTIME/.python-setup.lock"
if [[ ! -e "$LOCK" && ! -L "$LOCK" ]]; then (set -C; : > "$LOCK") 2>/dev/null || true; fi
[[ -f "$LOCK" && ! -L "$LOCK" && "$(/usr/bin/stat -f %u "$LOCK")" == "$(/usr/bin/id -u)" ]] || fail 'Не удалось заблокировать подготовку компонентов.'
exec 9<>"$LOCK"
/usr/bin/lockf -s -t 0 9 || fail 'Компоненты уже подготавливаются в другом окне После.'

POLICY="$HERE/python-runtime.json"
[[ -f "$POLICY" && ! -L "$POLICY" ]] || fail 'В приложении отсутствует описание среды Python. Переустановите После.'
PYTHON_DIRECTORY="$(/usr/bin/plutil -extract directory raw -o - "$POLICY")"
ARCHIVE_URL="$(/usr/bin/plutil -extract archive_url raw -o - "$POLICY")"
ARCHIVE_SHA="$(/usr/bin/plutil -extract archive_sha256 raw -o - "$POLICY")"
ARCHIVE_SIZE="$(/usr/bin/plutil -extract archive_size raw -o - "$POLICY")"
case "$PYTHON_DIRECTORY" in ''|*[!a-zA-Z0-9.+_-]*) fail 'Некорректное описание среды Python.' ;; esac
case "$ARCHIVE_SHA" in ''|*[!0-9a-f]*) fail 'Некорректная контрольная сумма среды Python.' ;; esac
[[ "${#ARCHIVE_SHA}" == 64 ]] || fail 'Некорректная контрольная сумма среды Python.'
case "$ARCHIVE_SIZE" in ''|*[!0-9]*) fail 'Некорректный размер среды Python.' ;; esac
case "$ARCHIVE_URL" in https://github.com/astral-sh/python-build-standalone/releases/download/*) ;; *) fail 'Некорректный адрес среды Python.' ;; esac
BASE="$RUNTIME/python/$PYTHON_DIRECTORY"
VENV="$RUNTIME/venv"
[[ ! -L "$BASE" && ! -L "$VENV" ]] || fail 'Среда распознавания не должна быть символической ссылкой.'
if [[ -e "$BASE" ]]; then owned_directory "$BASE"; fi
if [[ -e "$VENV" ]]; then owned_directory "$VENV"; fi

WORK="$(/usr/bin/mktemp -d "$RUNTIME/.python-setup.XXXXXX")"
BASE_CHANGED=0
VENV_CHANGED=0
HAD_BASE=0
HAD_VENV=0
COMMITTED=0
# Do not follow links while making a verified read-only tree removable.
remove_tree() {
  [[ ! -L "$1" ]] || { /bin/rm -f "$1"; return; }
  if [[ -d "$1" ]]; then /usr/bin/find "$1" -type d -exec /bin/chmod u+w {} +; fi
  /bin/rm -rf "$1"
}
cleanup() {
  local status="$?"
  trap - EXIT INT TERM
  if [[ "$COMMITTED" != 1 ]]; then
    /bin/rm -f "$RUNTIME/ready-v2"
    if [[ "$VENV_CHANGED" == 1 ]]; then
      if [[ -d "$WORK/previous-venv" ]]; then
        remove_tree "$VENV"; /bin/mv "$WORK/previous-venv" "$VENV"
      elif [[ "$HAD_VENV" == 0 ]]; then remove_tree "$VENV"; fi
    fi
    if [[ "$BASE_CHANGED" == 1 ]]; then
      if [[ -d "$WORK/previous-python" ]]; then
        remove_tree "$BASE"; /bin/mv "$WORK/previous-python" "$BASE"
      elif [[ "$HAD_BASE" == 0 ]]; then remove_tree "$BASE"; fi
    fi
  fi
  remove_tree "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/bin/rm -f "$RUNTIME/ready-v2"

if [[ ! -d "$BASE" ]] || ! "$HOST" --posle-verify-python-runtime "$BASE" 2>/dev/null; then
  echo 'Загружаю проверенную среду распознавания…'
  ARCHIVE="$WORK/python.tar.gz"
  /usr/bin/curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' --tlsv1.2 "$ARCHIVE_URL" -o "$ARCHIVE"
  [[ "$(/usr/bin/stat -f %z "$ARCHIVE")" == "$ARCHIVE_SIZE" ]] || fail 'Размер среды Python не совпал. Повторите подготовку.'
  [[ "$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')" == "$ARCHIVE_SHA" ]] || fail 'Проверка среды Python не прошла. Повторите подготовку.'
  /bin/mkdir -m 700 "$WORK/extracted"
  # The archive has already passed its pinned digest. Keep libarchive's default
  # protections against absolute paths, parent traversal and symlink traversal.
  /usr/bin/tar -xzf "$ARCHIVE" -C "$WORK/extracted" --no-same-owner --no-same-permissions
  "$HOST" --posle-verify-python-runtime "$WORK/extracted/python"
  /usr/bin/find "$WORK/extracted/python" -type f -exec /bin/chmod a-w {} +
  /usr/bin/find "$WORK/extracted/python" -mindepth 1 -type d -exec /bin/chmod a-w {} +
  # Existing runtimes remain available for rollback until the complete setup
  # succeeds. Publishing never merges new files into an older Python tree.
  if [[ -e "$BASE" ]]; then HAD_BASE=1; fi
  BASE_CHANGED=1
  if [[ "$HAD_BASE" == 1 ]]; then
    /bin/chmod u+w "$BASE" # macOS needs write access to update a moved directory's parent.
    /bin/mv "$BASE" "$WORK/previous-python"
  fi
  /bin/mv "$WORK/extracted/python" "$BASE"
fi
"$HOST" --posle-verify-python-runtime "$BASE"
/usr/bin/find "$BASE" -type f -exec /bin/chmod a-w {} +
/usr/bin/find "$BASE" -type d -exec /bin/chmod a-w {} +

# Always build from the verified base, never run the old venv (or an old uv).
# Install pip after publishing the venv so generated scripts use its final path.
echo 'Устанавливаю зависимости распознавания…'
"$BASE/bin/python3.12" -B -I -m venv --symlinks --without-pip "$WORK/new-venv"
if [[ -e "$VENV" ]]; then HAD_VENV=1; fi
VENV_CHANGED=1
if [[ "$HAD_VENV" == 1 ]]; then /bin/mv "$VENV" "$WORK/previous-venv"; fi
/bin/mv "$WORK/new-venv" "$VENV"
"$VENV/bin/python" -B -I -m ensurepip --upgrade
"$VENV/bin/python" -B -I -m pip --isolated install --no-compile --no-input --disable-pip-version-check --cache-dir "$ROOT/cache/pip" -r "$HERE/requirements.txt"
# Whisper's heavier dependencies are installed only after explicit selection.
SPEECH_FAMILY="$("$VENV/bin/python" -B -I - "$ROOT" "$HERE" <<'PYMODEL'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
sys.path.insert(0, sys.argv[2])
import models
path = root / "settings.json"
settings = json.loads(path.read_text()) if path.exists() else {}
if settings.get("speechMode", "local") == "cloud":
    print("cloud")
else:
    selected = models.selected_asr(root)
    print("whisper-local" if selected and selected["layout"] == "whisper-mlx" else settings.get("speechLocalModel", "parakeet-v3"))
PYMODEL
)"
if [[ "$SPEECH_FAMILY" == whisper-* ]]; then
  "$VENV/bin/python" -B -I -m pip --isolated install --no-compile --no-input --disable-pip-version-check --cache-dir "$ROOT/cache/pip" mlx-whisper==0.4.3
fi
# No package operation may modify the pinned base, including by adding pycache.
"$HOST" --posle-verify-python-runtime "$BASE"
echo 'Проверяю выбранную модель и разделение собеседников…'
export HF_HOME="$ROOT/cache/huggingface"
export HF_HUB_DISABLE_TELEMETRY=1
"$HOST" --posle-python-host "$VENV/bin/python" "$HERE/engine.py" prepare --root "$ROOT"
"$HOST" --posle-verify-python-runtime "$BASE"
: > "$WORK/ready-v2"
/bin/mv "$WORK/ready-v2" "$RUNTIME/ready-v2"
COMMITTED=1
echo 'Готово. Можно добавить первую встречу.'
