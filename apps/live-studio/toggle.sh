#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$HOME/.clauddy/live-studio.pids"
server_pid="" relay_pid=""
[ ! -f "$PID_FILE" ] || . "$PID_FILE"
running() { [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; }
case "${1:-status}" in
  on)
    if running; then echo "Live Studio is already on."; exit 0; fi
    mkdir -p "$HOME/.clauddy"
    log="$HOME/.clauddy/live-studio.log"
    # Start independently of the launching terminal or chat.
    python3 - "$HERE/run.sh" "$log" <<'PY'
import subprocess, sys
with open(sys.argv[2], "ab") as log:
    subprocess.Popen([sys.argv[1]], stdin=subprocess.DEVNULL, stdout=log,
                     stderr=log, start_new_session=True)
PY
    for i in {1..100}; do
      if [ -f "$PID_FILE" ]; then
        . "$PID_FILE"
        if running && curl -fsS "http://127.0.0.1:${LIVE_STUDIO_PORT:-8765}/health" >/dev/null 2>&1; then
          echo "Live Studio is on: http://127.0.0.1:${LIVE_STUDIO_PORT:-8765}"
          exit 0
        fi
      fi
      sleep 0.1
    done
    echo "Live Studio did not start. See $log" >&2
    tail -n 6 "$log" >&2
    exit 1 ;;
  off)
    if ! running; then echo "Live Studio is off."; exit 0; fi
    kill -TERM "$server_pid"
    for i in {1..150}; do
      if ! kill -0 "$server_pid" 2>/dev/null; then echo "Live Studio is off; previous face restored if the device is reachable."; exit 0; fi
      sleep 0.1
    done
    echo "Live Studio is stopping. See $HOME/.clauddy/live-studio.log" ;;
  status)
    if running; then echo "Live Studio is on."; else echo "Live Studio is off."; fi ;;
  back|forward|rewind) exec python3 "$HERE/nav.py" "${1/rewind/back}" ;;
  *) echo "Usage: toggle.sh on|off|status|back|forward" >&2; exit 64 ;;
esac
