import XCTest
@testable import simplebanking

// MARK: - MMI Slot-Scope + reine Komponenten-Berechnung
//
// Deckt zwei Fixes ab:
//  • #9 — `savingsKey` ist (slotId, fingerprint)-skaliert: identische Buchungen in
//    verschiedenen Slots dürfen sich im Unified-Modus NICHT gegenseitig taggen.
//  • #10 — `computeComponents` ist `nonisolated static` und rein (off-main aufrufbar).

final class MMISavingsSlotScopeTests: XCTestCase {

    private func tx(_ amount: Double, slot: String?, creditor: String = "Sparkonto",
                    e2e: String = "E") -> TransactionsResponse.Transaction {
        let amt = TransactionsResponse.Amount(currency: "EUR", amount: String(format: "%.2f", amount))
        var t = TransactionsResponse.Transaction(
            bookingDate: "2026-06-01", valueDate: "2026-06-01", status: "booked",
            endToEndId: e2e, amount: amt,
            creditor: TransactionsResponse.Party(name: creditor, iban: nil, bic: nil),
            debtor: nil, remittanceInformation: nil, additionalInformation: nil, purposeCode: nil
        )
        t.slotId = slot
        return t
    }

    func test_savingsKey_differsBySlot() {
        let a = tx(-100, slot: "slotA")
        let b = tx(-100, slot: "slotB")   // identische Buchung, anderer Slot
        XCTAssertNotEqual(MMIViewModel.savingsKey(for: a), MMIViewModel.savingsKey(for: b))
    }

    func test_savingsKey_sameSlot_sameKey() {
        let a = tx(-100, slot: "slotA")
        let b = tx(-100, slot: "slotA")
        XCTAssertEqual(MMIViewModel.savingsKey(for: a), MMIViewModel.savingsKey(for: b))
    }

    func test_computeComponents_pureIncomeAndExpenses() {
        let income  = tx(1000, slot: "slotA", creditor: "Arbeitgeber", e2e: "IN")
        let expense = tx(-50,  slot: "slotA", creditor: "REWE", e2e: "EX")
        let c = MMIViewModel.computeComponents(
            transactions: [income, expense], balance: 500, period: .max)
        XCTAssertEqual(c.income, 1000, accuracy: 0.001)
        XCTAssertEqual(c.expenses, 50, accuracy: 0.001)
        XCTAssertEqual(c.balance, 500, accuracy: 0.001)
    }
}
