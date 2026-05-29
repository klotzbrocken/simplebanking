import XCTest
@testable import simplebanking

final class RoundupCalculatorTests: XCTestCase {

    // MARK: - Guard clauses

    func test_income_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: 100, stepCents: 100), 0)
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "0.01")!, stepCents: 100), 0)
    }

    func test_zero_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: 0, stepCents: 100), 0)
    }

    func test_invalidStep_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: -3.47, stepCents: 0), 0)
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: -3.47, stepCents: -100), 0)
    }

    // MARK: - 1 € step

    func test_step100_normal() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-3.47")!, stepCents: 100), 53)
    }

    func test_step100_exactBoundary_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-5.00")!, stepCents: 100), 0)
    }

    func test_step100_oneCentBelowBoundary() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-4.99")!, stepCents: 100), 1)
    }

    func test_step100_smallAmount() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-0.01")!, stepCents: 100), 99)
    }

    // MARK: - 2 € step

    func test_step200_normal() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-3.47")!, stepCents: 200), 53)
    }

    func test_step200_exactBoundary_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-2.00")!, stepCents: 200), 0)
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-4.00")!, stepCents: 200), 0)
    }

    func test_step200_oddEuroDifference() {
        // 1.50 € → next mult of 2.00 → diff 0.50 = 50 ct
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-1.50")!, stepCents: 200), 50)
    }

    // MARK: - 5 € step

    func test_step500_normal() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-3.47")!, stepCents: 500), 153)
    }

    func test_step500_exactBoundary_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-5.00")!, stepCents: 500), 0)
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-10.00")!, stepCents: 500), 0)
    }

    // MARK: - 10 € step

    func test_step1000_normal() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-3.47")!, stepCents: 1000), 653)
    }

    func test_step1000_exactBoundary_returnsZero() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-10.00")!, stepCents: 1000), 0)
    }

    func test_step1000_largeAmount() {
        // -127.83 € → 12783 ct → 12783 % 1000 = 783 → diff 217 ct
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-127.83")!, stepCents: 1000), 217)
    }

    // MARK: - Decimal precision

    func test_decimalFromString_isExact() {
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(string: "-0.30")!, stepCents: 100), 70)
    }

    func test_amountFromDouble_stableForTypicalBankValues() {
        // Bank-API delivers prices like -19.95 — Decimal init from Double introduces
        // a tiny error, but NSDecimalRound(.plain) snaps it back to 1995 ct.
        XCTAssertEqual(RoundupCalculator.roundupCents(amount: Decimal(-19.95), stepCents: 100), 5)
    }
}
