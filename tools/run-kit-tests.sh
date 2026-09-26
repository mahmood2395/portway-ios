#!/bin/bash
# Runs PortwayKit's tests on macOS (parser, importer, bring-up rewriting) with the XCTest shim.
# Builds wireguard-go for macOS once, since WireGuardKit links it.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/kit-tests; mkdir -p "$OUT"
WG=Vendor/WireGuardKit/Sources
if [ ! -f "$OUT/wg/libwg-go.a" ]; then
  make -s -C "$WG/WireGuardKitGo" PLATFORM_NAME=macosx ARCHS=arm64 \
    CONFIGURATION_BUILD_DIR="$PWD/$OUT/wg" CONFIGURATION_TEMP_DIR="$PWD/$OUT/wg-tmp" > "$OUT/wg.log" 2>&1
fi
for c in "$WG"/WireGuardKitC/*.c; do clang -c -O2 "$c" -o "$OUT/$(basename "$c" .c).o"; done
cat Packages/Portway/Tests/PortwayKitTests/*.swift | sed -e '/^import XCTest$/d' -e '/^@testable import/d' -e '/^import WireGuardKit$/d' > "$OUT/Tests.swift"
python3 - "$OUT/Tests.swift" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
entries = []
for cls, body in re.findall(r'final class (\w+): XCTestCase \{(.*?)\n\}', s, re.S):
    for m in re.finditer(r'func (test\w+)\(\)( throws)?', body):
        call = f"try {cls}().{m.group(1)}()" if m.group(2) else f"{cls}().{m.group(1)}()"
        entries.append(f'    ("{cls}.{m.group(1)}", {{ {call} }}),')
s += "\nlet shimRegistry: [(String, () throws -> Void)] = [\n" + "\n".join(entries) + "\n]\n"
open(p, "w").write(s)
PY
echo 'import Foundation
extension Foundation.Bundle { static let module = Bundle.main }' > "$OUT/BundleModule.swift"
# One module: WireGuardKit + PortwayCore + PortwayKit + tests, so no cross-module plumbing —
# which means their imports of each other have to go.
rm -rf "$OUT/src"; mkdir -p "$OUT/src"
for f in Packages/Portway/Sources/PortwayCore/*.swift $(find Packages/Portway/Sources/PortwayKit -name '*.swift'); do
  sed -e '/^import PortwayCore$/d' -e '/^import WireGuardKit$/d' -e '/^@preconcurrency import WireGuardKit$/d' "$f" > "$OUT/src/$(basename "$f")"
done
rm -f "$OUT/run"
swiftc -parse-as-library -module-name KitTests -D SWIFT_PACKAGE -o "$OUT/run" \
  -I "$WG/WireGuardKitC" -I "$WG/WireGuardKitGo" -L "$OUT/wg" -lwg-go -lresolv "$OUT"/*.o \
  $(ls "$WG"/WireGuardKit/*.swift) "$OUT"/src/*.swift "$OUT/BundleModule.swift" \
  tools/testshim/XCTestShim.swift "$OUT/Tests.swift" 2>&1 \
  | grep -E "error:" && { echo "compile failed"; exit 1; } || true
[ -x "$OUT/run" ] || { echo "compile failed"; exit 1; }
"$OUT/run"
