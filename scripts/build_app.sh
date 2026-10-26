#!/bin/bash
# Assembles "KAIkei.app" next to the build output (outside OneDrive, so codesign accepts it).
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${SCRATCH:-$HOME/Library/Caches/ClaudeUsageWidget/build}"
APP="$(dirname "$SCRATCH")/KAIkei.app"

swift build -c release --scratch-path "$SCRATCH" >&2
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/ClaudeUsageWidget"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeUsageWidget"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>KAIkei</string>
  <key>CFBundleDisplayName</key><string>KAIkei</string>
  <key>CFBundleIdentifier</key><string>local.claude-usage-widget</string>
  <key>CFBundleExecutable</key><string>ClaudeUsageWidget</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>KAIkei types /compact or /clear into the Terminal or iTerm2 tab you choose.</string>
</dict></plist>
PLIST
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP" >&2
echo "$APP"
