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
# Universal build: SwiftPM puts multi-arch output under .build/apple/Products,
# not .build/release. Intel Macs can't launch an arm64-only binary at all.
BUILD_DIR=".build/apple/Products/Release"
BUNDLE_DIR="$BUILD_DIR/$APP_NAME.app"
ZIP_FILE="$BUILD_DIR/$APP_NAME.zip"
# shellcheck source=lib/sign.sh
source "$(dirname "$0")/lib/sign.sh"
SIGN_IDENTITY=$(resolve_identity release)
NOTARY_PROFILE="${NOTARY_PROFILE:-claudebar-notary}"
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-./scripts/sparkle-bin}"
SIGN_UPDATE="$SPARKLE_BIN_DIR/sign_update"
TAP_PATH="${HOMEBREW_TAP_PATH:-../homebrew-tap}"
CASK_FILE="$TAP_PATH/Casks/claudebar-menubar.rb"
APPCAST_FILE="./appcast.xml"

# ---- Prerequisite checks ----------------------------------------------------

# The signing identity was already resolved and validated above by
# resolve_identity, which aborts if no Developer ID certificate exists.
echo "==> Signing identity: $SIGN_IDENTITY"

CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "ERROR: release.sh must be run from the 'main' branch (currently on '$CURRENT_BRANCH')."
    echo "  Merge this branch to main first, then re-run from a checkout of main."
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "ERROR: notarytool keychain profile '$NOTARY_PROFILE' is missing or invalid."
    echo "Run the one-time setup in docs/RELEASING.md, then retry."
    exit 1
fi

if [ ! -x "./scripts/notarize.sh" ]; then
    echo "ERROR: ./scripts/notarize.sh is missing or not executable."
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

# ---- Run tests against current state ---------------------------------------
# Tests validate that the previously-committed Info.plist + appcast are
# consistent, so we run them BEFORE bumping the version (which would break
# AppcastTests.topmostItemMatchesInfoPlistVersion until we insert the new item).

echo "==> Running tests"
# --no-parallel: suites share the test Keychain service, parallel runs are flaky
# (see CLAUDE.md Testing).
swift test --no-parallel 2>&1 | tail -3

# ---- Bump version in Info.plist --------------------------------------------

echo "==> Updating Info.plist to $VERSION"
sed -i '' "s/<string>[0-9]*\.[0-9]*\.[0-9]*<\/string>/<string>$VERSION<\/string>/g" \
    Sources/ClaudeBar/Info.plist

# ---- Build, sign, bundle ---------------------------------------------------

echo "==> Building release (universal)"
swift build -c release --arch arm64 --arch x86_64

echo "==> Creating app bundle"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"
mkdir -p "$BUNDLE_DIR/Contents/Frameworks"
cp "$BUILD_DIR/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/"
cp Sources/ClaudeBar/Info.plist "$BUNDLE_DIR/Contents/"
cp Sources/Resources/AppIcon.icns "$BUNDLE_DIR/Contents/Resources/"
# ClaudeBarUI's localized strings. Bundle.module looks for this beside the other
# resources; without it every `Text(..., bundle: .module)` traps at render time,
# so the app crashes the moment the popover lays out. Shipped through v0.0.29,
# which only ran on the build machine because older SwiftPM baked an absolute
# fallback path into .build. Must land before signing.
ditto "$BUILD_DIR/${APP_NAME}_ClaudeBarUI.bundle" \
      "$BUNDLE_DIR/Contents/Resources/${APP_NAME}_ClaudeBarUI.bundle"
ditto "$BUILD_DIR/Sparkle.framework" "$BUNDLE_DIR/Contents/Frameworks/Sparkle.framework"

# SwiftPM-built binaries don't include @executable_path/../Frameworks in their
# rpath, so dyld can't find Sparkle.framework when bundled. Add it before
# signing (install_name_tool invalidates signatures).
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"

echo "==> Signing Sparkle.framework internals + app"
sign_bundle "$BUNDLE_DIR" "$SIGN_IDENTITY" release
verify_bundle "$BUNDLE_DIR"

# ---- Smoke test: does the thing actually run? -------------------------------
# Every check below this point is static, and static checks shipped three
# broken releases in a row -- the last one crashed on launch for everyone
# except this machine. Run the bundle we just built from a copy outside the
# package directory, so nothing in .build can satisfy it by accident, and
# require it to survive. `open` rather than exec'ing the binary: an accessory
# app needs a real launch to build its status item and lay out its panel, which
# is where a missing resource bundle traps.

echo "==> Smoke testing the built app"
SMOKE_DIR=$(mktemp -d)
ditto "$BUNDLE_DIR" "$SMOKE_DIR/$APP_NAME.app"
# Its own keychain service: reading the real one can block in SecItemCopyMatching
# behind a login-keychain ACL prompt, which freezes the app before it builds its
# status item. Passed in the environment because editing Info.plist -- the other
# way to set this -- would invalidate the signature of the bundle being shipped.
open -n --env "CLAUDEBAR_SMOKE=$SMOKE_DIR/panel.txt" \
        --env "CLAUDEBAR_KEYCHAIN_SERVICE=com.claudebar.smoke" "$SMOKE_DIR/$APP_NAME.app"
sleep 8
SMOKE_PID=$(pgrep -f "$SMOKE_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" || true)
if [ -z "$SMOKE_PID" ]; then
    echo "ERROR: the app did not survive 8 seconds after launch."
    echo "  Most recent crash report:"
    ls -t "$HOME/Library/Logs/DiagnosticReports/$APP_NAME"-*.ips 2>/dev/null \
        | head -1 | xargs -I{} sh -c 'grep -o "Fatal error:.*" "{}" | head -1'
    exit 1
fi
kill "$SMOKE_PID"

# CLAUDEBAR_SMOKE opens the panel and writes what it measured. An empty panel
# (content=0) or one sized differently from its content is the shape of every
# panel bug shipped so far, and surviving launch does not catch either.
PANEL=$(cat "$SMOKE_DIR/panel.txt" 2>/dev/null || true)
echo "    panel geometry: ${PANEL:-<none written>}"
if [ -z "$PANEL" ] || ! awk -F'[= ]' \
        '{ exit !($2 > 0 && $4 > 0 && ($2 - $4) ^ 2 < 1) }' <<<"$PANEL"; then
    echo "ERROR: the panel did not open at its content's size."
    exit 1
fi
rm -rf "$SMOKE_DIR"

echo "==> Notarizing"
NOTARY_PROFILE="$NOTARY_PROFILE" ./scripts/notarize.sh "$BUNDLE_DIR"

# ---- Gate on what a *user's* Mac will decide -------------------------------
# codesign --verify only proves the signature is well formed. It said "valid on
# disk" for every build through v0.0.28, which shipped without
# CFBundlePackageType and so was refused by Gatekeeper on any machine that saw
# it quarantined. spctl runs the assessment a user's Mac actually runs, and the
# lipo check catches an arm64-only build that Intel Macs cannot launch at all.
# Both are release-only: they need the stapled, Developer ID-signed bundle.

echo "==> Verifying Gatekeeper assessment"
if ! spctl -a -vvv -t exec "$BUNDLE_DIR" 2>&1 | grep -q "accepted"; then
    echo "ERROR: Gatekeeper rejects the notarized bundle -- users would see it"
    echo "  fail to launch. Full assessment:"
    spctl -a -vvv -t exec "$BUNDLE_DIR" 2>&1 | sed 's/^/    /'
    exit 1
fi

echo "==> Verifying universal binary"
ARCHS=$(lipo -archs "$BUNDLE_DIR/Contents/MacOS/$APP_NAME")
for arch in arm64 x86_64; do
    case " $ARCHS " in
        *" $arch "*) ;;
        *) echo "ERROR: binary is missing $arch (has: $ARCHS)"; exit 1 ;;
    esac
done

# Archive AFTER stapling. Stapling mutates the bundle, so the Sparkle
# edSignature, the enclosure length, and the cask sha256 -- all computed below
# from $ZIP_FILE -- must describe the stapled bytes users actually download.
# ditto rather than zip: zip does not faithfully preserve bundle symlinks.
echo "==> Zipping (post-staple)"
rm -f "$ZIP_FILE"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE_DIR" "$ZIP_FILE"

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
# Push the branch WITHOUT --force. Forcing it here silently destroyed a merged
# PR during the v0.0.29 release: anything landed on the remote since the last
# release is not in this checkout, and --force discards it. Only the tag needs
# forcing, so that re-running a failed release at the same version works.
if ! git push origin main; then
    echo "ERROR: pushing main was rejected -- the remote has commits this"
    echo "  checkout does not. Run 'git pull --rebase origin main' and re-run"
    echo "  this script; it is safe to re-run at the same version."
    exit 1
fi
git push origin --tags --force

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
    git add Casks/claudebar-menubar.rb
    git diff --cached --quiet || git commit -m "claudebar-menubar: $VERSION"
    git push origin master
)

# ---- Summary ---------------------------------------------------------------

echo
echo "==> Done."
echo "    Release:  https://github.com/chiliec/ClaudeBar/releases/tag/v$VERSION"
echo "    Appcast:  https://raw.githubusercontent.com/chiliec/ClaudeBar/main/appcast.xml"
echo "    Cask:     https://github.com/chiliec/homebrew-tap/blob/master/Casks/claudebar-menubar.rb"
echo
echo "Install: brew install --cask chiliec/tap/claudebar-menubar"
