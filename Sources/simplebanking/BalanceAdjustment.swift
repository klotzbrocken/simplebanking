import Foundation

enum BalanceAdjustment {

    /// Computes the displayed balance after optional Dispokredit subtraction.
    ///
    /// Some banks (e.g. C24) report the booked balance with the user's overdraft credit line
    /// already added in. The Routex/YAXI API signals this via the per-balance `creditLimitIncluded`
    /// flag. The user can additionally force the subtraction via a per-slot setting for banks that
    /// fail to report the flag correctly.
    ///
    /// Subtraction applies when either the bank reports the flag as `true` OR the user override is
    /// set, AND a non-zero `dispoLimit` is available (the API only signals *whether* the credit
    /// line is included, not *how much* — that amount must come from the user-entered limit).
    static func computeAdjustedBalance(
        raw: Double,
        apiFlag: Bool?,
        userOverride: Bool,
        dispoLimit: Int
    ) -> Double {
        let bankReportsIncluded = (apiFlag == true)
        let shouldSubtract = (bankReportsIncluded || userOverride) && dispoLimit > 0
        return shouldSubtract ? raw - Double(dispoLimit) : raw
    }
}
