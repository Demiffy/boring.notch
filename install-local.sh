#!/bin/sh
# Build this fork and replace the installed Boring Notch with it.
set -e
cd "$(dirname "$0")"

xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual build

APP="build/Build/Products/Release/boringNotch.app"
[ -d "$APP" ] || APP="$(ls -d build/Build/Products/Release/*.app | head -1)"

# Prebuilt frameworks keep the upstream team's signature, which dyld refuses
# to load into an ad-hoc signed app. Re-sign them, then reseal the app.
for fw in "$APP"/Contents/Frameworks/*.framework; do
  codesign --force --sign - "$fw"
done
codesign --force --sign - --preserve-metadata=entitlements,requirements "$APP"

osascript -e 'quit app id "theboringteam.boringnotch"' 2>/dev/null || true
sleep 1
rm -rf "/Applications/Boring Notch.app"
ditto "$APP" "/Applications/Boring Notch.app"

open "/Applications/Boring Notch.app"
