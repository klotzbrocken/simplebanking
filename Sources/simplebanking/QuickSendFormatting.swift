import Foundation

// MARK: - QuickSendFormatting
//
// Pure Formatierungs-/Parsing-Helfer für den Quick-Send-Drawer. Bewusst als
// free-standing static functions, damit sie ohne UI direkt testbar sind
// (siehe `QuickSendFormattingTests`). IBAN-Validierung delegiert an das
// bestehende `TransferRequest` (mod-97), damit es genau eine Quelle der
// Wahrheit gibt.

enum QuickSendFormatting {

    /// Obergrenze für Quick-Send-Beträge. Größere Eingaben werden NICHT gekürzt
    /// (das würde den Wert still verfälschen), sondern vom Drawer als „zu groß"
    /// invalidiert (Senden gesperrt).
    static let maxAmount: Decimal = 99999.99

    /// Normalisiert die Betrag-Eingabe locale-sicher und gibt sie im
    /// DE-Anzeigeformat (Komma als Dezimaltrenner) zurück.
    ///
    /// Regeln:
    ///  - Akzeptiert **Punkt UND Komma** als Trenner (DE „12,50" wie EN „12.50").
    ///  - Sind **beide** Trennertypen vorhanden, gilt der **letzte** als
    ///    Dezimaltrenner, frühere sind Gruppierung („1.234,56" / „1,234.56" → „1234,56").
    ///  - Bei **einem** Trennertyp entscheidet das Muster: ein **valides Tausender-
    ///    Muster** (jede Gruppe nach der ersten exakt 3 Ziffern) ist reine Gruppierung
    ///    („1.000"/„1,000" → 1000; „1.000.000" → 1000000). Sonst ist der **letzte**
    ///    Trenner der Dezimaltrenner („12,50"/„12.50" → 12,50; „1,5" → 1,5; „1,2,3" → 12,3).
    ///    Das behebt den „1.000" → 1,00 €-Fehler, ohne die gewollte EN-Dezimaleingabe
    ///    zu brechen. Der Confirm-Schritt zeigt den Betrag zusätzlich explizit.
    ///  - max. 2 Nachkommastellen. Vorkommastellen werden NICHT mehr gekürzt — zu
    ///    große Beträge invalidiert der Drawer via `maxAmount` (kein stilles Kürzen).
    static func sanitizeAmountInput(_ raw: String) -> String {
        let chars = Array(raw.filter { $0.isNumber || $0 == "," || $0 == "." })
        let sepIndices = chars.indices.filter { chars[$0] == "," || chars[$0] == "." }

        var intDigits: String
        var fracDigits: String?

        if sepIndices.isEmpty {
            intDigits = String(chars.filter { $0.isNumber })
            fracDigits = nil
        } else {
            let lastSep = sepIndices.last!
            let bothTypes = chars.contains(",") && chars.contains(".")

            // Zifferngruppen zwischen den Trennern. Valides Tausender-Muster:
            // ≥2 Gruppen, erste 1–3 Ziffern, alle weiteren exakt 3 („1.000",
            // „1.000.000"). „1,2,3" oder „12.50" passen NICHT → letzter Trenner = Dezimal.
            let segments = String(chars).split(omittingEmptySubsequences: false,
                                               whereSeparator: { $0 == "," || $0 == "." })
            let looksGrouped = segments.count >= 2
                && (1...3).contains(segments.first!.count)
                && segments.dropFirst().allSatisfy { $0.count == 3 }

            // Dezimaltrenner, wenn beide Trennertypen vorkommen (letzter = Dezimal)
            // ODER das Muster KEINE reine Tausender-Gruppierung ist.
            let isDecimal = bothTypes || !looksGrouped

            if isDecimal {
                intDigits = String(chars[..<lastSep].filter { $0.isNumber })
                fracDigits = String(chars[(lastSep + 1)...].filter { $0.isNumber })
            } else {
                intDigits = String(chars.filter { $0.isNumber })
                fracDigits = nil
            }
        }

        if let frac = fracDigits {
            return intDigits + "," + String(frac.prefix(2))
        }
        return intDigits
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

    /// Gekürzte IBAN für die Bestätigungszeile: „DE12 … 3456" (erste 4 + letzte 4).
    static func maskedIban(_ raw: String) -> String {
        let clean = TransferRequest.normalizeIban(raw)
        guard clean.count > 8 else { return groupIban(clean) }
        return "\(clean.prefix(4)) … \(clean.suffix(4))"
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
