import Foundation
import GRDB

/// Persistenz für REWE-eBons (Tabelle `rewe_receipts`, Migration v24).
/// Mirror-Pattern zu `RoundupStore`: statische Funktionen über die geteilte
/// `TransactionsDatabase`-Queue, `bankId`-parametrisiert für Tests.
enum ReweReceiptStore {

    /// Idempotenter Upsert auf `(slot_id, receipt_id)`. Bewahrt bereits geparste
    /// Einzelposten: ein reiner Listen-Sync (parsed=false) überschreibt NICHT
    /// die `items_json` eines schon geparsten Bons.
    static func upsert(_ receipts: [ReweReceipt], bankId: String = "primary") throws {
        guard !receipts.isEmpty else { return }
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        try queue.write { db in
            for r in receipts {
                let itemsJson: String? = r.items.isEmpty
                    ? nil
                    : (try? JSONEncoder().encode(r.items)).flatMap { String(data: $0, encoding: .utf8) }
                try db.execute(sql: """
                    INSERT INTO rewe_receipts
                        (slot_id, receipt_id, timestamp, total_cents, market_name,
                         market_city, cancelled, items_json, parsed, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(slot_id, receipt_id) DO UPDATE SET
                        timestamp   = excluded.timestamp,
                        total_cents = excluded.total_cents,
                        market_name = excluded.market_name,
                        market_city = excluded.market_city,
                        cancelled   = excluded.cancelled,
                        items_json  = CASE WHEN excluded.parsed = 1 THEN excluded.items_json ELSE rewe_receipts.items_json END,
                        parsed      = CASE WHEN excluded.parsed = 1 THEN 1 ELSE rewe_receipts.parsed END
                    """, arguments: [
                        r.slotId, r.receiptId, r.timestamp, r.totalCents, r.marketName,
                        r.marketCity, r.cancelled ? 1 : 0, itemsJson, r.parsed ? 1 : 0, r.fetchedAt,
                    ])
            }
        }
    }

    static func all(slotId: String, bankId: String = "primary") throws -> [ReweReceipt] {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM rewe_receipts WHERE slot_id = ? ORDER BY timestamp DESC
                """, arguments: [slotId]).map(rowToReceipt)
        }
    }

    static func latest(slotId: String, bankId: String = "primary") throws -> ReweReceipt? {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        return try queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM rewe_receipts WHERE slot_id = ? ORDER BY timestamp DESC LIMIT 1
                """, arguments: [slotId]).map(rowToReceipt)
        }
    }

    /// receiptIds, die bereits geparst sind — für den Sync-Dedup (welche PDFs
    /// müssen noch aus der ZIP extrahiert/geparst werden).
    static func parsedIds(slotId: String, bankId: String = "primary") throws -> Set<String> {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        return try queue.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT receipt_id FROM rewe_receipts WHERE slot_id = ? AND parsed = 1
                """, arguments: [slotId]))
        }
    }

    /// Ausgaben-Summe eines Monats ("yyyy-MM"), cancelled-Bons ausgenommen.
    static func monthTotalCents(slotId: String, yearMonth: String, bankId: String = "primary") throws -> Int {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        return try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(total_cents), 0) FROM rewe_receipts
                WHERE slot_id = ? AND cancelled = 0 AND substr(timestamp, 1, 7) = ?
                """, arguments: [slotId, yearMonth]) ?? 0
        }
    }

    static func deleteAll(slotId: String, bankId: String = "primary") throws {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM rewe_receipts WHERE slot_id = ?", arguments: [slotId])
        }
    }

    // MARK: - Mapping

    private static func rowToReceipt(_ row: Row) -> ReweReceipt {
        let itemsJson: String? = row["items_json"]
        let items: [ReweLineItem] = itemsJson
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([ReweLineItem].self, from: $0) } ?? []
        let cancelled: Int = row["cancelled"]
        let parsed: Int = row["parsed"]
        let total: Int = row["total_cents"]
        return ReweReceipt(
            slotId: row["slot_id"], receiptId: row["receipt_id"], timestamp: row["timestamp"],
            totalCents: total, marketName: row["market_name"], marketCity: row["market_city"],
            cancelled: cancelled != 0, items: items, parsed: parsed != 0, fetchedAt: row["fetched_at"])
    }
}
