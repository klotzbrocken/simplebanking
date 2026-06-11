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
        countedPayments(payments: payments,
                        salaryDay: salaryDay,
                        toleranceBefore: toleranceBefore,
                        toleranceAfter: toleranceAfter,
                        today: today)
            .reduce(0) { $0 + $1.averageAmount }
    }

    /// Die konkreten Posten, die `compute` aufsummiert — für Diagnose/Aufschlüsselung.
    /// Selbe Prädikate wie `compute`: nicht-irregulär, Confidence ≥ 0.6, in diesem
    /// Zyklus noch nicht gebucht (last < cycleStart) und nächste Fälligkeit ≤ cycleEnd
    /// (überfällige zählen bewusst mit).
    static func countedPayments(
        payments: [RecurringPayment],
        salaryDay: Int,
        toleranceBefore: Int = 0,
        toleranceAfter: Int = 0,
        today: Date = Date()
    ) -> [RecurringPayment] {
        let cStart = cycleStart(salaryDay: salaryDay, toleranceBefore: toleranceBefore, today: today)
        let cEnd   = cycleEnd(salaryDay: salaryDay,
                              toleranceBefore: toleranceBefore,
                              toleranceAfter: toleranceAfter,
                              today: today)
        return countedPayments(payments: payments, cycleStart: cStart, cycleEnd: cEnd)
    }

    /// Variante mit EXPLIZITEN Zyklusgrenzen (z.B. aus `cycleBounds`, wenn das
    /// Gehalt real früher einging). Selbe Prädikate.
    static func countedPayments(
        payments: [RecurringPayment],
        cycleStart cStart: Date,
        cycleEnd cEnd: Date
    ) -> [RecurringPayment] {
        payments.filter { p in
            guard p.frequency != .irregular,
                  p.confidence >= 0.6,
                  let last = isoFormatter.date(from: p.lastDate),
                  last < cStart                                   // noch nicht in diesem Zyklus gebucht
            else { return false }
            return nextExpected(last: last, frequency: p.frequency) <= cEnd
        }
    }

    /// Tatsächliche Zyklusgrenzen für „Noch offen":
    /// - Standard = NOMINALER Gehaltszyklus (Gehaltstag → Gehaltstag, OHNE Toleranz).
    /// - Wenn `actualSalaryArrival` gesetzt ist (real erkannte Gehalts-Gutschrift)
    ///   und aktueller als der nominale Start liegt (= Gehalt kam diesen Monat,
    ///   evtl. früher) → Start = dieses Eingangsdatum, Ende = +1 Monat.
    /// So schaltet der Zyklus NUR bei tatsächlich früherem Geldeingang um, nicht
    /// schon im Toleranzfenster davor.
    static func cycleBounds(
        salaryDay: Int,
        today: Date = Date(),
        actualSalaryArrival: Date? = nil
    ) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let nominalStart = cycleStart(salaryDay: salaryDay, toleranceBefore: 0, today: today)
        let nominalEnd   = cycleEnd(salaryDay: salaryDay, toleranceBefore: 0, toleranceAfter: 0, today: today)
        if let arrival = actualSalaryArrival {
            let a = cal.startOfDay(for: arrival)
            if a > nominalStart && a <= cal.startOfDay(for: today) {
                let end = cal.date(byAdding: .month, value: 1, to: a) ?? nominalEnd
                return (a, end)
            }
        }
        return (nominalStart, nominalEnd)
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
