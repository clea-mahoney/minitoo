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
. "$SCRIPT_DIR/clauddy-lib.sh"

usage() {
  cat <<EOF
Usage: push-custom-face.sh <state-label> <page_index> <clock_id> <style_id> <file_id> <rawfile> [--config <path>]

Uploads <rawfile> to custom-face slot <page_index>/<clock_id>, selects it, and
applies <style_id>. On success, records <state-label> as the believed display
state in the same shared file clauddy-hook.sh reads/writes
(\${CLAUDDY_HOOK_STATE_FILE:-/tmp/clauddy-hook-state}), so 'clauddy status' and
the hook's same-state fast path stay truthful regardless of which caller made
the push.

<state-label> does not have to be one of chilling/working/alerting/default --
it is just what gets recorded as "currently showing". Callers that intend to
share a slot with Clauddy's own faces (e.g. live-studio borrowing the
alerting slot) should pass that same label so the two agree on what's onscreen.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

state_label="${1:?state-label required}"
page_index="${2:?page_index required}"
clock_id="${3:?clock_id required}"
style_id="${4:?style_id required}"
file_id="${5:?file_id required}"
rawfile="${6:?rawfile required}"
shift 6

config="$CLAUDDY_CONFIG_DEFAULT"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) config="${2:?--config requires a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

clauddy_require_macos
clauddy_ensure_dv_app
clauddy_load_config "$config"

clauddy_upload_custom "$state_label" "$CLAUDDY_MINITOO_MAC" "$file_id" "$rawfile" \
  "$page_index" "$clock_id" "$style_id" "$CLAUDDY_DEVICE_ID"

state_file="${CLAUDDY_HOOK_STATE_FILE:-/tmp/clauddy-hook-state}"
tmp="$state_file.tmp.$$"
if printf '%s %s\n' "$state_label" "$(date +%s)" > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$state_file" 2>/dev/null || rm -f "$tmp"
fi

printf 'pushed: %s (ClockId=%s)\n' "$state_label" "$clock_id"
