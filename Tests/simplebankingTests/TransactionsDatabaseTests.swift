import XCTest
@testable import simplebanking

// MARK: - TransactionsDatabase Regression Tests
//
// Diese Tests laufen gegen eine isolierte `bankId`, damit die Produktions-DB
// nie berührt wird und parallel laufende Tests sich nicht stören. tearDown
// räumt die DB-Datei + WAL/SHM wieder auf.

final class TransactionsDatabaseTests: XCTestCase {

    private var testBankId: String = ""

    override func setUpWithError() throws {
        testBankId = "test-\(UUID().uuidString.lowercased().prefix(12))"
    }

    override func tearDownWithError() throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: testBankId)
    }

    // MARK: - markAllRead(slotIds:)

    /// Regression: `markAllRead(slotIds: [...])` darf nur Buchungen in den
    /// angegebenen Slots als gelesen markieren. Der „Alle gelesen"-Footer in
    /// der Single-Account-Ansicht darf keine Buchungen anderer Slots berühren.
    func test_regression_markAllRead_limitedToSlotIds_doesNotTouchOtherSlots() throws {
        let txA = makeTx(endToEndId: "ete-a", merchant: "MerchantA", amount: -10.0)
        let txB = makeTx(endToEndId: "ete-b", merchant: "MerchantB", amount: -20.0)
        let fpA = TransactionRecord.fingerprint(for: txA)
        let fpB = TransactionRecord.fingerprint(for: txB)

        TransactionsDatabase.activeSlotId = "slot-a"
        try TransactionsDatabase.upsert(transactions: [txA], bankId: testBankId)

        TransactionsDatabase.activeSlotId = "slot-b"
        try TransactionsDatabase.upsert(transactions: [txB], bankId: testBankId)

        // Sanity: beide Tx sind nach upsert als unread markiert.
        let before = try TransactionsDatabase.loadEnrichmentData(bankId: testBankId)
        XCTAssertEqual(before[TxEnrichmentKey.make(slotId: "slot-a", txID: fpA)]?.isUnread, true)
        XCTAssertEqual(before[TxEnrichmentKey.make(slotId: "slot-b", txID: fpB)]?.isUnread, true)

        // Akt: nur Slot A gelesen markieren.
        try TransactionsDatabase.markAllRead(bankId: testBankId, slotIds: ["slot-a"])

        let after = try TransactionsDatabase.loadEnrichmentData(bankId: testBankId)
        XCTAssertNil(after[TxEnrichmentKey.make(slotId: "slot-a", txID: fpA)],
            "Slot A muss nach markAllRead(slotIds: [slot-a]) aus Enrichment verschwinden (is_unread=0, keine Notes).")
        XCTAssertEqual(after[TxEnrichmentKey.make(slotId: "slot-b", txID: fpB)]?.isUnread, true,
            "Slot B darf vom Slot-A-Filter nicht beeinflusst werden.")
    }

    // MARK: - Enrichment-Key (Composite (slot_id, tx_id))

    /// Regression: gleiche `tx_id` in verschiedenen Slots muss getrennte
    /// Enrichment-Keys ergeben. Vor Migration v19 hätte das slot-übergreifend
    /// gemischt — Reminder/Notes eines Kontos wären auf ein anderes Konto
    /// übergelaufen.
    func test_regression_loadEnrichmentData_sameTxIdDifferentSlots_keysSeparately() throws {
        // Identische Eingaben → identischer `fingerprint` → gleicher tx_id,
        // in zwei verschiedenen Slots eingetragen.
        let tx = makeTx(endToEndId: "ete-shared-42", merchant: "SharedMerchant", amount: -99.0)
        let sharedId = TransactionRecord.fingerprint(for: tx)

        TransactionsDatabase.activeSlotId = "slot-a"
        try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)

        TransactionsDatabase.activeSlotId = "slot-b"
        try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)

        // Unterschiedliche Enrichment-Profile pro Slot setzen:
        //  Slot A: Reminder gesetzt, als read markiert
        //  Slot B: kein Reminder, unread bleibt
        try TransactionsDatabase.setReminderId(
            txID: sharedId, slotId: "slot-a", bankId: testBankId, reminderId: "ek-reminder-A"
        )
        try TransactionsDatabase.setUnread(
            txID: sharedId, slotId: "slot-a", bankId: testBankId, value: false
        )

        let enrichment = try TransactionsDatabase.loadEnrichmentData(bankId: testBankId)

        let keyA = TxEnrichmentKey.make(slotId: "slot-a", txID: sharedId)
        let keyB = TxEnrichmentKey.make(slotId: "slot-b", txID: sharedId)

        XCTAssertNotEqual(keyA, keyB,
            "Enrichment-Keys müssen slot-disjunkt sein.")
        XCTAssertEqual(enrichment[keyA]?.reminderId, "ek-reminder-A",
            "Slot A muss den gesetzten Reminder behalten.")
        XCTAssertEqual(enrichment[keyA]?.isUnread, false,
            "Slot A wurde explizit auf read gesetzt.")
        XCTAssertEqual(enrichment[keyB]?.isUnread, true,
            "Slot B darf von der Slot-A-Manipulation unberührt bleiben.")
        XCTAssertNil(enrichment[keyB]?.reminderId,
            "Slot B darf den Reminder von Slot A NICHT bekommen — sonst würde Composite-PK-Semantik brechen.")
    }

    // MARK: - Helpers

    private func makeTx(endToEndId: String, merchant: String, amount: Double)
        -> TransactionsResponse.Transaction
    {
        let amt = TransactionsResponse.Amount(
            currency: "EUR",
            amount: String(format: "%.2f", amount)
        )
        let party = TransactionsResponse.Party(name: merchant, iban: nil, bic: nil)
        return TransactionsResponse.Transaction(
            bookingDate: "2026-04-01",
            valueDate: "2026-04-01",
            status: "booked",
            endToEndId: endToEndId,
            amount: amt,
            creditor: amount < 0 ? party : nil,
            debtor:  amount > 0 ? party : nil,
            remittanceInformation: [merchant],
            additionalInformation: merchant,
            purposeCode: nil
        )
    }
}
