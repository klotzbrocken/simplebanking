import XCTest
@testable import simplebanking

// MARK: - BalanceAdjustment Tests
//
// Exercises BalanceAdjustment.computeAdjustedBalance, which decides whether to
// subtract a per-slot Dispokredit from the bank-reported balance.
// Subtraction must apply iff (apiFlag == true OR userOverride) AND dispoLimit > 0.

final class CreditLimitAdjustmentTests: XCTestCase {

    func test_apiFlagTrue_subtractsDispo() {
        // C24-style: bank includes overdraft in booked balance, user has 2000€ dispo.
        let result = BalanceAdjustment.computeAdjustedBalance(
            raw: 2000, apiFlag: true, userOverride: false, dispoLimit: 2000
        )
        XCTAssertEqual(result, 0)
    }

    func test_apiFlagFalse_noUserOverride_returnsRaw() {
        // Normal bank: balance is the real balance, no adjustment.
        let result = BalanceAdjustment.computeAdjustedBalance(
            raw: 1500, apiFlag: false, userOverride: false, dispoLimit: 2000
        )
        XCTAssertEqual(result, 1500)
    }

    func test_apiFlagNil_userOverrideTrue_subtractsDispo() {
        // Bank doesn't report the flag at all — user manually forces adjustment.
        let result = BalanceAdjustment.computeAdjustedBalance(
            raw: 2000, apiFlag: nil, userOverride: true, dispoLimit: 2000
        )
        XCTAssertEqual(result, 0)
    }

    func test_apiFlagTrue_dispoLimitZero_returnsRaw() {
        // API says dispo is included, but user hasn't entered the amount.
        // Cannot subtract because we don't know how much. Return raw.
        let result = BalanceAdjustment.computeAdjustedBalance(
            raw: 2000, apiFlag: true, userOverride: false, dispoLimit: 0
        )
        XCTAssertEqual(result, 2000)
    }

    func test_bothFlags_dispoSubtractedOnce() {
        // Override OR API both true — should subtract once, not twice.
        let result = BalanceAdjustment.computeAdjustedBalance(
            raw: 2000, apiFlag: true, userOverride: true, dispoLimit: 2000
        )
        XCTAssertEqual(result, 0)
    }

    func test_apiFlagNil_userOverrideFalse_returnsRaw() {
        // No signal in either direction — never subtract.
        let result = BalanceAdjustment.computeAdjustedBalance(
            raw: 1500, apiFlag: nil, userOverride: false, dispoLimit: 2000
        )
        XCTAssertEqual(result, 1500)
    }

    // MARK: - Edge cases

    func test_negativeRaw_subtracts() {
        // Account already overdrawn: -300€, dispo 2000€ included → real balance -2300€.
        let result = BalanceAdjustment.computeAdjustedBalance(
            raw: -300, apiFlag: true, userOverride: false, dispoLimit: 2000
        )
        XCTAssertEqual(result, -2300)
    }

    func test_apiFlagFalse_userOverrideTrue_subtracts() {
        // User explicitly overrides bank's "false" report.
        let result = BalanceAdjustment.computeAdjustedBalance(
            raw: 2000, apiFlag: false, userOverride: true, dispoLimit: 1000
        )
        XCTAssertEqual(result, 1000)
    }
}
