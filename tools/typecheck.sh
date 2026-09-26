#!/bin/bash
# Type-checks every Swift target against the iOS SDK with the Xcode toolchain's swiftc directly —
# no xcodebuild, no project, no signing. Fast feedback while editing, and it works on a machine
# where xcodebuild cannot run yet. It does NOT link or build the Go bridge; use xcodebuild for that.
#
#   tools/typecheck.sh [simulator|device]
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SWIFTC="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
if [ "${1:-simulator}" = device ]; then
  SDK="$DEV/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"; TARGET=arm64-apple-ios17.0
else
  SDK="$DEV/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"; TARGET=arm64-apple-ios17.0-simulator
fi
OUT=build/typecheck
rm -rf "$OUT"; mkdir -p "$OUT"
WG=Vendor/WireGuardKit/Sources
COMMON=(-sdk "$SDK" -target "$TARGET" -swift-version 5 -I "$OUT" -I "$WG/WireGuardKitC" -I "$WG/WireGuardKitGo" -D SWIFT_PACKAGE)

# SwiftPM generates Bundle.module; stand in for it.
echo 'import Foundation
extension Foundation.Bundle { static let module = Bundle.main }' > "$OUT/BundleModule.swift"

module() { # name, sources...
  local name=$1; shift
  echo "· $name"
  "$SWIFTC" -emit-module -parse-as-library -module-name "$name" -emit-module-path "$OUT/$name.swiftmodule" "${COMMON[@]}" "$@"
}
check() { # label, sources...
  local label=$1; shift
  echo "· $label"
  "$SWIFTC" -typecheck "${COMMON[@]}" "$@"
}

module WireGuardKit $WG/WireGuardKit/*.swift
module PortwayCore Packages/Portway/Sources/PortwayCore/*.swift "$OUT/BundleModule.swift"
module PortwayKit $(find Packages/Portway/Sources/PortwayKit -name '*.swift')
check "Portway (app)" -parse-as-library $(find App/Sources Shared -name '*.swift')
check "PortwayTunnel" -parse-as-library $(find Tunnel -name '*.swift')
check "PortwayWidgets" -parse-as-library $(find Widgets Shared -name '*.swift')
echo "OK"
