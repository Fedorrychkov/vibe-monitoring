#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/fetch-xray.py
VIBE_BUILD_VPN=1 swift build -c release --product VibeMonitoring
VIBE_BUILD_VPN=1 swift build -c release --product VibeTunnel
VIBE_BUILD_VPN=1 swift run -c release vibe-vpn-check
VPN_BIN_DIR="$(VIBE_BUILD_VPN=1 swift build -c release --show-bin-path)"
VPN_APP_DIR="$PWD/dist/VibeMonitoring-VPN.app"
VPN_EXTENSION_DIR="$VPN_APP_DIR/Contents/Library/SystemExtensions/dev.vibemonitoring.app.tunnel.systemextension"
mkdir -p "$VPN_APP_DIR/Contents/MacOS" "$VPN_APP_DIR/Contents/Resources" "$VPN_EXTENSION_DIR/Contents/MacOS"
cp "$VPN_BIN_DIR/VibeMonitoring" "$VPN_APP_DIR/Contents/MacOS/.VibeMonitoring.new"
mv -f "$VPN_APP_DIR/Contents/MacOS/.VibeMonitoring.new" "$VPN_APP_DIR/Contents/MacOS/VibeMonitoring"
cp "$VPN_BIN_DIR/VibeTunnel" "$VPN_EXTENSION_DIR/Contents/MacOS/.VibeTunnel.new"
mv -f "$VPN_EXTENSION_DIR/Contents/MacOS/.VibeTunnel.new" "$VPN_EXTENSION_DIR/Contents/MacOS/VibeTunnel"

python3 - "$VPN_APP_DIR" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1])
base={
    'CFBundleIdentifier':'dev.vibemonitoring.app', 'CFBundleName':'VibeMonitoring',
    'CFBundleDisplayName':'VibeMonitoring', 'CFBundleExecutable':'VibeMonitoring',
    'CFBundlePackageType':'APPL', 'CFBundleShortVersionString':'0.3.0', 'CFBundleVersion':'5',
    'LSMinimumSystemVersion':'13.0','LSUIElement':True,'NSHighResolutionCapable':True,
    'NSPrincipalClass':'NSApplication','NSAppTransportSecurity':{'NSAllowsLocalNetworking':True},
    'VibeVPNKeychainGroup':'UNPROVISIONED.dev.vibemonitoring.vpn',
    'NSSystemExtensionUsageDescription':'VibeMonitoring uses a separate VPN component to tunnel network traffic independently of the menu app.',
}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(base))
extension=app/'Contents/Library/SystemExtensions/dev.vibemonitoring.app.tunnel.systemextension/Contents/Info.plist'
extension.write_bytes(plistlib.dumps({
    'CFBundleIdentifier':'dev.vibemonitoring.app.tunnel','CFBundleName':'VibeMonitoring Tunnel',
    'CFBundleExecutable':'VibeTunnel','CFBundlePackageType':'SYSX',
    'CFBundleShortVersionString':'0.3.0','CFBundleVersion':'5','LSMinimumSystemVersion':'13.0',
    'NetworkExtension':{
        'NEMachServiceName':'$(TeamIdentifierPrefix)dev.vibemonitoring.app.tunnel',
        'NEProviderClasses':{'com.apple.networkextension.packet-tunnel':'VibePacketTunnelProvider'},
    },
}))
PY
cp LICENSE "$VPN_APP_DIR/Contents/Resources/VibeMonitoring-LICENSE"
cp THIRD_PARTY_NOTICES.md "$VPN_APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
codesign --force --sign - "$VPN_EXTENSION_DIR"
codesign --force --sign - "$VPN_APP_DIR"
codesign --verify --deep --strict "$VPN_APP_DIR"
printf '\nBuilt VPN candidate: %s\n' "$VPN_APP_DIR"
printf 'Ad-hoc build only: installation/connection is gated until proper signing and provisioning. No network settings were changed.\n'
