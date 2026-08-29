# ClaudeBar Pro — monetization setup

This adds a **freemium license layer** to ClaudeBar. Everything that ships today
stays free forever; Pro gates only *new* features. Payment runs through **Lemon
Squeezy** (a Merchant of Record — collects/remits global tax, pays out to a
non‑US individual, no company required).

## What the code already does

- `LicenseService` — the 3 Lemon Squeezy license calls (`activate` / `validate` /
  `deactivate`). The license key is the credential; no API token in the app.
- `LicenseStore` — `@Observable` entitlement: persists the license in the
  Keychain (mirrors `KeychainService`), decides `isPro`, and implements
  **offline grace** (a network blip never locks a paying user for 14 days; a
  real refund/expiry locks immediately).
- `ProConfig` — the checkout URL, price string, and the list of Pro features.
- `LicenseStoreTests` — activation, revocation, and both grace edges.

## Your one‑time setup (≈20 min, only you can do this)

1. **Create a Lemon Squeezy account** → https://lemonsqueezy.com
   - Store country = your residence (Bali/Indonesia is fine — MoR handles tax).
   - Payout to bank / Wise / PayPal.
2. **Create the product**
   - Type: **Single payment**, price **$9.99** (one‑time beats subscription for a
     small utility — no churn, no support load).
   - **Enable license keys.** Activation limit **3** (laptop + desktop + spare).
     License length **Never expires**.
3. **Grab the checkout link** → Product → Share → Buy link, e.g.
   `https://claudebar.lemonsqueezy.com/buy/<variant-uuid>`
   - Paste it into `ProConfig.checkoutURLString` (replace `REPLACE_ME`).
4. **Test in LS test mode** (free): make a $0 order → get a test key → in the app
   paste it in Settings → Pro. Verify:
   - activate 3 machines → the 4th fails with the limit error;
   - kill Wi‑Fi → stays unlocked (grace);
   - set the Mac clock +15 days offline → locks with "Reconnect";
   - refund the test order → next launch locks immediately.

## Remaining code (small, after this PR compiles green)

- A **Pro section in `SettingsView`**: an "Upgrade to Pro — $9.99" button that
  opens `ProConfig.checkoutURL`, a license‑key text field calling
  `LicenseStore.activate`, and a "Deactivate this Mac" button.
- Gate each `ProConfig.Feature` behind `licenseStore.isPro` at its call site
  (show a small "Pro" lock badge + the same upgrade button when locked).
- Wire one `LicenseStore` into `ClaudeBarApp` (next to `AppState`) and call
  `refresh()` at launch + daily.

These are deliberately left for a follow‑up so this PR is reviewable and the CI
compiles the license core before any UI wiring lands.

## Why $9.99 one‑time (not a subscription)

A menu‑bar utility can't justify recurring billing to most buyers, and a
subscription adds churn + dunning + support. A one‑time unlock converts better
and is near‑zero maintenance. Revisit only if the Pro tier grows into something
with ongoing server cost.
