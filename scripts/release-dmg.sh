#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# != 3 ]]; then
  printf 'Usage: %s APP_PATH DEVELOPER_ID_IDENTITY NOTARY_KEYCHAIN_PROFILE\n' "$0" >&2
  exit 1
fi
APP_PATH="$1"
IDENTITY="$2"
NOTARY_PROFILE="$3"
codesign --verify --deep --strict "$APP_PATH"
SIGNING_INFO="$(codesign -dvv "$APP_PATH" 2>&1)"
if [[ "$SIGNING_INFO" != *'Authority=Developer ID Application:'* || "$SIGNING_INFO" != *'runtime'* ]]; then
  printf 'Sign the app with Developer ID Application and hardened runtime first.\n' >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  printf 'Invalid release version.\n' >&2
  exit 1
fi
ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/VibeMonitoring")"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vibe-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP_PATH" "$STAGE/VibeMonitoring.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
DMG="$PWD/dist/VibeMonitoring-$VERSION-${ARCHS// /-}.dmg"
hdiutil create -ov -format UDZO -volname VibeMonitoring -srcfolder "$STAGE" "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"
printf '\nNotarized DMG: %s\nNot uploaded to GitHub or installed.\n' "$DMG"
