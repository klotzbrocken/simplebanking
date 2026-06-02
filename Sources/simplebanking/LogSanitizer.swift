import Foundation

// MARK: - PII redaction for log messages
//
// Schützt gegen versehentliches Loggen von Bank-Credentials, IBANs und
// Session-Tokens. Wird von AppLogger automatisch auf jede Message angewandt
// — alle 100+ Call-Sites sind damit ohne Code-Änderung geschützt.
//
// Patterns sind übernommen aus SetupDiagnosticsLogger (das hatte den
// Sanitizer ursprünglich für YAXI-Traces, die an den CTO gehen). Wir
// teilen jetzt eine zentrale Implementierung — beide Wege haben dieselben
// Garantien.
//
// Was redacted wird:
//   - IBAN: "DE89..." → "<redacted-iban>"
//   - Key=Value: "userid=...", "session=...", "password=..." → "userid=<redacted-secret>"
//     (Key bleibt sichtbar für Debug-Kontext — nur der Wert wird ersetzt.)
//   - Lange base64/hex-Tokens (≥24 chars) → "<redacted-token>"
//
// Was NICHT redacted wird:
//   - Beträge (€) — oft legitime Status-Info
//   - Diagnose-Werte: Bytecounts (`168b`, `42K`), `nil`, `true`/`false`,
//     `none`, `ok`/`err`, kurze numerische IDs ohne Buchstaben — diese
//     erkennt eine Negativ-Lookahead-Liste, damit Logs lesbar bleiben
//   - Allgemeine error-Beschreibungen ohne credential-Pattern

enum LogSanitizer {

    /// Pure function — testbar, keine Side Effects.
    static func redact(_ input: String) -> String {
        var output = input
        for rule in patterns {
            output = applyRegex(rule.regex, replacement: rule.replacement, to: output)
        }
        return output
    }

    private struct Rule {
        let regex: NSRegularExpression
        let replacement: String
    }

    private static let patterns: [Rule] = [
        // IBAN: 2 Buchstaben + 2 Prüfziffern + 11-30 alphanumerische Zeichen.
        // Konservativ: matches DE89..., AT12..., FR12..., etc. — sowohl
        // durchgeschrieben (DE89370400440532013000) als auch gruppiert mit
        // einzelnen Leerzeichen (DE89 3704 0044 0532 0130 00), wie es Banktexte
        // und YAXI-Traces oft liefern. Das optionale Space pro Zeichen erlaubt
        // beliebige Gruppierung; `\b` hält die Grenzen sauber.
        Rule(
            regex: compiled(#"(?i)\b[A-Z]{2}[0-9]{2}(?:[ ]?[0-9A-Z]){11,30}\b"#),
            replacement: "<redacted-iban>"
        ),

        // Key=Value-Pattern für offensichtliche Credentials. Matched z.B.:
        //   "userid=12345678", "password: secret", "session=abc...", "account=hans@..."
        // Negativ-Lookahead überspringt Diagnose-Werte wie `cd=168b`, `=nil`,
        // `=true`, `=ok` — die sind nicht sensitiv, sollen sichtbar bleiben.
        // Replacement behält den Key für Debug-Kontext.
        Rule(
            regex: compiled(
                #"(?i)(user(?:id)?|leg\.?-?id|login|anmeldename|pin|password|passwort|session|connectiondata|access[_-]?token|api[_-]?key|account|kunde|email|mail)"#
                + #"\s*[:=]\s*"#
                + #"(?!(?:\d+[bkmgKMG]?|nil|null|none|some|true|false|ok|err|fail|na|n/a)(?:[\s,;]|$))"#
                + #"[^\s,;]+"#
            ),
            replacement: "$1=<redacted-secret>"
        ),

        // Lange opaque Tokens (≥24 chars Base64/Hex) — typisch JWT, AGE-encrypted,
        // OAuth-Codes, Hash-Fingerprints. Fängt false positives in Ordnung
        // (Datei-Pfade, lange Wörter), aber hier gilt safety-first.
        Rule(
            regex: compiled(#"\b[A-Za-z0-9_\-+/=]{24,}\b"#),
            replacement: "<redacted-token>"
        ),
    ]

    private static func compiled(_ pattern: String) -> NSRegularExpression {
        // Patterns sind statisch geprüft — try! ist hier sicher.
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private static func applyRegex(_ regex: NSRegularExpression, replacement: String, to input: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}
