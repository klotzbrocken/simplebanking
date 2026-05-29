import XCTest
@testable import simplebanking

// MARK: - Roundup-Hook in TransactionsDatabase.upsert
//
// Integration-Tests gegen den realen upsert(...) und RoundupStore, isoliert über
// eigene `bankId` (DB-File) + eigener `slotId` (UserDefaults-Settings-Scope).
// Income, Non-EUR, Pending, und Re-Inserts dürfen keinen Pot füllen.

@MainActor
final class RoundupHookTests: XCTestCase {

    private var testBankId: String = ""
    private var testSlotId: String = ""

    override func setUpWithError() throws {
        testBankId = "test-roundup-hook-\(UUID().uuidString.lowercased().prefix(12))"
        testSlotId = "slot-rh-\(UUID().uuidString.lowercased().prefix(8))"
        TransactionsDatabase.activeSlotId = testSlotId
        try TransactionsDatabase.migrate(bankId: testBankId)
    }

    override func tearDownWithError() throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: testBankId)
        UserDefaults.standard.removeObject(forKey: "simplebanking.slotSettings.\(testSlotId)")
    }

    private func enableRoundup(stepCents: Int = 100) {
        var s = BankSlotSettingsStore.load(slotId: testSlotId)
        s.roundupEnabled = true
        s.roundupStepCents = stepCents
        BankSlotSettingsStore.save(s, slotId: testSlotId)
    }

    private func makeTx(
        endToEndId: String,
        merchant: String,
        amount: Double,
        status: String = "booked",
        currency: String = "EUR",
        bookingDate: String = "2026-05-27"
    ) -> TransactionsResponse.Transaction {
        let amt = TransactionsResponse.Amount(currency: currency, amount: String(format: "%.2f", amount))
        let party = TransactionsResponse.Party(name: merchant, iban: nil, bic: nil)
        return TransactionsResponse.Transaction(
            bookingDate: bookingDate,
            valueDate: bookingDate,
            status: status,
            endToEndId: endToEndId,
            amount: amt,
            creditor: amount < 0 ? party : nil,
            debtor:  amount > 0 ? party : nil,
            remittanceInformation: [merchant],
            additionalInformation: merchant,
            purposeCode: nil
        )
    }

    // MARK: - Master toggle

    func test_roundupDisabled_noPotCreated() throws {
        // Default ist disabled — nichts zu setzen.
        let tx = makeTx(endToEndId: "e2e-1", merchant: "Bakery", amount: -3.47)
        try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)

        XCTAssertNil(try RoundupStore.pot(slotId: testSlotId, potDate: "2026-05-27", bankId: testBankId))
    }

    // MARK: - Booked EUR expense

    func test_roundupEnabled_bookedEurExpense_fillsPot() throws {
        enableRoundup()
        let tx = makeTx(endToEndId: "e2e-1", merchant: "Bakery", amount: -3.47)
        try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)

        let pot = try RoundupStore.pot(slotId: testSlotId, potDate: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(pot?.amountCents, 53)
        XCTAssertEqual(pot?.entryCount, 1)
        XCTAssertEqual(pot?.status, .open)
    }

    func test_roundupEnabled_multipleBookedExpenses_aggregate() throws {
        enableRoundup()
        let txs = [
            makeTx(endToEndId: "e2e-1", merchant: "Bakery", amount: -3.47),  // 53 ct
            makeTx(endToEndId: "e2e-2", merchant: "Cafe",   amount: -2.10),  // 90 ct
            makeTx(endToEndId: "e2e-3", merchant: "Shop",   amount: -7.00)   // 0 ct (boundary)
        ]
        try TransactionsDatabase.upsert(transactions: txs, bankId: testBankId)

        let pot = try RoundupStore.pot(slotId: testSlotId, potDate: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(pot?.amountCents, 143, "53 + 90, boundary-Buchung trägt 0 bei.")
        XCTAssertEqual(pot?.entryCount, 2, "Boundary-TRX schreibt keinen Roundup-Entry.")
    }

    // MARK: - Skip rules

    func test_pendingTrx_doesNotFillPot() throws {
        enableRoundup()
        let tx = makeTx(endToEndId: "e2e-1", merchant: "Bakery", amount: -3.47, status: "pending")
        try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)

        XCTAssertNil(try RoundupStore.pot(slotId: testSlotId, potDate: "2026-05-27", bankId: testBankId))
    }

    func test_incomeTrx_doesNotFillPot() throws {
        enableRoundup()
        let tx = makeTx(endToEndId: "e2e-salary", merchant: "Employer", amount: 2_500.00)
        try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)

        XCTAssertNil(try RoundupStore.pot(slotId: testSlotId, potDate: "2026-05-27", bankId: testBankId))
    }

    func test_nonEurTrx_doesNotFillPot() throws {
        enableRoundup()
        let tx = makeTx(endToEndId: "e2e-usd", merchant: "Hotel USA", amount: -47.50, currency: "USD")
        try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)

        XCTAssertNil(try RoundupStore.pot(slotId: testSlotId, potDate: "2026-05-27", bankId: testBankId))
    }

    // MARK: - Re-Fetch / Pending→Booked

    func test_refetchSameBookedTrx_doesNotDoubleCount() throws {
        enableRoundup()
        let tx = makeTx(endToEndId: "e2e-1", merchant: "Bakery", amount: -3.47)
        try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)
        try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)
        try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)

        let pot = try RoundupStore.pot(slotId: testSlotId, potDate: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(pot?.amountCents, 53)
        XCTAssertEqual(pot?.entryCount, 1)
    }

    func test_pendingThenBooked_potFillsExactlyOnceOnBookedTransition() throws {
        enableRoundup()
        let pending = makeTx(endToEndId: "e2e-1", merchant: "Bakery", amount: -3.47, status: "pending")
        try TransactionsDatabase.upsert(transactions: [pending], bankId: testBankId)
        XCTAssertNil(try RoundupStore.pot(slotId: testSlotId, potDate: "2026-05-27", bankId: testBankId),
                     "pending darf noch keinen Pot füllen.")

        let booked = makeTx(endToEndId: "e2e-1", merchant: "Bakery", amount: -3.47, status: "booked")
        try TransactionsDatabase.upsert(transactions: [booked], bankId: testBankId)

        let pot = try RoundupStore.pot(slotId: testSlotId, potDate: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(pot?.amountCents, 53, "Pot füllt sich erst beim pending→booked-Übergang.")

        // Erneuter Booked-Refresh: nichts ändert sich.
        try TransactionsDatabase.upsert(transactions: [booked], bankId: testBankId)
        let after = try RoundupStore.pot(slotId: testSlotId, potDate: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(after?.amountCents, 53)
        XCTAssertEqual(after?.entryCount, 1)
    }

    // MARK: - Step size

    func test_stepSize500_aggregatesAccordingly() throws {
        enableRoundup(stepCents: 500)
        let tx = makeTx(endToEndId: "e2e-1", merchant: "Bakery", amount: -3.47)
        try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)

        let pot = try RoundupStore.pot(slotId: testSlotId, potDate: "2026-05-27", bankId: testBankId)
        XCTAssertEqual(pot?.amountCents, 153, "5 €-Step: 3.47 → next mult of 5.00 → 1.53 € = 153 ct.")
    }
}
