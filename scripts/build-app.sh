#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PWD/dist/VibeMonitoring.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp Assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/VibeMonitoring" "$APP_DIR/Contents/MacOS/.VibeMonitoring.new"
mv -f "$APP_DIR/Contents/MacOS/.VibeMonitoring.new" "$APP_DIR/Contents/MacOS/VibeMonitoring"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.vibemonitoring.app</string>
  <key>CFBundleName</key><string>VibeMonitoring</string>
  <key>CFBundleDisplayName</key><string>VibeMonitoring</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>VibeMonitoring</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.10</string>
  <key>CFBundleVersion</key><string>15</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
printf '\nBuilt: %s\n' "$APP_DIR"
