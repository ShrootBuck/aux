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
cat > build/release/Install.txt <<'EOF'
INSTALL AUX

1. Drag Aux into Applications.
2. Eject this disk image and open Aux from Applications.
3. Aux appears as a waveform in the menu bar.

This free build is not Apple-notarized. If macOS blocks it and you trust
this download from github.com/ShrootBuck/aux, open System Settings >
Privacy & Security, find the blocked Aux app, and choose Open Anyway.
macOS may ask you to confirm the first launch. You do not need to disable
Gatekeeper or run any Terminal commands.

Open Apple Music and Discord, then choose Connect Music in Aux and
allow access. The Discord application ID is already configured.

UPDATING

Quit Aux before replacing your Applications copy. Your settings stay saved.
Download new versions at https://github.com/ShrootBuck/aux/releases/latest

https://support.apple.com/102445
EOF
rm -f dist/Aux.dmg dist/Aux.zip
.venv-release/bin/dmgbuild -s packaging/dmg-settings.py \
    -D "app=$AUX_OUTPUT_APP" -D "readme=$ROOT/build/release/Install.txt" \
    "Aux $VERSION" dist/Aux.dmg
ditto -c -k --sequesterRsrc --keepParent "$AUX_OUTPUT_APP" dist/Aux.zip
python3 scripts/release.py manifest "$VERSION"
./scripts/verify-release.sh "$VERSION"
echo "Packaged dist/Aux.dmg and dist/Aux.zip"
