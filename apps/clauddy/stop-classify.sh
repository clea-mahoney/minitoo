#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd)"
PHRASES_FILE="$SCRIPT_DIR/alerting-phrases.txt"
payload="$(cat)"
transcript_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"

state="chilling"
if [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
  state="$(python3 - "$transcript_path" "$PHRASES_FILE" <<'PYEOF'
import json, sys

transcript_path, phrases_path = sys.argv[1], sys.argv[2]

last = ""
try:
    with open(transcript_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("type") != "assistant":
                continue
            content = d.get("message", {}).get("content")
            if not isinstance(content, list):
                continue
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    last = c.get("text", "")
except Exception:
    pass

last_lower = last.lower()
alerting = last_lower.rstrip().endswith("?")

if not alerting:
    try:
        with open(phrases_path, "r") as f:
            for line in f:
                phrase = line.strip()
                if not phrase or phrase.startswith("#"):
                    continue
                if phrase.lower() in last_lower:
                    alerting = True
                    break
    except Exception:
        pass

print("alerting" if alerting else "chilling")
PYEOF
)"
  case "$state" in
    alerting|chilling) ;;
    *) state="chilling" ;;
  esac
fi

printf '[%s] Stop -> %s\n' "$(date +%T)" "$state" >>/tmp/clauddy-hook-debug.log
printf '%s' "$payload" | CLAUDDY_HOOK_DEBUG=1 clauddy-hook.sh "$state" >>/tmp/clauddy-hook-debug.log 2>&1
