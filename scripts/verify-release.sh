#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:?Expected release version}"
WORK="$(mktemp -d "$ROOT/build/verify-release.XXXXXX")"
MOUNT="$WORK/mounted"
MOUNTED=false
cleanup() {
    if [[ "$MOUNTED" == true ]]; then hdiutil detach "$MOUNT" -quiet || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
verify_app() {
    local app="$1"
    codesign --verify --strict "$app"
    local archs
    archs="$(lipo -archs "$app/Contents/MacOS/Aux")"
    [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]]
    python3 - "$app/Contents/Info.plist" "$VERSION" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as stream:
    info = plistlib.load(stream)
assert info["CFBundleShortVersionString"] == sys.argv[2], "Wrong version in archive"
assert info["CFBundleIdentifier"] == "com.zayd.aux", "Wrong app in archive"
assert info["LSMinimumSystemVersion"] == "14.0", "Unexpected minimum macOS version"
PY
}
ditto -x -k dist/Aux.zip "$WORK/zip"
verify_app "$WORK/zip/Aux.app"
hdiutil verify dist/Aux.dmg
mkdir -p "$MOUNT"
hdiutil attach dist/Aux.dmg -readonly -nobrowse -mountpoint "$MOUNT" -quiet
MOUNTED=true
verify_app "$MOUNT/Aux.app"
[[ "$(readlink "$MOUNT/Applications")" == /Applications ]]
[[ -f "$MOUNT/Install.txt" ]]
(cd dist && shasum -a 256 -c SHA256SUMS.txt)
