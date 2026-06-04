import XCTest
@testable import simplebanking

final class SubscriptionStatsTests: XCTestCase {

    private func payment(
        _ merchant: String,
        amount: Double,
        frequency: PaymentFrequency,
        category: PaymentCategory,
        confidence: Double = 0.9
    ) -> RecurringPayment {
        RecurringPayment(
            merchant: merchant,
            groupKey: merchant,
            averageAmount: amount,
            occurrences: 3,
            months: 3,
            frequency: frequency,
            lastDate: "2026-05-01",
            category: category,
            confidence: confidence
        )
    }

    func test_empty_returnsEmpty() {
        XCTAssertEqual(SubscriptionStatsCalc.compute(payments: []), .empty)
    }

    func test_yearlyNormalization_perFrequency() {
        XCTAssertEqual(SubscriptionStatsCalc.yearlyAmount(payment("m", amount: -10, frequency: .monthly, category: .streaming)), 120, accuracy: 0.001)
        XCTAssertEqual(SubscriptionStatsCalc.yearlyAmount(payment("q", amount: -30, frequency: .quarterly, category: .utilities)), 120, accuracy: 0.001)
        XCTAssertEqual(SubscriptionStatsCalc.yearlyAmount(payment("y", amount: -120, frequency: .yearly, category: .software)), 120, accuracy: 0.001)
        XCTAssertEqual(SubscriptionStatsCalc.yearlyAmount(payment("i", amount: -50, frequency: .irregular, category: .other)), 0, accuracy: 0.001)
    }

    func test_yearlyForecastAndAvgMonthly() {
        let stats = SubscriptionStatsCalc.compute(payments: [
            payment("Spotify", amount: -10, frequency: .monthly, category: .streaming),   // 120/yr
            payment("Versicherung", amount: -120, frequency: .yearly, category: .insurance) // 120/yr
        ])
        XCTAssertEqual(stats.yearlyForecast, 240, accuracy: 0.001)
        XCTAssertEqual(stats.avgMonthly, 20, accuracy: 0.001)
    }

    func test_categoryAggregation_mergesAndSorts() {
        let stats = SubscriptionStatsCalc.compute(payments: [
            payment("Netflix", amount: -10, frequency: .monthly, category: .streaming),  // 120
            payment("Spotify", amount: -5, frequency: .monthly, category: .streaming),   // 60
            payment("iCloud", amount: -3, frequency: .monthly, category: .software)      // 36
        ])
        XCTAssertEqual(stats.byCategory.count, 2)
        XCTAssertEqual(stats.byCategory.first?.category, .streaming)
        XCTAssertEqual(stats.byCategory.first?.yearlyAmount ?? 0, 180, accuracy: 0.001)
        XCTAssertEqual(stats.byCategory.last?.category, .software)
    }

    func test_sharesSumToOne() {
        let stats = SubscriptionStatsCalc.compute(payments: [
            payment("Netflix", amount: -10, frequency: .monthly, category: .streaming),
            payment("iCloud", amount: -3, frequency: .monthly, category: .software),
            payment("Bahn", amount: -49, frequency: .yearly, category: .transport)
        ])
        XCTAssertEqual(stats.byCategory.reduce(0) { $0 + $1.share }, 1.0, accuracy: 0.0001)
    }

    func test_irregularAndLowConfidenceExcluded() {
        let stats = SubscriptionStatsCalc.compute(payments: [
            payment("Spotify", amount: -10, frequency: .monthly, category: .streaming),
            payment("Strom", amount: -80, frequency: .irregular, category: .utilities),
            payment("Maybe", amount: -99, frequency: .monthly, category: .other, confidence: 0.2)
        ])
        XCTAssertEqual(stats.yearlyForecast, 120, accuracy: 0.001)
        XCTAssertEqual(stats.byCategory.count, 1)
    }
}
