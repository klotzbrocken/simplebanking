import XCTest
@testable import simplebanking

final class AbosForecastTests: XCTestCase {

    private func payment(
        _ merchant: String,
        amount: Double,
        frequency: PaymentFrequency,
        lastDate: String,
        confidence: Double = 0.9
    ) -> RecurringPayment {
        RecurringPayment(
            merchant: merchant,
            groupKey: merchant,
            averageAmount: amount,
            occurrences: 3,
            months: 3,
            frequency: frequency,
            lastDate: lastDate,
            category: .streaming,
            confidence: confidence
        )
    }

    private func date(_ s: String) -> Date {
        AbosForecast.parseDate(s)!
    }

    // MARK: - nextPaymentDate

    func test_nextPaymentDate_monthly() {
        let next = AbosForecast.nextPaymentDate(after: date("2026-06-02"), lastDate: "2026-05-17", frequency: .monthly)
        XCTAssertEqual(next, date("2026-06-17"))
    }

    func test_nextPaymentDate_quarterly() {
        let next = AbosForecast.nextPaymentDate(after: date("2026-06-02"), lastDate: "2026-04-03", frequency: .quarterly)
        XCTAssertEqual(next, date("2026-07-03"))
    }

    func test_nextPaymentDate_yearly() {
        let next = AbosForecast.nextPaymentDate(after: date("2026-06-02"), lastDate: "2025-10-17", frequency: .yearly)
        XCTAssertEqual(next, date("2026-10-17"))
    }

    func test_nextPaymentDate_irregular_isNil() {
        XCTAssertNil(AbosForecast.nextPaymentDate(after: date("2026-06-02"), lastDate: "2026-05-01", frequency: .irregular))
    }

    func test_nextPaymentDate_strictlyAfter_whenLastDateIsReference() {
        // lastDate == after → must roll forward one step, not return the same day.
        let next = AbosForecast.nextPaymentDate(after: date("2026-06-17"), lastDate: "2026-06-17", frequency: .monthly)
        XCTAssertEqual(next, date("2026-07-17"))
    }

    // MARK: - project

    func test_project_monthlyFillsHorizon() {
        let p = payment("Spotify", amount: -9.99, frequency: .monthly, lastDate: "2026-05-17")
        let charges = AbosForecast.project(payments: [p], from: date("2026-06-02"), until: date("2026-09-30"))
        XCTAssertEqual(charges.map { AbosForecast.dayKey($0.date) }, ["2026-06-17", "2026-07-17", "2026-08-17", "2026-09-17"])
        XCTAssertTrue(charges.allSatisfy { $0.amount == -9.99 })
    }

    func test_project_signIsNegativeRegardlessOfInputSign() {
        let p = payment("Netflix", amount: 12.99, frequency: .monthly, lastDate: "2026-05-10")
        let charges = AbosForecast.project(payments: [p], from: date("2026-06-02"), until: date("2026-07-31"))
        XCTAssertTrue(charges.allSatisfy { $0.amount == -12.99 })
    }

    func test_project_excludesIrregularAndLowConfidence() {
        let irregular = payment("Strom", amount: -80, frequency: .irregular, lastDate: "2026-05-01")
        let lowConf = payment("Maybe", amount: -5, frequency: .monthly, lastDate: "2026-05-01", confidence: 0.3)
        let good = payment("Spotify", amount: -9.99, frequency: .monthly, lastDate: "2026-05-01")
        let charges = AbosForecast.project(payments: [irregular, lowConf, good], from: date("2026-06-02"), until: date("2026-07-31"))
        XCTAssertTrue(charges.allSatisfy { $0.merchant == "Spotify" })
        XCTAssertFalse(charges.isEmpty)
    }

    func test_project_emptyWhenHorizonInverted() {
        let p = payment("Spotify", amount: -9.99, frequency: .monthly, lastDate: "2026-05-17")
        XCTAssertTrue(AbosForecast.project(payments: [p], from: date("2026-09-30"), until: date("2026-06-02")).isEmpty)
    }

    func test_project_sortedByDate() {
        let a = payment("A", amount: -1, frequency: .monthly, lastDate: "2026-05-20")
        let b = payment("B", amount: -2, frequency: .monthly, lastDate: "2026-05-05")
        let charges = AbosForecast.project(payments: [a, b], from: date("2026-06-02"), until: date("2026-06-30"))
        XCTAssertEqual(charges.map { AbosForecast.dayKey($0.date) }, ["2026-06-05", "2026-06-20"])
    }

    // MARK: - daysUntil

    func test_daysUntil() {
        XCTAssertEqual(AbosForecast.daysUntil(from: date("2026-06-02"), to: date("2026-06-17")), 15)
        XCTAssertEqual(AbosForecast.daysUntil(from: date("2026-06-17"), to: date("2026-06-02")), -15)
    }
}
