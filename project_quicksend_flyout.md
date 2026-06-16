# Plan: Quick-Send Drawer im Menüleisten-Flyout

**Quelle:** `/Users/maik/Downloads/design_handoff_quicksend_flyout/` (High-Fidelity HTML/React-Referenz)
**Ziel:** Kompakte Inline-Schnellüberweisung im bestehenden Flyout. Großes `TransferSheet` (480 pt NSPanel) bleibt unberührt.

## Produkt-Entscheidungen (vom User bestätigt 2026-06-10)
1. **Vorlagen = User-gepinnte Favoriten** (eigene UserDefaults-Liste, Emoji frei, max 4; nicht statisch, nicht Historie).
2. **Sende-Flow = Direkt senden** — Master-Passwort-Dialog + SCA, **kein** `transferDelaySeconds`-Countdown/Confirm-Schritt.
3. **Opt-in** — Default aus, Toggle in Settings (Labs), analog simplesend-MCP-Muster. Respektiert weiter Lizenz-Gate/Demo-Mode.

## Architektur-Befund (warum machbar/risikoarm)
- `YaxiService.sendTransfer(request:userId:password:requestedExecutionDate:)` (YaxiService.swift:1293) ist **self-contained**: HBCI-Mutex via `BankRequestQueue.withSlot`, SCA komplett intern (`handleSCA` wählt push/decoupled automatisch, Text-TANs via globalem `SCAFieldInputPresenter`). Caller bekommt nur `TransferOutcome`. → Drawer ruft **denselben Pfad** wie `TransferSheet` (TransferSheet.swift:1637).
- Master-Passwort: `requestMasterPassword()` (BalanceBar.swift:1846) = blockierender NSAlert, von überall nutzbar. Demo-Mode → leere creds, `sendTransfer` short-circuited zu `.demoSuccess` (YaxiService.swift:1301).
- Validierung: `TransferRequest.normalizeIban` (TransferRequest.swift:67), `TransferRequest.validateIban` (throws, mod-97, :75), `init(...) throws` (:22). Wiederverwenden.
- Anker: `StatusBalanceFlyoutCardView` (BalanceBar.swift:5251); `body` VStack ab :5360; Karten-Header in `defaultThemeCard`/`legacyCard`/`unifiedCard`. Popover-Größe: `popover.contentSize = NSSize(width: 348, height: hasDots ? 192 : 170)` (:2994), animiert bei Slot-Wechsel mit `.easeInOut(0.3)`.
- Tokens (ThemeSupport.swift): sbSurfaceSoft, sbBorder, sbTextPrimary, sbTextSecondary, sbGreenStrong, sbRedStrong, panelBackground — alle vorhanden.

## Neue Dateien
1. **`QuickSendFavorite.swift`** — `struct QuickSendFavorite: Codable, Identifiable` (emoji, name, iban, amount?, purpose?) + `final class QuickSendFavoritesStore: ObservableObject` (UserDefaults-JSON, `@Published items`, `add/remove/move`, Cap 4). Pure → testbar.
2. **`QuickSendDrawerView.swift`** — SwiftUI-Drawer (348 pt breit):
   - `@State name, iban, amountInput, purpose; phase (idle/sending/sent)`.
   - Reihe 1: Name (flex) + Betrag (122 pt, „€" fix rechts, `.monospacedDigit`). Reihe 2: IBAN (Monospace, 4er-Gruppen, grüner Haken+Rahmen bei valid). Reihe 3: Betreff. Reihe 4: 4 Favoriten-Buttons (30×30, Emoji, leerer Slot = gestricheltes „+" das aktuelles Formular pinnt; Kontextmenü zum Entfernen) + Spacer + Senden (`sbRedStrong`/weiß aktiv, sonst disabled).
   - Feld-Style: height 30, radius 7, sbSurfaceSoft, 1px sbBorder, font 12.5, h-padding 10.
   - `canSubmit = !name.isEmpty && ibanValid && amount > 0`. Senden → `TransferRequest` bauen → `requestMasterPassword()` (außer Demo) → `YaxiService.sendTransfer` → `.sent`-Bestätigungszeile („{Betrag} an {Name} gesendet") → nach ~1.5 s Drawer zu.
   - Pure Helfer (free functions, testbar): `parseQuickSendAmount(_:) -> (display:String, value:Decimal?)` (Ziffern+ein Komma, ≤5 Vorkomma, ≤2 Nachkomma), `formatIbanGroups(_:)`.

## Geänderte Dateien
3. **`BalanceBar.swift`**
   - `StatusBalanceFlyoutCardView`: `@AppStorage("quickSendEnabled") var quickSendEnabled = false`, `@State showSend`, Toggle-Button 26×26 in Header-HStack nach `Spacer()` (zu: `paperplane`/sbSurface/1px sbBorder; offen: `chevron.up`/sbTextPrimary-BG/invertiert). Nur rendern wenn `quickSendEnabled` **und** Send-Gate (Lizenz/FeatureFlag/Demo) erfüllt.
   - Drawer unter dem VStack-Inhalt rendern wenn `showSend`, mit `Divider()` (sbBorder).
   - **Höhen-Animation:** GeometryReader/`PreferenceKey` misst Ist-Höhe des VStack-Inhalts → Callback `onContentHeightChange` → `buildFlyoutHost`-Closure setzt `popover.contentSize.height` in `NSAnimationContext`/`.easeOut`. Vermeidet hartes +210-Hardcoding und ist robust gegen `.sent`-Zeile. (Verifizieren, dass kein fixes `.frame(height:)` auf der View den Drawer clippt.)
   - Konsistenz-Invariante (Memory `feedback_balancebar_consistent_height`): Drawer ist additive Erweiterung **unter** der Karte — die drei Saldo-Modi bleiben gleich hoch. ✓
4. **`SettingsPanel.swift`** — Labs/„Konten"-Sektion: Toggle `quickSendEnabled` (Default aus, Disclosure-Text wie simplesend) + Favoriten-Editor (max 4 pinnen/entfernen/sortieren, Emoji-Feld).
5. **`CHANGELOG.md`** — `## [Unreleased]` → `feat(transfer): Quick-Send-Drawer im Flyout (opt-in)`.

## Tests (gegen echten Produktionscode, `@testable import simplebanking`)
- `QuickSendFavoritesStoreTests` — add/remove/move/Cap-4/Persistenz-Roundtrip.
- `QuickSendAmountParserTests` — Komma-Regeln, Vor-/Nachkomma-Limits, Decimal-Wert.
- IBAN-Format/Validate über bestehende `TransferRequest`-APIs.
- `canSubmit`-Logik als pure Funktion testen.
- Gate: `swift test` muss grün bleiben (aktuell 497/497).

## Risiken / offen
- **Höhen-Animation** ist der heikelste Teil (NSPopover ↔ SwiftUI intrinsic size). Falls PreferenceKey-Messung zickt: Fallback auf feste Zielhöhen (`~382/404`) wie im Handoff.
- Kein Empfänger-Bank-Preview/Autocomplete wie im großen Sheet (bewusst weggelassen — Kurzform).
- Kein PDF/Mail-Quittung, kein Scheduled-Date (Kurzform).
- **Nicht committen/pushen** ohne explizite Freigabe (offener 1.6.0-Branch, 22 Commits ahead).
