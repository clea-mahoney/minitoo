#!/usr/bin/env bash
set -u

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

state="${1:-}"
case "$state" in
  chilling|working|alerting|default) ;;
  *)
    printf 'usage: clauddy-hook.sh <chilling|working|alerting|default>\n' >&2
    exit 64
    ;;
esac

SCRIPT_DIR="$(resolve_script_dir "$0")"

. "$SCRIPT_DIR/lib/clauddy-helper-token.sh"

STATE_FILE="${CLAUDDY_HOOK_STATE_FILE:-/tmp/clauddy-hook-state}"
ALERT_HOLD="${CLAUDDY_ALERT_HOLD:-5}"
WORK_HOLD="${CLAUDDY_WORK_HOLD:-2}"
LOCK_DIR="${CLAUDDY_LOCK:-$HOME/.clauddy/lock}"
DEBUG="${CLAUDDY_HOOK_DEBUG:-0}"

hook_debug() {
  [ "$DEBUG" = "1" ] || return 0
  printf 'clauddy-hook: %s\n' "$*" >&2
}

DISABLED_FILE="${CLAUDDY_DISABLED_FILE:-$HOME/.clauddy/disabled}"

check_stale_live_studio() {
  local pid_file="${CLAUDDY_LIVE_STUDIO_PID_FILE:-$HOME/.clauddy/live-studio.pids}"
  [ -f "$pid_file" ] || return 0
  local server_pid="" relay_pid=""
  . "$pid_file" 2>/dev/null || return 0
  [ -n "$server_pid" ] || return 0
  kill -0 "$server_pid" 2>/dev/null && return 0
  hook_debug "live-studio server (pid $server_pid) is dead but $pid_file still claims it's on; clearing stale state"
  rm -f "$pid_file"
  if [ -e "$DISABLED_FILE" ]; then
    local expiry=""
    read -r expiry < "$DISABLED_FILE" 2>/dev/null || expiry=""
    case "$expiry" in
      ''|*[!0-9]*) ;; # bare manual pause -- not live-studio's, leave it
      *) rm -f "$DISABLED_FILE" 2>/dev/null || :; hook_debug "cleared live-studio's stale pause" ;;
    esac
  fi
}
check_stale_live_studio

BLUEUTIL="$(command -v blueutil || echo /opt/homebrew/bin/blueutil)"
if [ -x "$BLUEUTIL" ]; then
  if connected_out="$("$BLUEUTIL" --connected 2>/dev/null)"; then
    if ! printf '%s\n' "$connected_out" | grep -qi 'minitoo'; then
      hook_debug "MiniToo not connected over Bluetooth; leaving the display alone"
      exit 0
    fi
  else
    hook_debug "blueutil failed; skipping the Bluetooth gate"
  fi
fi

if [ -e "$DISABLED_FILE" ]; then
  paused_until=""
  read -r paused_until < "$DISABLED_FILE" 2>/dev/null || paused_until=""
  case "$paused_until" in
    ''|*[!0-9]*)
      hook_debug "paused (no expiry) via $DISABLED_FILE; leaving the display alone"
      exit 0
      ;;
    *)
      if [ "$(date +%s)" -lt "$paused_until" ]; then
        hook_debug "paused until $paused_until; leaving the display alone"
        exit 0
      fi
      rm -f "$DISABLED_FILE" 2>/dev/null || :
      hook_debug "pause expired; resuming"
      ;;
  esac
fi

ALERTS_DIR="${CLAUDDY_ALERTS_DIR:-$HOME/.clauddy/alerts}"
ALERT_MAX_AGE_MIN="${CLAUDDY_ALERT_MAX_AGE_MIN:-480}"  # crashed sessions never send SessionEnd
JQ="$(command -v jq || echo /usr/bin/jq)"
session_id="${CLAUDDY_SESSION_ID:-}"
hook_event="" notification_type="" notification_msg=""
if [ -z "$session_id" ] && [ ! -t 0 ]; then
  payload=""
  IFS= read -r -d '' -t 2 payload || :
  if [ -n "$payload" ] && [ -x "$JQ" ]; then
    session_id="$(printf '%s' "$payload" | "$JQ" -r '.session_id // empty' 2>/dev/null)"
    hook_event="$(printf '%s' "$payload" | "$JQ" -r '.hook_event_name // empty' 2>/dev/null)"
    notification_type="$(printf '%s' "$payload" | "$JQ" -r '.notification_type // empty' 2>/dev/null)"
    notification_msg="$(printf '%s' "$payload" | "$JQ" -r '.message // empty' 2>/dev/null)"
  fi
fi
[[ "$session_id" =~ ^[A-Za-z0-9-]+$ ]] || session_id=""
export CLAUDDY_SESSION_ID="$session_id"

mkdir -p "$ALERTS_DIR" 2>/dev/null || :
find "$ALERTS_DIR" -type f -mmin +"$ALERT_MAX_AGE_MIN" -delete 2>/dev/null || :

if [ -n "$session_id" ] && [ "${CLAUDDY_HOOK_DEFER_DEPTH:-0}" = "0" ]; then
  if [ "$state" = "alerting" ]; then
    case "$notification_type:$notification_msg" in
      idle_prompt:*|*"waiting for your input"*)
        hook_debug "idle notice from $session_id; not sticky" ;;
      *)
        : > "$ALERTS_DIR/$session_id"
        hook_debug "session $session_id is waiting on you; alert is sticky" ;;
    esac
  else
    if [ -e "$ALERTS_DIR/$session_id" ]; then
      rm -f "$ALERTS_DIR/$session_id"
      hook_debug "session $session_id moved on ($state); its sticky alert cleared"
    fi
  fi
fi

if [ "$state" != "alerting" ] && [ -n "$(ls -A "$ALERTS_DIR" 2>/dev/null)" ]; then
  hook_debug "$(ls -A "$ALERTS_DIR" | wc -l | tr -d ' ') session(s) still waiting on you; keeping alerting instead of $state"
  state="alerting"
fi
[ -n "$hook_event" ] && hook_debug "event=$hook_event session=${session_id:-none} -> $state"

lock_held_by_other() {
  [ -d "$LOCK_DIR" ] || return 1
  local pid
  pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  [ "$pid" = "$$" ] && return 1
  kill -0 "$pid" 2>/dev/null
}

severity() {
  case "$1" in
    default)  printf 0 ;;
    chilling) printf 1 ;;
    working)  printf 2 ;;
    alerting) printf 3 ;;
  esac
}

now="$(date +%s)"
new_sev="$(severity "$state")"

cur_state=""
cur_ts=0
cur_token=""
if [ -r "$STATE_FILE" ]; then
  read -r cur_state cur_ts cur_token < "$STATE_FILE" 2>/dev/null || {
    cur_state=""; cur_ts=0; cur_token=""
  }
fi
case "$cur_state" in
  chilling|working|alerting|default) ;;
  *) cur_state="" ;;
esac
[[ "$cur_ts" =~ ^[0-9]+$ ]] || cur_ts=0

write_state() {
  local tmp="$STATE_FILE.tmp.$$"
  if printf '%s %s %s\n' "$state" "$now" "$(clauddy_helper_token)" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp"
  fi
}

if [ "$cur_state" = "$state" ]; then
  if clauddy_claim_is_fresh "$cur_token" "$cur_ts" "$now"; then
    write_state
    exit 0
  fi
  hook_debug "claim '$cur_state' is stale (token='$cur_token' now='$(clauddy_helper_token)'); re-sending"
fi

if [ -n "$cur_state" ]; then
  cur_sev="$(severity "$cur_state")"
  if [ "$new_sev" -lt "$cur_sev" ]; then
    age=$(( now - cur_ts ))
    hold="$WORK_HOLD"
    [ "$cur_state" = "alerting" ] && hold="$ALERT_HOLD"
    [ "$state" = "default" ] && hold="${CLAUDDY_RELEASE_HOLD:-2}"
    if [ "$age" -lt "$hold" ]; then
      if [ "$state" = "default" ]; then
        [ "$age" -lt "$hold" ] && sleep "$(( hold - age ))"
        now="$(date +%s)"
        if [ -r "$STATE_FILE" ]; then
          recheck_state=""; recheck_ts=0
          read -r recheck_state recheck_ts < "$STATE_FILE" 2>/dev/null || { recheck_state=""; recheck_ts=0; }
          [[ "$recheck_ts" =~ ^[0-9]+$ ]] || recheck_ts=0
          if [ "$recheck_ts" -gt "$cur_ts" ]; then
            hook_debug "a live session refreshed '$recheck_state' while waiting; leaving the display alone"
            exit 0
          fi
        fi
      else
      depth="${CLAUDDY_HOOK_DEFER_DEPTH:-0}"
      if [ "$depth" -ge "${CLAUDDY_HOOK_DEFER_MAX:-1}" ]; then
        hook_debug "defer depth $depth reached; dropping deferred $state"
        exit 0
      fi
      remaining=$(( hold - age + 1 ))
      ( sleep "$remaining"; CLAUDDY_HOOK_DEFER_DEPTH=$((depth + 1)) exec "$0" "$state" ) >/dev/null 2>&1 &
      exit 0
      fi
    fi
  fi
fi

if lock_held_by_other; then
  hook_debug "device busy (lock held by pid $(cat "$LOCK_DIR/pid" 2>/dev/null)); skipping $state"
  exit 0
fi

write_state
invalidate_own_claim() {
  local seen_state seen_ts
  [ -r "$STATE_FILE" ] || return 0
  seen_state=""; seen_ts=""
  read -r seen_state seen_ts < "$STATE_FILE" 2>/dev/null || return 0
  if [ "$seen_state" = "$state" ] && [ "$seen_ts" = "$now" ]; then
    rm -f "$STATE_FILE"
    hook_debug "$state switch failed; retracted our state claim"
  else
    hook_debug "$state switch failed but '$seen_state' now owns the claim; left it alone"
  fi
}

restamp_own_claim() {
  local seen_state seen_ts tmp
  [ -r "$STATE_FILE" ] || return 0
  seen_state=""; seen_ts=""
  read -r seen_state seen_ts _ < "$STATE_FILE" 2>/dev/null || return 0
  [ "$seen_state" = "$state" ] && [ "$seen_ts" = "$now" ] || return 0
  tmp="$STATE_FILE.tmp.$$"
  if printf '%s %s %s\n' "$state" "$now" "$(clauddy_helper_token)" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp"
  fi
  return 0
}

switch_and_settle() {
  if "$SCRIPT_DIR/set-clauddy-state.sh" "$state"; then
    restamp_own_claim
  else
    invalidate_own_claim
  fi
}

if [ "$state" = "default" ] || [ "${CLAUDDY_HOOK_SYNC:-0}" = "1" ]; then
  export CLAUDDY_LOCK_WAIT="${CLAUDDY_LOCK_WAIT:-4}"
  if [ "$DEBUG" = "1" ]; then
    switch_and_settle >&2
  else
    switch_and_settle >/dev/null 2>&1
  fi
elif [ "$DEBUG" = "1" ]; then
  switch_and_settle >&2 &
else
  switch_and_settle >/dev/null 2>&1 &
fi
exit 0
