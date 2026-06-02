import XCTest
import GRDB
@testable import simplebanking

// MARK: - RoundupStore Tests
//
// Pro Test isolierte `bankId`, damit die Produktions-DB nie berührt wird und
// parallel laufende Tests sich nicht stören. setUp ruft `migrate(bankId:)`
// damit v22 die Tabellen anlegt; tearDown räumt DB + WAL/SHM wieder weg.

final class RoundupStoreTests: XCTestCase {

    private var testBankId: String = ""

    override func setUpWithError() throws {
        testBankId = "test-roundup-\(UUID().uuidString.lowercased().prefix(12))"
        try TransactionsDatabase.migrate(bankId: testBankId)
    }

    override func tearDownWithError() throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: testBankId)
    }

    // MARK: - record(): basic insert + aggregation

    func test_record_singleEntry_createsPotAtSeeded() throws {
        try RoundupStore.record(
            slotId: "slot-a", txId: "tx-1", potDate: "2026-05-27",
            amountCents: 53, stepCents: 100, bankId: testBankId
        )

        let pot = try RoundupStore.pot(slotId: "slot-a", potDate: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(pot?.amountCents, 53)
        XCTAssertEqual(pot?.entryCount, 1)
        XCTAssertEqual(pot?.status, .open)
        XCTAssertNil(pot?.resolvedAt)
    }

    func test_record_twoEntriesSamePot_aggregates() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-27",
                                amountCents: 53, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "s", txId: "tx-2", potDate: "2026-05-27",
                                amountCents: 47, stepCents: 100, bankId: testBankId)

        let pot = try RoundupStore.pot(slotId: "s", potDate: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(pot?.amountCents, 100)
        XCTAssertEqual(pot?.entryCount, 2)
    }

    func test_record_zeroAmount_isNoOp() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-27",
                                amountCents: 0, stepCents: 100, bankId: testBankId)
        XCTAssertNil(try RoundupStore.pot(slotId: "s", potDate: "2026-05-27", bankId: testBankId))
    }

    // MARK: - Idempotency

    func test_record_sameTxIdTwice_doesNotDoubleCount() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-27",
                                amountCents: 53, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-27",
                                amountCents: 53, stepCents: 100, bankId: testBankId)

        let pot = try RoundupStore.pot(slotId: "s", potDate: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(pot?.amountCents, 53, "Re-Insert mit identischem (slot,tx) darf Pot nicht erhöhen.")
        XCTAssertEqual(pot?.entryCount, 1)
    }

    // MARK: - Slot scope

    func test_record_separateSlots_keepSeparatePots() throws {
        try RoundupStore.record(slotId: "slot-a", txId: "tx-1", potDate: "2026-05-27",
                                amountCents: 53, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "slot-b", txId: "tx-1", potDate: "2026-05-27",
                                amountCents: 100, stepCents: 100, bankId: testBankId)

        XCTAssertEqual(try RoundupStore.pot(slotId: "slot-a", potDate: "2026-05-27", bankId: testBankId)?.amountCents, 53)
        XCTAssertEqual(try RoundupStore.pot(slotId: "slot-b", potDate: "2026-05-27", bankId: testBankId)?.amountCents, 100)
    }

    func test_record_separateDays_keepSeparatePots() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-27",
                                amountCents: 53, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "s", txId: "tx-2", potDate: "2026-05-28",
                                amountCents: 47, stepCents: 100, bankId: testBankId)

        XCTAssertEqual(try RoundupStore.pot(slotId: "s", potDate: "2026-05-27", bankId: testBankId)?.amountCents, 53)
        XCTAssertEqual(try RoundupStore.pot(slotId: "s", potDate: "2026-05-28", bankId: testBankId)?.amountCents, 47)
    }

    // MARK: - resolve() — status transitions

    func test_resolve_openToDiscarded_setsResolvedAt() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-27",
                                amountCents: 53, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "s", potDate: "2026-05-27", status: .discarded, bankId: testBankId)

        let pot = try RoundupStore.pot(slotId: "s", potDate: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(pot?.status, .discarded)
        XCTAssertNotNil(pot?.resolvedAt)
    }

    func test_resolve_doubleResolve_secondIsNoOp() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-27",
                                amountCents: 53, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "s", potDate: "2026-05-27", status: .discarded, bankId: testBankId)
        let firstResolved = try RoundupStore.pot(slotId: "s", potDate: "2026-05-27", bankId: testBankId)?.resolvedAt

        // Versuche jetzt auf keptVirtual umzuschalten — muss ignoriert werden.
        try RoundupStore.resolve(slotId: "s", potDate: "2026-05-27", status: .keptVirtual, bankId: testBankId)
        let pot = try RoundupStore.pot(slotId: "s", potDate: "2026-05-27", bankId: testBankId)

        XCTAssertEqual(pot?.status, .discarded, "Final-Status ist sticky — keptVirtual-Resolve nach discarded muss ignoriert werden.")
        XCTAssertEqual(pot?.resolvedAt, firstResolved, "resolved_at darf beim ignorierten zweiten Resolve nicht überschrieben werden.")
    }

    func test_resolve_nonexistentPot_isNoOp() throws {
        XCTAssertNoThrow(try RoundupStore.resolve(slotId: "s", potDate: "2026-01-01", status: .discarded, bankId: testBankId))
        XCTAssertNil(try RoundupStore.pot(slotId: "s", potDate: "2026-01-01", bankId: testBankId))
    }

    // MARK: - Late entry after resolution

    func test_record_afterFinalResolve_savesEntryButNotAggregate() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-27",
                                amountCents: 53, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "s", potDate: "2026-05-27", status: .keptVirtual, bankId: testBankId)

        // Late TRX trifft denselben Pot — Entry-Log soll wachsen, Aggregat aber nicht.
        try RoundupStore.record(slotId: "s", txId: "tx-late", potDate: "2026-05-27",
                                amountCents: 47, stepCents: 100, bankId: testBankId)

        let pot = try RoundupStore.pot(slotId: "s", potDate: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(pot?.amountCents, 53, "Aggregat darf nicht über Final-Status hinaus wachsen.")
        XCTAssertEqual(pot?.entryCount, 1, "entry_count im Aggregat bleibt — Late-Eintrag wird nur in roundup_entries gelistet.")

        // Sanity: der Late-Entry ist tatsächlich in roundup_entries gelandet.
        let queue = try TransactionsDatabase.makeQueue(bankId: testBankId)
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM roundup_entries WHERE slot_id = ? AND pot_date = ?",
                             arguments: ["s", "2026-05-27"]) ?? 0
        }
        XCTAssertEqual(count, 2)
    }

    // MARK: - pendingPots(before:)

    func test_pendingPots_returnsOnlyOldOpenAndPending() throws {
        // Day -2: open
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        // Day -1: open
        try RoundupStore.record(slotId: "s", txId: "tx-2", potDate: "2026-05-26",
                                amountCents: 60, stepCents: 100, bankId: testBankId)
        // Day -1 (other slot): should NOT appear
        try RoundupStore.record(slotId: "other", txId: "tx-3", potDate: "2026-05-26",
                                amountCents: 70, stepCents: 100, bankId: testBankId)
        // Day -3: already discarded → should NOT appear
        try RoundupStore.record(slotId: "s", txId: "tx-4", potDate: "2026-05-24",
                                amountCents: 80, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "s", potDate: "2026-05-24", status: .discarded, bankId: testBankId)
        // Today: still open but >= cutoff → should NOT appear
        try RoundupStore.record(slotId: "s", txId: "tx-5", potDate: "2026-05-27",
                                amountCents: 90, stepCents: 100, bankId: testBankId)

        let pending = try RoundupStore.pendingPots(slotId: "s", before: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(pending.map(\.potDate), ["2026-05-25", "2026-05-26"], "Sortierung ASC, nur slot=s, nur < cutoff, nur open|pending.")
    }

    // MARK: - virtualSavingsTotal

    // MARK: - markStalePending

    func test_markStalePending_movesOnlyOldOpenPots() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "s", txId: "tx-2", potDate: "2026-05-26",
                                amountCents: 60, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "s", txId: "tx-3", potDate: "2026-05-27",
                                amountCents: 70, stepCents: 100, bankId: testBankId)

        let changed = try RoundupStore.markStalePending(slotId: "s", before: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(changed, 2, "Zwei alte Pots werden pending; der heutige bleibt open.")

        XCTAssertEqual(try RoundupStore.pot(slotId: "s", potDate: "2026-05-25", bankId: testBankId)?.status, .pending)
        XCTAssertEqual(try RoundupStore.pot(slotId: "s", potDate: "2026-05-26", bankId: testBankId)?.status, .pending)
        XCTAssertEqual(try RoundupStore.pot(slotId: "s", potDate: "2026-05-27", bankId: testBankId)?.status, .open)
    }

    func test_markStalePending_skipsAlreadyFinalAndSetsNoResolvedAt() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "s", potDate: "2026-05-25", status: .discarded, bankId: testBankId)

        let changed = try RoundupStore.markStalePending(slotId: "s", before: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(changed, 0)
        XCTAssertEqual(try RoundupStore.pot(slotId: "s", potDate: "2026-05-25", bankId: testBankId)?.status, .discarded)
    }

    func test_markStalePending_idempotent() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        XCTAssertEqual(try RoundupStore.markStalePending(slotId: "s", before: "2026-05-27", bankId: testBankId), 1)
        XCTAssertEqual(try RoundupStore.markStalePending(slotId: "s", before: "2026-05-27", bankId: testBankId), 0)
        XCTAssertNil(try RoundupStore.pot(slotId: "s", potDate: "2026-05-25", bankId: testBankId)?.resolvedAt,
                     "markStalePending darf kein resolved_at setzen (User hat noch nicht entschieden).")
    }

    // MARK: - markVirtualSavingsTransferred

    func test_markVirtualSavingsTransferred_flipsKeptVirtualToTransferred() throws {
        try RoundupStore.record(slotId: "a", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "a", potDate: "2026-05-25", status: .keptVirtual, bankId: testBankId)
        try RoundupStore.record(slotId: "a", txId: "tx-2", potDate: "2026-05-26",
                                amountCents: 70, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "a", potDate: "2026-05-26", status: .keptVirtual, bankId: testBankId)
        // Anderer Slot bleibt unangetastet
        try RoundupStore.record(slotId: "other", txId: "tx-3", potDate: "2026-05-26",
                                amountCents: 200, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "other", potDate: "2026-05-26", status: .keptVirtual, bankId: testBankId)

        let n = try RoundupStore.markVirtualSavingsTransferred(slotId: "a", bankId: testBankId)
        XCTAssertEqual(n, 2)

        XCTAssertEqual(try RoundupStore.virtualSavingsTotal(slotId: "a", bankId: testBankId), 0)
        XCTAssertEqual(try RoundupStore.virtualSavingsTotal(slotId: "other", bankId: testBankId), 200)
        XCTAssertEqual(try RoundupStore.pot(slotId: "a", potDate: "2026-05-25", bankId: testBankId)?.status, .transferred)
        XCTAssertNotNil(try RoundupStore.pot(slotId: "a", potDate: "2026-05-25", bankId: testBankId)?.resolvedAt)
    }

    func test_markVirtualSavingsTransferred_idempotent() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "s", potDate: "2026-05-25", status: .keptVirtual, bankId: testBankId)
        XCTAssertEqual(try RoundupStore.markVirtualSavingsTransferred(slotId: "s", bankId: testBankId), 1)
        XCTAssertEqual(try RoundupStore.markVirtualSavingsTransferred(slotId: "s", bankId: testBankId), 0)
    }

    // MARK: - virtualSavingsTotal

    func test_virtualSavingsTotal_sumsOnlyKeptVirtual() throws {
        // Slot A: 3 Pots, 2 davon keptVirtual
        try RoundupStore.record(slotId: "a", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "a", potDate: "2026-05-25", status: .keptVirtual, bankId: testBankId)

        try RoundupStore.record(slotId: "a", txId: "tx-2", potDate: "2026-05-26",
                                amountCents: 70, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "a", potDate: "2026-05-26", status: .keptVirtual, bankId: testBankId)

        try RoundupStore.record(slotId: "a", txId: "tx-3", potDate: "2026-05-27",
                                amountCents: 30, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "a", potDate: "2026-05-27", status: .discarded, bankId: testBankId)

        // Slot B: 1 keptVirtual — darf nicht zu A zählen
        try RoundupStore.record(slotId: "b", txId: "tx-4", potDate: "2026-05-25",
                                amountCents: 200, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "b", potDate: "2026-05-25", status: .keptVirtual, bankId: testBankId)

        XCTAssertEqual(try RoundupStore.virtualSavingsTotal(slotId: "a", bankId: testBankId), 120)
        XCTAssertEqual(try RoundupStore.virtualSavingsTotal(slotId: "b", bankId: testBankId), 200)
        XCTAssertEqual(try RoundupStore.virtualSavingsTotal(slotId: "empty-slot", bankId: testBankId), 0)
    }

    // MARK: - markRangeTransferred (P1 Auszahlungs-Finalisierung)

    func test_markRangeTransferred_flipsOpenAndPendingInRange() throws {
        // 3 Tage open + 1 außerhalb des Range
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "s", txId: "tx-2", potDate: "2026-05-26",
                                amountCents: 60, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "s", txId: "tx-3", potDate: "2026-05-27",
                                amountCents: 70, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "s", txId: "tx-4", potDate: "2026-05-28",
                                amountCents: 80, stepCents: 100, bankId: testBankId)
        // 2026-05-26 vorab auf pending — muss ebenfalls finalisiert werden
        try RoundupStore.markStalePending(slotId: "s", before: "2026-05-27", bankId: testBankId)

        let n = try RoundupStore.markRangeTransferred(slotId: "s", from: "2026-05-25", to: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(n, 3)

        XCTAssertEqual(try RoundupStore.pot(slotId: "s", potDate: "2026-05-25", bankId: testBankId)?.status, .transferred)
        XCTAssertEqual(try RoundupStore.pot(slotId: "s", potDate: "2026-05-26", bankId: testBankId)?.status, .transferred)
        XCTAssertEqual(try RoundupStore.pot(slotId: "s", potDate: "2026-05-27", bankId: testBankId)?.status, .transferred)
        // außerhalb des Range bleibt offen
        XCTAssertEqual(try RoundupStore.pot(slotId: "s", potDate: "2026-05-28", bankId: testBankId)?.status, .open)
        XCTAssertNotNil(try RoundupStore.pot(slotId: "s", potDate: "2026-05-25", bankId: testBankId)?.resolvedAt)
    }

    func test_markRangeTransferred_singleDay_idempotent() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        XCTAssertEqual(try RoundupStore.markRangeTransferred(slotId: "s", from: "2026-05-25", to: "2026-05-25", bankId: testBankId), 1)
        // zweiter Lauf trifft keine open/pending mehr
        XCTAssertEqual(try RoundupStore.markRangeTransferred(slotId: "s", from: "2026-05-25", to: "2026-05-25", bankId: testBankId), 0)
        XCTAssertEqual(try RoundupStore.pot(slotId: "s", potDate: "2026-05-25", bankId: testBankId)?.status, .transferred)
    }

    func test_markRangeTransferred_doesNotTouchFinalPots() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        try RoundupStore.resolve(slotId: "s", potDate: "2026-05-25", status: .discarded, bankId: testBankId)
        XCTAssertEqual(try RoundupStore.markRangeTransferred(slotId: "s", from: "2026-05-24", to: "2026-05-26", bankId: testBankId), 0)
        XCTAssertEqual(try RoundupStore.pot(slotId: "s", potDate: "2026-05-25", bankId: testBankId)?.status, .discarded)
    }

    func test_markRangeTransferred_scopedToSlot() throws {
        try RoundupStore.record(slotId: "a", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "b", txId: "tx-2", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        try RoundupStore.markRangeTransferred(slotId: "a", from: "2026-05-25", to: "2026-05-25", bankId: testBankId)
        XCTAssertEqual(try RoundupStore.pot(slotId: "a", potDate: "2026-05-25", bankId: testBankId)?.status, .transferred)
        XCTAssertEqual(try RoundupStore.pot(slotId: "b", potDate: "2026-05-25", bankId: testBankId)?.status, .open)
    }

    // MARK: - transferredPotDates

    func test_transferredPotDates_returnsOnlyTransferred() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "s", txId: "tx-2", potDate: "2026-05-26",
                                amountCents: 60, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "s", txId: "tx-3", potDate: "2026-05-27",
                                amountCents: 70, stepCents: 100, bankId: testBankId)
        try RoundupStore.markRangeTransferred(slotId: "s", from: "2026-05-25", to: "2026-05-26", bankId: testBankId)

        let dates = try RoundupStore.transferredPotDates(slotId: "s", bankId: testBankId)
        XCTAssertEqual(dates, ["2026-05-25", "2026-05-26"])
    }

    func test_transferredPotDates_emptyWhenNone() throws {
        try RoundupStore.record(slotId: "s", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        XCTAssertTrue(try RoundupStore.transferredPotDates(slotId: "s", bankId: testBankId).isEmpty)
    }

    // MARK: - deleteForSlot (P2 Slot-Löschung)

    func test_deleteForSlot_removesEntriesAndPots() throws {
        try RoundupStore.record(slotId: "a", txId: "tx-1", potDate: "2026-05-25",
                                amountCents: 50, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "a", txId: "tx-2", potDate: "2026-05-26",
                                amountCents: 60, stepCents: 100, bankId: testBankId)
        try RoundupStore.record(slotId: "b", txId: "tx-3", potDate: "2026-05-25",
                                amountCents: 70, stepCents: 100, bankId: testBankId)

        try RoundupStore.deleteForSlot(slotId: "a", bankId: testBankId)

        XCTAssertNil(try RoundupStore.pot(slotId: "a", potDate: "2026-05-25", bankId: testBankId))
        XCTAssertNil(try RoundupStore.pot(slotId: "a", potDate: "2026-05-26", bankId: testBankId))
        // anderer Slot bleibt unberührt
        XCTAssertEqual(try RoundupStore.pot(slotId: "b", potDate: "2026-05-25", bankId: testBankId)?.amountCents, 70)
    }
}
