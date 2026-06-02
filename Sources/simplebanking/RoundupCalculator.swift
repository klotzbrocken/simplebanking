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
    ///
    /// `excludingDates` blendet bereits ausgezahlte Tage (status `transferred`) aus —
    /// so kann der Payout-Betrag im Auswahl-Dialog nicht erneut Tage enthalten, die
    /// schon überwiesen wurden (verhindert Doppelüberweisung). Default leer = volle
    /// hypothetische Sicht (für die motivational Savings-Card).
    static func liveRoundupCents(
        transactions: [TransactionsResponse.Transaction],
        bookingDateFrom: String,
        bookingDateTo: String,
        stepCents: Int,
        excludingDates: Set<String> = []
    ) -> Int {
        guard stepCents > 0 else { return 0 }
        var sum = 0
        for tx in transactions {
            guard let booking = tx.bookingDate,
                  booking >= bookingDateFrom,
                  booking <= bookingDateTo else { continue }
            if excludingDates.contains(booking) { continue }
            guard tx.status == "booked" else { continue }
            let currency = (tx.amount?.currency ?? "EUR").uppercased()
            guard currency == "EUR" else { continue }
            let amount = Decimal(tx.parsedAmount)
            sum += roundupCents(amount: amount, stepCents: stepCents)
        }
        return sum
    }

    /// Zählt aufeinanderfolgende Tage rückwärts ab heute, an denen eine echte
    /// Outgoing-Überweisung an die Sparkonto-IBAN in Höhe des aufgerundeten
    /// Tagesbetrags (±5 ct Toleranz) gebucht wurde.
    ///
    /// Streak zählt nur belohnt-konsistentes Verhalten — der hypothetische
    /// Aufrundungs-Beitrag muss tatsächlich überwiesen worden sein, sonst 0.
    ///
    /// • Heute keine Match-TRX → 0 (Anzeige im UI ausgeblendet)
    /// • Heute Match, gestern Match → 2
    /// • Tag dazwischen mit Beitrag aber ohne Match-TRX → Bruch
    /// • Tag dazwischen ohne Beitrag (kein Einkauf) → Bruch (konservativ)
    static func liveStreakDays(
        transactions: [TransactionsResponse.Transaction],
        savingsIban: String,
        today: Date = Date(),
        stepCents: Int
    ) -> Int {
        let normalizedSavings = savingsIban.uppercased().filter { !$0.isWhitespace }
        guard !normalizedSavings.isEmpty, stepCents > 0 else { return 0 }

        // Outgoing-TRX-Cents pro Tag, gefiltert auf Sparkonto-IBAN-Empfänger.
        // Gleichzeitig „Regular-Expenses" extrahieren (alle TRX die NICHT an
        // das Sparkonto gingen) — die liefern den Aufrunden-Tagesbetrag.
        var outgoingPerDay: [String: [Int]] = [:]
        var regularTxs: [TransactionsResponse.Transaction] = []
        regularTxs.reserveCapacity(transactions.count)
        for tx in transactions {
            let creditorIban = (tx.creditor?.iban ?? "").uppercased().filter { !$0.isWhitespace }
            let isSavingsTransfer = !creditorIban.isEmpty && creditorIban == normalizedSavings
            if isSavingsTransfer {
                guard let booking = tx.bookingDate else { continue }
                guard tx.status == "booked" else { continue }
                let currency = (tx.amount?.currency ?? "EUR").uppercased()
                guard currency == "EUR" else { continue }
                let raw = tx.parsedAmount
                guard raw < 0 else { continue }
                let absScaled = Decimal(abs(raw)) * 100
                var rounded = Decimal()
                var src = absScaled
                NSDecimalRound(&rounded, &src, 0, .plain)
                outgoingPerDay[booking, default: []].append(NSDecimalNumber(decimal: rounded).intValue)
            } else {
                regularTxs.append(tx)
            }
        }
        guard !outgoingPerDay.isEmpty else { return 0 }

        let cal = Calendar(identifier: .gregorian)
        let f = streakDateFormatter
        var cursor = cal.startOfDay(for: today)
        var count = 0

        while true {
            let dayStr = f.string(from: cursor)
            let outgoing = outgoingPerDay[dayStr] ?? []
            guard !outgoing.isEmpty else { break }

            let dayRoundup = liveRoundupCents(
                transactions: regularTxs,
                bookingDateFrom: dayStr,
                bookingDateTo: dayStr,
                stepCents: stepCents
            )
            guard dayRoundup > 0 else { break }

            let hasMatch = outgoing.contains { abs($0 - dayRoundup) <= 5 }
            guard hasMatch else { break }

            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
            if count >= 10_000 { break }
        }
        return count
    }

    nonisolated(unsafe) private static let streakDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

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
