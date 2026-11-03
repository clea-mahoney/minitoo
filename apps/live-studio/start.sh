#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
"$HERE/toggle.sh" on
open "http://127.0.0.1:${LIVE_STUDIO_PORT:-8765}"
