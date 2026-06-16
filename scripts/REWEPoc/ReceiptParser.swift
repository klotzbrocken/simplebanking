import Foundation

/// Geparster REWE-Bon (PoC-Modell — wandert bei Phase 1 ggf. ins App-Target).
struct ParsedReceipt {
    var market: String?
    var totalCents: Int?
    var items: [LineItem]
}

struct LineItem {
    var name: String
    var quantity: String?     // z. B. "2 Stk x 0,99" oder "0,750 kg x 2,99 EUR/kg"
    var totalCents: Int
    var taxCategory: String?  // "A" / "B"
}

/// Pure, testbare Extraktion der Einzelposten aus dem PDFKit-Rohtext einer
/// REWE-eBon-PDF. ERSTE VERSION — die exakten Layout-Regeln werden anhand der
/// echten Roh-Texte aus dem PoC kalibriert (siehe Roh-Text-Dump im PoC-Fenster).
///
/// Beobachtetes REWE-Format (grob):
///   ...
///   EUR
///   Produktname                 1,99 A
///   2 Stk x          0,99
///   GEMÜSE                       0,89 B
///   0,750 kg x 2,99 EUR/kg       2,24 B
///   ----------------------------------
///   SUMME                  EUR  27,90
///   ...
enum ReceiptParser {

    /// Zeilen, die nie ein Artikel sind (Footer/Steuer/Zahlung).
    private static let stopwords: [String] = [
        "summe", "mwst", "netto", "brutto", "geg.", "gegeben", "rückgeld",
        "bar", "ec-cash", "girocard", "kartenzahlung", "payback", "punkte",
        "coupon", "rabatt gesamt", "steuer", "ust", "betrag", "datum",
        "uhrzeit", "beleg", "bon-nr", "kasse", "filiale", "vielen dank"
    ]

    static func parse(_ rawText: String) -> ParsedReceipt {
        let lines = rawText
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var items: [LineItem] = []
        var total: Int? = nil
        var market: String? = nil

        // Markt: erste Zeile, die mit "REWE" beginnt
        for l in lines where l.uppercased().hasPrefix("REWE") {
            market = l
            break
        }

        // Preis-mit-Steuerbuchstabe:  "<name>  <12,99>  <A|B>"  — optional gefolgt
        // von einem " *" (Pfand/Kein-Bonus-Marker), z. B. "PFAND 0,25 EURO 0,50 A *".
        let itemRE = try! NSRegularExpression(
            pattern: #"^(.{2,}?)\s+(-?\d{1,4},\d{2})\s+([AB])\s*\*?\s*$"#)
        // Mengen-/Gewichtszeile:  "2 Stk x 0,99"  /  "0,750 kg x 2,99 EUR/kg"
        let qtyRE = try! NSRegularExpression(
            pattern: #"^(\d+(?:,\d+)?)\s*(stk|kg|g|st)\b.*x.*\d"#,
            options: [.caseInsensitive])
        // Summe:  "SUMME ... 27,90"
        let sumRE = try! NSRegularExpression(
            pattern: #"summe.*?(-?\d{1,4},\d{2})"#, options: [.caseInsensitive])

        func cents(_ s: String) -> Int? {
            let norm = s.replacingOccurrences(of: ".", with: "")
                        .replacingOccurrences(of: ",", with: ".")
            guard let d = Double(norm) else { return nil }
            return Int((d * 100).rounded())
        }
        func firstGroup(_ re: NSRegularExpression, _ line: String, _ idx: Int) -> String? {
            let r = NSRange(line.startIndex..., in: line)
            guard let m = re.firstMatch(in: line, range: r), m.numberOfRanges > idx,
                  let g = Range(m.range(at: idx), in: line) else { return nil }
            return String(line[g])
        }

        for line in lines {
            let lower = line.lowercased()

            if let sumStr = firstGroup(sumRE, line, 1), let c = cents(sumStr) {
                total = c
                continue
            }
            // Mengenzeile → an vorherigen Artikel anhängen
            if qtyRE.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil,
               !items.isEmpty {
                items[items.count - 1].quantity = line
                continue
            }
            if stopwords.contains(where: { lower.contains($0) }) { continue }

            let r = NSRange(line.startIndex..., in: line)
            if let m = itemRE.firstMatch(in: line, range: r),
               let nameR = Range(m.range(at: 1), in: line),
               let priceR = Range(m.range(at: 2), in: line),
               let taxR = Range(m.range(at: 3), in: line),
               let c = cents(String(line[priceR])) {
                let name = String(line[nameR]).trimmingCharacters(in: .whitespaces)
                if name.count >= 2 {
                    items.append(LineItem(name: name, quantity: nil,
                                          totalCents: c, taxCategory: String(line[taxR])))
                }
            }
        }

        return ParsedReceipt(market: market, totalCents: total, items: items)
    }
}
