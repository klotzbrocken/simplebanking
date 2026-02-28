# simplebanking

macOS menu bar app that shows your current account balance — no decimals, auto-refreshed.

## What it does

- Displays booked balance in the menu bar (e.g. `1.234 €`)
- Shows recent transactions with categories, merchant logos, and a financial health score
- Auto-refreshes on a configurable interval (default: every 4 hours); manual refresh via menu
- Supports any German bank reachable via YAXI Open Banking (PSD2)
- Setup wizard: enter IBAN + optional credentials, bank is discovered automatically
- SCA handled automatically where possible (push-TAN via banking app, OAuth redirect)
- Credentials stored AES-256 encrypted with a master password; master password in Keychain
- Optional Touch ID / Face ID unlock
- Auto-updates via Sparkle

## Architecture

```
Menu bar → Swift app → routex-client-swift (Swift Package) → YAXI API → Bank (PSD2)
```

Pure Swift — no Node.js, no embedded runtime. The `routex-client-swift` Swift Package handles
all YAXI Open Banking API calls directly. Session tokens and connection data are persisted in
UserDefaults; credentials encrypted in a local file (`Application Support/simplebanking/credentials.json`).

## Building

Requires: macOS 13+, Xcode CLI tools, Swift 5.9+

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

No Node.js, no `npm install` needed.

## Security

- Credentials encrypted with AES-GCM + PBKDF2-SHA256 (210,000 iterations)
- Master password stored in macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
- Credentials file permissions: `600` (owner read/write only)
- No credentials or IBAN written to log files
- SQL injection protection via parameterized queries + read-only query guard
- HTTPS for all API calls

## Dependencies

- [routex-client-swift](https://github.com/yaxi/routex-client-swift) — YAXI Open Banking Swift SDK
- [GRDB.swift](https://github.com/groue/GRDB.swift) — local transaction database (SQLite)
- [Sparkle](https://sparkle-project.org) — auto-update framework
