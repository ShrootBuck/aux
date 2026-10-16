#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:?Usage: ./scripts/package.sh VERSION}"
python3 scripts/release.py validate "$VERSION"
export AUX_VERSION="$VERSION"
export AUX_OUTPUT_APP="$ROOT/build/release/Aux.app"
# Public builds currently use free ad-hoc signing, without Apple notarization.
export AUX_SIGN_IDENTITY=-
./scripts/build.sh release universal
mkdir -p dist build/release
python3 -m venv .venv-release
.venv-release/bin/python -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: -r packaging/requirements.txt
swift -module-cache-path "$ROOT/.build/ModuleCache" packaging/Background.swift "$ROOT/build/release/background.tiff"
rm -f dist/Aux.dmg dist/Aux.zip
.venv-release/bin/dmgbuild -s packaging/dmg-settings.py \
    -D "app=$AUX_OUTPUT_APP" -D "background=$ROOT/build/release/background.tiff" \
    "Aux $VERSION" dist/Aux.dmg
ditto -c -k --sequesterRsrc --keepParent "$AUX_OUTPUT_APP" dist/Aux.zip
python3 scripts/release.py manifest "$VERSION"
./scripts/verify-release.sh "$VERSION"
echo "Packaged dist/Aux.dmg and dist/Aux.zip"
