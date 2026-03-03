# Changelog — simplebanking

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
