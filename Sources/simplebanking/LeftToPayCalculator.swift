import Foundation

/// Computes the sum of recurring payments that are still expected to hit the
/// account in the current cycle (previous salary day → next salary day).
///
/// Keep it dumb: only high-plausibility entries from FixedCostsAnalyzer,
/// no prediction magic. Returns the amount the user should mentally subtract
/// from their balance to know what's actually free to spend.
///
/// Asymmetrische Toleranz:
/// - `toleranceBefore`: Gehalt kann bis zu N Tage FRÜHER kommen (typ. 4)
/// - `toleranceAfter`: Gehalt kann bis zu N Tage SPÄTER kommen (typ. 1, nicht 4)
///   Real-World-Asymmetrie: Gehalt vorgezogen auf Freitag ist häufig,
///   Gehalt 4 Tage verspätet ist sehr selten.
enum LeftToPayCalculator {

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Sum of recurring payments expected in the current cycle and not yet charged.
    static func compute(
        payments: [RecurringPayment],
        salaryDay: Int,
        toleranceBefore: Int = 0,
        toleranceAfter: Int = 0,
        today: Date = Date()
    ) -> Double {
        let cStart = cycleStart(salaryDay: salaryDay, toleranceBefore: toleranceBefore, today: today)
        let cEnd   = cycleEnd(salaryDay: salaryDay,
                              toleranceBefore: toleranceBefore,
                              toleranceAfter: toleranceAfter,
                              today: today)

        var sum: Double = 0
        for p in payments {
            guard p.frequency != .irregular else { continue }
            guard p.confidence >= 0.6 else { continue }
            guard let last = isoFormatter.date(from: p.lastDate) else { continue }

            // Already charged in this cycle → nothing more expected from it.
            if last >= cStart { continue }

            let next = nextExpected(last: last, frequency: p.frequency)
            // Expected in the cycle (or overdue, which also counts).
            if next <= cEnd {
                sum += p.averageAmount
            }
        }
        return sum
    }

    // MARK: - Cycle boundaries
    //
    // Mirrors the pattern in SalaryProgressCalculator.progress() so that
    // "what is this cycle" is consistent across the app. The resolved salary
    // day is clamped to the actual days-in-target-month, so a 31 stays a 31
    // in March but becomes a 30 in April.

    /// Start of the current cycle = most recent salary day on or before today,
    /// shifted earlier by `toleranceBefore` days so payments booked within the
    /// pre-arrival window still count as "new cycle".
    static func cycleStart(salaryDay: Int, toleranceBefore: Int = 0, today: Date) -> Date {
        let cal = Calendar.current
        let anchor = resolvedSalaryDate(salaryDay: salaryDay, anchorMonth: today,
                                        toleranceBefore: toleranceBefore, forEnd: false, today: today)
        let start = cal.date(byAdding: .day, value: -toleranceBefore, to: anchor) ?? anchor
        return cal.startOfDay(for: start)
    }

    /// End of the current cycle = next salary day strictly after today,
    /// shifted later by `toleranceAfter` days. `toleranceBefore` wird nur
    /// für die „ist Gehalt schon da"-Weiche in `resolvedSalaryDate` gebraucht.
    static func cycleEnd(salaryDay: Int,
                         toleranceBefore: Int = 0,
                         toleranceAfter: Int = 0,
                         today: Date) -> Date {
        let cal = Calendar.current
        let anchor = resolvedSalaryDate(salaryDay: salaryDay, anchorMonth: today,
                                        toleranceBefore: toleranceBefore, forEnd: true, today: today)
        let end = cal.date(byAdding: .day, value: toleranceAfter, to: anchor) ?? anchor
        return cal.startOfDay(for: end)
    }

    /// Resolves the salary date for the cycle boundary:
    /// - `forEnd == false`: most recent resolved salary date ≤ today (within toleranceBefore)
    /// - `forEnd == true`:  next resolved salary date > today (within toleranceBefore)
    ///
    /// `toleranceBefore` bestimmt, ab wann wir „Gehalt ist angekommen" annehmen —
    /// nominaler Tag minus Before-Toleranz. Die After-Toleranz spielt für die
    /// Boundary-Entscheidung keine Rolle (nur für cycleEnd-Shift).
    private static func resolvedSalaryDate(
        salaryDay: Int,
        anchorMonth: Date,
        toleranceBefore: Int,
        forEnd: Bool,
        today: Date
    ) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: anchorMonth)
        let thisMonthStart = cal.date(from: comps) ?? today
        let thisMonthSalary = saveSalaryDate(
            in: thisMonthStart, nominalDay: salaryDay
        )

        let todayDay = cal.component(.day, from: today)
        let thisMonthDay = cal.component(.day, from: thisMonthSalary)
        // „Gehalt ist schon angekommen (oder im Pre-Fenster)" sobald heute >= salaryDay - toleranceBefore
        let salaryInPast = todayDay >= thisMonthDay - toleranceBefore

        if forEnd {
            if salaryInPast {
                let nextMonthStart = cal.date(byAdding: .month, value: 1, to: thisMonthStart) ?? today
                return saveSalaryDate(in: nextMonthStart, nominalDay: salaryDay)
            } else {
                return thisMonthSalary
            }
        } else {
            if salaryInPast {
                return thisMonthSalary
            } else {
                let prevMonthStart = cal.date(byAdding: .month, value: -1, to: thisMonthStart) ?? today
                return saveSalaryDate(in: prevMonthStart, nominalDay: salaryDay)
            }
        }
    }

    /// Builds a safe salary-day Date for the given target month, clamping the
    /// day to the month's length (so nominalDay=31 → 30 in April, 28 in Feb).
    private static func saveSalaryDate(in monthStart: Date, nominalDay: Int) -> Date {
        let cal = Calendar.current
        let daysInMonth = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 28
        let day = max(1, min(nominalDay, daysInMonth))
        var comps = cal.dateComponents([.year, .month], from: monthStart)
        comps.day = day
        return cal.date(from: comps) ?? monthStart
    }

    // MARK: - Frequency step

    static func nextExpected(last: Date, frequency: PaymentFrequency) -> Date {
        let cal = Calendar.current
        switch frequency {
        case .monthly:   return cal.date(byAdding: .month, value: 1,  to: last) ?? last
        case .quarterly: return cal.date(byAdding: .month, value: 3,  to: last) ?? last
        case .yearly:    return cal.date(byAdding: .month, value: 12, to: last) ?? last
        case .irregular: return last
        }
    }
}
