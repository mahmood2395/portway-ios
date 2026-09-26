#!/bin/bash
# Builds for the simulator, installs, launches with the given arguments and screenshots.
#   tools/sim.sh build
#   tools/sim.sh shot <name> [launch args...]      → build/shots/<name>.png
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DEVICE=${SIM_DEVICE:-iPhone 17}
APP=build/dd/Build/Products/Debug-iphonesimulator/Portway.app
case "$1" in
  build)
    xcodegen generate -q
    xcodebuild -project Portway.xcodeproj -scheme Portway -sdk iphonesimulator -derivedDataPath build/dd \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build > build/xcb.log 2>&1 \
      || { grep -E "error:" build/xcb.log | sort -u | head -20; exit 1; }
    xcrun simctl boot "$DEVICE" 2>/dev/null || true
    xcrun simctl bootstatus "$DEVICE" -b > /dev/null
    xcrun simctl install "$DEVICE" "$APP"
    echo "built and installed on $DEVICE" ;;
  shot)
    name=$2; shift 2
    BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")
    xcrun simctl terminate "$DEVICE" "$BID" 2>/dev/null || true
    xcrun simctl launch "$DEVICE" "$BID" -demo "$@" > /dev/null
    sleep "${SHOT_DELAY:-4}"
    mkdir -p build/shots
    xcrun simctl io "$DEVICE" screenshot "build/shots/$name.png" > /dev/null 2>&1
    echo "build/shots/$name.png" ;;
esac
