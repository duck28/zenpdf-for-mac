#!/bin/bash
# Builds ZenPDF.app and a disk image to install it, without Xcode or an Apple Developer account.
#
#   ./build.sh            release build → build/ZenPDF.app and build/ZenPDF.dmg
#   ./build.sh debug      debug build (no disk image)
#
# The app is ad-hoc signed unless you pass a signing identity:
#
#   SIGN_IDENTITY="Developer ID Application: …" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/ZenPDF.app"
TRIPLE="arm64-apple-macosx14.0"

# Apple silicon only, as the website and the release file name say.
swift build -c "$CONFIG" --triple "$TRIPLE"
BINARY="$(swift build -c "$CONFIG" --triple "$TRIPLE" --show-bin-path)/ZenPDF"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/ZenPDF"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The logo's two alpha masks (see ZenLogo in Theme.swift).
cp Resources/Branding/ink.png Resources/Branding/dot.png "$APP/Contents/Resources/"

# Generate the standard macOS icon sizes from the source icon on every build.
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" Resources/Branding/zenpdf-icon.png \
        --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z "$((SIZE * 2))" "$((SIZE * 2))" Resources/Branding/zenpdf-icon.png \
        --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${SIGN_IDENTITY:-ad-hoc})"

if [ "$CONFIG" = "release" ]; then
    # A disk image with the app and a link to Applications, the usual way to install a Mac app.
    STAGE="$ICON_TMP/dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f build/ZenPDF.dmg
    hdiutil create -volname "ZenPDF" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet build/ZenPDF.dmg
    echo "Built build/ZenPDF.dmg"
fi
echo "Run it with: open $APP"
