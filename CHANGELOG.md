# Changelog — simplebanking

## [1.4.0] — 2026-04-26

### Neu
- **CLI `sb`** — Neues 3. Executable im Bundle. Read-only Cache-Zugriff aus dem Terminal: `sb balance`, `sb accounts`, `sb tx`, `sb summary`, `sb today`, `sb week`, `sb month`, `sb refresh`. Alle Subcommands mit `--json`-Flag, `--slot`-Filter, `--color auto|always|never`. `sb refresh` triggert die laufende App via DistributedNotification und zeigt ehrlichen Status (success / locked / failed) statt pauschal „aktualisiert".
- **Dock-Mode** — Optionales Dock-Icon zusätzlich zur Menüleiste. Setting in „Allgemein → Dock". Cmd-Q-Verhalten passt sich an (Dock-Mode = „Beenden", Agent-Mode = „Fenster schließen"). Klick auf Dock-Icon öffnet das Umsatzfenster.
- **Import-System** — Neuer Import-Dialog in Settings → Konten mit vier Quellen:
  - **Deep-Sync 180 / 365 Tage** via YAXI (force-refetch, kann SCA/TAN triggern)
  - **OFX-Datei** (OFX 1.x SGML + OFX 2.x XML, mit Charset-Erkennung CP1252/ISO-8859-1/UTF-8)
  - **CAMT.053 XML** (Dialekt-Varianten 001.02–001.08+, getestet gegen DKB, Commerzbank, Sparkasse, ING, Comdirect)
- **Transaktions-Detail-View** — Vollbild-Sheet mit allen Buchungs-Properties, manueller Kategorie- und Händler-Override (slot-scoped), Reminder-Erstellung mit Datumspicker, Notiz-Feld, Anhänge bis 3 MB / 3 Stück pro Buchung, Bookmark-Funktion.
- **GreenZoneRing mit Dispo-Mode** — Neuer „Bin ich im grünen Bereich?"-Ring im Umsatzpanel. Diskrete semantische Farbbänder statt continuous hue: Freeze=Blau, Dispo (balance < 0)=Rot mit `|balance|/dispoLimit`-Anzeige, sonst Rot/Orange/Grün bei Schwellen 0.34/0.67.
- **Universelle Fehler-Übersetzung** — Bank-Fehlermeldungen (`RoutexClientError`) werden jetzt zentral auf deutsche Texte mit Aktions-Vorschlägen gemappt. Beispiel: „UnexpectedError" → „Unerwarteter Bankfehler — Kurz warten, dann erneut versuchen". Plus Retry-After-Hinweis bei Rate-Limit.

### Geändert
- **Settings → Konten** komplett überarbeitet: 3 klare Cards pro Slot (Stammdaten, Finanz-Ziele, Kontostand-Schwellen), neuer Settings-Bereich für Dock + Infinite Scroll + Balance-Click-Mode-Picker.
- **Menüleiste Unified-Mode-Icon**: `building.columns.fill` → `square.stack.3d.up.fill` (konsistent mit Flyout).
- **Auto-Refresh Default** 60 → 240 Min (4 h) für Konsistenz mit Anzeige-Labels.
- **App-Passwort-Beschreibung präzisiert** — schützt jetzt ehrlich nur die Bank-Zugangsdaten im Keychain. Lokal gespeicherte Umsätze (Cache) sind transparent als „auch für CLI/MCP lesbar" beschrieben.
- **SCA-Polling Backoff** — Threshold von 3 auf 8 consecutive errors mit exponentiellem Backoff (2s/4s/8s/16s/30s cap). Schützt vor 429-Rate-Limit-Bursts (N26/Sparkasse).
- **Routex SDK** auf 0.4.0 (war 0.3.0). Mac-Catalyst-Support hinzugefügt (für uns nicht relevant), erweiterte Test-Coverage.

### Behoben
- **Race bei Slot-Switch** — `checkNewBookings` hatte keinen `slotEpoch`-Check. Bei mid-fetch Slot-Wechsel landete die Antwort als Notification/Ripple/Unread-Indikator im neuen Slot. Plus: parallele HBCI-Calls aus `sb refresh` + Auto-Refresh-Timer wurden über zusätzlichen `isHBCICallInFlight`-Guard in `checkNewBookings` verhindert (vorher „Fehlender Dialogkontext" bei Sparkasse/Volksbank).
- **OAuth-Listener Hardening** — Lokaler Callback-Listener bindet jetzt nur auf Loopback (127.0.0.1), nicht alle LAN-Interfaces. Plus Path-Validation: nur `/simplebanking-auth-callback` triggert das Polling-Wakeup.
- **Master-Password Memory-Lifetime** — Abgeleitete PBKDF2-Schlüssel (32 Byte) und entschlüsselte Plaintext-Buffer werden nach Verwendung mit `memset_s` zeroized. Reduziert das Window in dem Schlüsselmaterial im Heap liegt.
- **Slot-Switch atomarer** — `SlotContext.activate(slotId:)` als zentrale Stelle für Slot-Wechsel über alle Layer (YaxiService, CredentialsStore, TransactionsDatabase). Sechs verteilte Triple-Set-Callsites mit teilweise inkonsistenter Reihenfolge konsolidiert.
- **Slot-Removal Cleanup** — `removeSlot` räumt jetzt auch UserDefaults-Bloat (`cachedBalance.<id>`, `lastSeenTxSig.<id>`), encrypted credentials-Files und YAXI-Session/connectionData auf. Vorher leakte ein entfernter Slot dauerhaft.
- **Manuelle Kategorie-/Händler-Overrides slot-scoped** — Composite-Key `slotId|txID` (vorher nur txID). Identische Tx in mehreren Slots leakten Override sonst slot-übergreifend.
- **Reminder-Erstellung atomar** — Wenn EventKit-Create succeeds aber DB-Write fails, wird der EventKit-Reminder rückwärts gerollt. Vorher orphaned Reminder in Reminders.app, den simplebanking nicht kannte.
- **OFX-Charset-Erkennung** — Sparkasse-OFX-Files mit `CHARSET:1252`-Header werden jetzt korrekt als Windows-1252 dekodiert. Vorher Mojibake bei Umlauten + €-Zeichen (Latin-1-Fallback dekodiert 0x80 als Control-Char).
- **CAMT.053 XXE-Härtung** — `XMLParser.shouldResolveExternalEntities = false` explizit gesetzt.
- **Migration v21 — `ON DELETE CASCADE`** für `transaction_attachments`. Bei DELETE FROM transactions (Slot-Removal, v17 wipe) bleiben jetzt keine orphaned Attachment-Rows zurück.
- **Compiler-Warnings** — `TransactionsPanelView` Toolbar-Delegate ist jetzt `@MainActor`, beseitigt Swift-6-Strict-Mode-Errors.
- **AppLogger PII-Schutz** — Zentraler `LogSanitizer` redacted IBAN, Credentials (key=value-Pattern), und lange Tokens (≥24 chars) automatisch in allen 100+ Log-Calls.
- **AI-Provider Fehlermeldungen** — 401/403/429/5xx werden jetzt verständlich gemappt („API-Schlüssel ungültig", „Rate-Limit, Retry in N s") statt rohem `AI API Fehler (401)`.
- **URLSession-Timeouts** für Logo-Fetches (LogoAssets, MerchantLogoService brandfetch + duckduckgo) — 15s explizit. Vorher hingen die Tasks bis zum macOS-Default (60s).
- **WAL-Sidecar Cleanup** beim App-Quit (`PRAGMA wal_checkpoint(TRUNCATE)`). Time-Machine-Backups sehen jetzt nur die Haupt-DB statt main + db-wal + db-shm (~3× kleiner).
- **`build-universal.sh` deprecated** — baute nur App-Binary ohne MCP+CLI. War Distribution-Trap. Standardpfad bleibt `build-app.sh`.
- **Tests verdreifacht** — 100 → 190. Neue Coverage für CLI-Refresh-Wire-Format, Slot-Context, Memory-Wipe, OAuth-Callback-Path-Matcher, AttentionInbox-Salary-Detection-Regression, Migration v21 Cascade, OFX-Charset-Erkennung, Override-Slot-Scope (Categorizer + MerchantResolver), AIHTTPError-Mapping, RoutexErrorMapper, LogSanitizer, SCA-Backoff.

### SDK-Update
- **Routex Client Swift 0.3.0 → 0.4.0** — kein Breaking-Change in unserem Use-Case. Alle 13 genutzten API-Calls funktionieren unverändert.

---

## [1.3.8] — 2026-04-17 (Build 20260417_045814_93)

### Neu
- **EventKit Reminders** — Erinnerungen zu Buchungen direkt in Apples Erinnerungen-App anlegen, Swipe-Aktion (Bell), neuer Filter „Erinnerungen" in der Umsatzliste, Startup-Sync gegen Ghost-Flags.
- **„Noch offen" (Left to Pay)** — Prognose der noch ausstehenden Fixkosten im aktuellen Zyklus als 11pt Subtitle unter dem Kontostand (Flyout + Panel). Cycle-Logik mit Salary-Day + Toleranz, pro Slot-Profil.
- **Stay on Top (Pin)** — Neue Pin-Nadel in der Toolbar neben dem Zahnrad: fixiert das Umsatzfenster oberhalb aller anderen Fenster (`panel.level = .floating`). State persistiert.
- **Aggregierte Flyout-Ansicht** — Stack-Icon (`square.stack.3d.up.fill`) konsistent in Menüleiste und Flyout, Mini-Account-Liste mit Bank-Icon + Betrag statt Pills.
- **„Alle als gelesen markieren"** — Im Footer-Menü „Mehr ▾", auto-disabled wenn nichts ungelesen.
- **Neue Neutral-Farben** — `sbNeutralStrong/Mid/Soft` (warmes Taupe) für die „Sonstiges"-Kategorie.

### Geändert
- **Settings-Panel UX-Polish** — Konten-Tab mit 3 klaren Cards (Stammdaten, Finanz-Ziele, Kontostand-Schwellen). „Money Mood" → „Kontostand-Schwellen" mit Untertitel. Labels „Kritisch ab" / „Komfortzone ab". Neuer `SettingsRow`-Helper mit `firstTextBaseline`-Alignment.
- **Freeze als Was-wäre-wenn** — Realer Kontostand dominant (30pt bold), Freeze-Projektion als 14pt Subtitle, GreenRing basiert auf realem Wert.
- **Bessere Fehlerkommunikation** — Bank-seitige `userMessage` wird direkt angezeigt. `Canceled` → „Erneut verbinden"-Button. YAXI Consent-Expired/Unauthorized → automatischer Retry ohne connectionData. RequestError → einmaliger Retry.
- **Attention Inbox** — Snooze permanent + additiv (kein 24h-Ablauf). Click-through scrollt direkt zur Buchung (Fingerprint-basiert).
- **Bank-Suche** — Limit 20 → 50 (ING findet jetzt ING-DiBa).

### Behoben
- **Datums-Verschiebung** — Buchungen waren um einen Tag verschoben. `isoDateFormatter` + `inputDateFormatter` auf `TimeZone.current` statt UTC.
- **Migration v17** — DB-Wipe nach dem Date-Fix (stale Fingerprints).
- **Flyout Doppelklick** — `popover.behavior = .semitransient` + `flyoutClosedByClickAt` via `popoverWillClose`.
- **Demo→Live Wechsel** — `activeSlotIds` (YaxiService/CredentialsStore/TransactionsDatabase) werden auf Live-Slot zurückgesetzt.
- **Refresh-Intervall Tooltip** — Default synchronisiert (240 statt 60), Stunden-Formatierung.
- **Unread-Dot nach Fetch** — `loadEnrichmentData` nach Upsert in `openTransactionsPanel`.
- **Reminder-Semantik** — `is_flagged` als Dead-Column, `reminderId` als Single Source of Truth, Migration v18 heilt Ghost-Flags.

---

## [1.3.1] — 2026-03-27 (Build 20260327_031316_239)

### Neu
- **Multi-Banking** — Bis zu 3 Bankverbindungen gleichzeitig; schnelles Umschalten über Tabs. Transparentes Upgrade von 1.2.x, keine Neueinrichtung der Konten nötig.
- **Transaktions-Filter** — Neues Filter-Menü neben „Umsätze": Alle / Einnahmen / Ausgaben / Abos / Fixkosten / Unkategorisiert. Aktiver Filter zeigt Statuszeile mit ×-Button.
- **Ripple-Effekt** — Wasserwellen-Animation auf der Kontostand-Kachel bei neuen Buchungen (Metal-Shader). Einstellbar: Classic (Konfetti) oder Ripple; optional dauerhaft.
- **AI-Kategorisierung** *(Experimentell)* — Automatische Kategorisierung über Anthropic Claude, Mistral oder OpenAI. 6 neue Kategorien: Gastronomie, Sparen, Freizeit, Gehalt, Gesundheit, Umbuchung. Läuft bankkontenübergreifend.
- **Kalender-Heatmap** — 5. Ansicht im Transaktionspanel: monatliche Ausgaben-Heatmap.
- **Verwendungszweck-Spalte** — Im breiten Panel-Modus (>840 px) eigene Spalte für den Verwendungszweck.
- **Doppelklick auf Flyout-Karte** — Öffnet direkt das Transaktionspanel.
- **Universal Binary** — arm64 + x86_64 (macOS 13+).

### Geändert
- Kontostand pro Bank gecacht → sofortige Anzeige beim Bankwechsel.
- Kontostand im Transaktionspanel aktualisiert sich nach Refresh.
- Standardwerte bei Neuinstallation: Flyout-Karte + Ripple aktiv.
- Refresh-Intervall-Labels in Stunden, Standard 4 Stunden.
- Neuer Settings-Bereich „Experimentell (Labs)" für AI-Assistent.
- YAXI-Traces und Setup-Diagnose-Logs nur bei aktiviertem Logging.
- Privacy-Text aktualisiert (erwähnt YAXI und Anthropic).
- „Zurücksetzen"-Menüeintrag ohne Warn-Emoji.
- Node.js/V8-Backend durch `routex-client-swift` (Rust FFI) ersetzt — kein lokaler Prozess mehr.

### Behoben
- Ripple-Effekt im Universal-Build fehlerhaft (fehlende Metal-Shader).
- Alle drei KI-Anbieter zeigten „aktiv", obwohl nur einer einen Key hatte.
- Nach Neuinstallation: unnötige 2FA beim ersten App-Neustart.
- FGW-Fix: veraltete Session-Daten beim Setup-Flow.

---

## [Unreleased] — v1.2.0

### Neu
- **Kalender-Heatmap** — 5. Icon im Transaktionspanel öffnet eine monatliche Heatmap der Buchungen. Rot = Ausgaben, Grün = Eingänge, Intensität entspricht dem Betrag. Navigation zwischen Monaten via `<` / `>`. Doppelklick auf einen Tag öffnet ein Detailblatt mit allen Buchungen des Tages.
- **Verwendungszweck-Spalte** — Im breiten Panel-Modus (840 px, Green-Button) wird zwischen Empfänger und Betrag eine zusätzliche Spalte mit dem Verwendungszweck angezeigt.
- **Doppelklick auf Flyout-Karte** — Doppelklick auf die Balance-Flyout-Karte schließt das Popover und öffnet direkt das Transaktionspanel.
- **Balance-Update bei Refresh** — Der angezeigte Kontostand im Transaktionspanel wird nach einem manuellen Refresh automatisch aktualisiert.

### Geändert
- **„Zurücksetzen"-Menüeintrag** — Das redundante ⚠︎-Emoji-Präfix wurde entfernt. Das SF-Symbol `exclamationmark.triangle` bleibt als Icon erhalten.

### Behoben (Kalender-Heatmap)
- Schließen-Button fehlte — Sheet konnte nur per Escape geschlossen werden.
- Keine Buchungen sichtbar — Die Heatmap las `tx.amount` aus dem `rawJSON`-Decode (immer `nil`). Umgestellt auf `TransactionRecord.betrag` (direkte SQLite-Spalte, korrekte `Double`-Werte).
- Tage 1–5 fehlten — ID-Kollision zwischen Offset-Zellen (`0…5`) und Tages-Zellen (`1…31`) in zwei separaten `ForEach`-Loops; zusammengeführt in einen einzigen Loop mit eindeutigen Indizes.
- Erster des Monats zeigte falschen Wochentag — `firstWeekdayOffset` nutzte jetzt einen Plain-Gregorian-Calendar ohne `firstWeekday`-Einstellung und setzt `day = 1` explizit.
- Betrag am 1. des Monats ca. 1.000 € zu hoch — Umstellung von `datum` (Wertstellungsdatum) auf `buchungsdatum` (Buchungsdatum) für die Tages-Zuordnung. Buchungen, die am letzten Tag des Vormonats gebucht wurden, aber Wertstellung am 1. des Folgemonats haben, erscheinen jetzt im korrekten Monat.
- Demo-Modus zeigte leere Heatmap — `loadAllTransactions()` liefert im Demo-Modus keine Daten (DB ist leer). Die Heatmap liest jetzt `@AppStorage("demoMode")` / `@AppStorage("demoSeed")` und generiert im Demo-Modus dieselben Fake-Transaktionen wie der Rest der App.

---

## [1.1.2] — 2026-02-xx

### Behoben
- Sparkle-Versionsnummern-Format korrigiert: Build-String enthielt Bindestriche, die Sparkle als Pre-Release-Trennzeichen interpretierte und Updates fälschlicherweise als Downgrade einstufte. Format auf `YYYYMMDD_HHMMSS_SEQ` umgestellt.

---

## [1.1.1] — 2026-02-xx

### Geändert
- Refresh-Intervall: Standard auf 4 Stunden (240 min) erhöht, Labels zeigen nun „X Stunden".
- Fehlermeldung bei `RoutexClientError.Unauthorized` wird als lesbare UI-Meldung angezeigt.
- Alle Logs vereint unter `~/Library/Logs/simplebanking/` (kein Desktop-Log mehr).

### Behoben
- Sparkasse Credential-Flow auf Browser-Redirect zurückgestellt.
- YAXI-Trace Ticket-Bug: Service „Trace" nutzte fälschlicherweise ein neues Ticket statt das originale wiederzuverwenden.

---

## [1.1.0] — 2026-02-24

### Neu
- Node.js/V8-Backend vollständig durch `routex-client-swift` (RoutexClient 0.3.0) ersetzt — keine Laufzeit-Abhängigkeit mehr, kleineres App-Bundle, kein JIT-Entitlement nötig.
- Neue Dateien: `YaxiService.swift`, `YaxiTicketMaker.swift`, `YaxiOAuthCallback.swift`.
- `sign-and-notarize.sh` benötigt keine JIT-Entitlements mehr.
