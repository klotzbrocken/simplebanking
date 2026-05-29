import Foundation

/// Pure round-up math for the savings pot ("Spartopf").
///
/// For each expense, returns the cent difference between the transaction amount and
/// the next higher multiple of `stepCents`. Income, exact boundary amounts, and
/// invalid step sizes return 0.
enum RoundupCalculator {

    /// Cent contribution to the savings pot.
    ///
    /// - Parameters:
    ///   - amount: TRX amount in EUR (negative = expense, positive = income).
    ///   - stepCents: Step size in cents — 100 = 1 €, 200 = 2 €, 500 = 5 €, 1000 = 10 €.
    /// - Returns: 0 for income, exact boundary, or non-positive step. Otherwise the
    ///   positive cent difference to the next higher multiple of `stepCents`.
    static func roundupCents(amount: Decimal, stepCents: Int) -> Int {
        guard stepCents > 0 else { return 0 }
        guard amount < 0 else { return 0 }

        let absAmount = -amount
        var scaled = absAmount * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let cents = NSDecimalNumber(decimal: rounded).intValue

        let remainder = cents % stepCents
        return remainder == 0 ? 0 : (stepCents - remainder)
    }
}
