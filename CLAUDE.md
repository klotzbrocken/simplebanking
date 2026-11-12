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
defaults write tech.yaxi.simplebanking demoMode -bool YES
```

**„Baut plötzlich nicht mehr" nach einem Neustart oder einer Wiederherstellung:**
```
error: unable to spawn process '…/MetalToolchain-v27.1.266.1.<RANDOM>/…/metal' (No such file or directory)
error: CompileMetalFile … BTXCRT.metal failed
```
Die Metal-Toolchain ist **nicht** weg (`xcodebuild -showComponent MetalToolchain` sagt
`installed`). Sie liegt in einem Cryptex, dessen Mountpfad ein Zufallssuffix trägt, und
das wechselt beim Neustart; `.build/out` hat den alten Pfad festgeschrieben. Abhilfe:
`rm -rf .build/out`, dann neu bauen (~75 s). Das Projekt hat zwei Shader
(`BTXCRT.metal`, `Ripple.metal`), es trifft also jeden Build.

## Architecture

### Four executables, one Swift Package

`Package.swift` defines four `executableTarget`s plus zwei Bibliotheksziele (`MCPRahmen`,
`MoneyMoneyForm`), die den Code teilen, aber unabhängig ausgeliefert werden:

| Target | Path | Role |
|---|---|---|
| `simplebanking` | `Sources/simplebanking/` | The menu bar app (182 files, ~74k LOC). Entry point: `SimpleBankingApp.swift` (`@main`) → `AppDelegate` → `BalanceBar`. |
| `simplebanking-cli` | `Sources/simplebanking-cli/` | The `sb` CLI for terminal scripts (`sb balance`, `sb tx`, `sb refresh`, `sb fixed`, `sb subs`, …). Built on `swift-argument-parser`. **Read-only against the cache** — write paths live in the app. |
| `simplebanking-mcp` | `Sources/simplebanking-mcp/` | MCP server that exposes banking tools to Claude Code / other MCP clients. |
| `simplebanking-mmimport` | `Sources/simplebanking-mmimport/` | Seit 2.2.0: liest eine MoneyMoney-Datenbank (SQLCipher) und schreibt sie als Plist auf stdout. **Eigener Prozess aus zwei Gründen:** GRDB linkt das System-SQLite, SQLCipher ist ein Fork mit denselben `sqlite3_*`-Symbolen — beides in einem Binary heißt doppelte Symbole oder falsche dyld-Bindung. Und in derselben MoneyMoney-Datei liegen Bank-PIN und HBCI-Privatschlüssel: Drei Zusagen (kein `SELECT *`, kein `sqlcipher_export`, `READONLY` ohne Diagnoseausgabe) hält `MoneyMoneyHelferTests` **am Quelltext** fest. Kennwort kommt über stdin, nie über `argv`. |

CLI and MCP read the **same SQLite DB** the app writes (`~/Library/Application Support/simplebanking/transactions.db`, GRDB-backed). They never call the bank themselves.

Fixkosten und Abos rechnet **nur die App**; sie legt das Ergebnis als Schnappschuss ab
(`MCPSchnappschuss`, `auswertung.json`), CLI und MCP lesen ihn. Zwei Auswertungen
derselben Zahl laufen garantiert auseinander — der Umweg ist Absicht, der Preis ist
Aktualität, deshalb trägt jede Antwort ihren Zeitstempel.

### App layer (`Sources/simplebanking/`)

- **No SwiftUI `App` struct, no Xcode project** — pure `NSApplication` with `.accessory` activation policy (menu bar, no Dock icon by default).
- `BalanceBar.swift` is the orchestrator god-object (~9400 LOC, ~80% of UI logic). Owns `NSStatusItem`, `NSPopover` for the flyout, `NSPanel`s for transfer + transactions, all hotkeys, refresh timers, and the slot-switching state machine. **Most features start here** — when in doubt, grep `BalanceBar`.
- **State stores** are `@MainActor final class … : ObservableObject` singletons with `@Published` properties — `MultibankingStore` (slots + activeIndex), `BankLogoStore`, `ThemeManager`, `FreezeState`, etc. SwiftUI views attach via `@ObservedObject`.
- **`TransactionsViewModel`** is the per-panel VM. `vm.transactions: [TransactionsResponse.Transaction]` is the canonical in-memory list; the bank model lives in `BankingModels.swift`.

### Banking flow

```
BalanceBar
  └─ YaxiService.swift           ← async API wrapper (fetchBalances, fetchTransactions, sendTransfer)
       └─ YaxiTicketMaker.swift  ← ticket signing (uses Transfer-Pair for licensed transfers)
            └─ RoutexClient (routex-client-swift SPM dep, seit 28.10.2026 auf 0.6.0)
                 └─ YAXI Open Banking API → bank (PSD2)
```

**Bankaufrufe laufen über `YaxiTransport`** — `client()` für den interaktiven Weg,
`refreshClient()` für den nicht-interaktiven. Beide ziehen ihren HTTP-Transport aus
`YaxiTransport.fabrik`; im Test lässt sich der ersetzen (`YaxiTransportTests`). Nie
direkt `RoutexClient()` bauen, sonst hängt die Stelle wieder am echten Netz.

**Bei Redirect-Banken (`model.none`) wird die Zustimmung NIE automatisch verworfen** —
weder bei `unauthorized` noch sonst. `darfZustimmungVerwerfen` ist die einzige Stelle,
die das entscheidet, und beide Folgeschritte (Abruf ohne connectionData, `clearAll`)
hängen daran. Neue Zustimmung entsteht dort ausschließlich bei der Einrichtung; jedes
automatische Wegwerfen kostet sicher einen QR-Scan und heilt nichts. Wer hier eine
Ausnahme einbauen will: Genau die gab es schon einmal, sie hat am 23.08.2026 eine
Dauerschleife erzeugt.

**Salden und Umsätze versuchen zuerst den Schnellabruf** (`RoutexRefresh`,
`schnellSalden` / `schnellUmsaetze` in `YaxiService`). Er braucht nur die gespeicherte
`connectionData` und kennt keine Freigabe-Zweige. Scheitert er, läuft unverändert der
interaktive Weg — ein `nil` von dort ist kein Fehler, sondern die Aufforderung
weiterzumachen. **Standardmäßig aus** seit dem 23.08.2026; zum Erproben:
`defaults write tech.yaxi.simplebanking yaxiNonInteractiveRefreshEnabled -bool YES`.

**SDK-Fehler kommen in vier Familien** (seit routex-client-swift 0.5): `RoutexError`
meldet der Dienst, `RoutexClientError` der Client, `HTTPError` der Transport,
`KeySettlementError` die Attestierung. Wer nur auf einen Typ prüft, übersieht die
anderen — und zwar **ohne Compilerfehler**, weil alle vier `Error` sind. Alle
Entscheidungsstellen liegen in `YaxiService` (`darfZustimmungVerwerfen`,
`erstMitConnectionDataWiederholen`, `isConnectionResetError`,
`captureUnexpectedErrorIfNeeded`) und in `RoutexErrorMapper`; `SDKFehlerfamilienTests`
hält sie fest. Beim Ergänzen eines `catch` oder `as?` dort immer prüfen, welche Familie
gemeint ist.

**HBCI mutex, je Konto:** banks like Volksbank reject parallel calls on the same connection with "Fehlender Dialogkontext". Jeder Abrufweg prüft `bankAufrufLaeuft(slotId)` gegen `hbciSlotsInFlight` / `paypalSlotsInFlight` (beides `Set<String>`) und läuft über `BankRequestQueue`. When adding any new bank-call site, **do not** start a `Task { fetch… }` without going through the queue or guarding against in-flight calls.

Die Sperre war bis 2.0.5 **global** (`isHBCICallInFlight: Bool`), und das war ein Fehler:
Wartete ein Redirect-Konto auf seine Freigabe, lag bis zu drei Minuten lang die ganze App
still — Herunterziehen, ↻ und Klick aufs Symbol taten nichts, ohne Rückmeldung. Die
Sperre gehört der Bankverbindung, nicht dem Programm. Wer hier wieder ein einzelnes
`Bool` einführt, baut genau diesen Fehler nach.

**Eine abgebrochene Freigabe muss neu anstoßbar bleiben.** Das Schließen des
Freigabe-Fensters ist absichtlich **kein** Abbruch (die Freigabe kann in der Banking-App
längst erteilt sein und noch eintreffen) — aber ohne Ausweg blockiert das Warten das
Konto zehn Minuten. Dafür gibt es seit 2.2.0 „Freigabe neu anstoßen" über der
Umsatzliste und im Menüleisten-Menü.

### Concurrency invariants

- All UI-touching state is `@MainActor`. `LicenseManager`, `MultibankingStore`, view models — all main-actor isolated.
- `Status` enums in stores are `Equatable` so SwiftUI's `onChange` works. Don't add stored closures without `@Sendable` annotations.
- Background work uses `Task { await … }` and switches to main with `await MainActor.run { … }` or by calling main-isolated methods directly. Avoid `DispatchQueue.main.async` in new code — it predates the actor migration.
- Carbon-Hotkey callbacks live outside the actor system; they wrap their bodies in `MainActor.assumeIsolated { … }`.
- **Im Einrichtungsassistenten gilt die Regel oben NICHT.** `NSApp.runModal` dreht die
  Schleife in `NSModalPanelRunLoopMode`; der Haupt-Actor plant über die gemeinsamen Modi.
  Also läuft `Task { … }` von dort **nie an** und `await MainActor.run { … }` kehrt **nie
  zurück** — ohne Warnung, ohne Fehler, ohne Absturz, die Oberfläche steht einfach. Wer
  aus dem Assistenten heraus Arbeit startet, nimmt `Task.detached` und kommt über
  `Hauptthread.sprung` / `Hauptthread.lauf` zurück (`RunLoop.perform(inModes:)` mit
  `.modalPanel`). Kostete 2.0.6/2.0.7 zwei Releases und am 11.11.2026 einen halben Tag am
  MoneyMoney-Import. `ModalHopRegelTests` hält die Regel fest.
- **Abschluss-Blöcke von System-APIs erben die Isolation der umgebenden Funktion.** Steht
  ein Completion-Handler in einer `@MainActor`-Methode, hält Swift 6 ihn für
  main-isoliert und prüft das beim Eintritt — ruft das Framework ihn auf einer eigenen
  Queue auf, endet der Prozess mit SIGTRAP (`_dispatch_assert_queue_fail`). Getroffen hat
  es `ASWebAuthenticationSession` in `Freigabefenster`: Freigabe erteilt, App weg, nichts
  im Log. Solche Blöcke ausdrücklich `@Sendable` auszeichnen und die gebrauchten Werte
  **vor** dem Sprung auf Sendable-Typen eindampfen (`any Error` darf die Grenze nicht
  überqueren).

### Slot scope

`MultibankingStore.shared.activeSlotId` (`nonisolated(unsafe)` for cross-thread reads) is the bank context every call must scope itself to. `slotEpoch` is bumped on every slot switch — refresh tasks check it on awaited boundaries and bail out if a switch happened mid-flight. Anything that caches per-slot (`cachedBalance.<slotId>`, `lastSeenTxSig.<slotId>`, settings) keys off `slotId`, not a transient index.

### Persistence

- **Transactions DB:** GRDB / SQLite at `~/Library/Application Support/simplebanking/transactions.db` (Demo-Modus: `transactions-demo.db`). Migrations live in `TransactionsDatabase.swift` and are append-only — never rename or remove existing migration steps. Numbered (v1, v2, …); the migration system replays in order on every launch.
- **Credentials:** AES-GCM at `~/Library/Application Support/simplebanking/credentials.json`, master password in Keychain (`tech.yaxi.simplebanking` service).
- **Per-slot settings:** `BankSlotSettingsStore` reads/writes UserDefaults keys prefixed with the slot id.
- **Session tokens (YAXI connection state):** UserDefaults via `SessionStore` — wiped on `Unauthorized` / `ConsentExpired`.
- **Kategorien:** `TransactionCategory` ist seit 2.2.0 kein `enum`, sondern eine
  **Struktur** — Grundlage für eigene Kategorien (`Eigenkategorien`). Die 14 eingebauten
  behalten ihre `rawValue`s, darum lesen Datenbank, Overrides und Regeln unverändert
  weiter. Zwei Fallen stehen als Warnung am Typ: `Codable` ist **von Hand** geschrieben
  und kodiert einen nackten String (eine synthetisierte Fassung schriebe
  `{"rawValue": …}` und verlöre still die Kategorie jeder gespeicherten Regel), und ein
  `switch` über Kategorien braucht ein `default` — wer eine eingebaute ergänzt, bekommt
  an den drei Stellen mit fester Zuordnung (`icon`, `BTXMosaic.style(for:)`,
  `categoryEmoji`) **keinen Compilerfehler** mehr.

### Tests

- Test target `simplebankingTests` uses `@testable import simplebanking` against **real production code** — there are no mock layers. Test new code by making it pure (extract free functions / static methods) and feeding it explicit inputs.
- Tests are `@MainActor` if they touch any store. XCTest is the framework.
- Current count is **1705** in 173 files (Stand 2026-11-12, davon 4 übersprungen, Laufzeit ~16 s). A green Suite is a hard gate before commit.
- Mehrere Tests prüfen den **Quelltext selbst** statt sein Verhalten (`Quelltext.swift` als Helfer): die drei Sicherheitszusagen des MoneyMoney-Helfers, die Modal-Hop-Regel, die Fensterbreite in den Einstellungen. Für Zusagen, die sich nicht ausführen lassen, ist das der einzige Weg, der nicht „Durchsicht" heißt.

## Memory of conventions worth re-reading

Die Notizen liegen im Gedächtnisverzeichnis der jeweiligen Claude-Code-Sitzung
(`~/.claude/projects/<slug>/memory/MEMORY.md`) und werden beim Start automatisch geladen
— **nicht** im Repo. Darin unter anderem: die `com.apple.macl`-Falle nach einer
Time-Machine-Wiederherstellung (und warum das Vorhandensein des xattr allein noch kein
Nachweis ist), der Cryptex-Pfad der Metal-Toolchain, die Build-Voraussetzungen dieser
Maschine und ein Protokoll der Projektzustände je Version. Check it before tackling
anything tagged "geparkt".

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
2. `BUILD_FIRST=1 bash sign-and-notarize.sh` → notarized, stapled DMG, and **step [11/11]**
   prints the ready-made `<item>` with version, length, signature and enclosure URL computed
   from the DMG it just built. **Do not run `generate_appcast`** — it scans the whole
   build folder (every throwaway build becomes an item) and cannot express the gate.
   That is why it was removed from the script.
   Soll das DMG einen sprechenden Namen tragen: `DMG_PATH="$PWD/SimpleBankingBuild/simplebanking-X.Y.Z.dmg"`
   davorsetzen. Muss **versioniert** sein — die Enclosure-URL zeigt auf genau diese Datei.
   Ein Lauf ohne Neubau (`BUILD_FIRST=0`) behält die Build-Nummer; ein voller Lauf zählt
   hoch und macht einen schon geschriebenen Appcast-Eintrag ungültig.
3. Paste the item into `appcast.xml`, fill in the release notes, `xmllint --noout appcast.xml`,
   commit.
4. **Reihenfolge, die beide Zwänge löst** (erprobt mit 2.0.5): Arbeitsbranch pushen →
   `gh release create vX.Y.Z <DMG> --target <branch>` → `main` per Fast-Forward
   (`git checkout main && git merge --ff-only <branch>`) → `main` pushen.
   Warum so: `gh release create` ohne `--target` tagt den aktuellen HEAD des Remotes, also
   den falschen Commit (nachträglich korrigierbar mit
   `gh api -X PATCH repos/klotzbrocken/simplebanking/git/refs/tags/vX.Y.Z -f sha=<sha> -F force=true`).
   Und das Release muss **vor** dem `main`-Push stehen, sonst zeigt die Enclosure-URL eine
   Weile ins Leere und wer in dem Fenster nach Updates sucht, bekommt einen Fehler. Der
   Branch-Push vorweg ist harmlos: Sparkle liest `main/appcast.xml`, nichts anderes.
   `--target` braucht einen Branch-**Namen** oder vollen SHA; ein Kurz-SHA wird mit
   `HTTP 422: Release.target_commitish is invalid` abgelehnt.
   Gepusht wird über HTTPS — das Remote ist `git@github.com:…`, SSH ist aber nicht
   eingerichtet; `gh` liefert die Zugangsdaten:
   `git push https://github.com/klotzbrocken/simplebanking.git main`.
5. Gegenprobe am ausgelieferten Artefakt: DMG von der Release-URL ziehen und den SHA-256
   gegen die lokale Datei vergleichen. Ein notarisiertes, gestapeltes DMG mit falschem
   Inhalt sieht von außen fehlerfrei aus — Gatekeeper winkt es durch, und das Ticket
   bestätigt nur, dass Apple es geprüft hat, nicht dass die Software taugt.
6. Verify what clients actually get — `raw.githubusercontent.com` lags ~1 minute behind
   the push:
   ```bash
   curl -s https://raw.githubusercontent.com/klotzbrocken/simplebanking/main/appcast.xml | grep -o '<title>[^<]*</title>' | head -3
   ```
7. Website: upload the DMG under its **versioned** filename and point `DOWNLOAD_URL` in
   `Download.tsx` at it. Never reuse `assets/simplebanking.dmg` — the site sits behind a
   cache with `max-age=2592000` (30 days) that kept serving the June file for weeks after
   the 2.0 upload. A URL that did not exist before cannot be stale. Same trap in
   `BetaDownload.tsx`.

`CFBundleVersion` is stamped as `YYYYMMDD<seq>` and rises with **every** build, including
throwaway ones — so the appcast version must always come from the DMG actually uploaded.
Schritt `[11/11]` des Skripts rechnet das aus der gebauten DMG. Never reset
`.build-number` after a public release.

`<sparkle:version>` in the appcast must be the CFBundleVersion of the DMG you actually
uploaded — it is stamped as `YYYYMMDD<seq>` at build time and rises with **every**
build, so re-check it after any rebuild. CFBundleVersion is monotonic across
release+delta — never reset `.build-number` after a public release.

## Raycast-Erweiterung (`raycast/`)

Eigenes TypeScript-Projekt im selben Repo, eigener Veröffentlichungszyklus über den
Raycast-Store. Sie ruft **ausschließlich** `sb --json` auf und kennt weder Zugangsdaten
noch Banken — jede neue Ansicht gehört deshalb erst ins CLI, dann hierher.

```bash
cd raycast && npm install
npx ray lint          # Store-Prüfung vorab
npx ray build -e dist
npm run dev           # lädt die Erweiterung live in Raycast
```

Vor der ersten Einreichung MUSS `author` in `package.json` auf einen existierenden
Raycast-Benutzernamen gesetzt werden — `ray lint` fragt die Store-API und schlägt sonst
mit 404 fehl.

**Stand:** Die Erweiterung ist im Store — PR raycast/extensions#30602 wurde am
08.10.2026 gemergt. Folgeänderungen gehen über den Fork-Klon unter
`~/raycast-extensions`.

## Code style (from CONTRIBUTING.md)

- Swift API Design Guidelines.
- `// MARK: -` to section large files.
- Prefer `async/await` over completion handlers for new code.
- No force unwraps (`!`) outside `@IBOutlet` / `fatalError`.
- Conventional Commits: `feat(scope): …`, `fix(scope): …`, `chore: …`, etc.
- One feature/fix per PR; update `CHANGELOG.md` under `## [Unreleased]`.
