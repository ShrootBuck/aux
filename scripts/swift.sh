#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache"
mkdir -p "$ROOT/.build/cache" "$ROOT/.build/config" "$ROOT/.build/security"
# Swift 6.4's CLT build engine doesn't discover its bundled Testing macros.
# Full Xcode toolchains discover them themselves; load the CLT plugin if present.
EXTRA=()
if [[ "${1:-}" == "test" ]]; then
    SWIFT_BIN="$(dirname "$(xcrun --find swiftc)")"
    TESTING_PLUGIN="$SWIFT_BIN/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
    if [[ -f "$TESTING_PLUGIN" ]]; then
        EXTRA=(-Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")
    fi
fi
exec swift "$@" ${EXTRA[@]+"${EXTRA[@]}"} --disable-sandbox --cache-path "$ROOT/.build/cache" --config-path "$ROOT/.build/config" --security-path "$ROOT/.build/security"
