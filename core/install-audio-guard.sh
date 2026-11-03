#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/audio-guard"
LABEL="com.clauddy.audio-guard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$LABEL.log"

LEGACY_LABELS=("com.clauddy.audio-output-guard" "com.clauddy.audio-input-guard")

teardown_legacy() {
  for label in "${LEGACY_LABELS[@]}"; do
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
  done
}

action="install"
prefer_output=""
prefer_input=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    install|uninstall|status) action="$1"; shift ;;
    --prefer-output) prefer_output="${2:?--prefer-output needs a value}"; shift 2 ;;
    --prefer-input) prefer_input="${2:?--prefer-input needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

case "$action" in
  status)
    if launchctl list "$LABEL" >/dev/null 2>&1; then
      echo "agent loaded: $LABEL"
    else
      echo "agent NOT loaded: $LABEL"
    fi
    [ -f "$PLIST" ] && echo "plist: $PLIST" || echo "plist: (absent)"
    echo "log:   $LOG"
    for label in "${LEGACY_LABELS[@]}"; do
      if launchctl list "$label" >/dev/null 2>&1; then
        echo "WARNING: legacy agent still loaded: $label (run uninstall then install to clean up)"
      fi
    done
    [ -x "$BIN" ] && "$BIN" status || true
    exit 0
    ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    teardown_legacy
    echo "removed $LABEL (and any legacy audio-output-guard/audio-input-guard agents)"
    exit 0
    ;;
esac

if [ ! -x "$BIN" ]; then
  echo "building audio-guard..." >&2
  (cd "$HERE" && swiftc -o audio-guard audio-guard.swift)
fi

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"

prefer_xml=""
if [ -n "$prefer_output" ]; then
  prefer_xml="$prefer_xml    <string>--prefer-output</string>
    <string>$prefer_output</string>
"
fi
if [ -n "$prefer_input" ]; then
  prefer_xml="$prefer_xml    <string>--prefer-input</string>
    <string>$prefer_input</string>
"
fi

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
    <string>$BIN</string>
    <string>watch</string>
$prefer_xml    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLISTEOF

plutil -lint "$PLIST" >/dev/null || { echo "generated plist is invalid: $PLIST" >&2; exit 1; }

teardown_legacy

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"

sleep 1
if launchctl list "$LABEL" >/dev/null 2>&1; then
  echo "installed and running: $LABEL"
  echo "  binary: $BIN watch${prefer_output:+ --prefer-output $prefer_output}${prefer_input:+ --prefer-input $prefer_input}"
  echo "  log:    $LOG"
else
  echo "installed the plist but the agent is not listed; check $LOG" >&2
  exit 1
fi
