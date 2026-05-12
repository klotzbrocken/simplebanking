import XCTest
@testable import simplebanking

final class TransferScheduleHelpersTests: XCTestCase {

    /// Fixe Test-Reference: 15.05.2026 14:32 lokal.
    private let now: Date = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        let comps = DateComponents(year: 2026, month: 5, day: 15, hour: 14, minute: 32)
        return c.date(from: comps)!
    }()

    func test_today_normalizesToStartOfDay() {
        let t = TransferScheduleHelpers.today(now)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: t)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 5)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.second, 0)
    }

    func test_tomorrow_isOneDayInFuture() {
        let t = TransferScheduleHelpers.tomorrow(now)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: t)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 5)
        XCTAssertEqual(comps.day, 16)
    }

    func test_in7Days_isSevenDaysInFuture() {
        let t = TransferScheduleHelpers.in7Days(now)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: t)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 5)
        XCTAssertEqual(comps.day, 22)
    }

    func test_firstOfNextMonth_fromMidMonth() {
        let t = TransferScheduleHelpers.firstOfNextMonth(now)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: t)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 1)
    }

    func test_firstOfNextMonth_acrossYearBoundary() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        let dec = c.date(from: DateComponents(year: 2026, month: 12, day: 5))!
        let t = TransferScheduleHelpers.firstOfNextMonth(dec)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: t)
        XCTAssertEqual(comps.year, 2027)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 1)
    }

    func test_formatDateDisplay_deDE() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        let d = c.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        XCTAssertEqual(TransferScheduleHelpers.formatDateDisplay(d), "01.06.2026")
    }

    func test_formatDateISO_yyyyMMdd() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        let d = c.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        XCTAssertEqual(TransferScheduleHelpers.formatDateISO(d), "2026-06-01")
    }
}
