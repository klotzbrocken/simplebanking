# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build, Test, Run

The project is a **Swift Package** (no Xcode project). All work flows through `swift` and the shell scripts at the repo root.

```bash
# Tests — always run before claiming a task done
swift test
swift test --filter <TestClassName>          # one test class
swift test --filter <TestClassName>/<method> # one method

# Build the SPM target alone (fast iteration during dev)
swift build

# Build the full universal app bundle (arm64 + x86_64, lipo'd, signed ad-hoc, Sparkle.framework embedded)
bash build-app.sh
# → SimpleBankingBuild/simplebanking.app

# Full release pipeline: build + sign with Developer ID + notarize + DMG + delta + appcast
SIGN_IDENTITY="Developer ID Application: Maik Klotz (FTJLR8JRNS)" \
NOTARY_PROFILE="simplebanking-notary" \
bash sign-and-notarize.sh
# Useful flags: BUILD_FIRST=0 (skip rebuild), SKIP_APPCAST=1

# Run the built app
open SimpleBankingBuild/simplebanking.app
```

**`Sources/simplebanking/Secrets.swift` is gitignored and required** — `build-app.sh` aborts if missing. Generate once via:
```bash
./make-secrets.sh "YAXI_KEY_ID" "YAXI_SECRET_BASE64"
```

**Code-gen runs implicitly on every build:** `scripts/generate-bank-colors.sh` regenerates `GeneratedBankColors.swift` from SVG metadata in `Resources/bank-logos/`. Don't edit the generated file.

**Bumping versions:** edit `VERSION_BASE` in `build-app.sh`. CFBundleVersion is composed at build time as `YYYYMMDD<seq>` — the seq counter lives in `SimpleBankingBuild/.build-number` and is required for Sparkle monotonicity.

**Demo mode** (no real bank credentials needed for UI work):
```bash
defaults write de.klotzbrocken.simplebanking demoMode -bool YES
```

## Architecture

### Three executables, one Swift Package

`Package.swift` defines three `executableTarget`s that share the repo but ship independently:

| Target | Path | Role |
|---|---|---|
| `simplebanking` | `Sources/simplebanking/` | The menu bar app (~96 files, ~35k LOC). Entry point: `SimpleBankingApp.swift` (`@main`) → `AppDelegate` → `BalanceBar`. |
| `simplebanking-cli` | `Sources/simplebanking-cli/` | The `sb` CLI for terminal scripts (`sb balance`, `sb tx`, `sb refresh`, …). Built on `swift-argument-parser`. **Read-only against the cache** — write paths live in the app. |
| `simplebanking-mcp` | `Sources/simplebanking-mcp/` | MCP server that exposes banking tools to Claude Code / other MCP clients. |

CLI and MCP read the **same SQLite DB** the app writes (`~/Library/Application Support/simplebanking/transactions.sqlite`, GRDB-backed). They never call the bank themselves.

### App layer (`Sources/simplebanking/`)

- **No SwiftUI `App` struct, no Xcode project** — pure `NSApplication` with `.accessory` activation policy (menu bar, no Dock icon by default).
- `BalanceBar.swift` is the orchestrator god-object (~4700 LOC, ~80% of UI logic). Owns `NSStatusItem`, `NSPopover` for the flyout, `NSPanel`s for transfer + transactions, all hotkeys, refresh timers, and the slot-switching state machine. **Most features start here** — when in doubt, grep `BalanceBar`.
- **State stores** are `@MainActor final class … : ObservableObject` singletons with `@Published` properties — `MultibankingStore` (slots + activeIndex), `BankLogoStore`, `ThemeManager`, `FreezeState`, etc. SwiftUI views attach via `@ObservedObject`.
- **`TransactionsViewModel`** is the per-panel VM. `vm.transactions: [TransactionsResponse.Transaction]` is the canonical in-memory list; the bank model lives in `BankingModels.swift`.

### Banking flow

```
BalanceBar
  └─ YaxiService.swift           ← async API wrapper (fetchBalances, fetchTransactions, sendTransfer)
       └─ YaxiTicketMaker.swift  ← ticket signing (uses Transfer-Pair for licensed transfers)
            └─ RoutexClient (routex-client-swift SPM dep)
                 └─ YAXI Open Banking API → bank (PSD2)
```

**HBCI mutex:** banks like Volksbank reject parallel calls on the same connection with "Fehlender Dialogkontext". Every refresh path checks `isHBCICallInFlight` / goes through `BankRequestQueue`. When adding any new bank-call site, **do not** start a `Task { fetch… }` without going through the queue or guarding against in-flight calls.

### Concurrency invariants

- All UI-touching state is `@MainActor`. `LicenseManager`, `MultibankingStore`, view models — all main-actor isolated.
- `Status` enums in stores are `Equatable` so SwiftUI's `onChange` works. Don't add stored closures without `@Sendable` annotations.
- Background work uses `Task { await … }` and switches to main with `await MainActor.run { … }` or by calling main-isolated methods directly. Avoid `DispatchQueue.main.async` in new code — it predates the actor migration.
- Carbon-Hotkey callbacks live outside the actor system; they wrap their bodies in `MainActor.assumeIsolated { … }`.

### Slot scope

`MultibankingStore.shared.activeSlotId` (`nonisolated(unsafe)` for cross-thread reads) is the bank context every call must scope itself to. `slotEpoch` is bumped on every slot switch — refresh tasks check it on awaited boundaries and bail out if a switch happened mid-flight. Anything that caches per-slot (`cachedBalance.<slotId>`, `lastSeenTxSig.<slotId>`, settings) keys off `slotId`, not a transient index.

### Persistence

- **Transactions DB:** GRDB / SQLite at `~/Library/Application Support/simplebanking/transactions.sqlite`. Migrations live in `TransactionsDatabase.swift` and are append-only — never rename or remove existing migration steps. Numbered (v1, v2, …); the migration system replays in order on every launch.
- **Credentials:** AES-GCM at `~/Library/Application Support/simplebanking/credentials.json`, master password in Keychain (`tech.yaxi.simplebanking` service).
- **Per-slot settings:** `BankSlotSettingsStore` reads/writes UserDefaults keys prefixed with the slot id.
- **Session tokens (YAXI connection state):** UserDefaults via `SessionStore` — wiped on `Unauthorized` / `ConsentExpired`.

### Tests

- Test target `simplebankingTests` uses `@testable import simplebanking` against **real production code** — there are no mock layers. Test new code by making it pure (extract free functions / static methods) and feeding it explicit inputs.
- Tests are `@MainActor` if they touch any store. XCTest is the framework.
- Current count is ~318. A green Suite is a hard gate before commit.

## Memory of conventions worth re-reading

`/Users/maik/.claude/projects/-Users-maik/memory/MEMORY.md` (loaded automatically) has long-lived feedback memos — testing style, BalanceBar/Flyout height invariants, Sparkle release-bump rule, and a running log of project states by version. Check it before tackling anything tagged "geparkt".

## Sparkle release process

1. Bump `VERSION_BASE` in `build-app.sh`.
2. `BUILD_FIRST=1 SKIP_APPCAST=1 SIGN_IDENTITY=… NOTARY_PROFILE=… bash sign-and-notarize.sh` → DMG + delta files in `SimpleBankingBuild/`.
3. `generate_appcast SimpleBankingBuild/ -o appcast_new.xml --download-url-prefix "https://github.com/klotzbrocken/simplebanking/releases/download/vX.Y.Z/"`.
4. `gh release create vX.Y.Z SimpleBankingBuild/simplebanking-<ts>.dmg SimpleBankingBuild/simplebanking-*.delta`.
5. `cp appcast_new.xml appcast.xml && git add appcast.xml && git commit -m "release: appcast X.Y.Z"`.

CFBundleVersion is monotonic across release+delta — never reset `.build-number` after a public release.

## Code style (from CONTRIBUTING.md)

- Swift API Design Guidelines.
- `// MARK: -` to section large files.
- Prefer `async/await` over completion handlers for new code.
- No force unwraps (`!`) outside `@IBOutlet` / `fatalError`.
- Conventional Commits: `feat(scope): …`, `fix(scope): …`, `chore: …`, etc.
- One feature/fix per PR; update `CHANGELOG.md` under `## [Unreleased]`.
