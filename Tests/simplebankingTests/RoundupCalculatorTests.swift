import XCTest
@testable import simplebanking

final class RoundupCalculatorTests: XCTestCase {

    // MARK: - Guard clauses

    func test_income_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: 100, stepCents: 100), 0)
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "0.01")!, stepCents: 100), 0)
    }

    func test_zero_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: 0, stepCents: 100), 0)
    }

    func test_invalidStep_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: -3.47, stepCents: 0), 0)
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: -3.47, stepCents: -100), 0)
    }

    // MARK: - 1 € step

    func test_step100_normal() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-3.47")!, stepCents: 100), 53)
    }

    func test_step100_exactBoundary_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-5.00")!, stepCents: 100), 0)
    }

    func test_step100_oneCentBelowBoundary() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-4.99")!, stepCents: 100), 1)
    }

    func test_step100_smallAmount() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-0.01")!, stepCents: 100), 99)
    }

    // MARK: - 2 € step

    func test_step200_normal() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-3.47")!, stepCents: 200), 53)
    }

    func test_step200_exactBoundary_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-2.00")!, stepCents: 200), 0)
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-4.00")!, stepCents: 200), 0)
    }

    func test_step200_oddEuroDifference() {
        // 1.50 € → next mult of 2.00 → diff 0.50 = 50 ct
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-1.50")!, stepCents: 200), 50)
    }

    // MARK: - 5 € step

    func test_step500_normal() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-3.47")!, stepCents: 500), 153)
    }

    func test_step500_exactBoundary_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-5.00")!, stepCents: 500), 0)
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-10.00")!, stepCents: 500), 0)
    }

    // MARK: - 10 € step

    func test_step1000_normal() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-3.47")!, stepCents: 1000), 653)
    }

    func test_step1000_exactBoundary_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-10.00")!, stepCents: 1000), 0)
    }

    func test_step1000_largeAmount() {
        // -127.83 € → 12783 ct → 12783 % 1000 = 783 → diff 217 ct
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-127.83")!, stepCents: 1000), 217)
    }

    // MARK: - Decimal precision

    func test_decimalFromString_isExact() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-0.30")!, stepCents: 100), 70)
    }

    func test_amountFromDouble_stableForTypicalBankValues() {
        // Bank-API delivers prices like -19.95 — Decimal init from Double introduces
        // a tiny error, but NSDecimalRound(.plain) snaps it back to 1995 ct.
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(-19.95), stepCents: 100), 5)
    }

    // MARK: - displayedAmount (Aufrunden-View-Lens)

    func test_displayedAmount_eurExpense_step100() {
        XCTAssertEqual(
            RoundupCalculator.displayedAmount(originalAmount: Decimal(string: "-3.47")!, currency: "EUR", stepCents: 100),
            Decimal(string: "-4.00")!
        )
    }

    func test_displayedAmount_eurExpense_step500() {
        XCTAssertEqual(
            RoundupCalculator.displayedAmount(originalAmount: Decimal(string: "-3.47")!, currency: "EUR", stepCents: 500),
            Decimal(string: "-5.00")!
        )
    }

    func test_displayedAmount_eurExpense_step1000() {
        XCTAssertEqual(
            RoundupCalculator.displayedAmount(originalAmount: Decimal(string: "-127.83")!, currency: "EUR", stepCents: 1000),
            Decimal(string: "-130.00")!
        )
    }

    func test_displayedAmount_boundary_returnsOriginal() {
        // -5.00 € bei 1 €-Step ist exakte Boundary → kein Roundup → Original bleibt.
        XCTAssertEqual(
            RoundupCalculator.displayedAmount(originalAmount: Decimal(string: "-5.00")!, currency: "EUR", stepCents: 100),
            Decimal(string: "-5.00")!
        )
    }

    func test_displayedAmount_income_returnsOriginal() {
        XCTAssertEqual(
            RoundupCalculator.displayedAmount(originalAmount: Decimal(string: "2500.00")!, currency: "EUR", stepCents: 100),
            Decimal(string: "2500.00")!
        )
    }

    func test_displayedAmount_nonEur_returnsOriginal() {
        XCTAssertEqual(
            RoundupCalculator.displayedAmount(originalAmount: Decimal(string: "-3.47")!, currency: "USD", stepCents: 100),
            Decimal(string: "-3.47")!
        )
    }

    func test_displayedAmount_invalidStep_returnsOriginal() {
        XCTAssertEqual(
            RoundupCalculator.displayedAmount(originalAmount: Decimal(string: "-3.47")!, currency: "EUR", stepCents: 0),
            Decimal(string: "-3.47")!
        )
    }

    func test_displayedAmount_eurLowercased_normalized() {
        // Currency wird case-insensitive geprüft.
        XCTAssertEqual(
            RoundupCalculator.displayedAmount(originalAmount: Decimal(string: "-3.47")!, currency: "eur", stepCents: 100),
            Decimal(string: "-4.00")!
        )
    }

    // MARK: - liveRoundupCents (Live-Sicht im Banner)

    private func makeTx(date: String, amount: String, status: String = "booked", currency: String = "EUR") -> TransactionsResponse.Transaction {
        let amt = TransactionsResponse.Amount(currency: currency, amount: amount)
        return TransactionsResponse.Transaction(
            bookingDate: date,
            valueDate: date,
            status: status,
            endToEndId: "\(date)-\(amount)",
            amount: amt,
            creditor: nil, debtor: nil,
            remittanceInformation: nil,
            additionalInformation: nil,
            purposeCode: nil
        )
    }

    func test_liveRoundupCents_singleDay_step100() {
        let txs = [
            makeTx(date: "2026-05-30", amount: "-3.47"),  // → 53 ct
            makeTx(date: "2026-05-30", amount: "-2.10"),  // → 90 ct
        ]
        XCTAssertEqual(
            RoundupCalculator.liveRoundupCents(transactions: txs, bookingDateFrom: "2026-05-30", bookingDateTo: "2026-05-30", stepCents: 100),
            143
        )
    }

    func test_liveRoundupCents_stepChangeChangesResult() {
        // Selbe TRX, anderer Step → andere Summe (Live-Sicht-Effekt).
        let txs = [makeTx(date: "2026-05-30", amount: "-3.47")]
        XCTAssertEqual(
            RoundupCalculator.liveRoundupCents(transactions: txs, bookingDateFrom: "2026-05-30", bookingDateTo: "2026-05-30", stepCents: 100),
            53
        )
        XCTAssertEqual(
            RoundupCalculator.liveRoundupCents(transactions: txs, bookingDateFrom: "2026-05-30", bookingDateTo: "2026-05-30", stepCents: 500),
            153
        )
        XCTAssertEqual(
            RoundupCalculator.liveRoundupCents(transactions: txs, bookingDateFrom: "2026-05-30", bookingDateTo: "2026-05-30", stepCents: 1000),
            653
        )
    }

    func test_liveRoundupCents_skipsOutOfRange() {
        let txs = [
            makeTx(date: "2026-05-29", amount: "-3.47"),  // außerhalb → skip
            makeTx(date: "2026-05-30", amount: "-3.47"),  // 53 ct
            makeTx(date: "2026-05-31", amount: "-3.47"),  // außerhalb → skip
        ]
        XCTAssertEqual(
            RoundupCalculator.liveRoundupCents(transactions: txs, bookingDateFrom: "2026-05-30", bookingDateTo: "2026-05-30", stepCents: 100),
            53
        )
    }

    func test_liveRoundupCents_skipsPendingIncomeNonEur() {
        let txs = [
            makeTx(date: "2026-05-30", amount: "-3.47", status: "pending"),   // pending → skip
            makeTx(date: "2026-05-30", amount: "2500.00"),                     // income → skip
            makeTx(date: "2026-05-30", amount: "-3.47", currency: "USD"),     // USD → skip
            makeTx(date: "2026-05-30", amount: "-3.47"),                       // booked EUR expense → 53 ct
        ]
        XCTAssertEqual(
            RoundupCalculator.liveRoundupCents(transactions: txs, bookingDateFrom: "2026-05-30", bookingDateTo: "2026-05-30", stepCents: 100),
            53
        )
    }

    func test_liveRoundupCents_monthRange_sumsAcrossDays() {
        let txs = [
            makeTx(date: "2026-05-01", amount: "-3.47"),   // 53
            makeTx(date: "2026-05-15", amount: "-7.20"),   // 80
            makeTx(date: "2026-05-30", amount: "-1.05"),   // 95
        ]
        XCTAssertEqual(
            RoundupCalculator.liveRoundupCents(transactions: txs, bookingDateFrom: "2026-05-01", bookingDateTo: "2026-05-31", stepCents: 100),
            228
        )
    }
}
