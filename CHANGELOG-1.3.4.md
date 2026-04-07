# Changelog: simplebanking 1.3.4

*Seit v1.3.2 (Build 287, 2026-03-30)*

---

## Neue Features

### MCP-Server für Claude Desktop
- Eigenständiges Executable (`simplebanking-mcp`) — liest direkt aus der Transaktions-DB
- 5 Read-only Tools: `get_accounts`, `get_transactions`, `get_spending_summary`, `get_monthly_overview`, `get_balance`
- Ein-Klick-Setup: Button in Einstellungen schreibt `claude_desktop_config.json` automatisch (mit Backup)

### SimpleReport — PDF-Monatsbericht
- Automatischer 3+ Seiten PDF-Report: Cashflow, Kategorien, Insights, Transaktionsliste
- Custom Fonts (SpaceMono), Rainbow-Stripe Design-Element
- Narrative Zusammenfassung, Highlight-Transaktionen, Recurring-Detection

### GreenZoneRing — "Bin ich im grünen Bereich?"
- Visueller Balance-Ring (72×72 Arc) im Flyout mit Farbverlauf rot→gelb→grün
- Fraction = Kontostand / Gehaltsreferenz (0…1)
- Dispo-Modus: Bei negativem Saldo roter Ring (Saldo/Dispolimit)
- Automatische Gehaltserkennung via SEPA SALA / GEHALT Keywords

### Unified Inbox / Multibanking
- "Alle Konten"-Ansicht mit aggregiertem Gesamtsaldo in Menüleiste
- Per-Slot Balance-Strip mit individuellen Farben
- Per-Konto `lastSeenTxSig` für Neubuchungs-Indikator (●)
- Dot-Piles zum Kontowechsel im Flyout

### Per-Konto-Einstellungen (BankSlotSettings)
- Individuelle Einstellungen pro Konto: Gehalt, Dispolimit, Puffer, Sparrate, Fetch-Tage
- Gehaltstag-Preset: Monatsanfang / Mitte / Individuell
- Automatische Comfort-Zone-Berechnung

### Globaler Hotkey
- Systemweiter Tastatur-Shortcut zum Anzeigen/Verstecken des Kontostands
- Konfigurierbar in Einstellungen (Allgemein-Tab)

### Einstellungen — 5 Tabs
1. **Allgemein**: Refresh, Menubar-Style, Demo, Themes, Launch at Login, Hotkey
2. **Konten** (neu): Per-Slot Gehalts-Settings, Comfort-Zone, Dispo
3. **Analyse**: Merchant Pipeline, Brandfetch, BalanceSignal, Puffer, Sparrate
4. **Claude/MCP** (neu): Auto-Setup für Claude Desktop
5. **Sicherheit**: TouchID, Passwort

### Fixkosten-Analyse & Abonnement-Erkennung
- Automatisches Clustering nach Merchant/IBAN
- Erkennung von monatlichen, vierteljährlichen und jährlichen Zahlungen
- Confidence-Score, User-Exclusion-List
- Toolbar-Buttons: Fixkosten, Financial Health Score, Abonnements

### Erweiterte Transaktionsansicht
- Neue Filter: Abos, Fixkosten, Unkategorisiert, Ausstehend
- Kalender-Heatmap mit Auto-Navigation und Day-Detail-Sheet
- Transaktionsdetail: Custom Logo, bearbeitbare Notizen, Anhänge
- Demo-Mode generiert realistische Fake-Transaktionen

### Merchant-Logos — erweitert
- Pipeline: Bundled SVG → Brandfetch → DuckDuckGo
- ~90 vorinstallierte Händler-SVGs (Top 100 DE Retail)
- Persistenter Logo-Cache (DB-backed)

### Themes — erweitert
- Per-Theme Farb-Overrides (positive/negative, Light/Dark)
- GameBoy-Theme überarbeitet

---

## Verbesserungen

### Auto-Hide Timer
- **Fix**: Timer wurde bei jedem Balance-Refresh zurückgesetzt — Saldo verschwand gefühlt zu früh
- **Fix**: `@AppStorage` in Nicht-SwiftUI-Klasse lieferte nach Neustart den Default statt den gespeicherten Wert → auf `UserDefaults.standard` umgestellt
- **Neu**: Option "Nach 20 Sekunden" hinzugefügt
- **Neu**: Flyout bleibt offen solange die Maus darüber ist

### Flyout
- Next-Bank-Icon bei Hover entfernt (redundant mit Dot-Piles)
- Kontowechsel erfolgt jetzt ausschließlich über die Dot-Indicators

### BiometricStore
- Auto-Unlock beim Start ohne Passwort-Prompt via Keychain

### Merchant-Resolver
- Erweiterte Alias-Map (~40 neue: Douglas, Microsoft, Garmin, Thomann…)
- PayPal-Extraktion, Cash-Pattern-Erkennung

---

## Bugfixes

- **P0**: Force-Unwrap `balance!` in GreenZoneRing → Safe Unwrap
- **P2**: NotificationCenter Observer-Leak (addAccount, globalHotkey) → Cleanup in `applicationWillTerminate`
- **P2**: Race Condition bei `activeSlotId` (YaxiService, CredentialsStore, TransactionsDatabase) → NSLock-basierte Thread-Safety
- **P2**: MCP-Server `SQLITE_OPEN_NOMUTEX` entfernt → sicherer Default-Mutex
- **Build**: Sparkle.framework-Embedding schlug still fehl (`grep -v` + `set -euo pipefail`) → `{ grep -v ... || true; }`

---

## Datenbank-Migrationen

- **v8**: `status`-Spalte (booked/pending) + Index
- **v9**: Dedup-Fingerprint-Cleanup
- **v10**: Vollständiger Fingerprint-Reset
- **v11**: Merchant-Alias-Backfill
- **v12**: `merchant_logos`-Tabelle (BLOB, key-indexed)
- **v13**: `transaction_logos`-Tabelle (per Transaktion)

---

## Tests

- UnifiedInboxTests: 4 Unit-Tests (empty slots, same/mixed currency, 3-currency cap)
