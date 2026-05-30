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

    /// Summe der Roundup-Cents über eine TRX-Liste im Datums-Range (inklusive).
    /// Filter: status == "booked", currency == "EUR", amount < 0. Ignoriert TRX
    /// ohne `bookingDate`. Datumsvergleich lexikographisch über YYYY-MM-DD.
    ///
    /// Für die Live-Sicht im Aufrunden-Modus — der aktuelle `stepCents` aus dem
    /// Banner-Picker wird auf die historischen TRX angewendet, sodass User
    /// hypothetisch sehen können wie viel mit anderem Step gespart wäre.
    static func liveRoundupCents(
        transactions: [TransactionsResponse.Transaction],
        bookingDateFrom: String,
        bookingDateTo: String,
        stepCents: Int
    ) -> Int {
        guard stepCents > 0 else { return 0 }
        var sum = 0
        for tx in transactions {
            guard let booking = tx.bookingDate,
                  booking >= bookingDateFrom,
                  booking <= bookingDateTo else { continue }
            guard tx.status == "booked" else { continue }
            let currency = (tx.amount?.currency ?? "EUR").uppercased()
            guard currency == "EUR" else { continue }
            let amount = Decimal(tx.parsedAmount)
            sum += roundupCents(amount: amount, stepCents: stepCents)
        }
        return sum
    }

    /// View-Lens für die Aufrunden-Ansicht: liefert den anzuzeigenden Betrag.
    /// Bei EUR-Ausgaben das nächste Vielfache von `stepCents` (mit negativem Vorzeichen);
    /// sonst (Income, Non-EUR, Boundary, ungültige Step) der Original-Betrag unverändert.
    ///
    /// - Parameters:
    ///   - originalAmount: Original-TRX-Betrag (Decimal, Vorzeichen wie in der Bank).
    ///   - currency: ISO-Currency-Code (case-insensitive).
    ///   - stepCents: Schrittweite in Cent. ≤ 0 → Original.
    static func displayedAmount(originalAmount: Decimal, currency: String, stepCents: Int) -> Decimal {
        guard currency.uppercased() == "EUR" else { return originalAmount }
        let cents = roundupCents(amount: originalAmount, stepCents: stepCents)
        guard cents > 0 else { return originalAmount }
        return originalAmount - Decimal(cents) / 100
    }
}
