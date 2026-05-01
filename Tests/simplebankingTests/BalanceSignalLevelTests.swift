import XCTest
@testable import simplebanking

// MARK: - BalanceSignal Level Classification
//
// Verifiziert, dass `BalanceSignal.classify(...)` mit dem 6-Tier-Modell
// (deepOverdraft, overdraft, low, medium, good, veryGood, +unknown)
// alle Übergänge korrekt setzt.

final class BalanceSignalLevelTests: XCTestCase {

    /// Standard-Defaults: deepOverdraft=-1000, low=500, medium=2000, veryGood=5000.
    private var defaultThresholds: BalanceSignalThresholds {
        BalanceSignal.normalizedThresholds(
            deepOverdraft: -1000,
            low: 500,
            medium: 2000,
            veryGood: 5000
        )
    }

    // MARK: - Sechs Tiers, ein Test pro repräsentativer Wert

    func test_deepOverdraft_belowThreshold() {
        XCTAssertEqual(BalanceSignal.classify(balance: -1500, thresholds: defaultThresholds), .deepOverdraft)
    }

    func test_overdraft_betweenDeepAndZero() {
        XCTAssertEqual(BalanceSignal.classify(balance: -500, thresholds: defaultThresholds), .overdraft)
    }

    func test_low_betweenZeroAndLowUB() {
        XCTAssertEqual(BalanceSignal.classify(balance: 200, thresholds: defaultThresholds), .low)
    }

    func test_medium_betweenLowAndMedium() {
        XCTAssertEqual(BalanceSignal.classify(balance: 1500, thresholds: defaultThresholds), .medium)
    }

    func test_good_betweenMediumAndVeryGood() {
        XCTAssertEqual(BalanceSignal.classify(balance: 3000, thresholds: defaultThresholds), .good)
    }

    func test_veryGood_aboveVeryGoodLB() {
        XCTAssertEqual(BalanceSignal.classify(balance: 8000, thresholds: defaultThresholds), .veryGood)
    }

    // MARK: - Edge cases an den Grenzen

    func test_zero_isLow_notOverdraft() {
        // Saldo = 0 ist nicht „überzogen" (balance < 0), sondern „knapp" (balance < lowUB).
        XCTAssertEqual(BalanceSignal.classify(balance: 0, thresholds: defaultThresholds), .low)
    }

    func test_exactlyDeepThreshold_isOverdraft() {
        // -1000 = deepThreshold; classify nutzt strikt < deepThr → -1000 fällt noch in overdraft.
        XCTAssertEqual(BalanceSignal.classify(balance: -1000, thresholds: defaultThresholds), .overdraft)
    }

    func test_exactlyVeryGoodLB_isStillGood() {
        // 5000 = veryGoodLowerBound; classify nutzt <=, also gerade noch good.
        XCTAssertEqual(BalanceSignal.classify(balance: 5000, thresholds: defaultThresholds), .good)
    }

    func test_unknown_whenBalanceNil() {
        XCTAssertEqual(BalanceSignal.classify(balance: nil, thresholds: defaultThresholds), .unknown)
    }

    // MARK: - normalizedThresholds clampt unsinnige Eingaben

    func test_normalize_clampsDeepToStrictlyNegative() {
        // User trägt 0 ein → muss auf -1 geclamped werden, sonst Lücke zum overdraft-Bereich.
        let t = BalanceSignal.normalizedThresholds(deepOverdraft: 0, low: 500, medium: 2000, veryGood: 5000)
        XCTAssertEqual(t.deepOverdraftThreshold, -1)
    }

    func test_normalize_clampsLowToZeroOrAbove() {
        let t = BalanceSignal.normalizedThresholds(deepOverdraft: -1000, low: -100, medium: 2000, veryGood: 5000)
        XCTAssertEqual(t.lowUpperBound, 0)
    }

    func test_normalize_keepsMediumAboveLow() {
        // medium <= low → wird auf low+1 gehoben.
        let t = BalanceSignal.normalizedThresholds(deepOverdraft: -1000, low: 500, medium: 300, veryGood: 5000)
        XCTAssertEqual(t.mediumUpperBound, 501)
    }

    func test_normalize_keepsVeryGoodAboveMedium() {
        // veryGood <= medium → wird auf medium+1 gehoben.
        let t = BalanceSignal.normalizedThresholds(deepOverdraft: -1000, low: 500, medium: 2000, veryGood: 1000)
        XCTAssertEqual(t.veryGoodLowerBound, 2001)
    }
}
