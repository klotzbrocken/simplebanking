# simplebanking

macOS menu bar app that shows your current account balance — no decimals, refreshed every 15 minutes.

## What it does

- Displays booked balance in the menu bar (e.g. `1.234 €`)
- Shows recent transactions with categories, merchant logos, and a financial health score
- Auto-refreshes every 15 minutes; manual refresh via menu
- Supports any German bank reachable via YAXI Open Banking (PSD2)
- Setup wizard: enter IBAN + optional credentials, bank is discovered automatically
- SCA handled automatically where possible (push-TAN via banking app, OAuth redirect)
- Credentials stored encrypted in macOS Keychain (optional master password)
- Auto-updates via Sparkle

## Architecture

```
Menu bar → Swift app → Node.js backend (localhost) → YAXI routex-client → Bank (PSD2)
```

The Swift app bundles a small Node.js server that handles all YAXI API calls. Session tokens and connection data are persisted in UserDefaults; credentials in the Keychain.

## Building

Requires: macOS 13+, Xcode CLI tools, Node.js, `npm install` in `backend/`

```bash
# Generate secrets (once)
./make-secrets.sh "YOUR_YAXI_KEY_ID" "YOUR_YAXI_SECRET_BASE64"

# Build ad-hoc signed app bundle
./build-app.sh
# → SimpleBankingBuild/simplebanking.app

# Build + sign + notarize + create DMG + update appcast
SIGN_IDENTITY="Developer ID Application: …" \
NOTARY_PROFILE="simplebanking-notary" \
./sign-and-notarize.sh
```

## Dependencies

- [YAXI routex-client](https://www.npmjs.com/package/routex-client) — Open Banking API client (Node.js)
- [GRDB.swift](https://github.com/groue/GRDB.swift) — local transaction database (SQLite)
- [Sparkle](https://sparkle-project.org) — auto-update framework
