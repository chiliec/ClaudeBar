#!/bin/bash
set -euo pipefail

# Usage: ./scripts/notarize.sh <path-to-.app>
#
# Submits the bundle to Apple's notary service, waits for the verdict, staples
# the ticket into the bundle, and refuses to succeed unless Gatekeeper reports
# the result as a notarized Developer ID app.
#
# The archive created here is a SUBMISSION copy and is thrown away. Stapling
# mutates the bundle, so the archive that actually ships must be created by the
# caller AFTER this script returns. See docs/RELEASING.md.
#
# Idempotent: an already-stapled bundle is verified but not resubmitted.

APP_PATH="${1:?Usage: ./scripts/notarize.sh <path-to-.app>}"
PROFILE="${NOTARY_PROFILE:-claudebar-notary}"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: no app bundle at $APP_PATH"
    exit 1
fi

if xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
    echo "==> Already stapled, skipping submission: $APP_PATH"
else
    SUBMIT_DIR=$(mktemp -d)
    trap 'rm -rf "$SUBMIT_DIR"' EXIT
    SUBMIT_ZIP="$SUBMIT_DIR/submission.zip"

    echo "==> Archiving for submission"
    # ditto, not zip: zip does not faithfully preserve bundle symlinks and
    # extended attributes, and the notary service rejects such archives.
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$SUBMIT_ZIP"

    echo "==> Submitting to Apple notary service (expect a few minutes)"
    SUBMIT_OUTPUT=$(xcrun notarytool submit "$SUBMIT_ZIP" \
        --keychain-profile "$PROFILE" --wait --output-format json)
    echo "$SUBMIT_OUTPUT"

    SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" \
        | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' | head -1)
    STATUS=$(echo "$SUBMIT_OUTPUT" \
        | sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p' | head -1)

    if [ "$STATUS" != "Accepted" ]; then
        echo "ERROR: notarization status='$STATUS' (submission '$SUBMISSION_ID')"
        if [ -n "$SUBMISSION_ID" ]; then
            echo "---- notary log ----"
            xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" || true
        fi
        exit 1
    fi

    echo "==> Stapling ticket"
    xcrun stapler staple "$APP_PATH"
fi

echo "==> Verifying"
xcrun stapler validate "$APP_PATH"

SPCTL_OUTPUT=$(spctl -a -vvv -t install "$APP_PATH" 2>&1)
echo "$SPCTL_OUTPUT"
if ! echo "$SPCTL_OUTPUT" | grep -q "source=Notarized Developer ID"; then
    echo "ERROR: Gatekeeper does not report this bundle as notarized Developer ID."
    echo "  A user launching this build would still see a Gatekeeper prompt."
    exit 1
fi

echo "==> Notarized and stapled: $APP_PATH"
