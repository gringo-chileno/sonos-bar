#!/bin/bash
# Builds "Sonos Bar.app" into ./build and signs it with the local Apple Development identity.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Sonos Bar.app"
# Deletes only the previous build of the app in ./build (cannot be undone, but it is rebuilt right below).
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

xcrun swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos14 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  Sources/*.swift -o "$APP/Contents/MacOS/SonosBar"

IDENTITY=$(security find-identity -p codesigning -v | grep -m1 "Apple Development" | awk '{print $2}' || true)
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
