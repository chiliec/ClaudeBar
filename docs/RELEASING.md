# Releasing ClaudeBar

## The one rule that matters

**Never rotate the Sparkle EdDSA key and the code signing identity in the
same release.**

Sparkle 2.9.2 accepts a bundle update when *either* the EdDSA public keys
match *or* the Apple code signing identity matches (`SUUpdateValidator.m`:
"we allow failure of one of them, because this allows key rotation without
breaking chain of trust"). Each change is individually safe because the
other check still passes. Both at once fails both checks, and every
installed copy loses auto-update permanently — the only recovery is asking
every user to reinstall by hand.

`Tests/SigningInvariantTests.swift` pins `SUPublicEDKey` so an accidental
rotation fails `swift test` instead of shipping.

## Signing identities

| Purpose | Identity | Used by |
| --- | --- | --- |
| Release | `Developer ID Application: Vladimir Babin (7JF6XQC536)` | `scripts/release.sh` |
| Local development | `Apple Development: Vladimir Babin (8FNR8DGE9N)` | `scripts/bundle.sh`, `scripts/run.sh` |

Both are resolved by `resolve_identity` in `scripts/lib/sign.sh`. Setting
`CODE_SIGN_IDENTITY` overrides the lookup. A release refuses to fall back to
a development certificate: such a build cannot be notarized.

## One-time credential setup

The Developer ID Application certificate must come from the **individual**
developer account, not the WAYTOHEY FZE LLC organization team. In an
organization team, Developer ID certificates are restricted to the Account
Holder.

1. Keychain Access → Certificate Assistant → Request a Certificate From a
   Certificate Authority → saved to disk, 2048-bit RSA. (Equivalently,
   `openssl genrsa` + `openssl req -new` + `security import` for the
   private key, if scripting this instead of using the GUI.)
2. developer.apple.com → Certificates → Developer ID Application → G2 Sub-CA
   → upload the CSR → download and double-click the `.cer`.
3. App Store Connect → Users and Access → Integrations → App Store Connect
   API → Team Keys → generate a key with the **Developer** role. The `.p8`
   downloads exactly once.
4. Store it for `notarytool`:

       xcrun notarytool store-credentials claudebar-notary \
         --key AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>

5. Back the `.p8` up to 1Password beside the Sparkle EdDSA private key, then
   delete the local copy. Nothing secret belongs in this repository.

Verify at any time with:

    security find-identity -v -p codesigning | grep "Developer ID Application"
    xcrun notarytool history --keychain-profile claudebar-notary

## Cutting a release

    ./scripts/release.sh 0.0.23 release-notes/0.0.23.md

The script runs tests, bumps `Info.plist`, builds, signs with hardened
runtime and a secure timestamp, notarizes, staples, and only then creates
the archive that ships. That order is mandatory: stapling mutates the
bundle, so the appcast `sparkle:edSignature` and `length` and the cask
`sha256` must all be computed afterwards. Getting it backwards publishes an
archive whose Sparkle signature does not match the file users download.

Notarization adds a few minutes of waiting to each release.

## Verifying a build by hand

    xcrun stapler validate .build/release/ClaudeBar.app
    spctl -a -vvv -t install .build/release/ClaudeBar.app

The second command must report `source=Notarized Developer ID`. Anything
else means the build would show a Gatekeeper prompt on a user's machine.
