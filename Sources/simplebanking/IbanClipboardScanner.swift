import AppKit
import Foundation

// MARK: - IbanClipboardScanner
//
// Erkennt eine IBAN in der allgemeinen Pasteboard. Wird vom TransferSheet
// beim Öffnen abgefragt, damit ein „IBAN aus Zwischenablage übernehmen"-
// Banner gezeigt werden kann (analog zum LicenseClipboardScanner-Banner
// in den Settings).
//
// Pure function — kein Logging (Pasteboard-Inhalt kann sensitiv sein).

enum IbanClipboardScanner {

    /// Liefert eine erkannte und syntaktisch valide IBAN (normalisiert,
    /// ohne Leerzeichen) oder nil. Validierung gegen `TransferRequest.validateIban`.
    static func detectIban(in pasteboard: NSPasteboard = .general) -> String? {
        guard let raw = pasteboard.string(forType: .string) else { return nil }
        return extractIban(from: raw)
    }

    /// Pure: extrahiert eine IBAN aus beliebigem Text. Testbar ohne Pasteboard.
    static func extractIban(from text: String) -> String? {
        // Pattern: 2 Country-Letters + 2 Digits + 1–7 Vierergruppen + 1–4 Trailing-Chars.
        // 4er-Gruppen sind optional getrennt durch Whitespace (Mensch-formatiert)
        // oder zusammenhängend (Maschine-formatiert).
        let pattern = #"\b[A-Z]{2}\d{2}(?:\s*[A-Z0-9]{4}){2,7}\s*[A-Z0-9]{1,4}\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: nsRange),
              let r = Range(m.range, in: text)
        else { return nil }

        let normalized = String(text[r])
            .uppercased()
            .replacingOccurrences(of: " ", with: "")

        // Mod-97 + Country-Length-Check über die existierende Validierung.
        if (try? TransferRequest.validateIban(normalized)) != nil {
            return normalized
        }
        return nil
    }
}
