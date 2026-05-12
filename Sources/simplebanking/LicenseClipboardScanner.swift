import AppKit
import Foundation

// MARK: - LicenseClipboardScanner
//
// Erkennt einen Polar-License-Key in der allgemeinen Pasteboard. Wird vom
// SettingsPanel beim Öffnen + bei Pasteboard-Änderungen abgefragt, damit ein
// "Aus Zwischenablage übernehmen"-Banner gezeigt werden kann.
//
// Pure function — keine Side Effects, kein Logging (Pasteboard-Inhalt kann
// sensitiv sein).

enum LicenseClipboardScanner {

    /// Liefert einen erkannten Key oder nil. Akzeptiert mit oder ohne Prefix
    /// (`SMPLBNKNG-`/anderer Prefix), Format dahinter UUID4-shaped
    /// (8-4-4-4-12 Hex-Zeichen, case-insensitive).
    static func detectKey(in pasteboard: NSPasteboard = .general) -> String? {
        guard let raw = pasteboard.string(forType: .string) else { return nil }
        return extractKey(from: raw)
    }

    /// Pure: holt einen Key aus beliebigem Text. Testbar ohne NSPasteboard.
    static func extractKey(from text: String) -> String? {
        // Nur den ersten/längsten plausiblen Match akzeptieren.
        // Pattern: optionaler ALPHANUM-Prefix + UUID4 (8-4-4-4-12 Hex).
        let pattern = #"\b[A-Z0-9]+-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        if let m = re.firstMatch(in: text, options: [], range: range),
           let r = Range(m.range, in: text) {
            return String(text[r]).uppercased()
        }
        // Fallback: nackte UUID4 (kein Prefix) — auch akzeptieren falls Polar
        // mal ohne Prefix generiert.
        let bareUuid = #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-4[0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}\b"#
        guard let re2 = try? NSRegularExpression(pattern: bareUuid, options: []) else { return nil }
        if let m = re2.firstMatch(in: text, options: [], range: range),
           let r = Range(m.range, in: text) {
            return String(text[r]).uppercased()
        }
        return nil
    }
}
