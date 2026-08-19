#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/LyricBar.app"
# Signing identity: override with SIGN_IDENTITY, else use the first Apple
# Development cert in the keychain, else fall back to ad-hoc.
IDENT="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')}"
IDENT="${IDENT:--}"
echo "signing as: $IDENT"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LyricBar "$APP/Contents/MacOS/LyricBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>LyricBar</string>
  <key>CFBundleDisplayName</key><string>LyricBar</string>
  <key>CFBundleIdentifier</key><string>quest.ohm.lyricbar</string>
  <key>CFBundleExecutable</key><string>LyricBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>LyricBar reads the currently playing track from Spotify to show its lyrics.</string>
</dict></plist>
PLIST

cat > /tmp/lyricbar.entitlements <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key><true/>
  <key>com.apple.security.network.client</key><true/>
</dict></plist>
ENT

# Stable bundle id + stable identity keeps the TCC grant across rebuilds.
codesign --force --deep --options runtime \
         --entitlements /tmp/lyricbar.entitlements \
         --sign "$IDENT" "$APP"
codesign -v -vvv "$APP" 2>&1 | tail -2
echo "built: $APP"
