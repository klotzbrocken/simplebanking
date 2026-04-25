import XCTest
@testable import simplebanking

// MARK: - AttentionInboxDetector Tests
//
// These tests exercise the REAL production code in AttentionInboxDetector.swift
// and SalaryProgressCalculator via `@testable import simplebanking`.
//
// Previously this file contained mirror implementations (copy-pasted algorithms)
// because SPM executable targets couldn't be imported. That generated false-green
// tests whenever production drifted from the mirror. Example found during the
// migration: the three-Netflix-payments duplicate test passed against the mirror
// but would have failed against production (known-subscription filter at
// AttentionInboxDetector.swift:165-166 excludes known subs under €30).
//
// If you need date injection for new tests, prefer adding a `now: Date = Date()`
// default parameter to the production function (see detectSalaryMissing).

final class AttentionInboxDetectorTests: XCTestCase {

    // MARK: - salaryMissing (real API via injected `now` parameter)

    /// salaryDay=1, tolerance=2 → deadline = 1st + 2 + 2 = 5th
    /// today = 8th → overdue and no income → card fires
    func test_salaryMissing_overdueByMoreThanTwoTolerance_fires() {
        let today = makeDate(year: 2026, month: 4, day: 8)
        let cards = AttentionInboxDetector.detectSalaryMissing(
            recent: [], salaryDay: 1, toleranceBefore: 0, toleranceAfter: 2, now: today
        )
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.type, .salaryMissing)
    }

    /// today exactly at deadline (toleranceAfter+2 days after) → not strictly past → no card
    func test_salaryMissing_exactlyAtDeadline_doesNotFire() {
        let today = makeDate(year: 2026, month: 4, day: 5)
        let cards = AttentionInboxDetector.detectSalaryMissing(
            recent: [], salaryDay: 1, toleranceBefore: 0, toleranceAfter: 2, now: today
        )
        XCTAssertTrue(cards.isEmpty)
    }

    /// salary within grace period (same month, toleranceAfter not yet expired) → no card
    func test_salaryMissing_withinGracePeriod_doesNotFire() {
        let today = makeDate(year: 2026, month: 4, day: 2)
        let cards = AttentionInboxDetector.detectSalaryMissing(
            recent: [], salaryDay: 1, toleranceBefore: 0, toleranceAfter: 1, now: today
        )
        XCTAssertTrue(cards.isEmpty)
    }

    /// Cross-month: salary day=25, today=April 10 → prev-month deadline March 30 → fires
    func test_salaryMissing_previousMonthOverdue_fires() {
        let today = makeDate(year: 2026, month: 4, day: 10)
        let cards = AttentionInboxDetector.detectSalaryMissing(
            recent: [], salaryDay: 25, toleranceBefore: 0, toleranceAfter: 3, now: today
        )
        XCTAssertEqual(cards.count, 1,
            "April 10 is past March 30 deadline for March 25 salary")
    }

    /// salaryDay=0 (not configured) → never fires
    func test_salaryMissing_salaryDayZero_doesNotFire() {
        let today = makeDate(year: 2026, month: 4, day: 20)
        let cards = AttentionInboxDetector.detectSalaryMissing(
            recent: [], salaryDay: 0, toleranceBefore: 0, toleranceAfter: 0, now: today
        )
        XCTAssertTrue(cards.isEmpty)
    }

    /// Cross-month: salary day=30, today=May 3 → last due April 30, deadline May 2 → fires
    func test_salaryMissing_crossMonthBoundary_fires() {
        let today = makeDate(year: 2026, month: 5, day: 3)
        let cards = AttentionInboxDetector.detectSalaryMissing(
            recent: [], salaryDay: 30, toleranceBefore: 0, toleranceAfter: 0, now: today
        )
        XCTAssertEqual(cards.count, 1,
            "Cross-month: April salary missed, today May 3 should fire")
    }

    /// Cross-month: salary day=30, today=May 2 = exactly at deadline → no card
    func test_salaryMissing_crossMonthBoundary_exactlyAtDeadline_doesNotFire() {
        let today = makeDate(year: 2026, month: 5, day: 2)
        let cards = AttentionInboxDetector.detectSalaryMissing(
            recent: [], salaryDay: 30, toleranceBefore: 0, toleranceAfter: 0, now: today
        )
        XCTAssertTrue(cards.isEmpty)
    }

    /// salaryDay=31 in a 30-day month → clamped to 30th
    /// deadline = 30 + 1 + 2 = 2nd May; today = May 1 → not yet past
    func test_salaryMissing_salaryDayClampsToMonthEnd() {
        let today = makeDate(year: 2026, month: 5, day: 1)
        let cards = AttentionInboxDetector.detectSalaryMissing(
            recent: [], salaryDay: 31, toleranceBefore: 0, toleranceAfter: 1, now: today
        )
        XCTAssertTrue(cards.isEmpty)
    }

    /// Asymmetrische Toleranzen: Gehaltstag 1., Gehalt kam bereits am 28. (4 d vor).
    /// toleranceBefore=4, toleranceAfter=1. Heute ist der 5. → Grace-Period abgelaufen
    /// (1 + 2 = 3 Tage), aber detectedIncome mit before=4 muss den 28. noch im Fenster
    /// sehen → Karte darf NICHT feuern. Regressionstest gegen den Fall, wo ein einzelner
    /// Toleranzwert genutzt wird.
    func test_salaryMissing_earlySalaryWithinBeforeWindow_doesNotFire() {
        let today = makeDate(year: 2026, month: 4, day: 5)
        // Gehalt am 28. März (4 Tage vor dem 1. April)
        let earlySalary = makeTx(
            bookingDate: "2026-03-28", merchant: "Arbeitgeber",
            amount: 2500.0, endToEndId: "sal-28"
        )
        let cards = AttentionInboxDetector.detectSalaryMissing(
            recent: [earlySalary], salaryDay: 1,
            toleranceBefore: 4, toleranceAfter: 1, now: today
        )
        XCTAssertTrue(cards.isEmpty,
            "Gehalt kam 4 Tage früh (28.3.), toleranceBefore=4 muss das erkennen")
    }

    /// Regression: derselbe User-Case (salaryDay=1, vor=4, nach=1, Gehalt am 28. Vormonat)
    /// über mehrere Monats-Anker — insbesondere auch über Jahresgrenze hinweg. Stellt
    /// sicher, dass der Fix nicht an ein bestimmtes Kalendermonat gebunden ist und
    /// `detectedIncome` `now` korrekt durchreicht (früherer Bug: intern `Date()`).
    func test_regression_salaryMissing_earlyPayment28_noCard_acrossMonths() {
        let cases: [(today: Date, salaryBooking: String, label: String)] = [
            (makeDate(year: 2026, month: 4, day: 5),  "2026-03-28", "Apr über März"),
            (makeDate(year: 2026, month: 9, day: 5),  "2026-08-28", "Sep über Aug"),
            (makeDate(year: 2026, month: 1, day: 5),  "2025-12-28", "Jan über Dez (Jahresgrenze)")
        ]
        for c in cases {
            let salary = makeTx(
                bookingDate: c.salaryBooking, merchant: "Arbeitgeber",
                amount: 2500.0, endToEndId: "sal-\(c.salaryBooking)"
            )
            let cards = AttentionInboxDetector.detectSalaryMissing(
                recent: [salary], salaryDay: 1,
                toleranceBefore: 4, toleranceAfter: 1, now: c.today
            )
            XCTAssertTrue(cards.isEmpty,
                "\(c.label): Gehalt am \(c.salaryBooking) liegt innerhalb toleranceBefore=4, Karte darf nicht feuern")
        }
    }

    /// Regression: isolated Test der darunterliegenden `detectedIncome`-Funktion.
    /// Diese wird auch außerhalb des Detectors verwendet (BalanceBar, SettingsPanel,
    /// TransactionsPanelView) — wenn sie den Bugcase nicht erkennt, fallen andere
    /// UI-Indikatoren ebenfalls auf „kein Gehalt" zurück.
    func test_regression_detectedIncome_earlyPayment28_countedAsCurrent() {
        let today = makeDate(year: 2026, month: 4, day: 5)
        let salary = makeTx(
            bookingDate: "2026-03-28", merchant: "Arbeitgeber",
            amount: 2500.0, endToEndId: "sal-28"
        )
        let detected = SalaryProgressCalculator.detectedIncome(
            salaryDay: 1, tolerance: 4, transactions: [salary], now: today
        )
        XCTAssertEqual(detected, 2500.0,
            "Gehalt am 28.3. mit salaryDay=1 und tolerance=4 muss als aktuelle Periode erkannt werden")
    }

    // MARK: - duplicates (real API via AttentionInboxDetector.analyze)
    //
    // analyze() looks at recentExpenses7 (< 7 days, negative amount) for duplicates.
    // We pass empty history/salaryDay=0 to silence other cards.

    func test_duplicates_sameMerchantAndAmount_detected() {
        let aral1 = makeTx(bookingDate: isoDay(0),  merchant: "Aral", amount: -78.50, endToEndId: "aral-1")
        let aral2 = makeTx(bookingDate: isoDay(-1), merchant: "Aral", amount: -78.50, endToEndId: "aral-2")

        let cards = AttentionInboxDetector.analyze(
            recent: [aral1, aral2], history: [], salaryDay: 0, salaryToleranceBefore: 0, salaryToleranceAfter: 0
        )
        XCTAssertTrue(
            cards.contains { $0.type == .possibleDuplicate },
            "Two identical Aral expenses within 7 days must be flagged"
        )
    }

    func test_duplicates_differentAmount_notFlagged() {
        let rewe1 = makeTx(bookingDate: isoDay(0),  merchant: "REWE", amount: -45.30, endToEndId: "rewe-1")
        let rewe2 = makeTx(bookingDate: isoDay(-1), merchant: "REWE", amount: -62.10, endToEndId: "rewe-2")

        let cards = AttentionInboxDetector.analyze(
            recent: [rewe1, rewe2], history: [], salaryDay: 0, salaryToleranceBefore: 0, salaryToleranceAfter: 0
        )
        XCTAssertFalse(cards.contains { $0.type == .possibleDuplicate })
    }

    func test_duplicates_differentMerchant_notFlagged() {
        let rewe  = makeTx(bookingDate: isoDay(0),  merchant: "REWE",  amount: -45.30, endToEndId: "rewe")
        let edeka = makeTx(bookingDate: isoDay(-1), merchant: "Edeka", amount: -45.30, endToEndId: "edeka")

        let cards = AttentionInboxDetector.analyze(
            recent: [rewe, edeka], history: [], salaryDay: 0, salaryToleranceBefore: 0, salaryToleranceAfter: 0
        )
        XCTAssertFalse(cards.contains { $0.type == .possibleDuplicate })
    }

    /// Replaces the old mirror test `test_duplicates_threeOccurrences_stillFlagged` which
    /// used Netflix 19.99 × 3 and passed against the mirror — but would FAIL against the
    /// real code because `isKnownSub = FixedCostsAnalyzer.categoryForMerchant(name) != .other
    /// && amount < 30` suppresses those (AttentionInboxDetector.swift:165-166).
    /// The production rule is: known subscription < €30 → NOT flagged as duplicate.
    func test_duplicates_knownSubscriptionUnderThreshold_notFlagged() {
        let nf1 = makeTx(bookingDate: isoDay(0),  merchant: "Netflix", amount: -19.99, endToEndId: "nf-1")
        let nf2 = makeTx(bookingDate: isoDay(-1), merchant: "Netflix", amount: -19.99, endToEndId: "nf-2")
        let nf3 = makeTx(bookingDate: isoDay(-2), merchant: "Netflix", amount: -19.99, endToEndId: "nf-3")

        let cards = AttentionInboxDetector.analyze(
            recent: [nf1, nf2, nf3], history: [], salaryDay: 0, salaryToleranceBefore: 0, salaryToleranceAfter: 0
        )
        XCTAssertFalse(
            cards.contains { $0.type == .possibleDuplicate },
            "Known subscriptions below €30 must not be flagged as duplicate (production rule)"
        )
    }

    // MARK: - newDirectDebit (real API via analyze)
    //
    // analyze() builds knownIBANs from `history` older than 14 days. A debit in `recent`
    // with an IBAN that is NOT in knownIBANs and `isDebit == true` must surface as
    // .newDirectDebit. isDebit requires purposeCode "DBIT" or "LASTSCHRIFT"/"SEPA" in
    // additionalInformation/remittanceInformation — see AttentionInboxDetector.swift:255-260.
    // Recent dates are within the 14-day window so they aren't filtered out upstream.

    func test_newDirectDebit_ibanNotInHistory_flaggedAsNew() {
        let newDebit = makeTx(
            bookingDate: isoDay(-3), merchant: "AcmeCorp",
            amount: -49.00, endToEndId: "acme-1",
            iban: "DE99TEST00000000000001",
            additionalInformation: "SEPA LASTSCHRIFT AcmeCorp",
            purposeCode: "DBIT"
        )
        let cards = AttentionInboxDetector.analyze(
            recent: [newDebit], history: [], salaryDay: 0, salaryToleranceBefore: 0, salaryToleranceAfter: 0
        )
        XCTAssertTrue(
            cards.contains { $0.type == .newDirectDebit },
            "A SEPA debit with an IBAN never seen before (empty history) must be flagged as new"
        )
    }

    func test_newDirectDebit_ibanInOldHistory_notFlagged() {
        // Same IBAN in history older than 14 days → "known" → not flagged.
        let oldDebit = makeTx(
            bookingDate: isoDay(-30), merchant: "AcmeCorp",
            amount: -49.00, endToEndId: "acme-old",
            iban: "DE00KNOWN0000000000001",
            additionalInformation: "SEPA LASTSCHRIFT AcmeCorp",
            purposeCode: "DBIT"
        )
        let newDebit = makeTx(
            bookingDate: isoDay(-3), merchant: "AcmeCorp",
            amount: -49.00, endToEndId: "acme-new",
            iban: "DE00KNOWN0000000000001",
            additionalInformation: "SEPA LASTSCHRIFT AcmeCorp",
            purposeCode: "DBIT"
        )
        let cards = AttentionInboxDetector.analyze(
            recent: [newDebit], history: [oldDebit], salaryDay: 0, salaryToleranceBefore: 0, salaryToleranceAfter: 0
        )
        XCTAssertFalse(
            cards.contains { $0.type == .newDirectDebit },
            "IBAN already known from history older than 14 days must NOT be flagged as new"
        )
    }

    func test_newDirectDebit_emptyIban_notFlagged() {
        // SEPA debit with empty IBAN → must never produce a newDirectDebit card.
        let noIban = makeTx(
            bookingDate: isoDay(-3), merchant: "CashPayment",
            amount: -20.00, endToEndId: "cash-1",
            iban: nil,
            additionalInformation: "SEPA LASTSCHRIFT CashPayment",
            purposeCode: "DBIT"
        )
        let cards = AttentionInboxDetector.analyze(
            recent: [noIban], history: [], salaryDay: 0, salaryToleranceBefore: 0, salaryToleranceAfter: 0
        )
        XCTAssertFalse(cards.contains { $0.type == .newDirectDebit })
    }
}

// MARK: - SalaryProgressCalculator Tests (real API)

final class SalaryProgressCalculatorTests: XCTestCase {

    /// salaryDay=1, today=15th → salary was 15 days ago → daysLeft non-negative
    func test_progress_salaryDayInPast_daysLeftIsZero() {
        let today = makeDate(year: 2026, month: 4, day: 15)
        let result = SalaryProgressCalculator.progress(salaryDay: 1, tolerance: 0, from: today)
        XCTAssertGreaterThanOrEqual(result.daysLeft, 0, "daysLeft must never be negative")
    }

    /// salaryDay=28, today=10th → 18 days until salary
    func test_progress_salaryDayInFuture_daysLeftPositive() {
        let today = makeDate(year: 2026, month: 4, day: 10)
        let result = SalaryProgressCalculator.progress(salaryDay: 28, tolerance: 0, from: today)
        XCTAssertGreaterThan(result.daysLeft, 0)
    }

    /// On payday: lastSalary=today → elapsed=0, daysLeft=totalDays (counting to NEXT payday)
    func test_progress_salaryDayToday_cycleJustStarted() {
        let today = makeDate(year: 2026, month: 4, day: 1)
        let result = SalaryProgressCalculator.progress(salaryDay: 1, tolerance: 0, from: today)
        XCTAssertEqual(result.elapsed, 0, "elapsed=0 on payday itself")
        XCTAssertEqual(result.daysLeft, result.totalDays, "daysLeft=totalDays on payday")
    }

    func test_progress_totalDaysIsPositive() {
        let today = makeDate(year: 2026, month: 4, day: 10)
        let result = SalaryProgressCalculator.progress(salaryDay: 1, tolerance: 0, from: today)
        XCTAssertGreaterThan(result.totalDays, 0)
    }

    func test_progress_elapsedNeverExceedsTotalDays() {
        for day in [1, 10, 20, 28, 30] {
            let today = makeDate(year: 2026, month: 4, day: day)
            let result = SalaryProgressCalculator.progress(salaryDay: 1, tolerance: 0, from: today)
            XCTAssertLessThanOrEqual(result.elapsed, result.totalDays,
                "elapsed (\(result.elapsed)) must not exceed totalDays (\(result.totalDays)) on day \(day)")
        }
    }

    /// salaryDay=5, tolerance=3, today=2nd → within tolerance window → salary "arrived"
    /// lastSalary = this month's 5th, nextSalary = next month's 5th → daysLeft > 0
    func test_progress_withTolerance_salaryConsideredArrivedEarly() {
        let today = makeDate(year: 2026, month: 4, day: 2)
        let result = SalaryProgressCalculator.progress(salaryDay: 5, tolerance: 3, from: today)
        XCTAssertGreaterThan(result.daysLeft, 0)
    }

    /// April has 30 days; salaryDay=31 → clamped to 30; today=28 → 2 days left
    func test_progress_salaryDayClampsToMonthEnd() {
        let today = makeDate(year: 2026, month: 4, day: 28)
        let result = SalaryProgressCalculator.progress(salaryDay: 31, tolerance: 0, from: today)
        XCTAssertEqual(result.daysLeft, 2)
    }
}

// MARK: - Shared test helpers

private func makeDate(year: Int, month: Int, day: Int) -> Date {
    var c = DateComponents()
    c.year = year; c.month = month; c.day = day
    c.hour = 12; c.minute = 0; c.second = 0
    return Calendar.current.date(from: c)!
}

/// Returns an ISO yyyy-MM-dd string for `Date() + offsetDays`.
private func isoDay(_ offsetDays: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: offsetDays, to: Date())!
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
}

/// Builds a minimal TransactionsResponse.Transaction for AttentionInboxDetector tests.
/// merchant → creditor.name (expense, amount < 0) or debtor.name (income, amount > 0).
/// Pass `purposeCode: "DBIT"` (or set `additionalInformation` to include "LASTSCHRIFT"/"SEPA")
/// to have detectNewDirectDebit recognise the transaction as a direct debit.
private func makeTx(
    bookingDate: String,
    merchant: String,
    amount: Double,
    endToEndId: String,
    iban: String? = nil,
    additionalInformation: String? = nil,
    purposeCode: String? = nil
) -> TransactionsResponse.Transaction {
    let amt = TransactionsResponse.Amount(
        currency: "EUR",
        amount: String(format: "%.2f", amount)
    )
    let party = TransactionsResponse.Party(name: merchant, iban: iban, bic: nil)
    return TransactionsResponse.Transaction(
        bookingDate: bookingDate,
        valueDate: bookingDate,
        status: "booked",
        endToEndId: endToEndId,
        amount: amt,
        creditor: amount < 0 ? party : nil,
        debtor:  amount > 0 ? party : nil,
        remittanceInformation: [merchant],
        additionalInformation: additionalInformation ?? merchant,
        purposeCode: purposeCode
    )
}
