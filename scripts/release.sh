#!/bin/bash
set -euo pipefail

# Usage: ./scripts/release.sh <version> [changes-file]
# Example: ./scripts/release.sh 0.0.14 release-notes/0.0.14.md

VERSION="${1:?Usage: ./scripts/release.sh <version> [changes-file]}"
CHANGES_FILE="${2:-}"
if [ -n "$CHANGES_FILE" ] && [ ! -f "$CHANGES_FILE" ]; then
    echo "Error: changes file '$CHANGES_FILE' not found"
    exit 1
fi

APP_NAME="ClaudeBar"
BUILD_DIR=".build/release"
BUNDLE_DIR="$BUILD_DIR/$APP_NAME.app"
ZIP_FILE="$BUILD_DIR/$APP_NAME.zip"
SIGN_IDENTITY="Apple Development: Vladimir Babin (8FNR8DGE9N)"
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-./scripts/sparkle-bin}"
SIGN_UPDATE="$SPARKLE_BIN_DIR/sign_update"
TAP_PATH="${HOMEBREW_TAP_PATH:-../homebrew-tap}"
CASK_FILE="$TAP_PATH/Casks/claudebar.rb"
APPCAST_FILE="./appcast.xml"

# ---- Prerequisite checks ----------------------------------------------------

if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "ERROR: signing identity '$SIGN_IDENTITY' not found in Keychain."
    exit 1
fi

if [ ! -x "$SIGN_UPDATE" ]; then
    echo "ERROR: Sparkle sign_update not found at $SIGN_UPDATE"
    echo "Run Task 2 of the brew-cask-sparkle plan to install the Sparkle CLI tools."
    exit 1
fi

if ! "$SIGN_UPDATE" --help 2>&1 | grep -qi "usage"; then
    echo "ERROR: $SIGN_UPDATE is not runnable. Try 'xattr -d com.apple.quarantine $SIGN_UPDATE'."
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not found. Install via 'brew install gh' and 'gh auth login'."
    exit 1
fi

if [ ! -f "$CASK_FILE" ]; then
    echo "ERROR: cask file not found at $CASK_FILE"
    echo "Clone chiliec/homebrew-tap to $TAP_PATH or set HOMEBREW_TAP_PATH=/path/to/clone."
    exit 1
fi

# ---- Bump version in Info.plist --------------------------------------------

echo "==> Updating Info.plist to $VERSION"
sed -i '' "s/<string>[0-9]*\.[0-9]*\.[0-9]*<\/string>/<string>$VERSION<\/string>/g" \
    Sources/ClaudeBar/Info.plist

# ---- Build, sign, bundle, test ---------------------------------------------

echo "==> Building release"
swift build -c release

echo "==> Creating app bundle"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/"
cp Sources/ClaudeBar/Info.plist "$BUNDLE_DIR/Contents/"
cp Sources/Resources/AppIcon.icns "$BUNDLE_DIR/Contents/Resources/"

echo "==> Signing app bundle"
codesign --force --sign "$SIGN_IDENTITY" "$BUNDLE_DIR"

echo "==> Zipping"
rm -f "$ZIP_FILE"
(cd "$BUILD_DIR" && zip -r -q "$APP_NAME.zip" "$APP_NAME.app")

echo "==> Running tests"
swift test 2>&1 | tail -3

# ---- Sparkle signature + appcast entry -------------------------------------

echo "==> Signing update with Sparkle EdDSA key"
# sign_update prints a single line like:
#   sparkle:edSignature="abc...==" length="123456"
SIGN_OUTPUT=$("$SIGN_UPDATE" "$ZIP_FILE")
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
if [ -z "$ED_SIGNATURE" ] || [ -z "$LENGTH" ]; then
    echo "ERROR: failed to parse sign_update output: $SIGN_OUTPUT"
    exit 1
fi
SHA256=$(shasum -a 256 "$ZIP_FILE" | awk '{print $1}')
PUBDATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")
ENCLOSURE_URL="https://github.com/chiliec/ClaudeBar/releases/download/v$VERSION/ClaudeBar.zip"
RELEASE_NOTES=""
if [ -n "$CHANGES_FILE" ]; then
    RELEASE_NOTES=$(cat "$CHANGES_FILE")
fi

echo "==> Inserting <item> into $APPCAST_FILE"
# Write the new <item> to a temp file because BSD awk can't take multi-line -v values.
NEW_ITEM_FILE=$(mktemp)
cat > "$NEW_ITEM_FILE" <<ITEM
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$RELEASE_NOTES]]></description>
      <enclosure url="$ENCLOSURE_URL" sparkle:edSignature="$ED_SIGNATURE" length="$LENGTH" type="application/octet-stream"/>
    </item>
ITEM
# Insert the new item as the first child of <channel>, after the <language> line.
TMP_APPCAST=$(mktemp)
awk -v itemfile="$NEW_ITEM_FILE" '
    /<\/language>/ {
        print
        while ((getline line < itemfile) > 0) print line
        close(itemfile)
        next
    }
    { print }
' "$APPCAST_FILE" > "$TMP_APPCAST"
mv "$TMP_APPCAST" "$APPCAST_FILE"
rm -f "$NEW_ITEM_FILE"

# ---- Commit + tag + push the ClaudeBar repo --------------------------------

echo "==> Committing release in ClaudeBar repo"
git add Sources/ClaudeBar/Info.plist "$APPCAST_FILE"
git diff --cached --quiet || git commit -m "release: v$VERSION"
git tag -f "v$VERSION"
git push origin main --tags --force

# ---- GitHub release --------------------------------------------------------

echo "==> Creating GitHub release"
NOTES_FILE=$(mktemp)
trap 'rm -f "$NOTES_FILE"' EXIT
if [ -n "$CHANGES_FILE" ]; then
    cat "$CHANGES_FILE" > "$NOTES_FILE"
else
    echo "Release v$VERSION" > "$NOTES_FILE"
fi
# Replace any existing release at this tag (idempotent reruns):
gh release delete "v$VERSION" --yes 2>/dev/null || true
gh release create "v$VERSION" "$ZIP_FILE" \
    --title "ClaudeBar v$VERSION" \
    --notes-file "$NOTES_FILE"

# ---- Update the cask in the tap repo ---------------------------------------

echo "==> Bumping cask version + sha256 in $TAP_PATH"
sed -i '' "s/version \"[0-9]*\.[0-9]*\.[0-9]*\"/version \"$VERSION\"/" "$CASK_FILE"
sed -i '' "s/sha256 .*/sha256 \"$SHA256\"/" "$CASK_FILE"
(
    cd "$TAP_PATH"
    git add Casks/claudebar.rb
    git diff --cached --quiet || git commit -m "claudebar: $VERSION"
    git push origin master
)

# ---- Summary ---------------------------------------------------------------

echo
echo "==> Done."
echo "    Release:  https://github.com/chiliec/ClaudeBar/releases/tag/v$VERSION"
echo "    Appcast:  https://raw.githubusercontent.com/chiliec/ClaudeBar/main/appcast.xml"
echo "    Cask:     https://github.com/chiliec/homebrew-tap/blob/master/Casks/claudebar.rb"
echo
echo "Install: brew install --cask chiliec/tap/claudebar"
