#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
    echo "Usage: ./scripts/build.sh [release|debug]" >&2
    exit 2
fi
cd "$ROOT"
./scripts/swift.sh build -c "$CONFIGURATION"
BIN_DIR="$(./scripts/swift.sh build -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/build/Aux.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Aux" "$APP/Contents/MacOS/Aux"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f "$APP/Contents/Resources/Aux.icns" || scripts/Icon.swift -nt "$APP/Contents/Resources/Aux.icns" ]]; then
    mkdir -p "$ROOT/.build/ModuleCache" "$ROOT/build/Aux.iconset"
    swift -module-cache-path "$ROOT/.build/ModuleCache" scripts/Icon.swift "$ROOT/build/Aux.iconset"
    iconutil -c icns "$ROOT/build/Aux.iconset" -o "$APP/Contents/Resources/Aux.icns"
fi
codesign --force --sign "${AUX_SIGN_IDENTITY:--}" --options runtime --entitlements Resources/Aux.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
