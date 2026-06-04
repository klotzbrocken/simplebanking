import XCTest
@testable import simplebanking

final class MMIPeriodTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: cutoffDate

    func test_month_cutoff_isOneMonthBack() {
        let now = date(2026, 6, 15)
        let cutoff = MMIPeriod.month.cutoffDate(asOf: now, calendar: cal)
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: cutoff),
                       DateComponents(year: 2026, month: 5, day: 15))
    }

    func test_quarter_cutoff_isThreeMonthsBack() {
        let now = date(2026, 6, 15)
        let cutoff = MMIPeriod.quarter.cutoffDate(asOf: now, calendar: cal)
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: cutoff),
                       DateComponents(year: 2026, month: 3, day: 15))
    }

    func test_max_cutoff_isStartOfCurrentYear() {
        let now = date(2026, 6, 15)
        let cutoff = MMIPeriod.max.cutoffDate(asOf: now, calendar: cal)
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: cutoff),
                       DateComponents(year: 2026, month: 1, day: 1))
    }

    func test_max_cutoff_earlyJanuary_staysInYear() {
        let now = date(2026, 1, 10)
        let cutoff = MMIPeriod.max.cutoffDate(asOf: now, calendar: cal)
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: cutoff),
                       DateComponents(year: 2026, month: 1, day: 1))
        XCTAssertTrue(cutoff <= now)
    }

    // MARK: monthsSpan

    func test_monthsSpan() {
        XCTAssertEqual(MMIPeriod.month.monthsSpan(asOf: date(2026, 6, 15), calendar: cal), 1, accuracy: 0.001)
        XCTAssertEqual(MMIPeriod.quarter.monthsSpan(asOf: date(2026, 6, 15), calendar: cal), 3, accuracy: 0.001)
        XCTAssertEqual(MMIPeriod.max.monthsSpan(asOf: date(2026, 6, 15), calendar: cal), 6, accuracy: 0.001)
        XCTAssertEqual(MMIPeriod.max.monthsSpan(asOf: date(2026, 1, 31), calendar: cal), 1, accuracy: 0.001)
        XCTAssertEqual(MMIPeriod.max.monthsSpan(asOf: date(2026, 12, 1), calendar: cal), 12, accuracy: 0.001)
    }

    // MARK: cases / labels

    func test_allCases_andLabels() {
        XCTAssertEqual(MMIPeriod.allCases, [.month, .quarter, .max])
        XCTAssertEqual(MMIPeriod.max.label, "Max")
    }

    // MARK: bufferMonths uses periodMonths

    func test_bufferMonths_usesPeriodMonths() {
        // 1200 € Ausgaben über 6 Monate = 200 €/Monat; 600 € Saldo → 3 Monate Puffer.
        let c = MMIComponents(income: 2000, expenses: 1200, savings: 0, balance: 600, periodMonths: 6)
        XCTAssertEqual(c.bufferMonths, 3, accuracy: 0.001)
    }
}
