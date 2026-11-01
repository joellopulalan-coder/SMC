#!/bin/sh
# Builds the command-line tool (build/smcfan) and the app (build/SMC Fan.app).
#
#   ./build.sh            build
#   ./build.sh install    build and copy the app to /Applications
#
# Needs Xcode or the Command Line Tools (xcode-select --install) on an Apple Silicon Mac.
set -eu
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 0)
APP="build/SMC Fan.app"
TARGET=arm64-apple-macos15
CFLAGS="-O2 -Wall -Wextra -mmacosx-version-min=15.0 -ICore"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# C: command-line tool and daemon (the same binary)
clang $CFLAGS -DSMCFAN_VERSION="\"$VERSION\"" -o build/smcfan Daemon/smcfan.c Core/smc.c -framework IOKit
cp build/smcfan "$APP/Contents/Resources/smcfand"

# Swift: the menu bar app, with the C core linked in through a bridging header
clang $CFLAGS -c Core/smc.c -o build/smc.o
clang $CFLAGS -c Core/stress.c -o build/stress.o
swiftc -O -parse-as-library -swift-version 5 -target "$TARGET" \
    -Xcc -ICore -import-objc-header Resources/Bridging.h App/*.swift build/smc.o build/stress.o \
    -framework IOKit -framework Metal \
    -o "$APP/Contents/MacOS/SMCFan"

cp Resources/Info.plist "$APP/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp Resources/install.sh Resources/uninstall.sh "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# Icon
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
swift Scripts/make_icon.swift build/icon.png
for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough to run locally. See README for Gatekeeper on downloaded builds.
codesign --force --deep --sign - "$APP"
echo "Built SMC Fan $VERSION ($BUILD_NUMBER): $APP"

if [ "${1:-}" = "install" ]; then
    pkill -x SMCFan 2>/dev/null || true
    rm -rf "/Applications/SMC Fan.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/SMC Fan.app"
fi
