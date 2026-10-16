#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
ARCHITECTURE="${2:-native}"
if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
    echo "Usage: ./scripts/build.sh [release|debug] [native|universal]" >&2
    exit 2
fi
if [[ "$ARCHITECTURE" != "native" && "$ARCHITECTURE" != "universal" ]]; then
    echo "Architecture must be native or universal." >&2
    exit 2
fi
cd "$ROOT"
mkdir -p build
APP="${AUX_OUTPUT_APP:-$ROOT/build/Aux.app}"
if [[ "$APP" != /* ]]; then APP="$ROOT/$APP"; fi
if [[ "$ARCHITECTURE" == "universal" ]]; then
    BINARIES=()
    for ARCH in arm64 x86_64; do
        OPTIONS=(-c "$CONFIGURATION" --build-system native --triple "$ARCH-apple-macosx14.0" --scratch-path "$ROOT/.build/$ARCH")
        ./scripts/swift.sh build "${OPTIONS[@]}"
        BIN_DIR="$(./scripts/swift.sh build "${OPTIONS[@]}" --show-bin-path)"
        BINARIES+=("$BIN_DIR/Aux")
    done
    lipo -create "${BINARIES[@]}" -output "$ROOT/build/Aux-universal"
    BINARY="$ROOT/build/Aux-universal"
    ARCHS="$(lipo -archs "$BINARY")"
    [[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]]
else
    ./scripts/swift.sh build -c "$CONFIGURATION"
    BIN_DIR="$(./scripts/swift.sh build -c "$CONFIGURATION" --show-bin-path)"
    BINARY="$BIN_DIR/Aux"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Aux"
cp Resources/Info.plist "$APP/Contents/Info.plist"
python3 - "$APP/Contents/Info.plist" <<'PY'
import os, plistlib, re, sys
path = sys.argv[1]
with open(path, "rb") as stream:
    info = plistlib.load(stream)
version = os.environ.get("AUX_VERSION", info["CFBundleShortVersionString"])
build = os.environ.get("AUX_BUILD_NUMBER", info["CFBundleVersion"])
if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
    raise SystemExit("AUX_VERSION must be a version such as 0.1.1")
if not re.fullmatch(r"[1-9][0-9]*", build):
    raise SystemExit("AUX_BUILD_NUMBER must be a positive integer")
info["CFBundleShortVersionString"] = version
info["CFBundleVersion"] = build
if os.environ.get("GITHUB_SHA"):
    info["AuxSourceRevision"] = os.environ["GITHUB_SHA"]
with open(path, "wb") as stream:
    plistlib.dump(info, stream)
PY
if [[ ! -f build/Aux.icns || scripts/Icon.swift -nt build/Aux.icns ]]; then
    mkdir -p "$ROOT/.build/ModuleCache" "$ROOT/build/Aux.iconset"
    swift -module-cache-path "$ROOT/.build/ModuleCache" scripts/Icon.swift "$ROOT/build/Aux.iconset"
    iconutil -c icns "$ROOT/build/Aux.iconset" -o "$ROOT/build/Aux.icns"
fi
cp build/Aux.icns "$APP/Contents/Resources/Aux.icns"
codesign --force --sign "${AUX_SIGN_IDENTITY:--}" --options runtime --entitlements Resources/Aux.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
