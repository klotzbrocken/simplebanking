# Changelog — simplebanking

## [Unreleased] (1.6.0)

### Neu

- **Aufrunden-Ansicht** — neuer Sicht-Modus im Umsatzpanel, der den **Freeze-Modus ersetzt**. Aktivierung über den Centsign-Toggle (ehem. Schneeflocken-Icon) im Filter-Header, nur sichtbar wenn Aufrunden in den Slot-Einstellungen aktiviert ist und kein Aggregat-Mode aktiv ist. Beim Einschalten:
  - **Beträge in der Liste werden aufgerundet** angezeigt (z. B. -3,47 € → -5,00 € bei 5 €-Step). Original-Beträge bleiben in Detail-Sheets/Reports unverändert.
  - **Unter dem Kontostand** erscheint zweizeilig „Virtuell gespart X €" + „Heute +Y €".
  - **Mint/Sage-Hintergrund** überschreibt Bank-Tönung als visueller Mode-Indikator (Bank-Tint kehrt beim Ausschalten zurück).
  - **Sticky-Banner oben** mit Heute-Pot + Inline-Step-Picker (1/2/5/10 € — Wechsel persistiert sofort in Slot-Settings und re-rendert Liste live).
  - **Greenring + Dispo-Ring bleiben auf echten Werten** — die Lens ist nur eine Sicht-Schicht, keine Daten-Mutation.
  - **Auto-Off** bei Slot-Switch, bei Wechsel in den Aggregat-Mode, und wenn Aufrunden in Settings deaktiviert wird.

- **Freeze-Modus entfernt** — der „Was-wäre-wenn"-Freeze-Stack (FreezeAnalyzer/FreezeOverlay, Cyan/Teal-Tönung, fiktiver Kontostand-Header, Snowflake-Toggle) ist nicht mehr im Code. Die Aufrunden-Ansicht ist der konzeptionelle Nachfolger: konkrete reale Ersparnis statt theoretischer Abo-Pausierung.

- **Aufrunden / Spartopf** — pro Buchung wird die Differenz zum nächsten glatten Betrag (1 €, 2 €, 5 € oder 10 €, Schrittweite per Slot wählbar) im Hintergrund in einen virtuellen Tages-Spartopf gelegt. Income, exakte Boundary-Beträge und Non-EUR-TRX werden übersprungen; gerechnet wird ausschließlich bei `status=booked` (keine Doppelzählungen bei Pending→Booked-Übergängen). Pro Slot eigener Topf, idempotent gegen Re-Fetches.
  - **End-of-Day-Prompt**: beim ersten App-Open nach lokaler Mitternacht (oder vor jedem Flyout-Open / nach jedem erfolgreichen Refresh) öffnet sich für offene Töpfe ein Modal mit drei Optionen: **Verwerfen**, **Virtuell behalten** (sammelt sich pro Slot in einer Summe) oder **Auf Sparkonto übertragen** (öffnet das TransferSheet mit Sparkonto-Prefill und „Vom Aufrunden vorbereitet"-Badge — SCA + Bestätigung wie immer durch den User).
  - **Snooze** im Modal: 1 h / 24 h / „Nie mehr heute" (pro Slot+Tag, persistent in UserDefaults).
  - **Settings → Konto-Einstellungen → Aufrunden** (Card 2c): globaler Toggle pro Slot, Schrittweite-Picker, Sparkonto-Name + IBAN mit Live-mod-97-Validation, Read-only-Anzeige der virtuell gesparten Gesamtsumme inklusive „Auszahlen…"-Button (markiert die Pots optimistisch als überwiesen und öffnet TransferSheet mit dem Gesamtbetrag).
  - **Fallback bei fehlender IBAN**: wenn der User „Auf Sparkonto übertragen" wählt aber noch keine Sparkonto-IBAN in den Settings hinterlegt hat, erscheint eine Inline-Eingabe direkt im Modal — die IBAN wird beim Bestätigen automatisch in den Slot-Settings persistiert.
  - Demo-Mode voll funktionsfähig (lokales Bookkeeping ohne Bank-Calls); nur die TransferSheet-Auszahlung läuft durch den bestehenden simplesend-Lizenz-Gate.
  - Neue SQLite-Tabellen `roundup_entries` (append-only Ledger, idempotent via `(slot_id, tx_id)`-PK) und `roundup_pots` (Tages-Aggregat mit Status open|pending|discarded|kept_virtual|transferred). Migration v22, keine Foreign-Keys — Re-Importe / Slot-Removes lassen den Pot intakt.

- **Umsatzliste in Bankfarbe einfärben** — der Hintergrund der Umsatzliste, die einzelnen Buchungen und der BalanceBar-Layer übernehmen jetzt die Primärfarbe der aktiven Bank (z. B. Sparkasse rot, ING orange, Deutsche Bank blau). Macht sofort sichtbar, welcher Slot gerade aktiv ist. Freeze-Modus überschreibt weiterhin mit Cyan/Teal; MoneyMood-Saldo-Farben (Amount-Text, Balance-Card-Gradient) bleiben unangetastet.
  - Globaler Toggle in Einstellungen → Verhalten → Darstellung (Default an).
  - **Sättigungs-Slider 0–100 %** zum Feintuning (Default 30 %). Im Dark Mode +30 % interner Sichtbarkeits-Boost.
  - **Pro-Slot-Override** in Konto-Einstellungen → Anzeige für Banken, deren Farbe zu grell wirkt.
  - Aggregiert-Mode bekommt keinen Tint (keine einzelne Bank dominant).

- **simplesend via MCP (`prepare_transfer`)** — Claude/MCP-Clients können eine SEPA-Überweisung **vorschlagen**: der MCP-Server validiert die Eingaben (Empfänger-Name, IBAN, Betrag, Verwendungszweck, End-to-End-ID) und schreibt einen Draft. Die App watcht den Draft-Ordner, öffnet das TransferSheet mit den vorausgefüllten Feldern und zeigt ein „Vom Assistant vorbereitet"-Badge. **Bestätigung + SCA bleiben beim User** — Lizenz-Gate, Send-Delay, SCA-Polling, Slot-Race-Schutz und volle IBAN-mod-97-Validierung laufen unverändert. Drafts haben 5-Min-TTL und sind one-shot.

- **Voll-Migration auf YAXI-Bank-Catalog** — Bank-Logos + Brand-Farben kommen jetzt aus dem offiziellen `https://logos.yaxi.tech/banks/catalog.json`-Snapshot (Resources/yaxi-bank-catalog.json). Vorteile:
  - **172 Banken** statt vorher ~30 (incl. AT/NL/IT/UK: bawag, easybank, raiffeisen-AT, abnamro, rabo, barclays, hsbc, natwest, lloyds, …).
  - **Strukturierte Brand-Farben** via `primaryColor`/`secondaryColor` aus dem Catalog (ersetzt das frühere SVG-data-Attribut-Parsing in `GeneratedBankColors`).
  - **Mask-Varianten systematisch** für Dark-Mode-Inversion (ersetzt unsere ad-hoc `data-maskable`-Markierung).
  - SVGs werden lazy aus dem Catalog ins User-Cache-Verzeichnis extrahiert. Cache wird beim Catalog-Update automatisch invalidiert (SHA-256-Hash-Manifest).
  - Entfernt: `Resources/bank-logos/*.svg` (113 Files), `GeneratedBankColors.swift`, `scripts/generate-bank-colors.sh`. Build-Script entrümpelt.
  - Neu: `BankLogoCatalog.swift` + `BankLogoCache.swift` + 19 Regression-Tests.

- **„Problem melden" bei unerwarteten Bank-Fehlern** — wenn ein Bank-Call mit einem nicht selbst-erklärenden Fehler (`RoutexClientError.UnexpectedError`) abbricht, fragt die App nach: „Möchtest du das melden?". Per Klick öffnet sich der Standard-Mail-Composer mit einer vorbefüllten Mail an `support@simplebanking.de` — verschlüsselte Diagnosedatei automatisch angehängt. Privacy-Hinweis macht transparent, was in der Datei steht (keine Online-Banking-Zugangsdaten). Aus dem Setup-Flow ist der Report über einen „Problem melden…"-Button im Diagnose-Bereich des Setup-Sheets erreichbar.
  - Throttle: max. 1 Report pro `(connectionId, Bank-Call)` in 30 Min — verhindert dass ein persistenter Bank-Bug die App mit Dialogen flutet.
  - Capture im Hintergrund: bei Auto-Refresh läuft kein Alert, der Report wird beim nächsten App-Fokus angeboten.
  - Skip in Demo-Mode, Bank-Diagnose-Session (eigener Mail-Flow), CLI und Background-Importer.

### Behoben
- **Aufrunden konnte denselben Betrag mehrfach überweisen** — der Auszahlungsdialog las Live-Werte aus der Umsatzliste und markierte nie einen Topf als überwiesen. Jetzt werden nach erfolgreicher Überweisung alle erfassten Pots im gewählten Zeitraum als `transferred` finalisiert und bereits ausgezahlte Tage aus dem Payout-Betrag ausgeblendet. Die hypothetische Savings-Card bleibt unverändert.
- **Slot-Löschung ließ Aufrundungsdaten zurück** — beim Entfernen eines Kontos werden `roundup_entries` und `roundup_pots` jetzt mit bereinigt (v22 nutzt bewusst keine Foreign-Keys).
- **Log-Sanitizer erkennt jetzt gruppierte IBANs** — die Redaction griff nur bei durchgeschriebenen IBANs; gruppierte Formen wie `DE89 3704 0044 0532 0130 00` aus Banktexten/Traces werden jetzt ebenfalls ersetzt.
- **simplesend-Datenschutz-Text ehrlicher** — statt „simplebanking sieht keine Bank-Daten" jetzt: kein Cloudkonto, Zugangsdaten lokal im Keychain, Zahlungsauslösung über YAXI, TAN/SCA direkt bei der Bank.
- Kleinere Konsistenz-Verbesserungen im Setup-Fehler-Pfad (Diagnose-Bereich zeigt jetzt ggf. „Problem melden"-Button neben „Log-Ordner öffnen").

## [1.5.0] — 2026-05-03

### Neu

- **Geld senden** — kostenpflichtige Erweiterung (€14 one-time, lifetime updates innerhalb 1.x). SEPA-Überweisung direkt aus simplebanking heraus, ohne die Banking-App zu öffnen.
  - Single-Input-Eingabe: tippe Empfänger-Name oder IBAN, Live-Vorschläge aus Deiner Buchungs-Historie (Top 5 nach Frequenz × Recency)
  - Klick auf Vorschlag füllt IBAN, Default-Betrag (häufigster Wert an diesen Empfänger) und Default-Verwendungszweck (letzter)
  - SEPA-Validation (IBAN mod-97, 34 Länder), Sicherheits-Limit 100.000 €
  - SCA-Flow (TAN/Browser-Redirect) wie gewohnt direkt mit der Bank — simplebanking sieht keine Bank-Daten
  - Demo-Mode-User können das Feature ohne Lizenz visuell testen (Mock-Sends, kein echter Bank-Call)
  - Lizenz-Verkauf via Polar. Aktivierung in Einstellungen → Über → Lizenz-Sektion. Lizenz-Key per Email nach Kauf.
- **TransferRecipientStore** — neue lokale Aggregation auf der `transactions`-Tabelle für die Autocomplete-Vorschläge. Slot-scoped, sortiert nach `frequency × max(0.1, 1 − daysSinceLast / 365)`.

### Geändert
- **Setup-Copy** — die Aussage „Nur Lesezugriff. Keine Überweisungen." entfällt, da Geld-senden nun als optionale Erweiterung verfügbar ist. Neue Formulierung nennt es ehrlich als kostenpflichtiges Add-on.
- **Menüleiste** — neuer Eintrag „Geld senden…" (⌘N) zwischen „Aktualisieren" und „Automatisch verstecken".

### Behoben
- Diverse Code-Ergonomie-Anpassungen rund um den TransferSheet-Workflow.

## [1.4.1] — 2026-05-02

### Neu
- **Money-Mood 6-Tier-System** — Stimmungs-Indikator wechselt jetzt durch sechs Stufen statt vier: `Tief im Dispo` (Burgund) — `Überzogen` (Rot) — `Knapp` (Orange) — `Komfortzone` (Sand) — `Gutes Polster` (Grün) — `Sehr wohlhabend` (Smaragd). Zwei neue per-Slot-Schwellen in Settings → Konten → Kontostand-Schwellen: „Tief im Dispo ab" (Default −1000 €) und „Sehr wohlhabend ab" (Default 5000 €), plus Live-Preview-Skala mit Marker am aktuellen Saldo.
- **Money-Mood Emojis (optional)** — Toggle in Settings → Verhalten: zeigt 💀 / 😟 / 🥵 / 🙃 / 🙂 / 😎 neben dem Bank-Logo in der Menüleiste und im Flyout-Popover. Bleibt sichtbar wenn der Saldo versteckt ist (Hide-Timer / privacy mode).
- **Bank-Logo Dark-Mode-Toggle** — Settings → Verhalten: kontrolliert ob sehr dunkle Bank-Logos (z.B. Deutsche Bank, C24) im Dark Mode automatisch invertiert werden. Default an. Luminanz-Berechnung jetzt mit korrekter sRGB-Linearisierung (war vorher fehlerhaft, daher haben einige Banken keinen Effekt gezeigt).
- **Demo-Mode global** — `sb` CLI und MCP-Server folgen jetzt dem App-Demo-Mode: ein Toggle, alle drei Pfade flippen mit auf Demo-Daten. CLI synthesisiert Demo-Slots aus den persistierten cachedBalance-Keys.
- **`creditLimitIncluded` API-Flag** — YAXI/Routex liefert pro Balance einen Flag, ob der Dispokredit bereits im Kontostand enthalten ist (z.B. C24). Wird jetzt automatisch ausgewertet; manuelle Override-Setting bleibt für Banken die den Flag falsch melden. Pure Funktion `BalanceAdjustment.computeAdjustedBalance` mit 8 Unit-Tests.

### Geändert
- **Setup-Copy ehrlicher** — Keine Behauptungen mehr über YAXIs interne Architektur („Tunnel", „YAXI sieht nichts"); stattdessen aus Code beweisbare Aussagen: TLS-verschlüsselte Bank-Abfragen, lokaler Keychain-Speicher, Read-Only-Zugriff. KI-Anbieter werden alle drei genannt (Anthropic / OpenAI / Mistral) statt nur Anthropic.
- **Filter-Pills im Umsatzpanel** — Edge-Fade-Gradient an beiden Seiten signalisiert Scrollbarkeit, ScrollViewReader scrollt den aktiven Pill automatisch in die Mitte. „Alle"-Pill entfällt; Reset via Klick auf aktiven Pill (mit kleinem ✕-Indikator).
- **Flyout-Subtitle kompakt** — Statt „1.234 € bis zum 1. verfügbar" (truncated) jetzt „1.234 € bis 15.05." mit Datum. Unverändert in der breiteren Transaktions-Panel-Anzeige.
- **Menüleiste-Breite umbenannt** — „Lang/Kurz" → „Fest/Dynamisch" mit Erklärtext (es geht um Breiten-Modus, nicht um Textlänge). Disabled wenn Flyout-Click-Mode aktiv ist.
- **Bank-Import Touch-ID-Cache** — Kein modaler Master-Password-Prompt mehr beim Deep-Sync-Import, wenn die App bereits via Touch-ID entsperrt ist (selbe Strategie wie BalanceBar-Startup).
- **Pull-to-Refresh holt Balance + Transactions** — Bisher nur Transactions; jetzt zusätzlich Balance (sequentiell, um HBCI-Dialog-Konflikte bei FinTS-Banken wie Volksbank zu vermeiden). Saldo erscheint früh, Transaktionen ziehen nach.
- **MCP `get_transactions` Composite-ID** — Seit DB-Migration v19 ist (tx_id, slot_id) Composite-PK. MCP-Output hat jetzt `id = "<slot_id>|<tx_id>"` plus separates `tx_id`-Feld. Vorher konnten zwei Buchungen in verschiedenen Slots dieselbe `id` haben — Dedup-Falle für MCP-Clients.

### Behoben
- **365-Tage-Import wird vollständig angezeigt** — `BankSlotSettings.lastImportedDays` trackt die Tiefe des letzten Deep-Sync-Imports; alle DB-Lese-Pfade (Flyout, Panel-Open, CSV-Export, Categorization-Reload, Slot-Switch-Bootstrap) nutzen jetzt `displayDays = max(fetchDays, lastImportedDays)`. Vorher schnitt die Liste nach `fetchDays` (default 60) ab, obwohl 365 Tage in der DB lagen.
- **Multi-Demo Bank-Logo** — Beim ersten Flyout-Open in Multi-Demo erscheint sofort das echte Bank-Logo (Sparkasse, Commerzbank etc.), nicht mehr ein generisches `wallet.pass`-Symbol. Vorher musste man die Banken einmal durchklicken.
- **Flyout-Datum-Format** — Respektiert jetzt die App-Sprache (`AppLanguage.resolved()`) statt nur das System-Locale: bei deutscher App + englischem System steht jetzt korrekt „15.05." statt „05/15".
- **Pull-to-Refresh-Regression** — Vorige Version feuerte `fetchBalances` und `fetchTransactions` parallel via `async let`; das brach FinTS-Banken (Volksbank, Genossenschaftsbanken, manche Sparkassen) mit „Fehlender Dialogkontext"-Fehlern. Jetzt strikt sequentiell.
- **CFBundleVersion-Format** — Plain Build-Sequence-Integer statt vorher Datums-String mit Underscores. Apple-Notary war schon immer lenient, aber strenge Validierer (Amore, MDM-Tools, App Store Connect) lehnten das alte Format ab.
- **Diverse kleinere Fixes** — Filter-Pills-Layout, BalanceBar-Refresh-Hooks, mehrere Demo-Mode-Konsistenz-Bugs.

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
