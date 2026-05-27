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
            ),
            tool(
                name: "prepare_transfer",
                description: """
                Prepares a SEPA credit transfer for the user to review and confirm in the simplebanking app. \
                This does NOT execute the transfer — it writes a draft file that the app picks up and pre-fills \
                into its transfer dialog. The user must still click 'Confirm' in the app and complete SCA \
                (TAN/BestSign) themselves. Returns the draft ID and a hint to open the app.
                """,
                properties: [
                    "creditor_name": prop("string",  "Recipient name (max 70 chars, SEPA-PAIN.001)"),
                    "creditor_iban": prop("string",  "Recipient IBAN (DE/AT/…); whitespace + case normalized server-side"),
                    "amount_eur":    prop("number",  "Amount in EUR (>0, max 100,000). Decimal, period as separator."),
                    "remittance":    prop("string",  "Purpose / Verwendungszweck (max 140 chars, optional)"),
                    "end_to_end_id": prop("string",  "End-to-end identifier (max 35 chars, optional)")
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
        case "prepare_transfer":     return prepareTransfer(args: args)
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
            // DB-Identität ist seit Migration v19 (tx_id, slot_id) als Composite-PK.
            // Zwei Slots dürfen denselben tx_id haben (Bank-Fingerprint kann kollidieren).
            // `id` muss daher global eindeutig sein → slot_id|tx_id. Den Bank-tx_id
            // exponieren wir zusätzlich separat, damit Clients ihn referenzieren können.
            let txID    = col(stmt, 0) ?? ""
            let slotID  = col(stmt, 9) ?? ""
            let unique  = slotID.isEmpty ? txID : "\(slotID)|\(txID)"
            var row: [String: Any] = [
                "id":           unique,
                "tx_id":        txID,
                "date":         col(stmt, 1) ?? "",
                "booking_date": col(stmt, 2) ?? "",
                "amount":       sqlite3_column_double(stmt, 3)
            ]
            if let v = col(stmt, 4) { row["currency"]    = v }
            if let v = col(stmt, 5) { row["recipient"]   = v }
            if let v = col(stmt, 6) { row["sender"]      = v }
            if let v = col(stmt, 7) { row["purpose"]     = v }
            if let v = col(stmt, 8) { row["category"]    = v }
            row["account_id"] = slotID
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

        // Load cached (real) balances from the app's UserDefaults plist.
        // Im Demo-Mode nur Demo-Slots zurückgeben, sonst Demo-Slots ausschließen — sonst
        // mischt MCP Live-Konten mit Demo-Daten, was insbesondere für Claude-Antworten
        // verwirrend wäre.
        let demo = isDemoMode
        let prefsPath = FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Preferences/tech.yaxi.simplebanking.plist"
        var cachedBalances: [String: Double] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: prefsPath)),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in plist {
                if key.hasPrefix("simplebanking.cachedBalance."),
                   let balance = value as? Double {
                    let slotId = String(key.dropFirst("simplebanking.cachedBalance.".count))
                    let slotIsDemo = slotId.hasPrefix("demo-slot-")
                    guard slotIsDemo == demo else { continue }
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

    // MARK: - prepare_transfer
    //
    // Schreibt einen JSON-Draft in das transfer-drafts/-Verzeichnis. Die App
    // watcht dieses Verzeichnis und öffnet bei Eintreffen das TransferSheet
    // mit den vorausgefüllten Feldern. SCA + Send-Delay + Lizenz-Gate laufen
    // unverändert in der App.
    //
    // JSON-Schema MUSS zu Sources/simplebanking/TransferDraftStore.swift
    // passen (Source of Truth). Schema-Änderungen dort = parallele Anpassung
    // hier.

    private static func prepareTransfer(args: [String: Any]) -> (String, Bool) {
        // 1) Required: creditor_name
        guard let rawName = args["creditor_name"] as? String,
              !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (errorJSON("Missing or empty 'creditor_name'."), true)
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= 70 else {
            return (errorJSON("creditor_name too long (\(name.count) chars, max 70 per SEPA-PAIN.001)."), true)
        }

        // 2) Required: creditor_iban — normalize whitespace + uppercase, validate length range only.
        // Full mod-97 check happens in the app when loading the draft (single source of truth).
        guard let rawIban = args["creditor_iban"] as? String,
              !rawIban.isEmpty else {
            return (errorJSON("Missing 'creditor_iban'."), true)
        }
        let iban = rawIban.uppercased().filter { !$0.isWhitespace }
        guard (15 ... 34).contains(iban.count) else {
            return (errorJSON("creditor_iban length \(iban.count) outside SEPA range 15…34."), true)
        }
        guard iban.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return (errorJSON("creditor_iban contains non-alphanumeric characters."), true)
        }

        // 3) Required: amount_eur — accept number, integer, or string
        let amountStr: String
        if let n = args["amount_eur"] as? Double {
            amountStr = String(format: "%.2f", n)
        } else if let n = args["amount_eur"] as? Int {
            amountStr = String(n)
        } else if let s = args["amount_eur"] as? String, !s.isEmpty {
            amountStr = s.replacingOccurrences(of: ",", with: ".")
        } else {
            return (errorJSON("Missing or invalid 'amount_eur'."), true)
        }
        guard let amount = Double(amountStr), amount > 0 else {
            return (errorJSON("'amount_eur' must be a positive number."), true)
        }
        guard amount <= 100_000 else {
            return (errorJSON("'amount_eur' exceeds safe ceiling of 100,000 EUR."), true)
        }

        // 4) Optional: remittance + end_to_end_id with length caps
        var remittance: String? = nil
        if let r = args["remittance"] as? String {
            let trimmed = r.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard trimmed.count <= 140 else {
                    return (errorJSON("'remittance' too long (\(trimmed.count) chars, max 140)."), true)
                }
                remittance = trimmed
            }
        }
        var endToEndId: String? = nil
        if let e = args["end_to_end_id"] as? String {
            let trimmed = e.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard trimmed.count <= 35 else {
                    return (errorJSON("'end_to_end_id' too long (\(trimmed.count) chars, max 35)."), true)
                }
                endToEndId = trimmed
            }
        }

        // 5) Build draft JSON
        let id = UUID().uuidString
        let now = Date()
        let expires = now.addingTimeInterval(5 * 60) // 5 min TTL — matches TransferDraftStore.ttlSeconds
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var draft: [String: Any] = [
            "id": id,
            "createdAt": iso.string(from: now),
            "expiresAt": iso.string(from: expires),
            "source": "mcp",
            "creditorName": name,
            "creditorIban": iban,
            "amountEUR": amountStr
        ]
        if let r = remittance { draft["remittance"] = r }
        if let e = endToEndId { draft["endToEndId"] = e }

        // 6) Write to draft dir
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let dir = homeURL
            .appendingPathComponent("Library/Application Support/simplebanking/transfer-drafts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(id).json")
            let data = try JSONSerialization.data(withJSONObject: draft, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)

            // Best-effort: bring simplebanking.app to the foreground so the user
            // sees the prefilled sheet right away. Failure is silent — the file
            // is still there and the watcher will pick it up next time.
            _ = try? runProcess("/usr/bin/open", args: ["-a", "simplebanking"])

            let result: [String: Any] = [
                "draft_id": id,
                "expires_at": iso.string(from: expires),
                "ttl_seconds": 300,
                "creditor_name": name,
                "creditor_iban": iban,
                "amount_eur": amountStr,
                "message": "Draft written. Tell the user to confirm the transfer in the simplebanking app (5 minute window). The app must be running to auto-open the sheet; otherwise it will appear at next launch."
            ]
            return (jsonString(result), false)
        } catch {
            return (errorJSON("Failed to write draft: \(error.localizedDescription)"), true)
        }
    }

    private static func errorJSON(_ msg: String) -> String {
        return jsonString(["error": msg])
    }

    @discardableResult
    private static func runProcess(_ path: String, args: [String]) throws -> Int32 {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        try task.run()
        // Don't wait — we don't care about result + don't want to block the response.
        return 0
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
