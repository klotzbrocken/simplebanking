import XCTest
@testable import simplebanking

// MARK: - Ausgaben-Heat (Händler-Slots) + Marken-Wash
//
// Verifiziert die reinen Funktionen hinter dem Händler-Redesign:
// `SpendSignal.classify/percentOfBudget/badge` und `MerchantWash.brandHex`.

final class SpendSignalTests: XCTestCase {

    // MARK: classify

    func test_classify_noBudget_whenBudgetZero() {
        XCTAssertEqual(SpendSignal.classify(spentCents: 5000, budgetCents: 0), .noBudget)
    }

    func test_classify_underBudget_below75Percent() {
        // 200 / 400 = 50 %
        XCTAssertEqual(SpendSignal.classify(spentCents: 20000, budgetCents: 40000), .underBudget)
    }

    func test_classify_nearBudget_atExactly75Percent() {
        // 300 / 400 = 75 % → nicht mehr under
        XCTAssertEqual(SpendSignal.classify(spentCents: 30000, budgetCents: 40000), .nearBudget)
    }

    func test_classify_nearBudget_justUnder100() {
        XCTAssertEqual(SpendSignal.classify(spentCents: 39900, budgetCents: 40000), .nearBudget)
    }

    func test_classify_overBudget_atExactly100Percent() {
        XCTAssertEqual(SpendSignal.classify(spentCents: 40000, budgetCents: 40000), .overBudget)
    }

    func test_classify_overBudget_above100() {
        XCTAssertEqual(SpendSignal.classify(spentCents: 45000, budgetCents: 40000), .overBudget)
    }

    // MARK: percentOfBudget

    func test_percent_nilWhenNoBudget() {
        XCTAssertNil(SpendSignal.percentOfBudget(spentCents: 1000, budgetCents: 0))
    }

    func test_percent_roundsToNearestInt() {
        // 31280 / 40000 = 78.2 % → 78
        XCTAssertEqual(SpendSignal.percentOfBudget(spentCents: 31280, budgetCents: 40000), 78)
    }

    // MARK: badge

    func test_badge_nilWhenNoBudget() {
        let level = SpendSignal.classify(spentCents: 1000, budgetCents: 0)
        XCTAssertNil(SpendSignal.badge(spentCents: 1000, budgetCents: 0, level: level))
    }

    func test_badge_overBudgetShowsPlusOverage() {
        let spent = 47200, budget = 40000
        let level = SpendSignal.classify(spentCents: spent, budgetCents: budget)
        let badge = SpendSignal.badge(spentCents: spent, budgetCents: budget, level: level)
        // 118 % → +18
        XCTAssertNotNil(badge)
        XCTAssertTrue(badge?.contains("18") == true, "expected overage 18 in \(badge ?? "nil")")
        XCTAssertTrue(badge?.contains("+") == true)
    }

    func test_badge_underBudgetShowsPercent() {
        let spent = 20000, budget = 40000
        let level = SpendSignal.classify(spentCents: spent, budgetCents: budget)
        let badge = SpendSignal.badge(spentCents: spent, budgetCents: budget, level: level)
        XCTAssertNotNil(badge)
        XCTAssertTrue(badge?.contains("50") == true, "expected 50 in \(badge ?? "nil")")
    }

    // MARK: MerchantWash brand colors

    func test_brandHex_perSource() {
        XCTAssertEqual(MerchantWash.brandHex(for: .rewe), "E30613")
        XCTAssertEqual(MerchantWash.brandHex(for: .amazon), "FF9900")
        XCTAssertEqual(MerchantWash.brandHex(for: .dm), "0A4EA2")
    }
}
