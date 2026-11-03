#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
(cd core && ./build.sh)
echo "Dependencies and Bluetooth helper are ready."
echo "Pair the MiniToo in System Settings, then run: ./minitoo setup"
