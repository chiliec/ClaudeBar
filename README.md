# ClaudeBar

A native macOS menu bar app that shows your Claude.ai usage at a glance.

![ClaudeBar popover](docs/image.png)

## Features

- **Menu bar indicator** -- ring icon with percentage fills and changes color as usage increases
- **5-hour rolling window** -- progress bar with reset countdown
- **7-day limits** -- separate bars for total, Sonnet, and Opus utilization
- **Subscription detection** -- automatically identifies Pro / Max tier
- **Auto-refresh** -- polls every 5 minutes, manual refresh available
- **Secure storage** -- session key stored in macOS Keychain

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.9+
- Claude Pro or Max subscription

## Install

    brew install --cask chiliec/tap/claudebar-menubar

That's it. After install, the app updates itself: Sparkle checks daily and shows an "Update available" dialog whenever there's a new version.

> The cask is named `claudebar-menubar` because the short name `claudebar` is taken by an unrelated project in the central Homebrew tap. Always use the fully-qualified `chiliec/tap/claudebar-menubar`.

### Manual install (without Homebrew)

Download the latest `.zip` from [Releases](https://github.com/chiliec/ClaudeBar/releases), unzip, drag `ClaudeBar.app` to `/Applications`, then double-click. Builds are notarized by Apple, so macOS opens the app without a Gatekeeper warning.

### Build from source

```bash
git clone https://github.com/chiliec/ClaudeBar.git
cd claudebar
./scripts/bundle.sh
cp -r .build/release/ClaudeBar.app /Applications/
```

The build scripts auto-detect your Apple Development certificate. If you have none, they fall back to ad-hoc signing (the app will ask for your Keychain password on every launch).

To use a specific certificate:

```bash
CODE_SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXX)" ./scripts/bundle.sh
```

On the first launch after building, macOS will ask for your Keychain password to authorize the app — click **Always Allow** so it won't ask again.

## Setup

1. Launch ClaudeBar and click **Sign in with Claude**
2. Approve access in the browser tab that opens
3. Come back — the menu bar starts showing your usage

Optionally, to also see your prepaid API credit balance, paste a `sessionKey` from
platform.claude.com in Settings → Platform API.

## Development

```bash
./scripts/run.sh          # build + sign + run
swift test                # run all tests
swift test --filter AppStateTests  # run one test suite
```

The project has two SPM targets: `ClaudeBarUI` (library with models, services, views) and `ClaudeBar` (thin executable entry point). This split enables SwiftUI `#Preview` support.

### Regenerating the app icon

The icon is generated programmatically with CoreGraphics. To tweak colors or shape, edit `scripts/generate-icon.swift` and run:

```bash
swift scripts/generate-icon.swift
iconutil -c icns .build/ClaudeBar.iconset -o Sources/Resources/AppIcon.icns
```

> **Note:** Do not use `swift run` -- the binary must be code-signed to access Keychain. Use `./scripts/run.sh` instead.

## How it works

ClaudeBar signs in with OAuth (the same flow Claude Code uses) and reads usage from
`api.anthropic.com/api/oauth/usage`. Tokens are stored in the macOS Keychain and
refreshed automatically; nothing is sent anywhere except to Anthropic.

## License

MIT
