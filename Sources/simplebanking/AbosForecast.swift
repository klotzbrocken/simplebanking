import Foundation

/// A single subscription charge on the calendar — either an actual past booking (`isForecast == false`)
/// or a projected future one (`isForecast == true`).
struct UpcomingCharge: Equatable, Identifiable {
    var id: String { "\(groupKey)|\(AbosForecast.dayKey(date))|\(isForecast)" }
    let date: Date
    let merchant: String
    let amount: Double          // signed; negative = expense
    let frequency: PaymentFrequency
    let groupKey: String
    var isForecast: Bool = true
}

/// Projects detected recurring payments (`FixedCostsAnalyzer.analyze`) forward in time so the
/// subscription calendar can show what's *coming*. Pure / deterministic — all reference dates are
/// passed in explicitly (no `Date()` inside) so it is fully testable.
///
/// Source is auto-detection only: subscriptions billed quarterly/yearly that fall outside the
/// visible transaction window simply won't be projected (manual marking is intentionally out of
/// scope for now). `.irregular` payments are never projected.
enum AbosForecast {

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }()

    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Month delta between consecutive charges; `nil` for `.irregular` (not projectable).
    static func monthStep(_ frequency: PaymentFrequency) -> Int? {
        switch frequency {
        case .monthly:   return 1
        case .quarterly: return 3
        case .yearly:    return 12
        case .irregular: return nil
        }
    }

    /// Parse a `RecurringPayment.lastDate` ("yyyy-MM-dd") into a start-of-day `Date`.
    static func parseDate(_ s: String) -> Date? {
        dateParser.date(from: s).map { calendar.startOfDay(for: $0) }
    }

    static func dayKey(_ date: Date) -> String {
        dateParser.string(from: date)
    }

    /// First projected occurrence strictly after `after`, anchored on `lastDate` and stepped by
    /// the frequency. Returns `nil` for irregular/unparseable input.
    static func nextPaymentDate(after: Date, lastDate: String, frequency: PaymentFrequency) -> Date? {
        guard let step = monthStep(frequency), let anchor = parseDate(lastDate) else { return nil }
        let afterDay = calendar.startOfDay(for: after)
        var d = anchor
        var safety = 0
        while d <= afterDay {
            guard let next = calendar.date(byAdding: .month, value: step, to: d) else { return nil }
            d = next
            safety += 1
            if safety > 2000 { return nil }
        }
        return d
    }

    /// All expected charges in `(from, until]` for the given recurring payments.
    /// Sorted ascending by date. Payments below `minConfidence` or `.irregular` are skipped
    /// (same 0.6 threshold `LeftToPayCalculator` uses).
    static func project(
        payments: [RecurringPayment],
        from: Date,
        until: Date,
        minConfidence: Double = 0.6
    ) -> [UpcomingCharge] {
        let fromDay = calendar.startOfDay(for: from)
        let untilDay = calendar.startOfDay(for: until)
        guard fromDay <= untilDay else { return [] }

        var charges: [UpcomingCharge] = []
        for p in payments where p.frequency != .irregular && p.confidence >= minConfidence {
            guard let step = monthStep(p.frequency),
                  var d = nextPaymentDate(after: fromDay, lastDate: p.lastDate, frequency: p.frequency)
            else { continue }
            var safety = 0
            while d <= untilDay {
                charges.append(UpcomingCharge(
                    date: d,
                    merchant: p.merchant,
                    amount: -abs(p.averageAmount),
                    frequency: p.frequency,
                    groupKey: p.groupKey
                ))
                guard let next = calendar.date(byAdding: .month, value: step, to: d) else { break }
                d = next
                safety += 1
                if safety > 2000 { break }
            }
        }
        return charges.sorted { $0.date < $1.date }
    }

    /// Whole days from `from` to `to` (start-of-day granularity). May be negative.
    static func daysUntil(from: Date, to: Date) -> Int {
        let a = calendar.startOfDay(for: from)
        let b = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }
}
