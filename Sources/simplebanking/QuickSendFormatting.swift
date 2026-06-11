import Foundation

// MARK: - QuickSendFormatting
//
// Pure Formatierungs-/Parsing-Helfer für den Quick-Send-Drawer. Bewusst als
// free-standing static functions, damit sie ohne UI direkt testbar sind
// (siehe `QuickSendFormattingTests`). IBAN-Validierung delegiert an das
// bestehende `TransferRequest` (mod-97), damit es genau eine Quelle der
// Wahrheit gibt.

enum QuickSendFormatting {

    /// Normalisiert die Betrag-Eingabe: nur Ziffern + ein einzelnes Komma,
    /// max. 5 Vorkomma- und 2 Nachkommastellen (≤ 99999,99).
    static func sanitizeAmountInput(_ raw: String) -> String {
        // Nur Ziffern und Kommas behalten.
        var cleaned = raw.filter { $0.isNumber || $0 == "," }

        // Mehrfach-Kommas auf das erste reduzieren.
        let parts = cleaned.split(separator: ",", omittingEmptySubsequences: false)
        if parts.count > 2 {
            cleaned = String(parts[0]) + "," + parts[1...].joined()
        }

        // In Vor-/Nachkomma zerlegen.
        var intPart: String
        var fracPart: String?
        if let commaIdx = cleaned.firstIndex(of: ",") {
            intPart = String(cleaned[cleaned.startIndex..<commaIdx])
            fracPart = String(cleaned[cleaned.index(after: commaIdx)...])
        } else {
            intPart = cleaned
            fracPart = nil
        }

        if intPart.count > 5 { intPart = String(intPart.prefix(5)) }

        if let frac = fracPart {
            return intPart + "," + String(frac.prefix(2))
        }
        return intPart
    }

    /// Wandelt die bereinigte Betrag-Eingabe in einen `Decimal`. Gibt `nil`
    /// zurück bei leerer Eingabe oder Betrag ≤ 0.
    static func amountDecimal(_ input: String) -> Decimal? {
        let normalized = input.replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, normalized != "." else { return nil }
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              value > 0 else { return nil }
        return value
    }

    /// Gruppiert eine IBAN in 4er-Blöcke für die Anzeige (uppercase, ohne
    /// vorhandene Leerzeichen, neu gruppiert).
    static func groupIban(_ raw: String) -> String {
        let clean = TransferRequest.normalizeIban(raw)
        var out = ""
        for (i, ch) in clean.enumerated() {
            if i > 0 && i % 4 == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    /// `true` wenn die (ggf. gruppierte) Eingabe eine gültige IBAN ist.
    static func isValidIban(_ raw: String) -> Bool {
        let clean = TransferRequest.normalizeIban(raw)
        return (try? TransferRequest.validateIban(clean)) != nil
    }

    /// "850,00 €" für die Erfolgs-Bestätigung im Drawer.
    static func displayEUR(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.locale = Locale(identifier: "de_DE")
        let s = f.string(from: amount as NSDecimalNumber) ?? "\(amount)"
        return s + " €"
    }
}
