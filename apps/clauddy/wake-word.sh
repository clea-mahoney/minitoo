#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDDY_BIN="${CLAUDDY_BIN:-$HOME/.local/bin/clauddy}"
HOOK_BIN="${CLAUDDY_HOOK_BIN:-$HOME/.local/bin/clauddy-hook.sh}"
LOG="${CLAUDDY_HOOK_DEBUG_LOG:-/tmp/clauddy-hook-debug.log}"

log() { printf '[%s] %s\n' "$(date +%T)" "$1" >>"$LOG" 2>&1; }

run_face() {
  local face="$1" out
  out="$("$CLAUDDY_BIN" face "$face" 2>&1)"
  printf '%s\n' "$out" >>"$LOG"
  [ -n "$out" ] && printf '%s\n' "$out"
}

payload="$(cat)"
lc="$(printf '%s' "$payload" | tr '[:upper:]' '[:lower:]')"

case "$lc" in
  *"bye clauddy"*)
    log "wake-word: bye clauddy -> pause + default"
    "$CLAUDDY_BIN" pause >>"$LOG" 2>&1
    run_face default
    exit 0
    ;;
  *"hey clauddy"*)
    log "wake-word: hey clauddy -> resume + chilling"
    "$CLAUDDY_BIN" resume >>"$LOG" 2>&1
    run_face chilling
    ;;
esac

printf '%s' "$payload" | CLAUDDY_HOOK_DEBUG=1 "$HOOK_BIN" working >>"$LOG" 2>&1
