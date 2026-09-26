#!/bin/bash
# Runs PortwayCore's unit tests on macOS without XCTest (see tools/testshim).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/core-tests; mkdir -p "$OUT"
sed -e 's/^import XCTest$//' -e 's/^@testable import PortwayCore$//' Packages/Portway/Tests/PortwayCoreTests/*.swift > "$OUT/Tests.swift"
echo 'import Foundation
extension Foundation.Bundle { static let module = Bundle.main }' > "$OUT/BundleModule.swift"
# Register every test method: (Class.method, closure).
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
rm -f "$OUT/run"
swiftc -O -parse-as-library -module-name CoreTests -o "$OUT/run" \
  Packages/Portway/Sources/PortwayCore/*.swift "$OUT/BundleModule.swift" tools/testshim/XCTestShim.swift "$OUT/Tests.swift" 2>&1 | grep -E "error:" && { echo "compile failed"; exit 1; } || true
[ -x "$OUT/run" ] || { echo "compile failed"; exit 1; }
status=0
"$OUT/run" || status=$?
pkill -f "tools/mock_panel.py" 2>/dev/null || true
exit $status
