#!/bin/bash
# Compatibility entry point; keep one definition of the quick checks.
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$PROJECT/scripts/verify.py" quick "$@"
