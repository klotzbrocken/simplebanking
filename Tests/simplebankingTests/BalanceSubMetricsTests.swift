import XCTest
@testable import simplebanking

final class BalanceSubMetricsTests: XCTestCase {

    /// Helper — fester Datums-Anker für deterministische Cycle-Math.
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comp = DateComponents()
        comp.year = y; comp.month = m; comp.day = d; comp.hour = 12
        return Calendar.current.date(from: comp)!
    }

    // MARK: - Normal state

    func test_normal_midMonth_producesDailyBudget() {
        // Heute 15.04. | salary=1, toleranceBefore=0, toleranceAfter=0 → cycleEnd = 01.05. → 16 Tage
        let today = date(2026, 4, 15)
        let m = BalanceSubMetrics.compute(balance: 1000, leftToPay: 200,
                                          salaryDay: 1, toleranceBefore: 0, toleranceAfter: 0, today: today)
        XCTAssertEqual(m.state, .normal)
        XCTAssertEqual(m.availableAmount, 800, accuracy: 0.01)
        XCTAssertEqual(m.daysUntilSalary, 16)
        XCTAssertEqual(m.dailyBudget, 50, accuracy: 0.01)  // 800 / 16
        XCTAssertEqual(m.salaryDayOfMonth, 1)
    }

    // MARK: - Unknown state (fallback)

    func test_unknown_whenLeftToPayIsNil() {
        // Regression: nil darf NICHT still als 0 interpretiert werden, sonst wird zu
        // optimistisches Budget angezeigt. State muss `.unknown` sein → Fallback auf Classic.
        let today = date(2026, 4, 15)
        let m = BalanceSubMetrics.compute(balance: 500, leftToPay: nil,
                                          salaryDay: 1, toleranceBefore: 0, toleranceAfter: 0, today: today)
        XCTAssertEqual(m.state, .unknown)
    }

    func test_unknown_whenBalanceIsNil() {
        let today = date(2026, 4, 15)
        let m = BalanceSubMetrics.compute(balance: nil, leftToPay: 200,
                                          salaryDay: 1, toleranceBefore: 0, toleranceAfter: 0, today: today)
        XCTAssertEqual(m.state, .unknown)
    }

    // MARK: - Overdrawn state

    func test_overdrawn_whenLeftToPayExceedsBalance() {
        let today = date(2026, 4, 15)
        let m = BalanceSubMetrics.compute(balance: 100, leftToPay: 300,
                                          salaryDay: 1, toleranceBefore: 0, toleranceAfter: 0, today: today)
        XCTAssertEqual(m.state, .overdrawn)
        XCTAssertEqual(m.availableAmount, -200, accuracy: 0.01)
        XCTAssertEqual(m.dailyBudget, 0)
    }

    // MARK: - Edge: divide-by-zero guard

    func test_noDivideByZero_whenOneDayLeft() {
        // Heute 30.04. | salary=1 → cycleEnd = 01.05. → 1 Tag
        let today = date(2026, 4, 30)
        let m = BalanceSubMetrics.compute(balance: 100, leftToPay: 0,
                                          salaryDay: 1, toleranceBefore: 0, toleranceAfter: 0, today: today)
        XCTAssertEqual(m.state, .normal)
        XCTAssertEqual(m.daysUntilSalary, 1)
        XCTAssertEqual(m.dailyBudget, 100, accuracy: 0.01)
    }

    // MARK: - salaryDayOfMonth extraction

    func test_salaryDayOfMonth_matchesCycleEnd() {
        // Heute 10.04. | salary=15 → cycleEnd = 15.04. → 5 Tage
        let today = date(2026, 4, 10)
        let m = BalanceSubMetrics.compute(balance: 300, leftToPay: 0,
                                          salaryDay: 15, toleranceBefore: 0, toleranceAfter: 0, today: today)
        XCTAssertEqual(m.daysUntilSalary, 5)
        XCTAssertEqual(m.salaryDayOfMonth, 15)
    }

    // MARK: - December → January rollover

    func test_yearRollover_fromDecToJan() {
        // Heute 20.12.2026 | salary=1 → cycleEnd = 01.01.2027 → 12 Tage
        let today = date(2026, 12, 20)
        let m = BalanceSubMetrics.compute(balance: 480, leftToPay: 0,
                                          salaryDay: 1, toleranceBefore: 0, toleranceAfter: 0, today: today)
        XCTAssertEqual(m.state, .normal)
        XCTAssertEqual(m.daysUntilSalary, 12)
        XCTAssertEqual(m.salaryDayOfMonth, 1)
        XCTAssertEqual(m.dailyBudget, 40, accuracy: 0.01)
    }

    // MARK: - Asymmetric tolerance (CR1)

    func test_asymmetricTolerance_afterIsShorterThanBefore() {
        // Heute 18.04. | salary=15, toleranceBefore=4, toleranceAfter=1
        // Ohne Fix wäre cycleEnd = 15.05. + 4 = 19.05.
        // Mit Fix: cycleEnd = 15.05. + 1 = 16.05. (realistischer — Gehalt ist selten 4 Tage spät)
        let today = date(2026, 4, 18)
        let m = BalanceSubMetrics.compute(balance: 600, leftToPay: 0,
                                          salaryDay: 15, toleranceBefore: 4, toleranceAfter: 1, today: today)
        XCTAssertEqual(m.salaryDayOfMonth, 15)
        // cycleEnd = 16.05. → 18.04. bis 16.05. = 28 Tage
        XCTAssertEqual(m.daysUntilSalary, 28)
    }
}
