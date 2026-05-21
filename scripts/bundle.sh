#!/bin/bash
set -e

APP_NAME="ClaudeBar"
BUILD_DIR=".build/release"
BUNDLE_DIR="$BUILD_DIR/$APP_NAME.app"

echo "Building release..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/"
cp Sources/ClaudeBar/Info.plist "$BUNDLE_DIR/Contents/"
cp Sources/Resources/AppIcon.icns "$BUNDLE_DIR/Contents/Resources/"

# Bundle Sparkle.framework if present (SwiftPM dependency)
if [ -d "$BUILD_DIR/Sparkle.framework" ]; then
    mkdir -p "$BUNDLE_DIR/Contents/Frameworks"
    ditto "$BUILD_DIR/Sparkle.framework" "$BUNDLE_DIR/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
fi

# Use CODE_SIGN_IDENTITY env var if set, otherwise auto-detect
if [ -z "$CODE_SIGN_IDENTITY" ]; then
    CODE_SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/')
fi

if [ -z "$CODE_SIGN_IDENTITY" ]; then
    echo "Warning: No Apple Development certificate found. Using ad-hoc signing."
    echo "  Set CODE_SIGN_IDENTITY env var or install a development certificate."
    CODE_SIGN_IDENTITY="-"
fi

echo "Signing with: $CODE_SIGN_IDENTITY"
if [ -d "$BUNDLE_DIR/Contents/Frameworks/Sparkle.framework" ]; then
    SPARKLE_FW="$BUNDLE_DIR/Contents/Frameworks/Sparkle.framework"
    codesign --force --sign "$CODE_SIGN_IDENTITY" "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --sign "$CODE_SIGN_IDENTITY" "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
    codesign --force --sign "$CODE_SIGN_IDENTITY" "$SPARKLE_FW/Versions/B/Updater.app"
    codesign --force --sign "$CODE_SIGN_IDENTITY" "$SPARKLE_FW/Versions/B/Autoupdate"
    codesign --force --sign "$CODE_SIGN_IDENTITY" "$SPARKLE_FW"
fi
codesign --force --sign "$CODE_SIGN_IDENTITY" --entitlements Sources/ClaudeBar/ClaudeBar.entitlements "$BUNDLE_DIR"

echo "Done: $BUNDLE_DIR"
echo "To install: cp -r $BUNDLE_DIR /Applications/"
