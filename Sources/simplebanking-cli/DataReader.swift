import Foundation
import GRDB

/// Leichtgewichtige Minimal-Repräsentation eines Slots — duplicated (nicht importiert),
/// damit das CLI keine Abhängigkeit zum Menüleisten-App-Target braucht.
struct Slot {
    let id: String
    let iban: String
    let displayName: String
    let nickname: String?
    let currency: String?
}

/// Eine Transaktion wie sie der CLI anzeigt. Direkt aus der SQLite-Tabelle gelesen.
struct TxRow {
    let txID: String
    let bookingDate: String       // YYYY-MM-DD
    let amount: Double
    let currency: String
    let empfaenger: String?
    let absender: String?
    let purpose: String?
    let category: String?
    let slotId: String
    let status: String
    let effectiveMerchant: String
}

enum DataReader {

    // MARK: - Paths

    private static let bundleIdentifier = "tech.yaxi.simplebanking"

    /// Da das CLI-Binary im App-Bundle liegt, ist `Bundle.main.bundleIdentifier`
    /// identisch mit dem der App → `UserDefaults(suiteName:)` würde macOS als
    /// „nonsensical own suite" ablehnen. Also lesen wir das Preferences-Plist
    /// direkt über `CFPreferences`, das ignoriert die Suite-Prüfung.
    static func prefString(_ key: String) -> String? {
        CFPreferencesCopyAppValue(key as CFString, bundleIdentifier as CFString) as? String
    }

    static func prefData(_ key: String) -> Data? {
        CFPreferencesCopyAppValue(key as CFString, bundleIdentifier as CFString) as? Data
    }

    static func prefDouble(_ key: String) -> Double? {
        if let n = CFPreferencesCopyAppValue(key as CFString, bundleIdentifier as CFString) as? Double {
            return n
        }
        if let n = CFPreferencesCopyAppValue(key as CFString, bundleIdentifier as CFString) as? NSNumber {
            return n.doubleValue
        }
        return nil
    }

    static func transactionsDBPath() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: false)
        return dir.appendingPathComponent("simplebanking/transactions.db")
    }

    // MARK: - Slots

    /// Liest die persistierte Slot-Liste aus den App-Defaults und dekodiert sie.
    static func loadSlots() -> [Slot] {
        guard let data = prefData("simplebanking.multibanking.slots") else {
            return legacyFallbackSlots()
        }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return legacyFallbackSlots()
        }
        return arr.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let iban = dict["iban"] as? String,
                  let displayName = dict["displayName"] as? String else { return nil }
            return Slot(
                id: id,
                iban: iban,
                displayName: displayName,
                nickname: dict["nickname"] as? String,
                currency: dict["currency"] as? String
            )
        }
    }

    /// Legacy-Fallback: frische App-Installationen ohne Multibanking-JSON.
    private static func legacyFallbackSlots() -> [Slot] {
        guard let iban = prefString("simplebanking.iban") else { return [] }
        let name = prefString("connectedBankDisplayName") ?? ""
        return [Slot(id: "legacy", iban: iban, displayName: name, nickname: nil, currency: "EUR")]
    }

    // MARK: - Balances

    static func cachedBalance(slotId: String) -> Double? {
        prefDouble("simplebanking.cachedBalance.\(slotId)")
    }

    // MARK: - Refresh marker

    /// Refresh-Completion-Marker für den IPC-Poller: wir kombinieren zwei Signale,
    /// damit wir jedes Refresh-Event zuverlässig sehen — auch wenn die Bank keine
    /// neuen Daten lieferte.
    ///
    /// 1. `UserDefaults` → `simplebanking.cli.lastRefreshCompletedAt`: wird von der
    ///    App nach **jedem** CLI-getriggerten Refresh gesetzt. Bumpt immer, selbst
    ///    wenn nichts Neues ankam.
    /// 2. `MAX(updated_at)` aus `transactions.db`: feiner — zeigt das letzte Daten-
    ///    Update (Upsert, Enrichment). Kann stagnieren wenn keine neuen Buchungen.
    ///
    /// Concat als „|"-Tuple, damit das Polling auf jeden der beiden Änderungen triggert.
    static func lastRefreshTimestamp() -> String? {
        let cliMarker = prefString("simplebanking.cli.lastRefreshCompletedAt") ?? ""
        var dbMax = ""
        if let dbURL = try? transactionsDBPath(),
           FileManager.default.fileExists(atPath: dbURL.path) {
            var config = Configuration()
            config.readonly = true
            if let queue = try? DatabaseQueue(path: dbURL.path, configuration: config) {
                dbMax = (try? queue.read { db in
                    try String.fetchOne(db, sql: "SELECT MAX(updated_at) FROM transactions")
                } ?? "") ?? ""
            }
        }
        if cliMarker.isEmpty && dbMax.isEmpty { return nil }
        return "\(cliMarker)|\(dbMax)"
    }

    /// Ehrlicher Outcome eines CLI-Refresh — von der App als JSON nach
    /// `simplebanking.cli.lastRefreshOutcome` geschrieben.
    struct RefreshOutcome {
        enum Status: String { case success, locked, failed }
        let status: Status
        let timestamp: String
        let detail: String?
    }

    static func lastRefreshOutcome() -> RefreshOutcome? {
        guard let json = prefString("simplebanking.cli.lastRefreshOutcome"),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusStr = obj["status"] as? String,
              let status = RefreshOutcome.Status(rawValue: statusStr),
              let ts = obj["timestamp"] as? String else {
            return nil
        }
        return RefreshOutcome(status: status, timestamp: ts, detail: obj["detail"] as? String)
    }

    // MARK: - Transactions

    /// Liest Transaktionen aus der SQLite-DB. Öffnet read-only, damit die
    /// laufende Menü-App nicht blockiert wird.
    static func loadTransactions(
        slotId: String?,
        sinceDaysAgo: Int,
        category: String?,
        limit: Int?
    ) throws -> [TxRow] {
        let dbURL = try transactionsDBPath()
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)

        // Cutoff als YYYY-MM-DD im Local-TZ
        let cutoff = cutoffDateString(daysAgo: sinceDaysAgo)

        var sql = """
            SELECT tx_id, buchungsdatum, betrag, waehrung, empfaenger, absender,
                   verwendungszweck, kategorie, slot_id, status, effective_merchant
            FROM transactions
            WHERE buchungsdatum >= ?
            """
        var args: [DatabaseValueConvertible] = [cutoff]
        if let slotId {
            sql += " AND slot_id = ?"
            args.append(slotId)
        }
        if let category {
            sql += " AND kategorie = ?"
            args.append(category)
        }
        sql += " ORDER BY buchungsdatum DESC"
        if let limit { sql += " LIMIT \(limit)" }

        return try queue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { r in
                TxRow(
                    txID: r["tx_id"],
                    bookingDate: r["buchungsdatum"],
                    amount: r["betrag"] ?? 0,
                    currency: r["waehrung"] ?? "EUR",
                    empfaenger: r["empfaenger"],
                    absender: r["absender"],
                    purpose: r["verwendungszweck"],
                    category: r["kategorie"],
                    slotId: r["slot_id"] ?? "legacy",
                    status: r["status"] ?? "booked",
                    effectiveMerchant: r["effective_merchant"] ?? ""
                )
            }
        }
    }

    private static func cutoffDateString(daysAgo: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        let d = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        return f.string(from: d)
    }
}
