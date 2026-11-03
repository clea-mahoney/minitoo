#!/bin/bash
set -euo pipefail

APP="divoom-send.app"
BIN="divoom-send"
GUARD="audio-guard"

swiftc -o "$BIN" divoom-send.swift
swiftc -o "$GUARD" "$GUARD.swift"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>divoom-send</string>
    <key>CFBundleIdentifier</key>
    <string>local.divoom.send</string>
    <key>CFBundleName</key>
    <string>divoom-send</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Send display commands to the Divoom Minitoo.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>Send display commands to the Divoom Minitoo.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --deep "$APP"
CDHASH="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')"

echo "Built: $APP  (CDHash ${CDHASH:-unknown})"
echo "Built: $GUARD"
echo
echo "Run via the wrapper (it launches the bundle so macOS grants Bluetooth):"
echo "  ./dv start <MAC>"
echo "  ./dv brightness 60"   # visible effect; 'dv face' is a no-op on the MiniToo
echo
echo "!! The ad-hoc signature just changed, so macOS has revoked this app's"
echo "   Bluetooth permission. Until you re-approve it, the helper will launch,"
echo "   hang with an empty log, and 'dv start' will fail."
echo
echo "   Re-approve: System Settings > Privacy & Security > Bluetooth"
echo "     - if 'divoom-send' is listed, toggle it OFF then ON"
echo "     - if it is not listed, remove any stale entry, then run ./dv start <MAC>"
echo
echo "   Check whether it worked:"
echo "     ./dv start <MAC> && ./dv stop"
