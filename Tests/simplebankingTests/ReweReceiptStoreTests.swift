import XCTest
@testable import simplebanking

final class ReweReceiptStoreTests: XCTestCase {
    let bank = "test-rewe"
    let slot = "slot-rewe-1"

    override func setUpWithError() throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: bank)
        try TransactionsDatabase.migrate(bankId: bank)
    }
    override func tearDownWithError() throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: bank)
    }

    private func receipt(_ id: String, total: Int, ts: String,
                         items: [ReweLineItem] = [], parsed: Bool = false) -> ReweReceipt {
        ReweReceipt(slotId: slot, receiptId: id, timestamp: ts, totalCents: total,
                    marketName: "REWE Markt", marketCity: "Siegen", cancelled: false,
                    items: items, parsed: parsed, fetchedAt: "2026-06-16T10:00:00Z")
    }

    func test_upsertAndFetch_orderedByTimestampDesc() throws {
        try ReweReceiptStore.upsert([
            receipt("a", total: 1000, ts: "2026-06-10T09:00:00Z"),
            receipt("b", total: 2000, ts: "2026-06-13T09:00:00Z"),
        ], bankId: bank)
        XCTAssertEqual(try ReweReceiptStore.all(slotId: slot, bankId: bank).map(\.receiptId), ["b", "a"])
        XCTAssertEqual(try ReweReceiptStore.latest(slotId: slot, bankId: bank)?.receiptId, "b")
    }

    func test_reSyncListDoesNotWipeParsedItems() throws {
        let items = [ReweLineItem(name: "APFEL", quantity: nil, totalCents: 100, taxCategory: "B")]
        try ReweReceiptStore.upsert([receipt("a", total: 100, ts: "2026-06-10T09:00:00Z",
                                             items: items, parsed: true)], bankId: bank)
        // Erneuter Listen-Sync ohne Items (parsed=false) darf die Items NICHT löschen.
        try ReweReceiptStore.upsert([receipt("a", total: 100, ts: "2026-06-10T09:00:00Z")], bankId: bank)
        let stored = try ReweReceiptStore.all(slotId: slot, bankId: bank).first
        XCTAssertEqual(stored?.items.count, 1)
        XCTAssertEqual(stored?.parsed, true)
        XCTAssertEqual(try ReweReceiptStore.parsedIds(slotId: slot, bankId: bank), Set(["a"]))
    }

    func test_itemsRoundTripThroughJSON() throws {
        let items = [
            ReweLineItem(name: "NEKTARINE GELB", quantity: "0,530 kg x 3,99 EUR/kg", totalCents: 211, taxCategory: "B"),
            ReweLineItem(name: "PFAND 0,25 EURO", quantity: "2 Stk x 0,25", totalCents: 50, taxCategory: "A"),
        ]
        try ReweReceiptStore.upsert([receipt("a", total: 261, ts: "2026-06-10T09:00:00Z",
                                             items: items, parsed: true)], bankId: bank)
        let back = try ReweReceiptStore.all(slotId: slot, bankId: bank).first
        XCTAssertEqual(back?.items, items)
        XCTAssertEqual(back?.itemsSumCents, 261)
    }

    func test_monthTotal_excludesOtherMonthsAndCancelled() throws {
        var cancelled = receipt("c1", total: 5000, ts: "2026-06-15T09:00:00Z")
        cancelled.cancelled = true
        try ReweReceiptStore.upsert([
            receipt("j1", total: 1500, ts: "2026-06-03T09:00:00Z"),
            receipt("j2", total: 2500, ts: "2026-06-20T09:00:00Z"),
            receipt("m1", total: 9999, ts: "2026-05-30T09:00:00Z"),
            cancelled,
        ], bankId: bank)
        XCTAssertEqual(try ReweReceiptStore.monthTotalCents(slotId: slot, yearMonth: "2026-06", bankId: bank), 4000)
    }
}
