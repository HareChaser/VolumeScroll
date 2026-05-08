#!/bin/bash
set -e

APP="VolumeScroll"
BUILD_DIR="build"
BUNDLE="$BUILD_DIR/$APP.app"
CONTENTS="$BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "→ Cleaning previous build..."
rm -rf "$BUILD_DIR" icon_gen
mkdir -p "$MACOS" "$RESOURCES"

echo "→ Generating icon..."
swift src/generate_icon.swift icon_gen
iconutil -c icns icon_gen/AppIcon.iconset -o "$RESOURCES/AppIcon.icns"
echo "  ✓ AppIcon.icns"

echo "→ Compiling Swift source..."
swiftc -O \
    -target arm64-apple-macos13.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -suppress-warnings \
    -o "$MACOS/$APP" \
    src/main.swift

echo "→ Copying Info.plist..."
cp src/Info.plist "$CONTENTS/Info.plist"

echo ""
echo "✓ Build complete: $BUNDLE"
echo ""
echo "  Run now:   open $BUNDLE"
echo "  Install:   cp -r $BUNDLE /Applications/"
echo ""
