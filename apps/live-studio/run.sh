#!/usr/bin/env bash
# Own the display for the Studio session, then restore the previous face and pause.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../clauddy/lib/clauddy-lib.sh"
[ ! -f "$HERE/../../personal.env" ] || . "$HERE/../../personal.env"
[ ! -f "$HOME/.clauddy/live-studio.env" ] || . "$HOME/.clauddy/live-studio.env"
clauddy_load_config "$CLAUDDY_CONFIG_DEFAULT"
clauddy_lock_acquire_or_die "Live Studio" 5
STATE_DIR="${LIVE_STUDIO_STATE_DIR:-$HOME/.clauddy/live-studio}"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
PAUSE="${CLAUDDY_DISABLED_FILE:-$HOME/.clauddy/disabled}"
STATE="${CLAUDDY_HOOK_STATE_FILE:-/tmp/clauddy-hook-state}"
prior_face=chilling
[ ! -r "$STATE" ] || read -r prior_face _ < "$STATE" || true
case "$prior_face" in working|alerting|chilling|default) ;; *) prior_face=chilling ;; esac
had_pause=0
if [ -e "$PAUSE" ]; then cp "$PAUSE" "$STATE_DIR/prior-pause"; had_pause=1; fi
server_child="" relay_pid="" connected=0
cleanup() {
  trap - EXIT INT TERM
  [ -z "$server_child" ] || kill "$server_child" 2>/dev/null || true
  [ -z "$relay_pid" ] || kill "$relay_pid" 2>/dev/null || true
  [ -z "$server_child" ] || wait "$server_child" 2>/dev/null || true
  [ -z "$relay_pid" ] || wait "$relay_pid" 2>/dev/null || true
  clauddy_lock_release
  if [ "$connected" -eq 1 ]; then
    "$HERE/../clauddy/set-clauddy-state.sh" "$prior_face" || echo "Could not restore the previous face. Run: minitoo face chilling" >&2
  else
    clauddy_stop_daemon
  fi
  if [ "$had_pause" -eq 1 ]; then cp "$STATE_DIR/prior-pause" "$PAUSE"; else rm -f "$PAUSE"; fi
  rm -f "$STATE_DIR/prior-pause" "$HOME/.clauddy/live-studio.pids"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# A pause also drains a face switch already in flight before this lock was acquired.
"$HERE/../clauddy/clauddy" pause 12h >/dev/null 2>&1
clauddy_start_daemon "$CLAUDDY_MINITOO_MAC"
connected=1
export LOCAL_UPDATE_URL="http://127.0.0.1:${LIVE_STUDIO_PORT:-8765}/update"
python3 -u "$HERE/server.py" "${LIVE_STUDIO_PORT:-8765}" &
server_child=$!
if [ -n "${FIREBASE_DB_URL:-}" ]; then
  python3 -u "$HERE/firebase-relay.py" &
  relay_pid=$!
fi
printf 'server_pid=%s\nrelay_pid=%s\n' "$$" "$relay_pid" > "$HOME/.clauddy/live-studio.pids"
wait "$server_child"
