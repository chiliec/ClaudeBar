#!/bin/bash
set -e

APP_NAME="ClaudeBar"

# Share the release scripts' identity resolution rather than duplicating it:
# this had its own "Apple Development" lookup, which meant it kept signing with
# a different certificate than every other build path.
# shellcheck source=lib/sign.sh
source "$(dirname "$0")/lib/sign.sh"
CODE_SIGN_IDENTITY=$(resolve_identity dev)
echo "Signing with: $CODE_SIGN_IDENTITY"

# Debug build, so KeychainService uses com.claudebar.dev -- this never reads or
# writes the installed app's accounts. Sign in again here; that is expected.
swift build
codesign --force --sign "$CODE_SIGN_IDENTITY" --entitlements Sources/ClaudeBar/ClaudeBar.entitlements ".build/debug/$APP_NAME"
".build/debug/$APP_NAME"
