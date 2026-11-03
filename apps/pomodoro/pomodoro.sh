#!/usr/bin/env bash
set -euo pipefail

resolve_script_dir() {
  local source="$1"
  local dir
  while [ -h "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    case "$source" in
      /*) ;;
      *) source="$dir/$source" ;;
    esac
  done
  cd -P "$(dirname "$source")" && pwd
}

SCRIPT_DIR="$(resolve_script_dir "$0")"
CLAUDDY_LIB="$SCRIPT_DIR/../clauddy/lib/clauddy-lib.sh"
. "$CLAUDDY_LIB"

usage() {
  cat <<EOF
Usage: pomodoro.sh [work_min] [break_min] [cycles] [--config <path>] [--no-music]
       pomodoro.sh --test-seconds <n> [--no-music]   # quick real-device test, one short block

Runs a Pomodoro session on the MiniToo: native countdown display plus Apple
Music routed to the device as a Bluetooth speaker.

  work_min   minutes per work block (default 25)
  break_min  minutes per break block (default 5)
  cycles     number of work/break cycles (default 4)

First time only: open Music.app, search "lofi", and press play once so
Music has something in its queue to resume.

This script never touches the MiniToo's own volume — set it on the device
itself and it stays put across runs.

The firmware's own Countdown-tool alarm is loud. This script stops the
countdown POMODORO_ALARM_LEAD seconds early (default 3) to preempt the
firmware alarm. Confirmed working: the device goes silent instead of
alarming. No replacement sound is played — kept deliberately simple.

Confirmed (live test): showing a true 0:00 on this firmware always
triggers the alarm, even when the display value is refreshed every
second from the host rather than left to the device's own internal
timer. There is no known way to show 0:00 silently — stopping just
before it is the closest safe option.

The display is re-sent every second (deactivate window) or every
POMODORO_RESEND_INTERVAL seconds (countdown), which self-heals against
interference the lock/pause below don't cover -- the phone app, a manual
dv command -- but that also means more Bluetooth traffic competing for
the same connection. If a Claude Code session is actively chatting while
a pomodoro block is near the end, that contention can delay the
stop-the-alarm command enough for the device's own internal timer to
cross zero first. A 3s lead gives real margin against that; raise
POMODORO_ALARM_LEAD further if it still slips through.

Clauddy (apps/clauddy) shares this same MiniToo. This script takes
Clauddy's real device lock for the whole session (clauddy-hook.sh skips
face switches while it's held) AND pauses Clauddy's hooks for the
session's real length via \`clauddy pause\`, which also drains any hook
already in flight -- closing the narrow startup race the lock alone
can't. \`clauddy resume\` runs on every exit path (cleanup()'s EXIT/INT/TERM
traps), so this is not an open conflict.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

test_seconds=""
config="$CLAUDDY_CONFIG_DEFAULT"
play_music=1
positional=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --test-seconds) test_seconds="${2:?--test-seconds requires a number}"; shift 2 ;;
    --config) config="${2:?--config requires a path}"; shift 2 ;;
    --no-music) play_music=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'pomodoro.sh: unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
    *) positional[${#positional[@]}]="$1"; shift ;;
  esac
done

if [ -n "$test_seconds" ]; then
  work_min=0
  break_min=0
  cycles=1
else
  work_min="${positional[0]:-25}"
  break_min="${positional[1]:-5}"
  cycles="${positional[2]:-4}"
fi

for n in "$test_seconds" "$work_min" "$break_min" "$cycles"; do
  case "$n" in
    ''|*[!0-9]*) [ -z "$n" ] || { printf 'pomodoro.sh: not a number: %s\n' "$n" >&2; exit 64; } ;;
  esac
done

# Studio owns the display until it is turned off.
if [ -f "$HOME/.clauddy/live-studio.pids" ]; then
  studio_owner="$(sed -n 's/^server_pid=//p' "$HOME/.clauddy/live-studio.pids")"
  if [ -n "$studio_owner" ] && kill -0 "$studio_owner" 2>/dev/null; then
    clauddy_die "Live Studio owns the display. Run minitoo studio off first."
  fi
fi

clauddy_require_macos
clauddy_ensure_dv_app
clauddy_load_config "$config"

dv="$(clauddy_dv)"
original_output=""

restore_audio() {
  if [ "$play_music" -eq 1 ]; then
    osascript -e 'tell application "Music" to pause' >/dev/null 2>&1 || true
  fi
  clauddy_audio_takeover_restore "$original_output"
}

cleanup() {
  "$dv" raw 72 03 00 00 00 >/dev/null 2>&1 || true
  restore_audio
  clauddy_stop_daemon
  clauddy_lock_release
  "$SCRIPT_DIR/../clauddy/clauddy" resume >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

if [ -n "$test_seconds" ]; then
  total_seconds="$test_seconds"
else
  total_seconds=$(( (work_min + break_min) * 60 * cycles ))
fi
pause_seconds=$(( total_seconds + 120 ))
"$SCRIPT_DIR/../clauddy/clauddy" pause "${pause_seconds}s" >/dev/null 2>&1 || true

clauddy_lock_acquire_or_die "pomodoro" "${CLAUDDY_LOCK_WAIT:-20}"

if [ "$play_music" -eq 1 ]; then
  if ! command -v SwitchAudioSource >/dev/null 2>&1; then
    clauddy_note "SwitchAudioSource not found (brew install switchaudio-osx); skipping music routing."
    play_music=0
  fi
fi

if [ "$play_music" -eq 1 ]; then
  if original_output="$(clauddy_audio_takeover)"; then
    clauddy_note "Routing audio to MiniToo."
  else
    clauddy_note "MiniToo not found in audio output devices. Pair it as a Bluetooth speaker first (System Settings > Bluetooth). Skipping music."
    play_music=0
  fi
fi

clauddy_stop_daemon
clauddy_start_daemon "$CLAUDDY_MINITOO_MAC" || exit 1

countdown_seconds() {
  local label="$1"
  local total="$2"
  local lead="${POMODORO_ALARM_LEAD:-3}"
  local resend_every="${POMODORO_RESEND_INTERVAL:-2}"
  clauddy_note "$label: ${total}s"
  local remaining="$total"
  local ticks=0
  while [ "$remaining" -gt 0 ]; do
    if [ "$remaining" -le "$lead" ]; then
      "$dv" raw 72 03 00 00 00 >/dev/null 2>&1 || true
    elif [ "$((ticks % resend_every))" -eq 0 ]; then
      local mins=$((remaining / 60))
      local secs=$((remaining % 60))
      "$dv" raw 72 03 01 "$(printf '%02x' "$mins")" "$(printf '%02x' "$secs")" >/dev/null 2>&1 || true
    fi
    ticks=$((ticks + 1))
    sleep 1
    remaining=$((remaining - 1))
  done
}

countdown() {
  local label="$1"
  local minutes="$2"
  countdown_seconds "$label" "$((minutes * 60))"
}

pause_music() {
  [ "$play_music" -eq 1 ] && osascript -e 'tell application "Music" to pause' >/dev/null 2>&1 || true
}

resume_music() {
  [ "$play_music" -eq 1 ] && osascript -e 'tell application "Music" to play' >/dev/null 2>&1 || true
}

if [ -n "$test_seconds" ]; then
  resume_music
  countdown_seconds "Test" "$test_seconds"
else
  for ((i = 1; i <= cycles; i++)); do
    resume_music
    countdown "Work $i/$cycles" "$work_min"
    pause_music
    countdown "Break $i/$cycles" "$break_min"
  done
fi

clauddy_note "Pomodoro session complete."
