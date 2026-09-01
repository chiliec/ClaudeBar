#!/bin/bash
set -e

APP_NAME="ClaudeBar"
# Universal build: SwiftPM puts multi-arch output under .build/apple/Products,
# not .build/release. Intel Macs can't launch an arm64-only binary at all.
BUILD_DIR=".build/apple/Products/Release"
BUNDLE_DIR="$BUILD_DIR/$APP_NAME.app"

echo "Building release (universal)..."
swift build -c release --arch arm64 --arch x86_64

echo "Creating app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/"
cp Sources/ClaudeBar/Info.plist "$BUNDLE_DIR/Contents/"
cp Sources/Resources/AppIcon.icns "$BUNDLE_DIR/Contents/Resources/"
# ClaudeBarUI's localized strings. Bundle.module looks for this beside the other
# resources; without it every `Text(..., bundle: .module)` traps at render time,
# so the app crashes the moment the popover lays out. Must land before signing.
ditto "$BUILD_DIR/${APP_NAME}_ClaudeBarUI.bundle" \
      "$BUNDLE_DIR/Contents/Resources/${APP_NAME}_ClaudeBarUI.bundle"

# Bundle Sparkle.framework if present (SwiftPM dependency)
if [ -d "$BUILD_DIR/Sparkle.framework" ]; then
    mkdir -p "$BUNDLE_DIR/Contents/Frameworks"
    ditto "$BUILD_DIR/Sparkle.framework" "$BUNDLE_DIR/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
fi

# shellcheck source=lib/sign.sh
source "$(dirname "$0")/lib/sign.sh"

CODE_SIGN_IDENTITY=$(resolve_identity dev)
echo "Signing with: $CODE_SIGN_IDENTITY"
sign_bundle "$BUNDLE_DIR" "$CODE_SIGN_IDENTITY" dev
verify_bundle "$BUNDLE_DIR"

echo "Done: $BUNDLE_DIR"
echo "To install: cp -r $BUNDLE_DIR /Applications/"
