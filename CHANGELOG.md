# Changelog — simplebanking

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
