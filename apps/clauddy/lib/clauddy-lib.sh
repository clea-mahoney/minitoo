#!/usr/bin/env bash

clauddy_resolve_path() {
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

CLAUDDY_LIB_DIR="$(clauddy_resolve_path "${BASH_SOURCE[0]}")"

. "$CLAUDDY_LIB_DIR/clauddy-helper-token.sh"

CLAUDDY_PACKAGE_DIR="$(cd "$CLAUDDY_LIB_DIR/.." && pwd)"
CLAUDDY_REPO_ROOT="$(cd "$CLAUDDY_PACKAGE_DIR/../.." && pwd)"
CLAUDDY_CORE_DIR_DEFAULT="$CLAUDDY_REPO_ROOT/core"
CLAUDDY_CONFIG_DEFAULT="${CLAUDDY_CONFIG:-$HOME/.clauddy/config}"
CLAUDDY_DETECTED_DEFAULT="${CLAUDDY_DETECTED:-$HOME/.clauddy/detected}"
CLAUDDY_FIFO="${DIVOOM_FIFO:-/tmp/divoom.fifo}"
CLAUDDY_LOG="${DIVOOM_LOG:-/tmp/divoom-send.log}"
CLAUDDY_LOCK="${CLAUDDY_LOCK:-$HOME/.clauddy/lock}"

clauddy_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

clauddy_note() {
  printf '%s\n' "$*" >&2
}

clauddy_normalize_mac() {
  printf '%s\n' "${1//-/:}" | tr '[:lower:]' '[:upper:]'
}

clauddy_is_mac() {
  [[ "$1" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

clauddy_is_device_id() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

clauddy_config_get() {
  local config="$1"
  local key="$2"
  [ -f "$config" ] || return 1
  (
    set +u
    . "$config" >/dev/null 2>&1 || exit 1
    case "$key" in
      CLAUDDY_MINITOO_MAC) printf '%s\n' "${CLAUDDY_MINITOO_MAC:-}" ;;
      CLAUDDY_DEVICE_ID) printf '%s\n' "${CLAUDDY_DEVICE_ID:-}" ;;
      *) exit 1 ;;
    esac
  )
}

clauddy_write_detected_config() {
  local config="$1"
  local mac="$2"
  local device_id="$3"

  mkdir -p "$(dirname "$config")" || return 1
  {
    printf '# Clauddy Bluetooth detection cache.\n'
    printf '# Contains no Divoom password, auth token, or account secret.\n'
    [ -n "$mac" ] && printf 'CLAUDDY_MINITOO_MAC=%q\n' "$mac"
    [ -n "$device_id" ] && printf 'CLAUDDY_DEVICE_ID=%q\n' "$device_id"
  } > "$config"
  chmod 600 "$config"
}

clauddy_detect_minitoo_macs() {
  python3 "$CLAUDDY_PACKAGE_DIR/tools/detect-minitoo-mac.py"
}

clauddy_require_macos() {
  [ "$(uname -s)" = "Darwin" ] || clauddy_die "Clauddy currently supports macOS only."
}

clauddy_require_python_pillow() {
  command -v python3 >/dev/null 2>&1 || clauddy_die "python3 is required."
  if ! python3 - <<'PY' >/dev/null 2>&1
from PIL import Image
PY
  then
    clauddy_die "Python Pillow is required. Install it with: python3 -m pip install Pillow"
  fi
}

clauddy_core_dir() {
  printf '%s\n' "${CLAUDDY_CORE_DIR:-$CLAUDDY_CORE_DIR_DEFAULT}"
}

clauddy_dv() {
  printf '%s/dv\n' "$(clauddy_core_dir)"
}

clauddy_require_dv() {
  local dv
  dv="$(clauddy_dv)"
  [ -x "$dv" ] || clauddy_die "missing Divoom Bluetooth helper: $dv"
}

clauddy_ensure_dv_app() {
  local dir
  dir="$(clauddy_core_dir)"
  clauddy_require_dv
  if [ ! -x "$dir/divoom-send.app/Contents/MacOS/divoom-send" ]; then
    clauddy_note "Building macOS Bluetooth helper..."
    (cd "$dir" && ./build.sh) || clauddy_die "failed to build divoom-send.app. Xcode command line tools may be missing."
  fi
}

clauddy_daemon_running() {
  [ -p "$CLAUDDY_FIFO" ] && pgrep -x divoom-send >/dev/null 2>&1
}

clauddy_clear_stale_fifo() {
  if [ -p "$CLAUDDY_FIFO" ] && ! pgrep -x divoom-send >/dev/null 2>&1; then
    rm -f "$CLAUDDY_FIFO"
  fi
}

clauddy_orphan_helper_pids() {
  if [ -p "$CLAUDDY_FIFO" ]; then
    return 0
  fi
  pgrep -x divoom-send 2>/dev/null || true
}

clauddy_kill_orphan_helpers() {
  local pids
  pids="$(clauddy_orphan_helper_pids)"
  [ -n "$pids" ] || return 0
  clauddy_note "Found Bluetooth helper process(es) with no command FIFO: $(echo "$pids" | tr '\n' ' ')"
  clauddy_note "They hold RFCOMM channel 1 and would block this run. Terminating them."
  echo "$pids" | while read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  sleep 1
  pids="$(clauddy_orphan_helper_pids)"
  if [ -n "$pids" ]; then
    echo "$pids" | while read -r pid; do
      [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
    done
    sleep 1
  fi
}

clauddy_lock_pid() {
  cat "$CLAUDDY_LOCK/pid" 2>/dev/null || true
}

clauddy_lock_age() {
  local mtime
  mtime="$(stat -f %m "$CLAUDDY_LOCK" 2>/dev/null || printf 0)"
  printf '%s' $(( $(date +%s) - mtime ))
}

clauddy_lock_owner_alive() {
  local pid
  pid="$(clauddy_lock_pid)"
  if [ -z "$pid" ]; then
    [ "$(clauddy_lock_age)" -le "${CLAUDDY_LOCK_GRACE:-5}" ]
    return
  fi
  kill -0 "$pid" 2>/dev/null
}

clauddy_lock_held_by_other() {
  [ -d "$CLAUDDY_LOCK" ] || return 1
  if [ "$(clauddy_lock_pid)" = "$$" ]; then
    return 1
  fi
  clauddy_lock_owner_alive
}

clauddy_lock_acquire() {
  local label="${1:-clauddy}"
  local timeout="${2:-0}"
  local deadline=$((SECONDS + timeout))
  mkdir -p "$(dirname "$CLAUDDY_LOCK")" 2>/dev/null || true
  while :; do
    if mkdir "$CLAUDDY_LOCK" 2>/dev/null; then
      printf '%s\n' "$$" > "$CLAUDDY_LOCK/pid"
      printf '%s\n' "$label" > "$CLAUDDY_LOCK/label"
      CLAUDDY_LOCK_OWNED=1
      return 0
    fi
    if ! clauddy_lock_owner_alive; then
      clauddy_note "Clearing stale Clauddy device lock (holder $(clauddy_lock_pid) gone)."
      rm -rf "$CLAUDDY_LOCK"
      continue
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.2
  done
}

clauddy_lock_release() {
  [ "${CLAUDDY_LOCK_OWNED:-0}" = "1" ] || return 0
  [ "$(clauddy_lock_pid)" = "$$" ] || return 0
  rm -rf "$CLAUDDY_LOCK"
  CLAUDDY_LOCK_OWNED=0
}

clauddy_lock_acquire_or_die() {
  local label="$1"
  local timeout="${2:-20}"
  if ! clauddy_lock_acquire "$label" "$timeout"; then
    clauddy_die "another Clauddy operation holds the device (pid $(clauddy_lock_pid), $(cat "$CLAUDDY_LOCK/label" 2>/dev/null || echo unknown)). Wait for it to finish, or remove $CLAUDDY_LOCK if it is debris."
  fi
  local prev
  prev="$(trap -p EXIT 2>/dev/null | sed -n "s/^trap -- '\(.*\)' EXIT\$/\1/p")"
  if [ -n "$prev" ]; then
    trap "$prev; clauddy_lock_release" EXIT
    trap "$prev; clauddy_lock_release; exit 130" INT
    trap "$prev; clauddy_lock_release; exit 143" TERM
  else
    trap 'clauddy_lock_release' EXIT
    trap 'clauddy_lock_release; exit 130' INT
    trap 'clauddy_lock_release; exit 143' TERM
  fi
}

clauddy_bluetooth_help() {
  cat >&2 <<'HELPEOF'
Could not complete the Bluetooth exchange with the Divoom display device.

Check, in this order:

  1. A leftover helper on this Mac is holding the channel.
       pgrep -x divoom-send
     If that prints anything:  core/dv stop
     RFCOMM channel 1 is the only channel that executes commands and it takes
     exactly one client, so a stale helper blocks every new connection.

  2. The Divoom phone app is open, or your phone is still connected to the
     device over Bluetooth. Force-quit the app AND disconnect the device in
     the phone's Bluetooth settings.

  3. The helper connected on the wrong channel. Check with:
       grep -E 'connected on RFCOMM|port policy' /tmp/divoom-send.log
     Anything other than "port 1" means commands are accepted and silently
     ignored (channel 10 is a loopback that echoes frames back).

  4. The device's upload handshake is wedged. If channel 1 opened fine but the
     upload still timed out, repeated custom-face uploads have desynced it.
     Wait a few minutes and retry -- it recovers on its own (observed: back to
     normal after ~20 minutes, no power cycle). Power-cycle only if it persists.
     Face switching keeps working in this state; only uploads are affected.

  5. The helper has no Bluetooth permission. If the log below is EMPTY and a
     divoom-send process is running, macOS is silently blocking it: rebuilding
     core/divoom-send.app changes its ad-hoc code signature, which voids the
     app's Bluetooth grant. Approve it again in
     System Settings > Privacy & Security > Bluetooth.

  6. The Bluetooth MAC address in the Clauddy config is correct.

HELPEOF
  printf 'Channel selection:\n' >&2
  grep -E '^(port policy:|SDP summary:|trying RFCOMM|  result = |connected on RFCOMM|WARNING:|ERROR:|FATAL:)' \
    "$CLAUDDY_LOG" >&2 2>/dev/null || printf '  (no channel lines in %s)\n' "$CLAUDDY_LOG" >&2
  printf '\nRecent helper traffic (keepalives filtered):\n' >&2
  grep -vE '^delegate: rx\[17\]' "$CLAUDDY_LOG" 2>/dev/null | tail -n 20 >&2 || true
  printf '\nFull log: %s\n' "$CLAUDDY_LOG" >&2
}

clauddy_start_daemon() {
  local mac="$1"
  local dv
  dv="$(clauddy_dv)"
  clauddy_clear_stale_fifo
  if clauddy_daemon_running; then
    return 0
  fi
  clauddy_kill_orphan_helpers
  if ! "$dv" start "$mac" >/tmp/clauddy-dv-start.out 2>&1; then
    cat /tmp/clauddy-dv-start.out >&2 2>/dev/null || true
    clauddy_bluetooth_help
    return 1
  fi
}

clauddy_stop_daemon() {
  local dv i
  dv="$(clauddy_dv)"
  "$dv" stop >/dev/null 2>&1 || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x divoom-send >/dev/null 2>&1 || return 0
    sleep 0.3
  done
  clauddy_kill_orphan_helpers
}

clauddy_check_connection() {
  local mac="$1"
  local dv detected port
  dv="$(clauddy_dv)"

  clauddy_stop_daemon
  if ! clauddy_start_daemon "$mac"; then
    return 1
  fi

  port="$(grep -oE 'connected on RFCOMM port [0-9]+' "$CLAUDDY_LOG" 2>/dev/null | tail -1 | awk '{print $NF}')"
  if [ -z "$port" ]; then
    clauddy_note "Bluetooth helper never reported an open RFCOMM channel."
    clauddy_bluetooth_help
    clauddy_stop_daemon
    return 1
  fi
  if [ "$port" != "1" ]; then
    clauddy_note "Bluetooth helper connected on RFCOMM channel $port, not channel 1."
    clauddy_note "Only channel 1 executes commands on this device; channel 10 is a"
    clauddy_note "loopback that echoes frames back and silently ignores them."
    clauddy_bluetooth_help
    clauddy_stop_daemon
    return 1
  fi

  "$dv" raw bd 2b 00 >/dev/null 2>&1 || true
  sleep 1
  detected="$(python3 "$CLAUDDY_PACKAGE_DIR/tools/parse-device-id-log.py" "$CLAUDDY_LOG" 2>/dev/null || true)"
  clauddy_stop_daemon
  printf '%s\n' "$detected"
}

clauddy_load_config() {
  local config="$1"
  [ -f "$config" ] || clauddy_die "missing config: $config. Run install.sh first."
  . "$config"
  : "${CLAUDDY_MINITOO_MAC:?missing CLAUDDY_MINITOO_MAC in config}"
  : "${CLAUDDY_DEVICE_ID:?missing CLAUDDY_DEVICE_ID in config}"
  : "${CLAUDDY_CLOCK_CHILLING:?missing CLAUDDY_CLOCK_CHILLING in config}"
  : "${CLAUDDY_CLOCK_WORKING:?missing CLAUDDY_CLOCK_WORKING in config}"
  : "${CLAUDDY_CLOCK_ALERTING:?missing CLAUDDY_CLOCK_ALERTING in config}"
}

clauddy_default_clock_id() {
  if [ -n "${CLAUDDY_CLOCK_DEFAULT:-}" ]; then
    printf '%s\n' "$CLAUDDY_CLOCK_DEFAULT"
  else
    printf '%s\n' "$CLAUDDY_CLOCK_CHILLING"
  fi
}

clauddy_has_default_clock() {
  [ -n "${CLAUDDY_CLOCK_DEFAULT:-}" ]
}

clauddy_confirm_hint() {
  local state="$1"
  local clock_id
  clock_id="$(clauddy_state_clock_id "$state" 2>/dev/null || printf '?')"
  clauddy_note "Check the MiniToo now -- should show '$state' (ClockId=$clock_id)."
  clauddy_note "Not matching? Power-cycle the MiniToo with its own button (never unplug), then retry."
}

clauddy_state_clock_id() {
  case "$1" in
    chilling) printf '%s\n' "$CLAUDDY_CLOCK_CHILLING" ;;
    working) printf '%s\n' "$CLAUDDY_CLOCK_WORKING" ;;
    alerting) printf '%s\n' "$CLAUDDY_CLOCK_ALERTING" ;;
    default) clauddy_default_clock_id ;;
    *) return 1 ;;
  esac
}

clauddy_state_page_index() {
  case "$1" in
    chilling) printf '%s\n' "${CLAUDDY_PAGE_CHILLING:-0}" ;;
    working) printf '%s\n' "${CLAUDDY_PAGE_WORKING:-1}" ;;
    alerting) printf '%s\n' "${CLAUDDY_PAGE_ALERTING:-2}" ;;
    *) return 1 ;;
  esac
}

clauddy_state_style_id() {
  case "$1" in
    chilling) printf '%s\n' "${CLAUDDY_STYLE_CHILLING:-798}" ;;
    working) printf '%s\n' "${CLAUDDY_STYLE_WORKING:-828}" ;;
    alerting) printf '%s\n' "${CLAUDDY_STYLE_ALERTING:-798}" ;;
    *) return 1 ;;
  esac
}

clauddy_selector_json() {
  local clock_id="$1"
  local device_id="$2"
  printf '{"Command":"Channel/SetClockSelectId","ClockId":%s,"DeviceId":%s,"ParentClockId":0,"ParentItemId":"","PageIndex":0,"LcdIndependence":0,"LcdIndex":0,"Language":"en"}' "$clock_id" "$device_id"
}

clauddy_clean_json() {
  local page_index="$1"
  local clock_id="$2"
  local device_id="$3"
  printf '{"Command":"Channel/CleanCustom","CustomPageIndex":%s,"ClockId":%s,"ParentClockId":0,"ParentItemId":"","DeviceId":%s}' "$page_index" "$clock_id" "$device_id"
}

clauddy_set_custom_json() {
  local page_index="$1"
  local file_id="$2"
  local clock_id="$3"
  local device_id="$4"
  printf '{"Command":"Channel/SetCustom","CustomPageIndex":%s,"CustomId":0,"FileId":"%s","ClockId":%s,"ParentClockId":0,"ParentItemId":"","LcdIndependence":0,"LcdIndex":0,"Language":"en","DeviceId":%s}' "$page_index" "$file_id" "$clock_id" "$device_id"
}

clauddy_style_json() {
  local clock_id="$1"
  local style_id="$2"
  local device_id="$3"
  printf '{"Command":"Channel/SetClockStyle","ClockId":%s,"StyleId":%s,"DeviceId":%s,"ParentClockId":0,"ParentItemId":"","PageIndex":0,"LcdIndependence":0,"LcdIndex":0,"Language":"en"}' "$clock_id" "$style_id" "$device_id"
}

clauddy_delivery_count() {
  local n
  n="$(grep -c 'writeComplete status=0x00000000' "$CLAUDDY_LOG" 2>/dev/null)" || n=0
  printf '%s' "${n:-0}"
}

clauddy_confirm_delivery() {
  local before="$1"
  local timeout="${2:-3}"
  local deadline=$((SECONDS + timeout))
  local now
  while [ "$SECONDS" -lt "$deadline" ]; do
    now="$(clauddy_delivery_count)"
    if [ "$now" -gt "$before" ]; then
      return 0
    fi
    if [ "$now" -lt "$before" ] && [ "$now" -ge 1 ]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

clauddy_send_json() {
  local json="$1"
  local dv before
  dv="$(clauddy_dv)"
  if ! clauddy_daemon_running; then
    clauddy_die "Bluetooth helper is not running."
  fi
  before="$(clauddy_delivery_count)"
  "$dv" json "$json" || clauddy_die "failed to send Bluetooth JSON command."
  if ! clauddy_confirm_delivery "$before" "${CLAUDDY_DELIVERY_TIMEOUT:-3}"; then
    clauddy_die "the helper accepted the command but never confirmed putting it on the Bluetooth channel (no writeComplete in $CLAUDDY_LOG within ${CLAUDDY_DELIVERY_TIMEOUT:-3}s). Either the daemon is wedged, or it is connected to the channel-10 loopback. Check: grep -E 'connected on RFCOMM|LOOPBACK' $CLAUDDY_LOG"
  fi
}

clauddy_wait_for_upload_ack() {
  local timeout="${1:-30}"
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if grep -q "bd 55 13 01 05 00" "$CLAUDDY_LOG" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

clauddy_start_custom_daemon() {
  local mac="$1"
  local file_id="$2"
  local rawfile="$3"
  local device_id="$4"
  local delay_ms="$5"
  local dv
  dv="$(clauddy_dv)"

  clauddy_stop_daemon
  clauddy_clear_stale_fifo
  if ! "$dv" start-custom "$mac" "$file_id" "$rawfile" "$device_id" "$delay_ms" >/tmp/clauddy-dv-start-custom.out 2>&1; then
    cat /tmp/clauddy-dv-start-custom.out >&2 2>/dev/null || true
    clauddy_bluetooth_help
    return 1
  fi
}

clauddy_upload_custom() {
  local state="$1"
  local mac="$2"
  local file_id="$3"
  local rawfile="$4"
  local page_index="$5"
  local clock_id="$6"
  local style_id="$7"
  local device_id="$8"
  local delay_ms="${9:-5}"

  clauddy_note "Uploading $state to CustomPageIndex=$page_index ClockId=$clock_id..."
  clauddy_start_custom_daemon "$mac" "$file_id" "$rawfile" "$device_id" "$delay_ms" || return 1
  if [ "${CLAUDDY_SKIP_CLEAN:-0}" != "1" ]; then
    clauddy_send_json "$(clauddy_clean_json "$page_index" 0 "$device_id")"
  fi
  clauddy_send_json "$(clauddy_set_custom_json "$page_index" "$file_id" 0 "$device_id")"
  if ! clauddy_wait_for_upload_ack "${CLAUDDY_ACK_TIMEOUT:-20}"; then
    clauddy_bluetooth_help
    clauddy_stop_daemon
    clauddy_die "timed out waiting for device to ACK $state upload."
  fi
  clauddy_send_json "$(clauddy_style_json "$clock_id" "$style_id" "$device_id")"
  clauddy_stop_daemon
}

clauddy_audio_output_allow_file() {
  echo "${CLAUDDY_AUDIO_OUTPUT_ALLOW:-$HOME/.clauddy/audio-output-allow}"
}

clauddy_audio_takeover() {
  command -v SwitchAudioSource >/dev/null 2>&1 || return 1
  local allow_file minitoo_output original_output
  allow_file="$(clauddy_audio_output_allow_file)"
  original_output="$(SwitchAudioSource -c -t output 2>/dev/null || true)"
  minitoo_output="$(SwitchAudioSource -a -t output 2>/dev/null | grep -i "minitoo\|tiivoo" | head -1 || true)"
  [ -n "$minitoo_output" ] || return 1
  mkdir -p "$(dirname "$allow_file")" 2>/dev/null || true
  : > "$allow_file"
  SwitchAudioSource -s "$minitoo_output" -t output >/dev/null 2>&1 || true
  echo "$original_output"
}

clauddy_audio_takeover_restore() {
  local original_output="$1"
  if command -v SwitchAudioSource >/dev/null 2>&1 && [ -n "$original_output" ]; then
    SwitchAudioSource -s "$original_output" -t output >/dev/null 2>&1 || true
  fi
  rm -f "$(clauddy_audio_output_allow_file)" 2>/dev/null || true
}

clauddy_foreign_marker() {
  if [ "$1" = "alerting" ]; then
    printf '%s\n' "${CLAUDDY_ALERTING_FOREIGN_FILE:-$HOME/.clauddy/alerting-slot-foreign}"
  else
    printf '%s\n' "$HOME/.clauddy/$1-slot-foreign"
  fi
}

clauddy_reupload_face() {
  local state="$1"
  local gif="$CLAUDDY_PACKAGE_DIR/assets/$state.gif"
  local tmpdir raw file_id clock_id page_index style_id rc

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/clauddy-reupload.XXXXXX")" || clauddy_die "could not create a temp dir for the $state reupload."
  raw="$tmpdir/$state.raw"
  file_id="clauddy-$state-$(date +%s)"
  clock_id="$(clauddy_state_clock_id "$state")" || clauddy_die "unknown state '$state'."
  page_index="$(clauddy_state_page_index "$state")"
  style_id="$(clauddy_state_style_id "$state")"

  python3 "$CLAUDDY_PACKAGE_DIR/tools/encode-custom-raw.py" \
    --input "$gif" --output "$raw" --file-id "$file_id" \
    --quality 95 --fit cover --resample nearest \
    --max-payload-bytes 0 --speed-scale 1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -rf "$tmpdir"
    clauddy_die "encoding $gif failed."
  fi

  clauddy_upload_custom "$state" "$CLAUDDY_MINITOO_MAC" "$file_id" "$raw" \
    "$page_index" "$clock_id" "$style_id" "$CLAUDDY_DEVICE_ID" 5
  rm -rf "$tmpdir"
}
