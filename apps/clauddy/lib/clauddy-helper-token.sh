#!/usr/bin/env bash

clauddy_helper_token() {
  local pid start
  pid="$(pgrep -x divoom-send 2>/dev/null | head -1)"
  if [ -z "$pid" ]; then
    printf 'nohelper'
    return 0
  fi
  start="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -d ' :')"
  printf 'h%s-%s' "$pid" "${start:-unknown}"
}

CLAUDDY_CLAIM_TTL="${CLAUDDY_CLAIM_TTL:-600}"

clauddy_claim_is_fresh() {
  local claim_token="${1:-}" claim_ts="${2:-0}" now="${3:-}"
  [ -n "$claim_token" ] || return 1
  [ "$claim_token" = "nohelper" ] && return 1
  [ "$claim_token" = "$(clauddy_helper_token)" ] || return 1

  [ "${CLAUDDY_CLAIM_TTL:-120}" -gt 0 ] 2>/dev/null || return 0
  [[ "$claim_ts" =~ ^[0-9]+$ ]] || return 1
  [ -n "$now" ] || now="$(date +%s)"
  [ "$(( now - claim_ts ))" -lt "$CLAUDDY_CLAIM_TTL" ]
}
