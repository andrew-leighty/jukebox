#!/bin/bash
# Builds the Jukebox helper and installs it as a login service (LaunchAgent).
# Re-run after changing Sources/main.swift.
set -euo pipefail

cd "$(dirname "$0")"
LABEL=com.andrewleighty.jukebox
# Packaged as an app so macOS lists it by name under Privacy & Security → Automation.
APP="$HOME/Applications/Jukebox.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/Jukebox.log"

mkdir -p build "$APP/Contents/MacOS"
swiftc -O -swift-version 5 Sources/main.swift -o build/jukebox \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
codesign -s - -i "$LABEL" -f build/jukebox
cp Info.plist "$APP/Contents/Info.plist"
cp build/jukebox "$APP/Contents/MacOS/jukebox"
codesign -s - -i "$LABEL" -f "$APP"
# Older installs ran a bare binary from Application Support.
rm -f "$HOME/Library/Application Support/Jukebox/jukebox"

if ! security find-generic-password -s jukebox-ha-token >/dev/null 2>&1; then
    echo "Note: no Home Assistant token in the Keychain yet. See README.md, step 1."
fi

cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/jukebox</string><string>serve</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Installed. Log: $LOG"
