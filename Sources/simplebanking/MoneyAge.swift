import Foundation

// MARK: - MoneyAge
//
// FIFO-basierte Auswertung „wie alt ist das Geld, das du gerade ausgibst?".
// Annahme: das älteste Geld wird zuerst ausgegeben (Warteschlange). Pro
// Ausgabe wird ein gewichteter Durchschnitt des Alters der verbrauchten
// Eingangs-Chunks berechnet — eine Zahl pro Ausgabe. Der gemeldete Wert
// ist der Durchschnitt über die letzten N Ausgaben.

enum MoneyAge {

    /// Ein Geldfluss-Eintrag: positiver `amount` = Eingang, negativer = Ausgabe.
struct Entry: Equatable {
    let date: Date
    let amount: Decimal

    init(date: Date, amount: Decimal) {
            self.date = date
            self.amount = amount
        }
    }

struct Result: Equatable {
        /// Durchschnittliches Alter (in Tagen) der letzten `windowSize` Ausgaben.
    let averageDays: Double
        /// Wieviele Ausgaben tatsächlich in den Durchschnitt eingeflossen sind
        /// (Cap: `windowSize`).
    let sampleSize: Int
        /// Wieviele Ausgaben insgesamt aus den Daten beobachtet wurden.
    let totalExpenses: Int
        /// Wieviele Ausgaben gar nicht (oder nur teilweise) durch frühere
        /// Eingänge gedeckt waren — der ungedeckte Anteil entstand aus
        /// Dispokredit oder Daten-Lücken am Anfang des Zeitraums.
    let uncoveredExpenses: Int
    let band: Band
    }

enum Band: String, Equatable {
        case sparse        // < 15 Tage — „Eingang zu Ausgang"
        case ok            // 15–30 Tage — „solide, aber eng"
        case puffer        // 30–60 Tage — „du hast Puffer"
        case monthAhead    // ≥ 60 Tage — „du lebst einen Monat voraus"
        case unknown       // keine Ausgaben/Daten

    static func from(days: Double) -> Band {
            if days < 15 { return .sparse }
            if days < 30 { return .ok }
            if days < 60 { return .puffer }
            return .monthAhead
        }
    }

    /// Berechnet das durchschnittliche Geld-Alter über die letzten
    /// `windowSize` Ausgaben. Liefert `nil` wenn keine Daten vorhanden sind.
    ///
    /// - Parameter entries: Beliebige Reihenfolge — wird intern chronologisch sortiert.
    /// - Parameter windowSize: Wieviele letzte Ausgaben in den Durchschnitt eingehen.
    /// - Parameter now: Wird derzeit nicht für die Berechnung gebraucht (das
    ///   Alter ist relativ zum jeweiligen Ausgabe-Datum, nicht zu heute);
    ///   bleibt als Parameter für zukünftige „live floating"-Varianten.
static func calculate(
        entries: [Entry],
        windowSize: Int = 10,
        now: Date = Date()
    ) -> Result {
        let sorted = entries.sorted { $0.date < $1.date }

        // Queue: (Eingangs-Datum, verbleibender Betrag). FIFO.
        var queue: [(date: Date, amount: Decimal)] = []
        var perExpenseAges: [Double] = []
        var totalExpenses = 0
        var uncovered = 0

        for entry in sorted {
            if entry.amount > 0 {
                queue.append((entry.date, entry.amount))
                continue
            }
            if entry.amount == 0 { continue }

            totalExpenses += 1
            var remaining = -entry.amount
            var weightedAgeSum: Decimal = 0
            var consumed: Decimal = 0

            while remaining > 0, !queue.isEmpty {
                let ageDays = max(0, entry.date.timeIntervalSince(queue[0].date) / 86_400)
                let take = min(queue[0].amount, remaining)
                weightedAgeSum += Decimal(ageDays) * take
                consumed += take
                if queue[0].amount <= remaining {
                    queue.removeFirst()
                    remaining -= take
                } else {
                    queue[0].amount -= take
                    remaining = 0
                }
            }

            if consumed > 0 {
                let avgAge = NSDecimalNumber(decimal: weightedAgeSum).doubleValue
                            / NSDecimalNumber(decimal: consumed).doubleValue
                perExpenseAges.append(avgAge)
            }
            if remaining > 0 {
                uncovered += 1
            }
        }

        let window = Array(perExpenseAges.suffix(max(1, windowSize)))
        guard !window.isEmpty else {
            return Result(
                averageDays: 0,
                sampleSize: 0,
                totalExpenses: totalExpenses,
                uncoveredExpenses: uncovered,
                band: .unknown
            )
        }
        let avg = window.reduce(0, +) / Double(window.count)
        return Result(
            averageDays: avg,
            sampleSize: window.count,
            totalExpenses: totalExpenses,
            uncoveredExpenses: uncovered,
            band: Band.from(days: avg)
        )
    }

    /// Adapter: konvertiert die App-Transaktionen in `Entry`-Liste.
    /// Ungültige Daten / Beträge werden übersprungen.
static func entries(
        from transactions: [TransactionsResponse.Transaction]
    ) -> [Entry] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current

        return transactions.compactMap { tx -> Entry? in
            guard let dateStr = tx.bookingDate ?? tx.valueDate,
                  let date = formatter.date(from: dateStr),
                  let amountStr = tx.amount?.amount,
                  let amount = Decimal(string: amountStr, locale: Locale(identifier: "en_US_POSIX"))
            else { return nil }
            return Entry(date: date, amount: amount)
        }
    }
}
