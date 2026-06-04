import XCTest
@testable import simplebanking

final class AvailableBalanceTests: XCTestCase {

    // MARK: - Helpers

    private func tx(_ amount: Double, status: String) -> TransactionsResponse.Transaction {
        let amt = TransactionsResponse.Amount(currency: "EUR", amount: String(format: "%.2f", amount))
        let party = TransactionsResponse.Party(name: "X", iban: nil, bic: nil)
        return TransactionsResponse.Transaction(
            bookingDate: "2026-06-01",
            valueDate: "2026-06-01",
            status: status,
            endToEndId: UUID().uuidString,
            amount: amt,
            creditor: amount < 0 ? party : nil,
            debtor: amount > 0 ? party : nil,
            remittanceInformation: ["X"],
            additionalInformation: "X",
            purposeCode: nil
        )
    }

    // MARK: - compute

    func test_noPending_equalsBooked() {
        XCTAssertEqual(AvailableBalance.compute(adjustedBooked: 1000, pendingTx: []), 1000, accuracy: 0.001)
    }

    func test_onlyPendingCredits_ignored_equalsBooked() {
        let pending = [tx(250, status: "pending"), tx(80, status: "pending")]
        XCTAssertEqual(AvailableBalance.compute(adjustedBooked: 1000, pendingTx: pending), 1000, accuracy: 0.001)
    }

    func test_pendingDebits_subtracted() {
        let pending = [tx(-30, status: "pending"), tx(-12.50, status: "pending")]
        XCTAssertEqual(AvailableBalance.compute(adjustedBooked: 1000, pendingTx: pending), 957.50, accuracy: 0.001)
    }

    func test_mixedPending_onlyDebitsCount() {
        let pending = [tx(-30, status: "pending"), tx(200, status: "pending"), tx(-5, status: "pending")]
        XCTAssertEqual(AvailableBalance.compute(adjustedBooked: 1000, pendingTx: pending), 965, accuracy: 0.001)
    }

    func test_bookedDebits_ignored() {
        // Only status == "pending" counts; booked debits are already in the booked balance.
        let txs = [tx(-30, status: "booked"), tx(-15, status: "pending")]
        XCTAssertEqual(AvailableBalance.compute(adjustedBooked: 1000, pendingTx: txs), 985, accuracy: 0.001)
    }

    func test_canGoNegative_whenPendingExceedsBooked() {
        let pending = [tx(-120, status: "pending")]
        XCTAssertEqual(AvailableBalance.compute(adjustedBooked: 100, pendingTx: pending), -20, accuracy: 0.001)
    }

    func test_dispoAdjustedInputUsedDirectly() {
        // Caller passes the already-Dispo-adjusted booked value; helper does not re-adjust.
        let adjusted = BalanceAdjustment.computeAdjustedBalance(raw: 1000, apiFlag: true, userOverride: false, dispoLimit: 500)
        let pending = [tx(-50, status: "pending")]
        XCTAssertEqual(AvailableBalance.compute(adjustedBooked: adjusted, pendingTx: pending), 450, accuracy: 0.001)
    }

    // MARK: - pendingDebitSum (drives "show sub-line?" decision)

    func test_pendingDebitSum_zeroWhenNoDebits() {
        XCTAssertEqual(AvailableBalance.pendingDebitSum([tx(200, status: "pending")]), 0, accuracy: 0.001)
        XCTAssertEqual(AvailableBalance.pendingDebitSum([]), 0, accuracy: 0.001)
    }

    func test_pendingDebitSum_negativeWhenDebits() {
        XCTAssertEqual(AvailableBalance.pendingDebitSum([tx(-30, status: "pending"), tx(-5, status: "pending")]), -35, accuracy: 0.001)
    }
}
