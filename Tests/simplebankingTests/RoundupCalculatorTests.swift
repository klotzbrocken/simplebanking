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

    // MARK: - liveStreakDays

    private static let SAVINGS_IBAN = "DE83460500010001808336"

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comp = DateComponents()
        comp.year = y; comp.month = m; comp.day = d; comp.hour = 12
        return Calendar(identifier: .gregorian).date(from: comp)!
    }

    /// Helper für eine Outgoing-TRX an Sparkonto-IBAN mit explizitem creditor.
    private func makeSavingsTx(date: String, amount: String) -> TransactionsResponse.Transaction {
        let amt = TransactionsResponse.Amount(currency: "EUR", amount: amount)
        let party = TransactionsResponse.Party(name: "Sparkonto", iban: Self.SAVINGS_IBAN, bic: nil)
        return TransactionsResponse.Transaction(
            bookingDate: date, valueDate: date, status: "booked",
            endToEndId: "savings-\(date)-\(amount)", amount: amt,
            creditor: party, debtor: nil,
            remittanceInformation: nil, additionalInformation: nil, purposeCode: nil
        )
    }

    func test_liveStreakDays_noSavingsTx_returnsZero() {
        // Nur Aufrundungs-Beiträge, keine Überweisung an Sparkonto → 0.
        let txs = [
            makeTx(date: "2026-06-01", amount: "-3.47"),
            makeTx(date: "2026-05-31", amount: "-3.47")
        ]
        let n = RoundupCalculator.liveStreakDays(
            transactions: txs,
            savingsIban: Self.SAVINGS_IBAN,
            today: date(2026, 6, 1),
            stepCents: 100
        )
        XCTAssertEqual(n, 0, "Aufrundungs-Beiträge allein zählen nicht — Überweisung fehlt.")
    }

    func test_liveStreakDays_matchingSavingsTx_counts() {
        // -3,47 € → 53ct roundup. Outgoing an Sparkonto = 0,53 €.
        let txs = [
            makeTx(date: "2026-06-01", amount: "-3.47"),
            makeSavingsTx(date: "2026-06-01", amount: "-0.53"),
            makeTx(date: "2026-05-31", amount: "-3.47"),
            makeSavingsTx(date: "2026-05-31", amount: "-0.53")
        ]
        let n = RoundupCalculator.liveStreakDays(
            transactions: txs,
            savingsIban: Self.SAVINGS_IBAN,
            today: date(2026, 6, 1),
            stepCents: 100
        )
        XCTAssertEqual(n, 2)
    }

    func test_liveStreakDays_amountMismatchBreaksStreak() {
        // Heute matched, gestern hat Overshoot (1 €) → Bruch.
        let txs = [
            makeTx(date: "2026-06-01", amount: "-3.47"),
            makeSavingsTx(date: "2026-06-01", amount: "-0.53"),
            makeTx(date: "2026-05-31", amount: "-3.47"),
            makeSavingsTx(date: "2026-05-31", amount: "-1.00")  // != 0.53 → kein match
        ]
        let n = RoundupCalculator.liveStreakDays(
            transactions: txs,
            savingsIban: Self.SAVINGS_IBAN,
            today: date(2026, 6, 1),
            stepCents: 100
        )
        XCTAssertEqual(n, 1, "Heute zählt, 31.05. mismatch → Bruch nach 1.")
    }

    func test_liveStreakDays_toleranceFiveCent() {
        // Outgoing 0,55 € statt 0,53 € → 2ct Abweichung, innerhalb 5ct Toleranz.
        let txs = [
            makeTx(date: "2026-06-01", amount: "-3.47"),
            makeSavingsTx(date: "2026-06-01", amount: "-0.55")
        ]
        let n = RoundupCalculator.liveStreakDays(
            transactions: txs,
            savingsIban: Self.SAVINGS_IBAN,
            today: date(2026, 6, 1),
            stepCents: 100
        )
        XCTAssertEqual(n, 1, "2ct Abweichung liegt innerhalb der 5ct Toleranz.")
    }

    func test_liveStreakDays_todayNoMatch_returnsZero() {
        // Heute keine Sparkonto-TRX, gestern matched. Streak = 0 (heute fehlt).
        let txs = [
            makeTx(date: "2026-06-01", amount: "-3.47"),
            makeTx(date: "2026-05-31", amount: "-3.47"),
            makeSavingsTx(date: "2026-05-31", amount: "-0.53")
        ]
        let n = RoundupCalculator.liveStreakDays(
            transactions: txs,
            savingsIban: Self.SAVINGS_IBAN,
            today: date(2026, 6, 1),
            stepCents: 100
        )
        XCTAssertEqual(n, 0, "Heute ohne match → Streak = 0.")
    }

    func test_liveStreakDays_emptySavingsIban_returnsZero() {
        let txs = [makeTx(date: "2026-06-01", amount: "-3.47")]
        let n = RoundupCalculator.liveStreakDays(
            transactions: txs,
            savingsIban: "",
            today: date(2026, 6, 1),
            stepCents: 100
        )
        XCTAssertEqual(n, 0)
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

    // MARK: - excludingDates (P1: bereits ausgezahlte Tage ausblenden)

    func test_liveRoundupCents_excludesTransferredDays() {
        let txs = [
            makeTx(date: "2026-05-01", amount: "-3.47"),   // 53
            makeTx(date: "2026-05-15", amount: "-7.20"),   // 80
            makeTx(date: "2026-05-30", amount: "-1.05"),   // 95
        ]
        // 2026-05-15 bereits ausgezahlt → fällt aus der Summe (228 - 80 = 148)
        XCTAssertEqual(
            RoundupCalculator.liveRoundupCents(
                transactions: txs, bookingDateFrom: "2026-05-01", bookingDateTo: "2026-05-31",
                stepCents: 100, excludingDates: ["2026-05-15"]
            ),
            148
        )
    }

    func test_liveRoundupCents_emptyExclusion_matchesDefault() {
        let txs = [makeTx(date: "2026-05-30", amount: "-3.47")]
        XCTAssertEqual(
            RoundupCalculator.liveRoundupCents(
                transactions: txs, bookingDateFrom: "2026-05-30", bookingDateTo: "2026-05-30",
                stepCents: 100, excludingDates: []
            ),
            53
        )
    }

    func test_liveRoundupCents_allDaysExcluded_returnsZero() {
        let txs = [makeTx(date: "2026-05-30", amount: "-3.47")]
        XCTAssertEqual(
            RoundupCalculator.liveRoundupCents(
                transactions: txs, bookingDateFrom: "2026-05-30", bookingDateTo: "2026-05-30",
                stepCents: 100, excludingDates: ["2026-05-30"]
            ),
            0
        )
    }
}
