# ClaudeBar
Native SwiftUI macOS menu bar app (macOS 14+) showing Claude.ai subscription usage. Polls Claude.ai API, shows ring icon + utilization % in menu bar.

## Commands
```bash
./scripts/run.sh                            # Build + sign + run (development)
./scripts/bundle.sh                         # Release build + .app bundle
swift test                                  # All tests
swift test --filter AppStateTests           # Single suite
swift test --filter ClaudeBarTests.AppStateTests.testMenuBarTextWithNoUsage
```
**Do NOT use `swift run`** — binary must be code-signed before launch (Keychain + SMAppService). Use `./scripts/run.sh` instead.

## Architecture
Three-layer: Views → `AppState` (`@Observable` class) → Services

- `ClaudeAPIClient`: stateless. Usage/profile via `GET api.anthropic.com/api/oauth/{usage,profile}` with `Authorization: Bearer <token>` + `anthropic-beta: oauth-2025-04-20`
- `OAuthService`: PKCE sign-in through the browser (client ID is Claude Code's), token refresh, Keychain blob (`oauth_credentials`). `OAuthCallbackServer` is a one-shot `NWListener` on an OS-assigned ephemeral port (the authorize URL must match Claude Code CLI's byte-for-byte — see `authorizeURL`)
- `KeychainService`: struct with injectable `serviceName`. Tests use `com.claudebar.test`.
- **API quirk**: utilization returned 0–100; `WindowUsage` normalizes to 0–1.0 on decode (values > 1.0 divided by 100)
- Date parsing: custom decoder handles ISO 8601 with/without fractional seconds (`.000Z` vs `Z`)

## SPM structure
Two targets: `ClaudeBarUI` (library: all models/services/views) + `ClaudeBar` (thin `@main` executable). This split enables SwiftUI `#Preview` — previews don't work in executable targets. All `ClaudeBarUI` types are `public`.

## Testing
- `makeState()` — injects test keychain (`com.claudebar.test`), clears before each test
- ViewInspector: `@retroactive Inspectable` conformance required (views and protocol in different modules)
- `CoreData: XPC: sendMessage: failed` in test output — harmless

## Icon
Regenerate: `swift scripts/generate-icon.swift && iconutil -c icns .build/ClaudeBar.iconset -o Sources/Resources/AppIcon.icns`
Code signing: auto-detects `Apple Development` cert. Set `CODE_SIGN_IDENTITY` to override; falls back to ad-hoc (`-`).
