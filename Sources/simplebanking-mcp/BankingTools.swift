import Foundation
import SQLite3

// MARK: - sqlite3_destructor_type helper

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - BankingTools

struct BankingTools {

    // MARK: - Tool list

    static func toolList() -> [[String: Any]] {
        [
            tool(
                name: "get_accounts",
                description: "Lists all connected bank accounts (id, iban, name, nickname, currency).",
                properties: [:]
            ),
            tool(
                name: "get_transactions",
                description: "Returns transactions with optional filters. Amounts are negative for expenses, positive for income.",
                properties: [
                    "days":        prop("integer", "How many days back to look (default: 30)"),
                    "account_id":  prop("string",  "Filter by account slot ID (optional)"),
                    "category":    prop("string",  "Filter by category name, e.g. 'Gastronomie' (optional)"),
                    "search":      prop("string",  "Search in recipient, sender, or purpose (optional)"),
                    "min_amount":  prop("number",  "Minimum amount in EUR, e.g. -500 for expenses over 500€ (optional)"),
                    "max_amount":  prop("number",  "Maximum amount in EUR (optional)")
                ]
            ),
            tool(
                name: "get_spending_summary",
                description: "Returns expenses grouped by category for a period. Totals are negative (money spent).",
                properties: [
                    "days":       prop("integer", "How many days back (default: 30)"),
                    "account_id": prop("string",  "Filter by account slot ID (optional)")
                ]
            ),
            tool(
                name: "get_monthly_overview",
                description: "Returns income vs. expenses per calendar month.",
                properties: [
                    "months":     prop("integer", "How many months back (default: 6)"),
                    "account_id": prop("string",  "Filter by account slot ID (optional)")
                ]
            ),
            tool(
                name: "get_balance",
                description: "Returns the calculated balance (sum of all transactions) per account.",
                properties: [
                    "account_id": prop("string", "Filter by account slot ID (optional, returns all accounts if omitted)")
                ]
            )
        ]
    }

    private static func tool(name: String, description: String, properties: [String: Any]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties
            ] as [String: Any]
        ]
    }

    private static func prop(_ type: String, _ description: String) -> [String: String] {
        ["type": type, "description": description]
    }

    // MARK: - Dispatch

    static func call(name: String, args: [String: Any]) -> (String, Bool) {
        switch name {
        case "get_accounts":         return getAccounts()
        case "get_transactions":     return getTransactions(args: args)
        case "get_spending_summary": return getSpendingSummary(args: args)
        case "get_monthly_overview": return getMonthlyOverview(args: args)
        case "get_balance":          return getBalance(args: args)
        default:                     return ("Unknown tool: \(name)", true)
        }
    }

    // MARK: - get_accounts

    private static func getAccounts() -> (String, Bool) {
        if isDemoMode {
            return (jsonString([
                ["id": "demo-main",  "iban": "DE89200400600284202600", "name": "Klotzbrocken AG",   "nickname": "Hauptkonto", "currency": "EUR"],
                ["id": "demo-daily", "iban": "DE89370400440532013000", "name": "Payment & Banking",  "nickname": "Alltag",     "currency": "EUR"],
                ["id": "demo-bills", "iban": "DE89500400600284202601", "name": "Fliegenfranz GmbH", "nickname": "Kosten",     "currency": "EUR"]
            ]), false)
        }

        let prefsPath = FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Preferences/tech.yaxi.simplebanking.plist"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: prefsPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let slotsData = plist["simplebanking.multibanking.slots"] as? Data
        else {
            return ("[]", false)
        }

        struct Slot: Codable {
            let id: String
            var iban: String
            var displayName: String
            var currency: String?
            var nickname: String?
        }

        guard let slots = try? JSONDecoder().decode([Slot].self, from: slotsData) else {
            return ("[]", false)
        }

        let result: [[String: Any]] = slots.map { s in
            var d: [String: Any] = ["id": s.id, "iban": s.iban, "name": s.displayName]
            if let n = s.nickname  { d["nickname"] = n }
            if let c = s.currency  { d["currency"] = c }
            return d
        }
        return (jsonString(result), false)
    }

    // MARK: - get_transactions

    private static func getTransactions(args: [String: Any]) -> (String, Bool) {
        let days      = args["days"]       as? Int    ?? 30
        let accountId = args["account_id"] as? String
        let category  = args["category"]   as? String
        let search    = args["search"]     as? String
        let minAmount = args["min_amount"] as? Double
        let maxAmount = args["max_amount"] as? Double
        let cutoff    = cutoffDate(daysBack: days)

        var conditions = ["(datum >= ? OR buchungsdatum >= ?)"]
        var binds: [BindValue] = [.text(cutoff), .text(cutoff)]

        if let aid = accountId { conditions.append("slot_id = ?"); binds.append(.text(aid)) }
        if let cat = category  { conditions.append("kategorie = ?"); binds.append(.text(cat)) }
        if let s = search {
            let p = "%\(s)%"
            conditions.append("(empfaenger LIKE ? OR absender LIKE ? OR verwendungszweck LIKE ?)")
            binds += [.text(p), .text(p), .text(p)]
        }
        if let min = minAmount { conditions.append("betrag >= ?"); binds.append(.real(min)) }
        if let max = maxAmount { conditions.append("betrag <= ?"); binds.append(.real(max)) }

        let sql = """
            SELECT tx_id, datum, buchungsdatum, betrag, waehrung,
                   empfaenger, absender, verwendungszweck, kategorie, slot_id, user_note
            FROM transactions
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY buchungsdatum DESC, datum DESC
            LIMIT 500
            """

        let rows = query(sql: sql, binds: binds) { stmt -> [String: Any] in
            var row: [String: Any] = [
                "id":           col(stmt, 0) ?? "",
                "date":         col(stmt, 1) ?? "",
                "booking_date": col(stmt, 2) ?? "",
                "amount":       sqlite3_column_double(stmt, 3)
            ]
            if let v = col(stmt, 4) { row["currency"]    = v }
            if let v = col(stmt, 5) { row["recipient"]   = v }
            if let v = col(stmt, 6) { row["sender"]      = v }
            if let v = col(stmt, 7) { row["purpose"]     = v }
            if let v = col(stmt, 8) { row["category"]    = v }
            row["account_id"] = col(stmt, 9) ?? ""
            if let v = col(stmt, 10) { row["note"]       = v }
            return row
        }

        return (jsonString(rows), false)
    }

    // MARK: - get_spending_summary

    private static func getSpendingSummary(args: [String: Any]) -> (String, Bool) {
        let days      = args["days"]       as? Int    ?? 30
        let accountId = args["account_id"] as? String
        let cutoff    = cutoffDate(daysBack: days)

        var conditions = ["betrag < 0", "(datum >= ? OR buchungsdatum >= ?)"]
        var binds: [BindValue] = [.text(cutoff), .text(cutoff)]

        if let aid = accountId { conditions.append("slot_id = ?"); binds.append(.text(aid)) }

        let sql = """
            SELECT COALESCE(kategorie, 'Sonstiges') as cat,
                   COUNT(*) as cnt,
                   SUM(betrag) as total
            FROM transactions
            WHERE \(conditions.joined(separator: " AND "))
            GROUP BY cat
            ORDER BY total ASC
            """

        let rows = query(sql: sql, binds: binds) { stmt -> [String: Any] in [
            "category": col(stmt, 0) ?? "Sonstiges",
            "count":    Int(sqlite3_column_int64(stmt, 1)),
            "total":    sqlite3_column_double(stmt, 2)
        ]}

        return (jsonString(rows), false)
    }

    // MARK: - get_monthly_overview

    private static func getMonthlyOverview(args: [String: Any]) -> (String, Bool) {
        let months    = args["months"]     as? Int    ?? 6
        let accountId = args["account_id"] as? String
        let cutoff    = cutoffDate(daysBack: months * 31)

        var conditions = ["(datum >= ? OR buchungsdatum >= ?)"]
        var binds: [BindValue] = [.text(cutoff), .text(cutoff)]

        if let aid = accountId { conditions.append("slot_id = ?"); binds.append(.text(aid)) }

        let sql = """
            SELECT strftime('%Y-%m', datum) as month,
                   SUM(CASE WHEN betrag > 0 THEN betrag ELSE 0 END) as income,
                   SUM(CASE WHEN betrag < 0 THEN betrag ELSE 0 END) as expenses,
                   SUM(betrag) as net,
                   COUNT(*) as cnt
            FROM transactions
            WHERE \(conditions.joined(separator: " AND "))
            GROUP BY month
            ORDER BY month DESC
            """

        let rows = query(sql: sql, binds: binds) { stmt -> [String: Any] in [
            "month":             col(stmt, 0) ?? "",
            "income":            sqlite3_column_double(stmt, 1),
            "expenses":          sqlite3_column_double(stmt, 2),
            "net":               sqlite3_column_double(stmt, 3),
            "transaction_count": Int(sqlite3_column_int64(stmt, 4))
        ]}

        return (jsonString(rows), false)
    }

    // MARK: - get_balance

    private static func getBalance(args: [String: Any]) -> (String, Bool) {
        let accountId = args["account_id"] as? String

        // Load cached (real) balances from the app's UserDefaults plist
        let prefsPath = FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Preferences/tech.yaxi.simplebanking.plist"
        var cachedBalances: [String: Double] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: prefsPath)),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in plist {
                if key.hasPrefix("simplebanking.cachedBalance."),
                   let balance = value as? Double {
                    let slotId = String(key.dropFirst("simplebanking.cachedBalance.".count))
                    cachedBalances[slotId] = balance
                }
            }
        }

        // Get transaction counts per slot from DB
        var conditions: [String] = []
        var binds: [BindValue]   = []
        if let aid = accountId { conditions.append("slot_id = ?"); binds.append(.text(aid)) }
        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = """
            SELECT slot_id, COUNT(*) as cnt
            FROM transactions
            \(whereClause)
            GROUP BY slot_id
            """

        let dbRows = query(sql: sql, binds: binds) { stmt -> (String, Int) in
            (col(stmt, 0) ?? "", Int(sqlite3_column_int64(stmt, 1)))
        }
        let txCounts = Dictionary(uniqueKeysWithValues: dbRows)

        // Build result: use cached real balance, fall back to DB sum only if unavailable
        let slotIds: [String]
        if let aid = accountId {
            slotIds = [aid]
        } else {
            // Union of slots seen in cache and in DB
            slotIds = Array(Set(cachedBalances.keys).union(txCounts.keys))
        }

        let rows: [[String: Any]] = slotIds.compactMap { sid in
            guard cachedBalances[sid] != nil || txCounts[sid] != nil else { return nil }
            var row: [String: Any] = ["account_id": sid]
            if let real = cachedBalances[sid] {
                row["balance"] = real
                row["balance_source"] = "bank"
            } else {
                // Fallback: compute from DB
                let fallbackSQL = "SELECT SUM(betrag) FROM transactions WHERE slot_id = ?"
                let sum = query(sql: fallbackSQL, binds: [.text(sid)]) { stmt -> Double in
                    sqlite3_column_double(stmt, 0)
                }.first ?? 0.0
                row["balance"] = sum
                row["balance_source"] = "transactions_sum"
            }
            row["transaction_count"] = txCounts[sid] ?? 0
            return row
        }.sorted { ($0["account_id"] as? String ?? "") < ($1["account_id"] as? String ?? "") }

        return (jsonString(rows), false)
    }

    // MARK: - Demo Mode

    private static var isDemoMode: Bool {
        let prefsPath = FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Preferences/tech.yaxi.simplebanking.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: prefsPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return plist["demoMode"] as? Bool ?? false
    }

    // MARK: - SQLite helpers

    private static let dbPath: String = {
        FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Application Support/simplebanking/transactions.db"
    }()

    private static var activeDbPath: String {
        isDemoMode
            ? FileManager.default.homeDirectoryForCurrentUser.path
                + "/Library/Application Support/simplebanking/transactions-demo.db"
            : dbPath
    }

    private enum BindValue {
        case text(String)
        case real(Double)
    }

    private static func query<T>(sql: String, binds: [BindValue], row: (OpaquePointer) -> T) -> [T] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(activeDbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = db else { return [] }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        for (i, bind) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch bind {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            }
        }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(row(stmt))
        }
        return results
    }

    private static func col(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    // MARK: - JSON helper

    private static func jsonString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    private static func cutoffDate(daysBack: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}
