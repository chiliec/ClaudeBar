# Canonical code signing for ClaudeBar .app bundles.
#
# Sourced by scripts/bundle.sh (dev) and scripts/release.sh (release).
# This file is sourced, never executed, so it has no shebang and no `set`.
#
# Signing is inside-out: nested code first, container last. `--deep` is never
# used to SIGN -- it re-signs nested code with the container's entitlements,
# which Apple documents as unsuitable for distribution. Using it to VERIFY, as
# verify_bundle does below, is correct and unrelated.

ENTITLEMENTS="Sources/ClaudeBar/ClaudeBar.entitlements"

# resolve_identity <release|dev>
#
# Echoes the code signing identity to use. Honors CODE_SIGN_IDENTITY above all
# else. In release mode, fails loudly rather than falling back to a development
# certificate: a development-signed build cannot be notarized, and silently
# shipping one would reintroduce the Gatekeeper prompt this whole setup exists
# to remove.
resolve_identity() {
    local mode="$1"
    local id=""

    if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
        echo "$CODE_SIGN_IDENTITY"
        return 0
    fi

    case "$mode" in
        release)
            id=$(security find-identity -v -p codesigning \
                 | grep -v CSSMERR \
                 | grep "Developer ID Application" \
                 | head -1 | sed 's/.*"\(.*\)".*/\1/')
            if [ -z "$id" ]; then
                echo "ERROR: no 'Developer ID Application' certificate found in Keychain." >&2
                echo "  A release must not fall back to a development certificate:" >&2
                echo "  the resulting build cannot be notarized." >&2
                echo "  See docs/RELEASING.md for the one-time setup." >&2
                return 1
            fi
            ;;
        dev)
            id=$(security find-identity -v -p codesigning \
                 | grep -v CSSMERR \
                 | grep "Apple Development" \
                 | head -1 | sed 's/.*"\(.*\)".*/\1/')
            if [ -z "$id" ]; then
                echo "Warning: no Apple Development certificate found. Using ad-hoc signing." >&2
                echo "  Set CODE_SIGN_IDENTITY or install a development certificate." >&2
                id="-"
            fi
            ;;
        *)
            echo "ERROR: resolve_identity: mode must be 'release' or 'dev', got '$mode'" >&2
            return 1
            ;;
    esac

    echo "$id"
}

# sign_bundle <bundle-path> <identity> <release|dev>
#
# Hardened runtime is applied in both modes so that a hardened-runtime problem
# with the bundled Sparkle.framework surfaces during a local ./scripts/bundle.sh
# rather than mid-release. A secure timestamp is release-only because it
# requires network access.
sign_bundle() {
    local bundle="$1"
    local identity="$2"
    local mode="$3"
    local opts

    if [ -z "$bundle" ] || [ -z "$identity" ] || [ -z "$mode" ]; then
        echo "ERROR: sign_bundle <bundle-path> <identity> <release|dev>" >&2
        return 1
    fi

    set -- --force --options runtime
    if [ "$mode" = "release" ]; then
        set -- "$@" --timestamp
    fi
    opts=("$@")

    local fw="$bundle/Contents/Frameworks/Sparkle.framework"
    if [ -d "$fw" ]; then
        codesign "${opts[@]}" --sign "$identity" "$fw/Versions/B/XPCServices/Downloader.xpc"
        codesign "${opts[@]}" --sign "$identity" "$fw/Versions/B/XPCServices/Installer.xpc"
        codesign "${opts[@]}" --sign "$identity" "$fw/Versions/B/Updater.app"
        codesign "${opts[@]}" --sign "$identity" "$fw/Versions/B/Autoupdate"
        codesign "${opts[@]}" --sign "$identity" "$fw"
    fi

    codesign "${opts[@]}" --sign "$identity" --entitlements "$ENTITLEMENTS" "$bundle"
}

# verify_bundle <bundle-path>
#
# Sparkle rejects an update whose new bundle signature is not valid on its own,
# so a malformed nested signature here would break auto-update rather than just
# notarization. Worth checking on every build.
verify_bundle() {
    local bundle="$1"
    codesign --verify --strict --deep --verbose=2 "$bundle"
}
