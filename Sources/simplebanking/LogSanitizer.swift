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
//   - Key=Value: "userid=...", "session=...", "password=..." → "<redacted-secret>"
//   - Lange base64/hex-Tokens (≥24 chars) → "<redacted-token>"
//
// Was NICHT redacted wird:
//   - Beträge (€) — oft legitime Status-Info
//   - Kurze IDs / Counts
//   - Allgemeine error-Beschreibungen ohne credential-Pattern

enum LogSanitizer {

    /// Pure function — testbar, keine Side Effects.
    static func redact(_ input: String) -> String {
        var output = input
        for (pattern, replacement) in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression]
            )
        }
        return output
    }

    /// Reihenfolge ist relevant — IBAN-Pattern muss VOR dem generischen
    /// langen-token-Pattern laufen, sonst würden IBANs als generic token
    /// redacted (gleicher Effekt, aber weniger sprechender Replacement-Text).
    private static let patterns: [(String, String)] = [
        // IBAN: 2 Buchstaben + 13-30 alphanumerische Zeichen.
        // Konservativ: matches DE89..., AT12..., FR12..., etc.
        (#"(?i)\b[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}\b"#, "<redacted-iban>"),

        // Key=Value-Pattern für offensichtliche Credentials. Matched z.B.:
        //   "userid=12345", "password: secret", "session=abc...", "account=hans@..."
        (#"(?i)(user(id)?|leg\.?-?id|login|anmeldename|pin|password|passwort|session|connectiondata|access[_-]?token|api[_-]?key|account|kunde|email|mail)\s*[:=]\s*[^\s,;]+"#,
         "<redacted-secret>"),

        // Lange opaque Tokens (≥24 chars Base64/Hex) — typisch JWT, AGE-encrypted,
        // OAuth-Codes, Hash-Fingerprints. Fängt false positives in Ordnung
        // (Datei-Pfade, lange Wörter), aber hier gilt safety-first.
        (#"\b[A-Za-z0-9_\-+/=]{24,}\b"#, "<redacted-token>"),
    ]
}
