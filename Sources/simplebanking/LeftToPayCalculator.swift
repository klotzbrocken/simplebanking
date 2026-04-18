import Foundation

/// Computes the sum of recurring payments that are still expected to hit the
/// account in the current cycle (previous salary day → next salary day).
///
/// Keep it dumb: only high-plausibility entries from FixedCostsAnalyzer,
/// no prediction magic. Returns the amount the user should mentally subtract
/// from their balance to know what's actually free to spend.
///
/// Tolerance window semantics:
/// - salaryDay is the nominal day of month the cycle resets
/// - tolerance widens the boundary on BOTH sides of the resolved date
///   (used for .begin/.mid presets where the exact day varies ±4)
/// - manual exact day = tolerance 0
enum LeftToPayCalculator {

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Sum of recurring payments expected in the current cycle and not yet charged.
    /// - Parameters:
    ///   - payments: RecurringPayment entries from FixedCostsAnalyzer (90d history).
    ///   - salaryDay: day of month the cycle resets (from BankSlotSettings.effectiveSalaryDay).
    ///   - tolerance: ±days around the resolved salary day (from BankSlotSettings.salaryDayTolerance).
    ///   - today: injection point for tests.
    static func compute(
        payments: [RecurringPayment],
        salaryDay: Int,
        tolerance: Int = 0,
        today: Date = Date()
    ) -> Double {
        let cStart = cycleStart(salaryDay: salaryDay, tolerance: tolerance, today: today)
        let cEnd   = cycleEnd(salaryDay: salaryDay, tolerance: tolerance, today: today)

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
    /// shifted earlier by `tolerance` days so payments booked within the
    /// pre-arrival window still count as "new cycle".
    static func cycleStart(salaryDay: Int, tolerance: Int = 0, today: Date) -> Date {
        let cal = Calendar.current
        let anchor = resolvedSalaryDate(salaryDay: salaryDay, anchorMonth: today, tolerance: tolerance, forEnd: false, today: today)
        let start = cal.date(byAdding: .day, value: -tolerance, to: anchor) ?? anchor
        return cal.startOfDay(for: start)
    }

    /// End of the current cycle = next salary day strictly after today,
    /// shifted later by `tolerance` days so late-arriving payments still
    /// count as "this cycle".
    static func cycleEnd(salaryDay: Int, tolerance: Int = 0, today: Date) -> Date {
        let cal = Calendar.current
        let anchor = resolvedSalaryDate(salaryDay: salaryDay, anchorMonth: today, tolerance: tolerance, forEnd: true, today: today)
        let end = cal.date(byAdding: .day, value: tolerance, to: anchor) ?? anchor
        // Include the full end day (so cycleEnd is the START of the day after +tolerance)
        return cal.startOfDay(for: end)
    }

    /// Resolves the salary date for the cycle boundary:
    /// - `forEnd == false`: most recent resolved salary date ≤ today (within tolerance)
    /// - `forEnd == true`:  next resolved salary date > today (within tolerance)
    ///
    /// Day is clamped to the target month's length each time, so day 31 becomes
    /// 30 in April, 28/29 in February, etc.
    private static func resolvedSalaryDate(
        salaryDay: Int,
        anchorMonth: Date,
        tolerance: Int,
        forEnd: Bool,
        today: Date
    ) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: anchorMonth)
        let thisMonthStart = cal.date(from: comps) ?? today
        let thisMonthSalary = saveSalaryDate(
            in: thisMonthStart, nominalDay: salaryDay
        )

        // Determine if this month's salary is "in the past" relative to today.
        // Matches SalaryProgressCalculator: tolerance pulls the boundary earlier,
        // so we consider salary arrived even a few days before the nominal date.
        let todayDay = cal.component(.day, from: today)
        let thisMonthDay = cal.component(.day, from: thisMonthSalary)
        let salaryInPast = todayDay >= thisMonthDay - tolerance

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
