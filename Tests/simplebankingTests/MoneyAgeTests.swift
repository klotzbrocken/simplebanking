import XCTest
@testable import simplebanking

final class MoneyAgeTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(daysOffset: Double, amount: Decimal) -> MoneyAge.Entry {
        MoneyAge.Entry(date: anchor.addingTimeInterval(daysOffset * day), amount: amount)
    }

    func test_emptyInput_returnsZeroUnknown() {
        let result = MoneyAge.calculate(entries: [])
        XCTAssertEqual(result.averageDays, 0)
        XCTAssertEqual(result.sampleSize, 0)
        XCTAssertEqual(result.totalExpenses, 0)
        XCTAssertEqual(result.band, .unknown)
    }

    func test_minMaxDays_acrossWindow() {
        let entries = [
            entry(daysOffset: 0, amount: 1000),
            entry(daysOffset: 5, amount: -10),
            entry(daysOffset: 20, amount: -10),
        ]
        let r = MoneyAge.calculate(entries: entries)
        XCTAssertEqual(r.minDays, 5, accuracy: 0.001)
        XCTAssertEqual(r.maxDays, 20, accuracy: 0.001)
        XCTAssertEqual(r.averageDays, 12.5, accuracy: 0.001)
    }

    func test_onlyInflows_returnsUnknown() {
        let entries = [
            entry(daysOffset: 0, amount: 1000),
            entry(daysOffset: 5, amount: 500)
        ]
        let result = MoneyAge.calculate(entries: entries)
        XCTAssertEqual(result.totalExpenses, 0)
        XCTAssertEqual(result.band, .unknown)
    }

    func test_singleExpenseFullyCovered_byOldestInflow() {
        // Tag 0: +2000, Tag 5: +500, Tag 13: -800 (komplett aus 2000 vom Tag 0)
        let entries = [
            entry(daysOffset: 0, amount: 2000),
            entry(daysOffset: 5, amount: 500),
            entry(daysOffset: 13, amount: -800)
        ]
        let result = MoneyAge.calculate(entries: entries)
        XCTAssertEqual(result.totalExpenses, 1)
        XCTAssertEqual(result.uncoveredExpenses, 0)
        XCTAssertEqual(result.sampleSize, 1)
        XCTAssertEqual(result.averageDays, 13, accuracy: 0.001)
        XCTAssertEqual(result.band, .sparse)   // 13 < 15
    }

    func test_expenseAcrossTwoInflows_weightsAgeByConsumedAmount() {
        // Tag 0: +200 (älter), Tag 10: +1000 (jünger)
        // Tag 20: -600 → 200 aus Tag 0 (alter=20), 400 aus Tag 10 (alter=10)
        // Erwartet: (200*20 + 400*10) / 600 = (4000 + 4000)/600 = 13.333...
        let entries = [
            entry(daysOffset: 0, amount: 200),
            entry(daysOffset: 10, amount: 1000),
            entry(daysOffset: 20, amount: -600)
        ]
        let result = MoneyAge.calculate(entries: entries)
        XCTAssertEqual(result.totalExpenses, 1)
        XCTAssertEqual(result.uncoveredExpenses, 0)
        XCTAssertEqual(result.averageDays, 13.333, accuracy: 0.01)
    }

    func test_expenseExceedsAvailable_isMarkedUncovered() {
        // Tag 0: +100, Tag 10: -500 → 100 gedeckt (Alter 10), 400 ungedeckt
        let entries = [
            entry(daysOffset: 0, amount: 100),
            entry(daysOffset: 10, amount: -500)
        ]
        let result = MoneyAge.calculate(entries: entries)
        XCTAssertEqual(result.totalExpenses, 1)
        XCTAssertEqual(result.uncoveredExpenses, 1)
        XCTAssertEqual(result.averageDays, 10, accuracy: 0.001)
    }

    func test_windowSize_capsToLastNExpenses() {
        // 12 Eingänge à 100 an Tag 0..11, 12 Ausgaben à 100 jeweils einen Tag später
        // → Alter pro Ausgabe = 1 Tag (FIFO greift sauber)
        // Mit windowSize=10 ist sampleSize=10, averageDays=1
        var entries: [MoneyAge.Entry] = []
        for i in 0..<12 {
            entries.append(entry(daysOffset: Double(i) * 2, amount: 100))
            entries.append(entry(daysOffset: Double(i) * 2 + 1, amount: -100))
        }
        let result = MoneyAge.calculate(entries: entries, windowSize: 10)
        XCTAssertEqual(result.totalExpenses, 12)
        XCTAssertEqual(result.sampleSize, 10)
        XCTAssertEqual(result.averageDays, 1, accuracy: 0.001)
        XCTAssertEqual(result.band, .sparse)
    }

    func test_chronologicalSorting_ignoresInputOrder() {
        // Gleiche Daten wie test_singleExpenseFullyCovered, aber unsortiert.
        let entries = [
            entry(daysOffset: 13, amount: -800),
            entry(daysOffset: 0, amount: 2000),
            entry(daysOffset: 5, amount: 500)
        ]
        let result = MoneyAge.calculate(entries: entries)
        XCTAssertEqual(result.averageDays, 13, accuracy: 0.001)
    }

    func test_bandThresholds() {
        XCTAssertEqual(MoneyAge.Band.from(days: 0), .sparse)
        XCTAssertEqual(MoneyAge.Band.from(days: 14.99), .sparse)
        XCTAssertEqual(MoneyAge.Band.from(days: 15), .ok)
        XCTAssertEqual(MoneyAge.Band.from(days: 29.99), .ok)
        XCTAssertEqual(MoneyAge.Band.from(days: 30), .puffer)
        XCTAssertEqual(MoneyAge.Band.from(days: 59.99), .puffer)
        XCTAssertEqual(MoneyAge.Band.from(days: 60), .monthAhead)
        XCTAssertEqual(MoneyAge.Band.from(days: 365), .monthAhead)
    }
}
