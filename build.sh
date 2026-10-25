#!/bin/zsh
# Compile, assemble le bundle, signe (Developer ID) et installe dans /Applications.
# Usage : ./build.sh [--notarize] [--no-install]
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${SIGN_IDENTITY:-F6E6688B309BBCACF52B3D5AB1C5061B68D0D0E7}" # Developer ID Application: IACHI Dimitri Fabien (G2, 2031)
APP=build/MacAltTab.app

swift build -c release
BIN=$(swift build -c release --show-bin-path)/MacAltTab

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacAltTab"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --timestamp --entitlements Resources/MacAltTab.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ " $* " == *" --notarize "* ]]; then
  # Profil créé une fois : xcrun notarytool store-credentials notary --apple-id … --team-id 5D6QHL72QC
  ditto -c -k --keepParent "$APP" build/MacAltTab.zip
  xcrun notarytool submit build/MacAltTab.zip --keychain-profile notary --wait --timeout 30m
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

if [[ " $* " != *" --no-install "* ]]; then
  pkill -x MacAltTab && sleep 1 || true
  rm -rf /Applications/MacAltTab.app
  cp -R "$APP" /Applications/
  open /Applications/MacAltTab.app
  echo "Installé et lancé : /Applications/MacAltTab.app"
fi
