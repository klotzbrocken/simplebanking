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
# Defaults are already correct for this machine (cert FTJLR8JRNS / 53CF9A, notary
# profile "Retromac"), so a bare call works:
bash sign-and-notarize.sh
# Override if needed: SIGN_IDENTITY=… NOTARY_PROFILE=… bash sign-and-notarize.sh
# Useful flags: BUILD_FIRST=0 (skip rebuild), SKIP_APPCAST=1
# Notary profile: the app's own "simplebanking-notary" was lost in the Mac move;
# we reuse the shared "Retromac" profile (same Apple ID / team FTJLR8JRNS).

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

**The appcast lives on GitHub `main`, the DMG on two hosts.** Every shipped build has
`SUFeedURL = https://raw.githubusercontent.com/klotzbrocken/simplebanking/main/appcast.xml`
baked into its Info.plist, unchanged since the initial commit. **Pushing `appcast.xml`
to `main` is what triggers the update for customers** — not the DMG upload. The DMG
goes to the GitHub Release (that URL is the `<enclosure>`) *and* to the website for
manual downloads.

**⚠️ Signing-key migration (done with 2.0.0, but its consequence is permanent):** the
old EdDSA key (public `BOcdIyAH…`) was **lost**. `sparkle-public-key.txt` holds the
**new** key (`uXP0XBQg…`; private key at `~/Documents/RetroMac-Sparkle-Key/`, shared
with RetroMac). Installs up to 1.6.1 carry the OLD public key and **cannot verify** any
new-key-signed update — measured, not assumed: the 2.0 DMG verifies against `uXP0XBQg…`
and fails against `BOcdIyAH…`. There is no auto-update path for them, ever; they must
download once by hand.

**Therefore every future appcast item keeps the gate:**
```xml
<sparkle:informationalUpdate>
    <sparkle:belowVersion>20260725535</sparkle:belowVersion>
</sparkle:informationalUpdate>
```
`20260725535` is the build number of the first release carrying the NEW key (the 2.0
beta) and is a **constant** — never the current build. Below it → old key → Sparkle only
shows the notice and opens `<link>`, nothing is downloaded and no signature is checked.
At or above → normal signed update. Drop the gate and a 1.6.x client picks the newest
item, downloads, and fails verification: an error dialog instead of the migration hint.

Verify a signature matches the key baked into a build (do this whenever the key
changes — a broken auto-update path otherwise surfaces one release too late):
```bash
{ printf '302a300506032b6570032100' | xxd -r -p; base64 -d < sparkle-public-key.txt; } \
  | openssl pkey -pubin -inform DER -out /tmp/ed.pem
echo "<edSignature>" | base64 -d > /tmp/sig.bin
openssl pkeyutl -verify -pubin -inkey /tmp/ed.pem -rawin -in <DMG> -sigfile /tmp/sig.bin
```

### Release steps

0. **`WhatsNewContent.highlights(for:)` um die neue Version ergänzen**
   (`Sources/simplebanking/WhatsNewSheet.swift`). Fehlt der `case`, liefert die Funktion
   `nil` — dann erscheint beim Update **kein** „Was ist neu"-Fenster, und mit ihm auch
   nicht die Newsletter-Anmeldung in dessen Fuß. Das fällt nicht auf, weil nichts
   fehlschlägt; es passiert einfach nichts.
1. Bump `VERSION_BASE` in `build-app.sh`.
2. `BUILD_FIRST=1 bash sign-and-notarize.sh` → notarized, stapled DMG, and step 9 prints
   the ready-made `<item>` with version, length, signature and enclosure URL computed
   from the DMG it just built. **Do not run `generate_appcast`** — it scans the whole
   build folder (every throwaway build becomes an item) and cannot express the gate.
   That is why it was removed from the script.
3. `gh release create vX.Y.Z <DMG>` — **push first** (next step), otherwise `gh` tags the
   remote's current HEAD, i.e. the wrong commit. Fixable afterwards with
   `gh api -X PATCH repos/klotzbrocken/simplebanking/git/refs/tags/vX.Y.Z -f sha=<sha> -F force=true`.
4. Paste the item into `appcast.xml`, fill in the release notes, `xmllint --noout appcast.xml`.
5. **Check the branch.** Development runs on a feature branch (2.0 was on
   `feat/flyout-refresh-4b`); local `main` lags far behind, so a bare `git push origin main`
   ships the *old* state. Fast-forward first: `git branch -f main <branch>`.
6. Push. The remote is `git@github.com:…` but SSH is not set up — use the HTTPS URL, `gh`
   supplies the credentials: `git push https://github.com/klotzbrocken/simplebanking.git main`.
7. Verify what clients actually get — `raw.githubusercontent.com` lags ~1 minute behind
   the push:
   ```bash
   curl -s https://raw.githubusercontent.com/klotzbrocken/simplebanking/main/appcast.xml | grep -o '<title>[^<]*</title>' | head -3
   ```
8. Website: upload the DMG under its **versioned** filename and point `DOWNLOAD_URL` in
   `Download.tsx` at it. Never reuse `assets/simplebanking.dmg` — the site sits behind a
   cache with `max-age=2592000` (30 days) that kept serving the June file for weeks after
   the 2.0 upload. A URL that did not exist before cannot be stale. Same trap in
   `BetaDownload.tsx`.

`CFBundleVersion` is stamped as `YYYYMMDD<seq>` and rises with **every** build, including
throwaway ones — so the appcast version must always come from the DMG actually uploaded.
Step 9 does that for you. Never reset `.build-number` after a public release.

`<sparkle:version>` in the appcast must be the CFBundleVersion of the DMG you actually
uploaded — it is stamped as `YYYYMMDD<seq>` at build time and rises with **every**
build, so re-check it after any rebuild. CFBundleVersion is monotonic across
release+delta — never reset `.build-number` after a public release.

## Code style (from CONTRIBUTING.md)

- Swift API Design Guidelines.
- `// MARK: -` to section large files.
- Prefer `async/await` over completion handlers for new code.
- No force unwraps (`!`) outside `@IBOutlet` / `fatalError`.
- Conventional Commits: `feat(scope): …`, `fix(scope): …`, `chore: …`, etc.
- One feature/fix per PR; update `CHANGELOG.md` under `## [Unreleased]`.
