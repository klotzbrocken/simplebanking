import Foundation

// MARK: - Models

/// Ein Einzelposten einer REWE-eBon-PDF.
struct ReweLineItem: Codable, Equatable {
    var name: String
    /// Optionale Mengen-/Gewichtszeile, z. B. "2 Stk x 1,19" oder
    /// "0,828 kg x 4,49 EUR/kg". `nil` bei Standard-Einzelposten.
    var quantity: String?
    var totalCents: Int
    var taxCategory: String?   // "A" (19 %) / "B" (7 %)
}

/// Roh-Ergebnis des PDF-Text-Parsings (vor Anreicherung mit Listen-Metadaten).
struct ReweParsedReceipt: Equatable {
    var marketHeader: String?
    var totalCents: Int?
    var items: [ReweLineItem]
}

/// Domain-/Persistenz-Modell eines REWE-Einkaufs: Listen-Metadaten plus
/// (nach dem PDF-Parse) die Einzelposten.
struct ReweReceipt: Codable, Equatable, Identifiable {
    var id: String { receiptId }
    var slotId: String
    var receiptId: String
    var timestamp: String      // ISO-8601 (receiptTimestamp aus der Liste)
    var totalCents: Int
    var marketName: String?
    var marketCity: String?
    var cancelled: Bool
    var items: [ReweLineItem]
    var parsed: Bool           // true, sobald die zugehörige PDF geparst wurde
    var fetchedAt: String

    /// Summe der geparsten Einzelposten (Plausibilitäts-Check gegen `totalCents`).
    var itemsSumCents: Int { items.reduce(0) { $0 + $1.totalCents } }
}

// MARK: - Parser

/// Pure, testbare Extraktion der Einzelposten aus dem PDFKit-Rohtext einer
/// REWE-eBon-PDF. Format (pdftotext/PDFKit, In-Markt-Bon):
///   Markt-Header → Zeile "EUR" → Artikel "NAME … 1,59 B" → optional Folgezeile
///   "0,828 kg x 4,49 EUR/kg" oder "2 Stk x 1,19" (gehört zum Artikel davor) →
///   "SUMME EUR 27,90" → Footer (Zahlung/Steuer/TSE/PAYBACK).
/// Pfand-Zeilen tragen ein angehängtes "*": "PFAND 0,25 EURO 0,50 A *".
enum ReweReceiptParser {

    private static let stopwords: [String] = [
        "summe", "mwst", "netto", "brutto", "geg.", "gegeben", "rückgeld",
        "bar", "ec-cash", "girocard", "kartenzahlung", "payback", "punkte",
        "coupon", "rabatt gesamt", "steuer", "ust", "betrag", "datum",
        "uhrzeit", "beleg", "bon-nr", "kasse", "filiale", "vielen dank"
    ]

    static func parse(_ rawText: String) -> ReweParsedReceipt {
        let lines = rawText
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var items: [ReweLineItem] = []
        var total: Int? = nil
        var market: String? = nil

        for l in lines where l.uppercased().hasPrefix("REWE") || l.uppercased().contains("GMBH") {
            market = l
            break
        }

        // "<name>  <12,99>  <A|B>" — optional gefolgt von " *" (Pfand/Kein-Bonus).
        let itemRE = try! NSRegularExpression(
            pattern: #"^(.{2,}?)\s+(-?\d{1,4},\d{2})\s+([AB])\s*\*?\s*$"#)
        // "2 Stk x 0,99" / "0,750 kg x 2,99 EUR/kg"
        let qtyRE = try! NSRegularExpression(
            pattern: #"^(\d+(?:,\d+)?)\s*(stk|kg|g|st)\b.*x.*\d"#, options: [.caseInsensitive])
        // "SUMME ... 27,90"
        let sumRE = try! NSRegularExpression(
            pattern: #"summe.*?(-?\d{1,4},\d{2})"#, options: [.caseInsensitive])

        for line in lines {
            let lower = line.lowercased()

            if let sumStr = firstGroup(sumRE, line, 1), let c = cents(sumStr) {
                total = c
                continue
            }
            if qtyRE.firstMatch(in: line, range: nsRange(line)) != nil, !items.isEmpty {
                items[items.count - 1].quantity = line
                continue
            }
            if stopwords.contains(where: { lower.contains($0) }) { continue }

            if let m = itemRE.firstMatch(in: line, range: nsRange(line)),
               let nameR = Range(m.range(at: 1), in: line),
               let priceR = Range(m.range(at: 2), in: line),
               let taxR = Range(m.range(at: 3), in: line),
               let c = cents(String(line[priceR])) {
                let name = String(line[nameR]).trimmingCharacters(in: .whitespaces)
                if name.count >= 2 {
                    items.append(ReweLineItem(name: name, quantity: nil,
                                              totalCents: c, taxCategory: String(line[taxR])))
                }
            }
        }

        return ReweParsedReceipt(marketHeader: market, totalCents: total, items: items)
    }

    // MARK: - Helpers

    private static func nsRange(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }

    private static func cents(_ s: String) -> Int? {
        let norm = s.replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
        guard let d = Double(norm) else { return nil }
        return Int((d * 100).rounded())
    }

    private static func firstGroup(_ re: NSRegularExpression, _ line: String, _ idx: Int) -> String? {
        guard let m = re.firstMatch(in: line, range: nsRange(line)), m.numberOfRanges > idx,
              let g = Range(m.range(at: idx), in: line) else { return nil }
        return String(line[g])
    }
}
