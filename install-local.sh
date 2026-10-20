#!/bin/sh
# Build this fork and replace the installed Boring Notch with it.
set -e
cd "$(dirname "$0")"

xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual build

APP="build/Build/Products/Release/boringNotch.app"
[ -d "$APP" ] || APP="$(ls -d build/Build/Products/Release/*.app | head -1)"

# Sign with the local "Boring Notch Local" identity when it exists, so macOS
# keeps Accessibility and other permissions across rebuilds (an ad-hoc
# signature changes every build and silently loses them).
IDENTITY="Boring Notch Local"
security find-certificate -c "$IDENTITY" >/dev/null 2>&1 || IDENTITY="-"

# Prebuilt frameworks keep the upstream team's signature, which dyld refuses
# to load into our app. Re-sign them, then the helper, then reseal the app.
for fw in "$APP"/Contents/Frameworks/*.framework; do
  codesign --force --sign "$IDENTITY" "$fw"
done
for xpc in "$APP"/Contents/XPCServices/*.xpc; do
  codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements "$xpc"
done
codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements "$APP"

osascript -e 'quit app id "theboringteam.boringnotch"' 2>/dev/null || true
sleep 1
rm -rf "/Applications/Boring Notch.app"
ditto "$APP" "/Applications/Boring Notch.app"

open "/Applications/Boring Notch.app"
