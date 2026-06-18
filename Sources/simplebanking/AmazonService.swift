import Foundation

// MARK: - Result

struct AmazonSyncResult: Equatable {
    var scraped: Int    // im DOM gefundene Bestellungen
    var stored: Int     // persistierte Bestellungen
}

// MARK: - Wire-Modell (vom JS-Scraper gelieferte Roh-Bestellung)

struct AmazonScrapedOrder: Codable, Equatable {
    var id: String
    var dateText: String     // "12. Mai 2026" oder "12.05.2026"
    var totalText: String    // "47,99 €" / "EUR 47,99"
    var items: [String]      // Produkttitel
}

// MARK: - Parser (pure, testbar)

/// Wandelt die vom WebView-DOM gescrapten Roh-Bestellungen in `ReweReceipt`s
/// (dieselbe Tabelle/Modelle wie REWE/dm). Amazon zeigt pro Position keinen
/// verlässlichen Einzelpreis — daher Posten mit Preis 0 (Ring gewichtet dann
/// nach Stückzahl), die Bestell-Summe bleibt maßgeblich.
enum AmazonOrderParser {
    static func parse(_ orders: [AmazonScrapedOrder], slotId: String, fetchedAt: String) -> [ReweReceipt] {
        var seen = Set<String>()
        var out: [ReweReceipt] = []
        for (idx, o) in orders.enumerated() {
            guard let cents = parseAmountCents(o.totalText) else { continue }
            let day = parseDate(o.dateText)                       // "yyyy-MM-dd" oder nil
            let ts = (day ?? "0000-00-00") + "T00:00:00Z"
            let rid = !o.id.isEmpty ? o.id : "\(day ?? "x")-\(cents)-\(idx)"
            guard !seen.contains(rid) else { continue }
            seen.insert(rid)
            let items = o.items
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
                .map { ReweLineItem(name: String($0.prefix(140)), quantity: nil, totalCents: 0, taxCategory: nil) }
            out.append(ReweReceipt(
                slotId: slotId, receiptId: rid, timestamp: ts, totalCents: cents,
                marketName: "Amazon", marketCity: nil, cancelled: false,
                items: items, parsed: !items.isEmpty, fetchedAt: fetchedAt))
        }
        return out
    }

    /// JSON-String des Scrapers → Modelle.
    static func decode(_ json: String) -> [AmazonScrapedOrder] {
        guard let data = json.data(using: .utf8),
              let orders = try? JSONDecoder().decode([AmazonScrapedOrder].self, from: data) else { return [] }
        return orders
    }

    /// "47,99 €" / "EUR 1.234,56" / "1\u{00a0}234,56 €" → Cent.
    static func parseAmountCents(_ s: String) -> Int? {
        // Letztes Vorkommen von d,dd nehmen (robust gegen "EUR"-Präfix).
        guard let re = try? NSRegularExpression(pattern: #"(\d{1,3}(?:[.  ]\d{3})*,\d{2})"#) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.matches(in: s, range: range).last,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        let digits = String(s[r]).replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let d = Double(digits) else { return nil }
        return Int((d * 100).rounded())
    }

    /// "12. Mai 2026" oder "12.05.2026" → "yyyy-MM-dd".
    static func parseDate(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = DateFormatter(); out.locale = Locale(identifier: "en_US_POSIX"); out.dateFormat = "yyyy-MM-dd"
        for fmt in ["d. MMMM yyyy", "d.MM.yyyy", "dd.MM.yyyy", "d MMMM yyyy"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = fmt
            if let date = f.date(from: trimmed) { return out.string(from: date) }
        }
        return nil
    }
}

// MARK: - Persist

@MainActor
enum AmazonService {
    static func persist(_ orders: [AmazonScrapedOrder], slotId: String, bankId: String = "primary") throws -> AmazonSyncResult {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let receipts = AmazonOrderParser.parse(orders, slotId: slotId, fetchedAt: stamp)
        try ReweReceiptStore.upsert(receipts, bankId: bankId)
        return AmazonSyncResult(scraped: orders.count, stored: receipts.count)
    }
}
