import XCTest
@testable import simplebanking

// MARK: - LeftToPayCalculator Tests
//
// Exercises the real production code in LeftToPayCalculator.swift via
// `@testable import simplebanking`. All dates are Date-injected so the tests
// are deterministic regardless of wall-clock or local calendar.

final class LeftToPayCalculatorTests: XCTestCase {

    // MARK: - cycleStart / cycleEnd boundaries

    func test_cycleBoundaries_midMonthSalary_middleOfCycle() {
        // salary day 15, today = April 20 → cycle = April 15 ... May 15
        let today = day(2026, 4, 20)
        let start = LeftToPayCalculator.cycleStart(salaryDay: 15, today: today)
        let end   = LeftToPayCalculator.cycleEnd(salaryDay: 15, today: today)
        XCTAssertEqual(start, day(2026, 4, 15))
        XCTAssertEqual(end,   day(2026, 5, 15))
    }

    func test_cycleBoundaries_beforeSalaryThisMonth_previousCycle() {
        // salary day 25, today = April 10 → cycle = March 25 ... April 25
        let today = day(2026, 4, 10)
        let start = LeftToPayCalculator.cycleStart(salaryDay: 25, today: today)
        let end   = LeftToPayCalculator.cycleEnd(salaryDay: 25, today: today)
        XCTAssertEqual(start, day(2026, 3, 25))
        XCTAssertEqual(end,   day(2026, 4, 25))
    }

    // MARK: - Day clamping across short months

    /// Regression: previously clamped salaryDay hard to 28. A user paid on the
    /// 31st would have their cycle end pulled to the 28th — losing payments
    /// booked on the 29th–31st.
    func test_cycleEnd_salaryDay31_resolvesToLastDayOfMonth() {
        // salary day 31, today = April 20 (April has 30 days)
        // Expected next cycleEnd = April 30 (clamped to April's last day)
        let today = day(2026, 4, 20)
        let end = LeftToPayCalculator.cycleEnd(salaryDay: 31, today: today)
        XCTAssertEqual(end, day(2026, 4, 30))
    }

    func test_cycleEnd_salaryDay31_january_stays31() {
        // salary day 31, today = January 10 → cycleEnd should be January 31
        let today = day(2026, 1, 10)
        let end = LeftToPayCalculator.cycleEnd(salaryDay: 31, today: today)
        XCTAssertEqual(end, day(2026, 1, 31))
    }

    func test_cycleEnd_salaryDay30_february_clampsTo28() {
        // salary day 30, today = February 5 (2026 = non-leap year)
        let today = day(2026, 2, 5)
        let end = LeftToPayCalculator.cycleEnd(salaryDay: 30, today: today)
        XCTAssertEqual(end, day(2026, 2, 28))
    }

    // MARK: - Tolerance window

    /// Preset "beginning of month" = salary day 1, toleranceBefore=4, toleranceAfter=1.
    /// Today = April 15 → cycle start = April 1 − 4 = March 28,
    /// cycle end = May 1 + 1 = May 2 (salary might arrive 1 day late, asymmetric).
    func test_cycleBoundaries_asymmetricTolerance() {
        let today = day(2026, 4, 15)
        let start = LeftToPayCalculator.cycleStart(salaryDay: 1, toleranceBefore: 4, today: today)
        let end   = LeftToPayCalculator.cycleEnd(salaryDay: 1, toleranceBefore: 4, toleranceAfter: 1, today: today)
        XCTAssertEqual(start, day(2026, 3, 28))
        XCTAssertEqual(end,   day(2026, 5, 2))
    }

    // MARK: - compute()

    /// Monthly Netflix last charged on April 1, today = April 5, cycle = 1→30.
    /// Netflix already booked this cycle → contributes 0.
    func test_compute_alreadyPaidThisCycle_excluded() {
        let today = day(2026, 4, 5)
        let netflix = recurring(merchant: "Netflix", amount: 15, lastDate: "2026-04-01", frequency: .monthly)
        let sum = LeftToPayCalculator.compute(
            payments: [netflix],
            salaryDay: 1,
            today: today
        )
        XCTAssertEqual(sum, 0, accuracy: 0.01)
    }

    /// Monthly rent last charged March 15, today = April 14, cycle = Mar 28 ... Apr 28.
    /// lastDate (Mar 15) is before cycleStart → not yet paid this cycle.
    /// Next expected April 15 → falls into current cycle → counted.
    func test_compute_dueNextInCycle_counted() {
        let today = day(2026, 4, 14)
        let rent = recurring(merchant: "Landlord", amount: 850, lastDate: "2026-03-15", frequency: .monthly)
        let sum = LeftToPayCalculator.compute(
            payments: [rent],
            salaryDay: 28,
            today: today
        )
        XCTAssertEqual(sum, 850, accuracy: 0.01)
    }

    /// Irregular frequency → always excluded (too low confidence).
    func test_compute_irregular_excluded() {
        let today = day(2026, 4, 14)
        let thing = recurring(merchant: "Random", amount: 40, lastDate: "2026-03-01", frequency: .irregular)
        let sum = LeftToPayCalculator.compute(
            payments: [thing],
            salaryDay: 28,
            today: today
        )
        XCTAssertEqual(sum, 0, accuracy: 0.01)
    }

    /// Low confidence payments → excluded.
    func test_compute_lowConfidence_excluded() {
        let today = day(2026, 4, 14)
        let meh = recurring(
            merchant: "Guessed", amount: 20, lastDate: "2026-03-15",
            frequency: .monthly, confidence: 0.55
        )
        let sum = LeftToPayCalculator.compute(
            payments: [meh],
            salaryDay: 28,
            today: today
        )
        XCTAssertEqual(sum, 0, accuracy: 0.01)
    }

    /// Overdue payments count: next expected = March 20, today = April 14,
    /// cycleStart = March 28 → already-paid guard uses March 20 < March 28 so not excluded;
    /// next expected March 20 < cycleEnd April 28 → counted.
    func test_compute_overduePayment_counted() {
        let today = day(2026, 4, 14)
        let overdue = recurring(merchant: "Overdue Co", amount: 99, lastDate: "2026-02-20", frequency: .monthly)
        let sum = LeftToPayCalculator.compute(
            payments: [overdue],
            salaryDay: 28,
            today: today
        )
        XCTAssertEqual(sum, 99, accuracy: 0.01)
    }

    /// Quarterly payment last charged Jan 15, today = April 14, salary day 28
    /// → cycle Mar 28 ... Apr 28
    /// → next expected Apr 15 → in cycle → counted.
    func test_compute_quarterlyInCycle_counted() {
        let today = day(2026, 4, 14)
        let p = recurring(merchant: "Quarterly", amount: 120, lastDate: "2026-01-15", frequency: .quarterly)
        let sum = LeftToPayCalculator.compute(
            payments: [p],
            salaryDay: 28,
            today: today
        )
        XCTAssertEqual(sum, 120, accuracy: 0.01)
    }

    /// Mixed set: Netflix already paid + Rent due + Irregular filter
    func test_compute_mixedBag_sumsOnlyEligible() {
        let today = day(2026, 4, 14)
        let payments = [
            recurring(merchant: "Netflix",  amount: 15,  lastDate: "2026-04-01", frequency: .monthly),
            recurring(merchant: "Rent",     amount: 850, lastDate: "2026-03-28", frequency: .monthly),
            recurring(merchant: "Random",   amount: 40,  lastDate: "2026-03-01", frequency: .irregular),
            recurring(merchant: "Insurance",amount: 60,  lastDate: "2026-03-30", frequency: .monthly),
        ]
        // salary day 28 → cycle Mar 28 ... Apr 28
        // Netflix: last=Apr 1 >= Mar 28 (cycleStart) → already paid, excluded
        // Rent: last=Mar 28 >= Mar 28 → already paid, excluded
        // Random: irregular → excluded
        // Insurance: last=Mar 30 >= Mar 28 → already paid, excluded
        let sum = LeftToPayCalculator.compute(
            payments: payments,
            salaryDay: 28,
            today: today
        )
        XCTAssertEqual(sum, 0, accuracy: 0.01)
    }

    /// Same bag but rent booked just before cycle start → should count.
    func test_compute_rentDueBeforeCycleEnd_counted() {
        let today = day(2026, 4, 14)
        let rent = recurring(merchant: "Rent", amount: 850, lastDate: "2026-03-27", frequency: .monthly)
        // salary day 28 → cycle Mar 28 ... Apr 28
        // Rent last=Mar 27 < Mar 28 → NOT already paid
        // Next expected=Apr 27 <= Apr 28 → counted
        let sum = LeftToPayCalculator.compute(
            payments: [rent],
            salaryDay: 28,
            today: today
        )
        XCTAssertEqual(sum, 850, accuracy: 0.01)
    }
}

// MARK: - Test helpers

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    var c = DateComponents()
    c.year = year; c.month = month; c.day = dayOfMonth
    return Calendar.current.startOfDay(for: Calendar.current.date(from: c)!)
}

private func recurring(
    merchant: String,
    amount: Double,
    lastDate: String,
    frequency: PaymentFrequency,
    confidence: Double = 0.85
) -> RecurringPayment {
    RecurringPayment(
        merchant: merchant,
        groupKey: merchant,
        averageAmount: amount,
        occurrences: 3,
        months: 3,
        frequency: frequency,
        lastDate: lastDate,
        category: .other,
        confidence: confidence
    )
}
