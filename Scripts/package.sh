#!/bin/sh
# Zips the built app for a release: dist/SMC-Fan-<version>.zip plus a SHA-256 checksum file.
# Run ./build.sh first.
set -eu
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
APP="build/SMC Fan.app"
ZIP="dist/SMC-Fan-$VERSION.zip"

[ -d "$APP" ] || { echo "Build the app first: ./build.sh" >&2; exit 1; }
mkdir -p dist
rm -f "$ZIP" "$ZIP.sha256"
# ditto keeps the bundle's extended attributes and signature intact
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Packaged $ZIP"
cat "$ZIP.sha256"
