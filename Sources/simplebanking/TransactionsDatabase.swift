import Foundation
import GRDB

// MARK: - Transaction Enrichment

struct TxEnrichment {
    var note: String?
    var attachmentCount: Int
    var isUnread: Bool
    var isFlagged: Bool
}

// MARK: - Attachment Info

struct AttachmentInfo: Identifiable {
    let id: String       // UUID string
    let txID: String
    let bankId: String
    let filename: String
    let mimeType: String
    let fileSize: Int64
    let createdAt: String
}

enum TransactionsDatabase {

    // MARK: - Active slot ID (set by BalanceBar when switching accounts)

    private static let _slotLock = NSLock()
    nonisolated(unsafe) private static var _activeSlotId: String = "legacy"
    static var activeSlotId: String {
        get { _slotLock.lock(); defer { _slotLock.unlock() }; return _activeSlotId }
        set { _slotLock.lock(); defer { _slotLock.unlock() }; _activeSlotId = newValue }
    }
    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_transactions") { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    tx_id TEXT PRIMARY KEY,
                    end_to_end_id TEXT,
                    datum TEXT NOT NULL,
                    buchungsdatum TEXT NOT NULL,
                    betrag REAL NOT NULL,
                    waehrung TEXT NOT NULL DEFAULT 'EUR',
                    empfaenger TEXT,
                    absender TEXT,
                    iban TEXT,
                    verwendungszweck TEXT,
                    kategorie TEXT,
                    additional_information TEXT,
                    raw_json TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)

            try db.execute(sql: "CREATE INDEX idx_transactions_datum ON transactions(datum DESC)")
            try db.execute(sql: "CREATE INDEX idx_transactions_empfaenger ON transactions(empfaenger)")
            try db.execute(sql: "CREATE INDEX idx_transactions_end_to_end_id ON transactions(end_to_end_id)")
        }
        migrator.registerMigration("v2_effective_merchant") { db in
            try addColumnIfMissing(db, table: "transactions", column: "effective_merchant", definition: "TEXT NOT NULL DEFAULT ''")
            try addColumnIfMissing(db, table: "transactions", column: "normalized_merchant", definition: "TEXT NOT NULL DEFAULT ''")
            try addColumnIfMissing(db, table: "transactions", column: "merchant_source", definition: "TEXT NOT NULL DEFAULT 'unknown'")
            try addColumnIfMissing(db, table: "transactions", column: "merchant_confidence", definition: "REAL NOT NULL DEFAULT 0")
            try addColumnIfMissing(db, table: "transactions", column: "search_text", definition: "TEXT NOT NULL DEFAULT ''")

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_transactions_effective_merchant ON transactions(effective_merchant)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_transactions_normalized_merchant ON transactions(normalized_merchant)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_transactions_search_text ON transactions(search_text)")

            try backfillMerchantColumns(db: db)
        }
        migrator.registerMigration("v3_effective_merchant_recompute") { db in
            try backfillMerchantColumns(db: db)
        }
        migrator.registerMigration("v4_category_labels") { db in
            try backfillCategoryColumn(db: db)
        }
        migrator.registerMigration("v5_enrichment") { db in
            try addColumnIfMissing(db, table: "transactions", column: "user_note", definition: "TEXT")
            try addColumnIfMissing(db, table: "transactions", column: "attachment_count", definition: "INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS transaction_attachments (
                    id TEXT PRIMARY KEY,
                    tx_id TEXT NOT NULL,
                    bank_id TEXT NOT NULL,
                    filename TEXT NOT NULL,
                    mime_type TEXT NOT NULL DEFAULT '',
                    file_size INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_attachments_tx_id ON transaction_attachments(tx_id)")
        }
        migrator.registerMigration("v6_slot_id") { db in
            try addColumnIfMissing(db, table: "transactions", column: "slot_id", definition: "TEXT NOT NULL DEFAULT 'legacy'")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_transactions_slot_id ON transactions(slot_id)")
        }
        migrator.registerMigration("v7_repair_slot_id") { db in
            // Repair: transactions accidentally stamped with a temporary UUID slot_id
            // (can happen if a refresh task was in-flight when the add-account wizard set activeSlotId).
            // All single-account installs should have slot_id = 'legacy'.
            try db.execute(sql: "UPDATE transactions SET slot_id = 'legacy' WHERE slot_id != 'legacy'")
        }
        migrator.registerMigration("v8_status") { db in
            // Store transaction status so we can distinguish pending from booked rows
            // and purge stale pending entries after each refresh.
            try addColumnIfMissing(db, table: "transactions", column: "status", definition: "TEXT NOT NULL DEFAULT 'booked'")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_transactions_status ON transactions(status)")
        }
        migrator.registerMigration("v9_dedup_fingerprint") { db in
            // Cleanup: a previous version temporarily removed bookingDate from the
            // fingerprint, causing every transaction to get a second DB row on the
            // next refresh.  Keep the row with the latest updated_at per slot and
            // de-duplicate on (slot_id, betrag, datum, buchungsdatum, empfaenger,
            // absender, verwendungszweck) — enough to identify the same real-world tx.
            try db.execute(sql: """
                DELETE FROM transactions
                WHERE rowid NOT IN (
                    SELECT MAX(rowid)
                    FROM transactions
                    GROUP BY slot_id, betrag, datum, buchungsdatum,
                             COALESCE(empfaenger, ''), COALESCE(absender, ''),
                             COALESCE(verwendungszweck, '')
                )
                """)
        }
        migrator.registerMigration("v10_reset_fingerprint") { db in
            // v9 kept the wrong-fingerprint rows (inserted after bookingDate was removed).
            // The reverted fingerprint now generates different tx_ids → doubles again on
            // every refresh.  Simplest fix: wipe all rows; next refresh re-populates
            // with the correct fingerprint.  User notes are lost but categories are
            // re-applied automatically by TransactionCategorizer.
            try db.execute(sql: "DELETE FROM transactions")
        }
        migrator.registerMigration("v11_recompute_merchant_aliases") { db in
            // Re-resolve all stored merchant names with the extended alias list.
            try backfillMerchantColumns(db: db)
        }
        migrator.registerMigration("v12_merchant_logos") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS merchant_logos (
                    key TEXT PRIMARY KEY NOT NULL,
                    data BLOB NOT NULL,
                    fetched_at TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """)
        }
        migrator.registerMigration("v13_transaction_logos") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS transaction_logos (
                    tx_id TEXT PRIMARY KEY NOT NULL,
                    data BLOB NOT NULL,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """)
        }
        migrator.registerMigration("v14_merchant_custom_logos") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS merchant_custom_logos (
                    merchant_key TEXT PRIMARY KEY NOT NULL,
                    data BLOB NOT NULL,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """)
        }
        migrator.registerMigration("v15_swipe_flags") { db in
            try addColumnIfMissing(db, table: "transactions", column: "is_unread", definition: "INTEGER NOT NULL DEFAULT 0")
            try addColumnIfMissing(db, table: "transactions", column: "is_flagged", definition: "INTEGER NOT NULL DEFAULT 0")
        }
        return migrator
    }

    static func migrate(bankId: String = "primary") throws {
        let queue = try makeQueue(bankId: bankId)
        try migrator.migrate(queue)
    }

    // MARK: - Demo DB

    /// Generates fake transactions for all 3 demo slots and writes them to transactions-demo.db.
    /// Called whenever demo mode is activated or the seed is changed.
    static func writeDemoDB(seed: Int) {
        guard let queue = try? makeQueue(bankId: "demo") else { return }
        guard (try? migrator.migrate(queue)) != nil else { return }

        let slotConfigs: [(id: String, profile: Int)] = [
            ("demo-main",  0),
            ("demo-daily", 1),
            ("demo-bills", 2)
        ]
        let now = currentTimestamp()

        for (slotId, profile) in slotConfigs {
            var s = UInt64(bitPattern: Int64(truncatingIfNeeded: seed)) &+ UInt64(profile)
            let txs = FakeData.generateDemoTransactions(seed: &s, days: 365, slotId: slotId, slotProfile: profile)

            try? queue.write { db in
                try db.execute(sql: "DELETE FROM transactions WHERE slot_id = ?", arguments: [slotId])
                for tx in txs {
                    let record = try TransactionRecord(transaction: tx, updatedAt: now)
                    try db.execute(
                        sql: """
                            INSERT INTO transactions (
                                tx_id, end_to_end_id, datum, buchungsdatum, betrag, waehrung,
                                empfaenger, absender, iban, verwendungszweck, kategorie,
                                additional_information, effective_merchant, normalized_merchant,
                                merchant_source, merchant_confidence, search_text, raw_json,
                                updated_at, slot_id, status, is_unread
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                            """,
                        arguments: [
                            record.txID, record.endToEndID, record.datum, record.buchungsdatum,
                            record.betrag, record.waehrung, record.empfaenger, record.absender,
                            record.iban, record.verwendungszweck, record.kategorie,
                            record.additionalInformation, record.effectiveMerchant,
                            record.normalizedMerchant, record.merchantSource, record.merchantConfidence,
                            record.searchText, record.rawJSON, record.updatedAt,
                            slotId, record.status
                        ]
                    )
                }
            }
        }
    }

    static func upsert(transactions: [TransactionsResponse.Transaction], bankId: String = "primary") throws {
        guard !transactions.isEmpty else { return }

        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)
        let now = currentTimestamp()

        let slotId = activeSlotId
        try queue.write { db in
            for transaction in transactions {
                let record = try TransactionRecord(transaction: transaction, updatedAt: now)
                try db.execute(
                    sql: """
                        INSERT INTO transactions (
                            tx_id, end_to_end_id, datum, buchungsdatum, betrag, waehrung,
                            empfaenger, absender, iban, verwendungszweck, kategorie,
                            additional_information, effective_merchant, normalized_merchant,
                            merchant_source, merchant_confidence, search_text, raw_json, updated_at,
                            slot_id, status, is_unread
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                        ON CONFLICT(tx_id) DO UPDATE SET
                            end_to_end_id = excluded.end_to_end_id,
                            datum = excluded.datum,
                            buchungsdatum = excluded.buchungsdatum,
                            betrag = excluded.betrag,
                            waehrung = excluded.waehrung,
                            empfaenger = excluded.empfaenger,
                            absender = excluded.absender,
                            iban = excluded.iban,
                            verwendungszweck = excluded.verwendungszweck,
                            kategorie = excluded.kategorie,
                            additional_information = excluded.additional_information,
                            effective_merchant = excluded.effective_merchant,
                            normalized_merchant = excluded.normalized_merchant,
                            merchant_source = excluded.merchant_source,
                            merchant_confidence = excluded.merchant_confidence,
                            search_text = excluded.search_text,
                            raw_json = excluded.raw_json,
                            updated_at = excluded.updated_at,
                            status = excluded.status,
                            user_note = user_note,
                            attachment_count = attachment_count,
                            is_unread = is_unread,
                            is_flagged = is_flagged
                        """,
                    arguments: [
                        record.txID,
                        record.endToEndID,
                        record.datum,
                        record.buchungsdatum,
                        record.betrag,
                        record.waehrung,
                        record.empfaenger,
                        record.absender,
                        record.iban,
                        record.verwendungszweck,
                        record.kategorie,
                        record.additionalInformation,
                        record.effectiveMerchant,
                        record.normalizedMerchant,
                        record.merchantSource,
                        record.merchantConfidence,
                        record.searchText,
                        record.rawJSON,
                        record.updatedAt,
                        slotId,
                        record.status,
                    ]
                )
            }

            // Purge pending transactions that were NOT returned in this refresh batch.
            // After a card payment is booked the bank stops returning the pending entry;
            // without cleanup it would linger in the DB forever.
            // We only remove rows that are still pending AND whose updated_at was NOT
            // touched by this batch (i.e., YAXI no longer includes them).
            try db.execute(
                sql: """
                    DELETE FROM transactions
                    WHERE slot_id = ? AND status = 'pending' AND updated_at < ?
                    """,
                arguments: [slotId, now]
            )
        }
    }

    static func loadTransactions(days: Int, bankId: String = "primary") throws -> [TransactionsResponse.Transaction] {
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)

        let normalizedDays = max(1, days)
        let cutoffDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: -(normalizedDays - 1), to: Date()) ?? Date()
        let cutoff = isoDateFormatter.string(from: cutoffDate)
        let slotId = activeSlotId

        return try queue.read { db in
            let records = try TransactionRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM transactions
                    WHERE slot_id = ? AND (datum >= ? OR buchungsdatum >= ?)
                    ORDER BY buchungsdatum DESC, datum DESC, updated_at DESC
                    """,
                arguments: [slotId, cutoff, cutoff]
            )
            return records.compactMap { $0.toTransaction() }
        }
    }

    /// Load transactions from one or more slots (unified inbox).
    /// - `slots: nil` — all slots (no filter)
    /// - `slots: []` — guard: returns [] immediately to avoid `WHERE slot_id IN ()` SQLite error
    /// - `slots: [String]` — exactly those slot IDs
    /// Bound: last `days` days. Cap: 999 slot IDs max (realistic users have 2-5).
    static func loadUnifiedTransactions(slots: [String]?, days: Int, bankId: String = "primary") throws -> [TransactionsResponse.Transaction] {
        if let slots, slots.isEmpty { return [] }
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)
        let normalizedDays = max(1, days)
        let cutoffDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: -(normalizedDays - 1), to: Date()) ?? Date()
        let cutoff = isoDateFormatter.string(from: cutoffDate)

        return try queue.read { db in
            let records: [TransactionRecord]
            if let slots {
                // Bind at most 999 slot IDs (SQLite limit; realistic users have 2-5)
                let safeSlots = Array(slots.prefix(999))
                let placeholders = safeSlots.map { _ in "?" }.joined(separator: ", ")
                var args: [DatabaseValueConvertible] = safeSlots.map { $0 as DatabaseValueConvertible }
                args.append(cutoff)
                args.append(cutoff)
                records = try TransactionRecord.fetchAll(db, sql: """
                    SELECT * FROM transactions
                    WHERE slot_id IN (\(placeholders))
                      AND (datum >= ? OR buchungsdatum >= ?)
                    ORDER BY buchungsdatum DESC, datum DESC, updated_at DESC
                    """, arguments: StatementArguments(args))
            } else {
                records = try TransactionRecord.fetchAll(db, sql: """
                    SELECT * FROM transactions
                    WHERE (datum >= ? OR buchungsdatum >= ?)
                    ORDER BY buchungsdatum DESC, datum DESC, updated_at DESC
                    """, arguments: [cutoff, cutoff])
            }
            return records.compactMap { $0.toTransaction() }
        }
    }

    static func loadAllTransactions(limit: Int? = nil, bankId: String = "primary") throws -> [TransactionRecord] {
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)
        let slotId = activeSlotId

        return try queue.read { db in
            if let limit, limit > 0 {
                return try TransactionRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM transactions
                        WHERE slot_id = ?
                        ORDER BY buchungsdatum DESC, datum DESC, updated_at DESC
                        LIMIT ?
                        """,
                    arguments: [slotId, limit]
                )
            }

            return try TransactionRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM transactions
                    WHERE slot_id = ?
                    ORDER BY buchungsdatum DESC, datum DESC, updated_at DESC
                    """,
                arguments: [slotId]
            )
        }
    }

    static func executeReadOnlyQuery(sql: String, bankId: String = "primary") throws -> [[String: String]] {
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)

        return try queue.read { db in
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.map { row in
                var map: [String: String] = [:]
                for columnName in row.columnNames {
                    let value: DatabaseValue = row[columnName]
                    map[columnName] = stringValue(for: value)
                }
                return map
            }
        }
    }

    static func refreshEffectiveMerchantData(bankId: String = "primary") throws {
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)
        try queue.write { db in
            try backfillMerchantColumns(db: db)
            try backfillCategoryColumn(db: db)
        }
    }

    static func refreshTransactionCategories(bankId: String = "primary") throws {
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)
        try queue.write { db in
            try backfillCategoryColumn(db: db)
        }
    }

    // MARK: - Notes

    static func saveNote(txID: String, note: String?, bankId: String = "primary") throws {
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE transactions SET user_note = ? WHERE tx_id = ?",
                arguments: [note, txID]
            )
        }
    }

    static func loadEnrichmentData(bankId: String = "primary") throws -> [String: TxEnrichment] {
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)
        return try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT tx_id, user_note, attachment_count, is_unread, is_flagged
                FROM transactions
                WHERE is_unread = 1 OR is_flagged = 1 OR user_note IS NOT NULL OR attachment_count > 0
                """)
            var result: [String: TxEnrichment] = [:]
            for row in rows {
                let txID: String = row["tx_id"]
                let note: String? = row["user_note"]
                let count: Int = row["attachment_count"] ?? 0
                let unread: Bool = (row["is_unread"] as Int?) == 1
                let flagged: Bool = (row["is_flagged"] as Int?) == 1
                if note != nil || count > 0 || unread || flagged {
                    result[txID] = TxEnrichment(note: note, attachmentCount: count, isUnread: unread, isFlagged: flagged)
                }
            }
            return result
        }
    }

    // MARK: - Swipe Flags

    static func setUnread(txID: String, bankId: String = "primary", value: Bool) throws {
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE transactions SET is_unread = ? WHERE tx_id = ?",
                arguments: [value ? 1 : 0, txID]
            )
        }
    }

    static func setFlagged(txID: String, bankId: String = "primary", value: Bool) throws {
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE transactions SET is_flagged = ? WHERE tx_id = ?",
                arguments: [value ? 1 : 0, txID]
            )
        }
    }

    // MARK: - Attachments

    static func attachmentsDirectory(txID: String, bankId: String = "primary") throws -> URL {
        let credentialsURL = try CredentialsStore.defaultURL()
        let appDirectory = credentialsURL.deletingLastPathComponent()
        return appDirectory
            .appendingPathComponent("attachments")
            .appendingPathComponent(bankId)
            .appendingPathComponent(txID)
    }

    static func addAttachment(txID: String, bankId: String = "primary", sourceURL: URL) throws -> AttachmentInfo {
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)

        // Validate size (max 3 MB)
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        guard fileSize <= 3 * 1024 * 1024 else {
            throw NSError(domain: "TransactionsDatabase", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Datei ist größer als 3 MB."
            ])
        }

        // Check current count (max 3)
        let currentCount = try queue.read { db -> Int in
            let row = try Row.fetchOne(db, sql: "SELECT attachment_count FROM transactions WHERE tx_id = ?", arguments: [txID])
            return row?["attachment_count"] ?? 0
        }
        guard currentCount < 3 else {
            throw NSError(domain: "TransactionsDatabase", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Maximal 3 Anhänge pro Buchung erlaubt."
            ])
        }

        // Copy file to storage directory
        let dir = try attachmentsDirectory(txID: txID, bankId: bankId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let attachmentID = UUID().uuidString
        let ext = sourceURL.pathExtension.lowercased()
        let filename = attachmentID + (ext.isEmpty ? "" : ".\(ext)")
        let destURL = dir.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        let mimeType = mimeTypeFor(extension: ext)
        let now = ISO8601DateFormatter().string(from: Date())
        let info = AttachmentInfo(id: attachmentID, txID: txID, bankId: bankId, filename: filename, mimeType: mimeType, fileSize: fileSize, createdAt: now)

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transaction_attachments (id, tx_id, bank_id, filename, mime_type, file_size, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [info.id, txID, bankId, filename, mimeType, fileSize, now]
            )
            try db.execute(
                sql: "UPDATE transactions SET attachment_count = attachment_count + 1 WHERE tx_id = ?",
                arguments: [txID]
            )
        }
        return info
    }

    static func loadAttachments(txID: String, bankId: String = "primary") throws -> [AttachmentInfo] {
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)
        return try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, tx_id, bank_id, filename, mime_type, file_size, created_at FROM transaction_attachments WHERE tx_id = ? ORDER BY created_at",
                arguments: [txID]
            )
            return rows.map { row in
                AttachmentInfo(
                    id: row["id"],
                    txID: row["tx_id"],
                    bankId: row["bank_id"],
                    filename: row["filename"],
                    mimeType: row["mime_type"],
                    fileSize: row["file_size"] ?? 0,
                    createdAt: row["created_at"]
                )
            }
        }
    }

    static func deleteAttachment(id: String, txID: String, bankId: String = "primary") throws {
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)

        // Find the attachment to get filename
        let filename: String? = try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT filename FROM transaction_attachments WHERE id = ?", arguments: [id])
            return row?["filename"]
        }

        // Delete file from disk
        if let filename {
            let dir = try attachmentsDirectory(txID: txID, bankId: bankId)
            let fileURL = dir.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
        }

        // Remove from DB and decrement count
        try queue.write { db in
            try db.execute(sql: "DELETE FROM transaction_attachments WHERE id = ?", arguments: [id])
            if db.changesCount > 0 {
                try db.execute(
                    sql: "UPDATE transactions SET attachment_count = MAX(0, attachment_count - 1) WHERE tx_id = ?",
                    arguments: [txID]
                )
            }
        }
    }

    private static func mimeTypeFor(extension ext: String) -> String {
        switch ext {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    static func deleteTransactions(forSlotId slotId: String, bankId: String = "primary") throws {
        try migrate(bankId: bankId)
        let queue = try makeQueue(bankId: bankId)
        var txIds: [String] = []
        try queue.write { db in
            // Collect tx_ids before deleting so we can clean up attachments
            txIds = try String.fetchAll(db, sql:
                "SELECT tx_id FROM transactions WHERE slot_id = ?", arguments: [slotId])
            // Delete attachment metadata for all transactions in this slot
            if !txIds.isEmpty {
                let placeholders = txIds.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM transaction_attachments WHERE tx_id IN (\(placeholders))",
                    arguments: StatementArguments(txIds))
            }
            try db.execute(sql: "DELETE FROM transactions WHERE slot_id = ?", arguments: [slotId])
        }
        // Delete attachment files on disk
        for txId in txIds {
            if let dir = try? attachmentsDirectory(txID: txId, bankId: bankId),
               FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    static func deleteDatabaseFileIfExists(bankId: String = "primary") throws {
        let fileManager = FileManager.default
        let url = try databaseURL(bankId: bankId)
        let sidecars = [
            url,
            URL(fileURLWithPath: "\(url.path)-wal"),
            URL(fileURLWithPath: "\(url.path)-shm"),
        ]

        for fileURL in sidecars where fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    // MARK: - Helpers

    private static func makeQueue(bankId: String = "primary") throws -> DatabaseQueue {
        let path = try databaseURL(bankId: bankId).path
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        return try DatabaseQueue(path: path, configuration: configuration)
    }

    private static func databaseURL(bankId: String = "primary") throws -> URL {
        let credentialsURL = try CredentialsStore.defaultURL()
        let appDirectory = credentialsURL.deletingLastPathComponent()
        if bankId == "primary" {
            return appDirectory.appendingPathComponent("transactions.db")
        }
        return appDirectory.appendingPathComponent("transactions-\(bankId).db")
    }

    private static func stringValue(for value: DatabaseValue) -> String {
        if value.isNull {
            return "NULL"
        }
        if let text = String.fromDatabaseValue(value) {
            return text
        }
        if let int = Int64.fromDatabaseValue(value) {
            return String(int)
        }
        if let double = Double.fromDatabaseValue(value) {
            return String(double)
        }
        if let bool = Bool.fromDatabaseValue(value) {
            return bool ? "true" : "false"
        }
        return String(describing: value)
    }

    private static func currentTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func addColumnIfMissing(
        _ db: Database,
        table: String,
        column: String,
        definition: String
    ) throws {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        let hasColumn = rows.contains { row in
            let name: String = row["name"]
            return name == column
        }
        guard !hasColumn else { return }
        try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private static func backfillMerchantColumns(db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT tx_id, empfaenger, absender, verwendungszweck,
                       additional_information, iban
                FROM transactions
                """
        )

        for row in rows {
            let txID: String = row["tx_id"]
            let empfaenger: String? = row["empfaenger"]
            let absender: String? = row["absender"]
            let verwendungszweck: String? = row["verwendungszweck"]
            let additionalInformation: String? = row["additional_information"]
            let iban: String? = row["iban"]

            let resolution = MerchantResolver.resolve(
                txID: txID,
                empfaenger: empfaenger,
                absender: absender,
                verwendungszweck: verwendungszweck,
                additionalInformation: additionalInformation
            )
            try db.execute(
                sql: """
                    UPDATE transactions
                    SET effective_merchant = ?,
                        normalized_merchant = ?,
                        merchant_source = ?,
                        merchant_confidence = ?
                    WHERE tx_id = ?
                    """,
                arguments: [
                    resolution.effectiveMerchant,
                    resolution.normalizedMerchant,
                    resolution.source,
                    resolution.confidence,
                    txID,
                ]
            )
        }
    }

    /// Load transactions without a category (or with the fallback "Sonstiges") for AI categorization.
    /// Scoped to a single slot to prevent cross-account data leakage to AI providers.
    static func loadRecordsForCategorization(slotId: String) throws -> [TransactionRecord] {
        let queue = try makeQueue()
        return try queue.read { db in
            try TransactionRecord.fetchAll(db, sql: """
                SELECT * FROM transactions
                WHERE slot_id = ?
                  AND (kategorie IS NULL OR kategorie = '' OR kategorie = 'Sonstiges')
                ORDER BY buchungsdatum DESC LIMIT 200
                """, arguments: [slotId])
        }
    }

    /// Update the category label for a single transaction by tx_id.
    static func updateKategorie(txID: String, kategorie: String) throws {
        let queue = try makeQueue()
        try queue.write { db in
            try db.execute(sql: "UPDATE transactions SET kategorie = ? WHERE tx_id = ?",
                           arguments: [kategorie, txID])
        }
    }

    private static func backfillCategoryColumn(db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT tx_id, betrag, empfaenger, absender, verwendungszweck,
                       additional_information, effective_merchant
                FROM transactions
                """
        )

        for row in rows {
            let txID: String = row["tx_id"]
            let amount: Double = row["betrag"]
            let empfaenger: String? = row["empfaenger"]
            let absender: String? = row["absender"]
            let verwendungszweck: String? = row["verwendungszweck"]
            let additionalInformation: String? = row["additional_information"]
            let effectiveMerchant: String? = row["effective_merchant"]

            let category = TransactionCategorizer.category(
                txID: txID,
                amount: amount,
                empfaenger: empfaenger,
                absender: absender,
                verwendungszweck: verwendungszweck,
                additionalInformation: additionalInformation,
                effectiveMerchant: effectiveMerchant
            )

            try db.execute(
                sql: """
                    UPDATE transactions
                    SET kategorie = ?
                    WHERE tx_id = ?
                    """,
                arguments: [category.displayName, txID]
            )
        }
    }

    // MARK: - Logo Cache

    static func loadCachedLogoData() throws -> [String: Data] {
        try migrate()
        let queue = try makeQueue()
        return try queue.read { db in
            var result: [String: Data] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT key, data FROM merchant_logos")
            for row in rows {
                if let key = row["key"] as String?,
                   let data = row["data"] as Data? {
                    result[key] = data
                }
            }
            return result
        }
    }

    static func saveLogo(key: String, data: Data) {
        guard let queue = try? makeQueue() else { return }
        try? queue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO merchant_logos (key, data, fetched_at) VALUES (?, ?, datetime('now'))",
                arguments: [key, data]
            )
        }
    }

    static func clearLogoCache() {
        guard let queue = try? makeQueue() else { return }
        try? queue.write { db in
            try db.execute(sql: "DELETE FROM merchant_logos")
        }
    }

    // MARK: - Merchant Custom Logos (per normalizedMerchant key, affects all matching transactions)

    static func loadAllMerchantCustomLogos() -> [String: Data] {
        guard let queue = try? makeQueue() else { return [:] }
        return (try? queue.read { db in
            var result: [String: Data] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT merchant_key, data FROM merchant_custom_logos")
            for row in rows {
                if let key = row["merchant_key"] as String?,
                   let data = row["data"] as Data? {
                    result[key] = data
                }
            }
            return result
        }) ?? [:]
    }

    static func saveMerchantCustomLogo(merchantKey: String, data: Data) {
        guard let queue = try? makeQueue() else { return }
        try? queue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO merchant_custom_logos (merchant_key, data, created_at) VALUES (?, ?, datetime('now'))",
                arguments: [merchantKey, data]
            )
        }
    }

    static func deleteMerchantCustomLogo(merchantKey: String) {
        guard let queue = try? makeQueue() else { return }
        try? queue.write { db in
            try db.execute(sql: "DELETE FROM merchant_custom_logos WHERE merchant_key = ?", arguments: [merchantKey])
        }
    }

    // MARK: - Custom Transaction Logos

    static func loadCustomLogo(txId: String) -> Data? {
        guard let queue = try? makeQueue() else { return nil }
        return try? queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT data FROM transaction_logos WHERE tx_id = ?", arguments: [txId])
            return row?["data"] as Data?
        }
    }

    static func saveCustomLogo(txId: String, data: Data) {
        guard let queue = try? makeQueue() else { return }
        try? queue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO transaction_logos (tx_id, data, created_at) VALUES (?, ?, datetime('now'))",
                arguments: [txId, data]
            )
        }
    }

    static func deleteCustomLogo(txId: String) {
        guard let queue = try? makeQueue() else { return }
        try? queue.write { db in
            try db.execute(sql: "DELETE FROM transaction_logos WHERE tx_id = ?", arguments: [txId])
        }
    }
}
