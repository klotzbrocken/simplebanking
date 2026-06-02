import Foundation
import GRDB

// MARK: - Pot model

enum PotStatus: String {
    case open
    case pending
    case discarded
    case keptVirtual = "kept_virtual"
    case transferred
}

struct RoundupPot: Equatable {
    let slotId: String
    let potDate: String
    let amountCents: Int
    let entryCount: Int
    let status: PotStatus
    let resolvedAt: Date?
}

// MARK: - Store

/// Persistence layer for the round-up pot. Append-only ledger in `roundup_entries`
/// (idempotent on `(slot_id, tx_id)`), aggregated into `roundup_pots` per day.
enum RoundupStore {

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let stickyFinalStatuses: Set<String> = [
        PotStatus.discarded.rawValue,
        PotStatus.keptVirtual.rawValue,
        PotStatus.transferred.rawValue
    ]

    /// Idempotent. Re-Inserts derselben (slotId, txId) werden ignoriert — der Pot
    /// wird nur beim ersten Insert inkrementiert. Wenn der Pot bereits final
    /// resolved ist, wird die Entry geschrieben aber das Aggregat nicht angepasst
    /// (Log-Warnung).
    static func record(
        slotId: String,
        txId: String,
        potDate: String,
        amountCents: Int,
        stepCents: Int,
        bankId: String = "primary"
    ) throws {
        guard amountCents > 0 else { return }
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        let now = isoFormatter.string(from: Date())

        try queue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO roundup_entries
                    (slot_id, tx_id, pot_date, amount_cents, step_cents, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [slotId, txId, potDate, amountCents, stepCents, now])

            // Nur aggregieren, wenn der Eintrag tatsächlich neu war.
            guard db.changesCount > 0 else { return }

            let row = try Row.fetchOne(db, sql: """
                SELECT status FROM roundup_pots WHERE slot_id = ? AND pot_date = ?
                """, arguments: [slotId, potDate])

            if let row {
                let status: String = row["status"]
                guard !stickyFinalStatuses.contains(status) else {
                    AppLogger.log(
                        "Late roundup entry for already-resolved pot (slot=\(slotId), date=\(potDate), status=\(status))",
                        category: "Roundup", level: "WARN"
                    )
                    return
                }
                try db.execute(sql: """
                    UPDATE roundup_pots
                       SET amount_cents = amount_cents + ?,
                           entry_count  = entry_count + 1
                     WHERE slot_id = ? AND pot_date = ?
                    """, arguments: [amountCents, slotId, potDate])
            } else {
                try db.execute(sql: """
                    INSERT INTO roundup_pots
                        (slot_id, pot_date, amount_cents, entry_count, status)
                    VALUES (?, ?, ?, 1, 'open')
                    """, arguments: [slotId, potDate, amountCents])
            }
        }
    }

    static func pot(
        slotId: String,
        potDate: String,
        bankId: String = "primary"
    ) throws -> RoundupPot? {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        return try queue.read { db in
            try fetchPot(db: db, slotId: slotId, potDate: potDate)
        }
    }

    /// Pots, die noch auf eine User-Entscheidung warten: status `open` oder `pending`,
    /// mit `pot_date < cutoffDate` und `amount_cents > 0`. Sortiert nach Datum ASC
    /// (ältester pending Tag zuerst).
    static func pendingPots(
        slotId: String,
        before cutoffDate: String,
        bankId: String = "primary"
    ) throws -> [RoundupPot] {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        return try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT slot_id, pot_date, amount_cents, entry_count, status, resolved_at
                  FROM roundup_pots
                 WHERE slot_id = ?
                   AND pot_date < ?
                   AND amount_cents > 0
                   AND status IN ('open', 'pending')
                 ORDER BY pot_date ASC
                """, arguments: [slotId, cutoffDate])
            return rows.compactMap(rowToPot)
        }
    }

    /// Hebt `open` Pots eines Slots vor `cutoffDate` auf `pending` an — markiert sie
    /// als „User muss noch entscheiden". Idempotent: bereits `pending` oder final
    /// Pots bleiben unverändert. Setzt kein `resolved_at`.
    @discardableResult
    static func markStalePending(
        slotId: String,
        before cutoffDate: String,
        bankId: String = "primary"
    ) throws -> Int {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        return try queue.write { db in
            try db.execute(sql: """
                UPDATE roundup_pots
                   SET status = 'pending'
                 WHERE slot_id = ?
                   AND pot_date < ?
                   AND status = 'open'
                   AND amount_cents > 0
                """, arguments: [slotId, cutoffDate])
            return db.changesCount
        }
    }

    /// Setzt den Status. Bereits final-resolved Pots (discarded/keptVirtual/transferred)
    /// werden NICHT überschrieben — re-runs sind no-op (Log-Warnung wenn der Ziel-Status
    /// abweicht).
    static func resolve(
        slotId: String,
        potDate: String,
        status: PotStatus,
        bankId: String = "primary"
    ) throws {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        let now = isoFormatter.string(from: Date())
        try queue.write { db in
            let current = try String.fetchOne(db, sql: """
                SELECT status FROM roundup_pots WHERE slot_id = ? AND pot_date = ?
                """, arguments: [slotId, potDate])
            guard let current else { return }

            if stickyFinalStatuses.contains(current) && current != status.rawValue {
                AppLogger.log(
                    "Skipping resolve: pot (slot=\(slotId), date=\(potDate)) already final at status=\(current), requested=\(status.rawValue)",
                    category: "Roundup", level: "WARN"
                )
                return
            }

            let resolvedAt: String? = (status == .open) ? nil : now
            try db.execute(sql: """
                UPDATE roundup_pots
                   SET status = ?, resolved_at = ?
                 WHERE slot_id = ? AND pot_date = ?
                """, arguments: [status.rawValue, resolvedAt, slotId, potDate])
        }
    }

    /// Markiert alle `keptVirtual`-Pots des Slots als `transferred`. Idempotent.
    /// Aufgerufen optimistisch beim „Auszahlen…"-Klick in Settings — wenn der
    /// User das TransferSheet abbricht, bleiben sie auf `transferred` (User hatte
    /// die Intention; Bookkeeping wird nicht nochmal angeboten).
    @discardableResult
    static func markVirtualSavingsTransferred(
        slotId: String,
        bankId: String = "primary"
    ) throws -> Int {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        let now = isoFormatter.string(from: Date())
        return try queue.write { db in
            try db.execute(sql: """
                UPDATE roundup_pots
                   SET status = ?, resolved_at = ?
                 WHERE slot_id = ? AND status = ?
                """, arguments: [
                    PotStatus.transferred.rawValue, now,
                    slotId, PotStatus.keptVirtual.rawValue
                ])
            return db.changesCount
        }
    }

    /// Markiert alle noch offenen (`open`/`pending`) Pots eines Slots im Datums-
    /// Range `[from, to]` (inklusive) als `transferred`. Aufgerufen nach einer
    /// erfolgreichen Aufrunden-Auszahlung — finalisiert exakt die Tage, die der
    /// gewählte Zeitraum abgedeckt hat (alle erfassten Pots, unabhängig davon ob
    /// der User den Betrag im TransferSheet noch geändert hat). Idempotent: bereits
    /// finale Pots (discarded/keptVirtual/transferred) bleiben unangetastet.
    @discardableResult
    static func markRangeTransferred(
        slotId: String,
        from: String,
        to: String,
        bankId: String = "primary"
    ) throws -> Int {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        let now = isoFormatter.string(from: Date())
        return try queue.write { db in
            try db.execute(sql: """
                UPDATE roundup_pots
                   SET status = ?, resolved_at = ?
                 WHERE slot_id = ?
                   AND pot_date >= ?
                   AND pot_date <= ?
                   AND status IN ('open', 'pending')
                """, arguments: [
                    PotStatus.transferred.rawValue, now,
                    slotId, from, to
                ])
            return db.changesCount
        }
    }

    /// Pot-Daten (`pot_date`) eines Slots, die bereits als `transferred` finalisiert
    /// wurden. Wird von der Live-Anzeige genutzt, um ausgezahlte Tage aus dem
    /// Payout-Betrag auszublenden (verhindert Doppelüberweisung).
    static func transferredPotDates(
        slotId: String,
        bankId: String = "primary"
    ) throws -> Set<String> {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        return try queue.read { db in
            let dates = try String.fetchAll(db, sql: """
                SELECT pot_date FROM roundup_pots
                 WHERE slot_id = ? AND status = ?
                """, arguments: [slotId, PotStatus.transferred.rawValue])
            return Set(dates)
        }
    }

    /// Summe aller Pot-Beiträge des laufenden Monats (status-agnostisch — zeigt
    /// die echte Roundup-Aktivität, auch wenn Pots inzwischen verworfen oder
    /// ausgezahlt wurden). Cutoff ist `monthStartDate` (lokaler Monatsanfang).
    static func monthToDateRoundupTotal(
        slotId: String,
        monthStartDate: String,
        bankId: String = "primary"
    ) throws -> Int {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        return try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(amount_cents), 0)
                  FROM roundup_pots
                 WHERE slot_id = ? AND pot_date >= ?
                """, arguments: [slotId, monthStartDate]) ?? 0
        }
    }

    /// Summe aller `keptVirtual`-Pots für den Slot (Cent).
    static func virtualSavingsTotal(
        slotId: String,
        bankId: String = "primary"
    ) throws -> Int {
        let queue = try TransactionsDatabase.makeQueue(bankId: bankId)
        return try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(amount_cents), 0)
                  FROM roundup_pots
                 WHERE slot_id = ? AND status = ?
                """, arguments: [slotId, PotStatus.keptVirtual.rawValue]) ?? 0
        }
    }

    // MARK: - Private

    private static func fetchPot(db: Database, slotId: String, potDate: String) throws -> RoundupPot? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT slot_id, pot_date, amount_cents, entry_count, status, resolved_at
              FROM roundup_pots
             WHERE slot_id = ? AND pot_date = ?
            """, arguments: [slotId, potDate]) else { return nil }
        return rowToPot(row)
    }

    private static func rowToPot(_ row: Row) -> RoundupPot? {
        // GRDB exposes INTEGER as Int64; use typed subscript to get straight Int.
        let slotId: String = row["slot_id"]
        let potDate: String = row["pot_date"]
        let amountCents: Int = row["amount_cents"]
        let entryCount: Int = row["entry_count"]
        let statusStr: String = row["status"]
        guard let status = PotStatus(rawValue: statusStr) else { return nil }
        let resolvedAtRaw: String? = row["resolved_at"]
        let resolvedAt = resolvedAtRaw.flatMap { isoFormatter.date(from: $0) }
        return RoundupPot(
            slotId: slotId, potDate: potDate,
            amountCents: amountCents, entryCount: entryCount,
            status: status, resolvedAt: resolvedAt
        )
    }
}
