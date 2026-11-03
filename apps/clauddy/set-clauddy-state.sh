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
. "$SCRIPT_DIR/lib/clauddy-lib.sh"

usage() {
  cat <<EOF
Usage: set-clauddy-state.sh <working|chilling|alerting|default> [--config <path>] [--stop-after]

Switches the Divoom display device to a preloaded Clauddy custom face.

  working | chilling | alerting   the three Clauddy faces
  default                         hand the display back to the face named by
                                  CLAUDDY_CLOCK_DEFAULT (a stock face you chose
                                  in the Divoom phone app) and release the
                                  Bluetooth channel. Falls back to the chilling
                                  face when CLAUDDY_CLOCK_DEFAULT is unset.
                                  Find ClockIds with:
                                    python3 tools/clauddy-cloud.py list-clocks

Options:
  --config <path>   config file to read (default ~/.clauddy/config)
  --stop-after      stop the Bluetooth helper when done instead of leaving it
                    running for faster subsequent switches ("default" always
                    stops it)
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

state="${1:-}"
if [ -z "$state" ]; then
  usage >&2
  exit 64
fi
shift

config="$CLAUDDY_CONFIG_DEFAULT"
stop_after=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      config="${2:-}"
      shift 2
      ;;
    --stop-after)
      stop_after=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

case "$state" in
  working|chilling|alerting|default) ;;
  *)
    clauddy_die "unknown state '$state'. Expected: working, chilling, alerting, default."
    ;;
esac

if [ "$state" = "default" ]; then
  stop_after=1
fi

clauddy_require_macos
clauddy_ensure_dv_app
clauddy_load_config "$config"

clauddy_lock_acquire_or_die "set-state:$state" "${CLAUDDY_LOCK_WAIT:-15}"

case "$state" in
  working|chilling|alerting)
    foreign_file="$(clauddy_foreign_marker "$state")"
    if [ -e "$foreign_file" ]; then
      clauddy_note "$state slot was last overwritten by live-studio and never restored; repairing it first..."
      clauddy_reupload_face "$state"
      rm -f "$foreign_file"
    fi
    ;;
esac

started=0
if ! clauddy_daemon_running; then
  started=1
  clauddy_note "Bluetooth helper is not running; starting it for device at $CLAUDDY_MINITOO_MAC..."
  clauddy_start_daemon "$CLAUDDY_MINITOO_MAC" || exit 1
fi

clock_id="$(clauddy_state_clock_id "$state")"
if [ "$state" = "default" ] && ! clauddy_has_default_clock; then
  clauddy_note "CLAUDDY_CLOCK_DEFAULT is not set; falling back to the chilling face."
  clauddy_note "To hand the display back to a stock face instead, list your faces with:"
  clauddy_note "  python3 $SCRIPT_DIR/tools/clauddy-cloud.py list-clocks"
  clauddy_note "then add CLAUDDY_CLOCK_DEFAULT=<ClockId> to $config"
fi
clauddy_send_json "$(clauddy_selector_json "$clock_id" "$CLAUDDY_DEVICE_ID")"
printf 'clauddy state: %s (ClockId=%s)\n' "$state" "$clock_id"

if [ "$stop_after" -eq 1 ]; then
  clauddy_stop_daemon
elif [ "$started" -eq 1 ]; then
  clauddy_note "Bluetooth helper left running for faster future switches. Stop it with: $(clauddy_dv) stop"
fi
