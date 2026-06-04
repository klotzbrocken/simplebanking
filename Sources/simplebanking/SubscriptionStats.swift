import Foundation

/// Aggregated subscription cost overview for the stats view (yearly forecast, average monthly,
/// per-category breakdown for the ring). Mirrors the normalization in
/// `FixedCostsAnalyzer.totalMonthlyFixedCosts`: `averageAmount` is the per-charge amount, so a
/// monthly sub costs ×12/year, quarterly ×4, yearly ×1.
struct SubscriptionStats: Equatable {
    struct CategorySlice: Equatable {
        let category: PaymentCategory
        let yearlyAmount: Double     // absolute € per year
        let share: Double            // 0…1 of yearlyForecast
    }
    let yearlyForecast: Double
    let avgMonthly: Double
    let byCategory: [CategorySlice]  // sorted descending by yearlyAmount

    static let empty = SubscriptionStats(yearlyForecast: 0, avgMonthly: 0, byCategory: [])
}

enum SubscriptionStatsCalc {

    /// Yearly cost of one recurring payment. `.irregular` contributes 0 (not a reliable subscription).
    static func yearlyAmount(_ p: RecurringPayment) -> Double {
        let per = abs(p.averageAmount)
        switch p.frequency {
        case .monthly:   return per * 12
        case .quarterly: return per * 4
        case .yearly:    return per
        case .irregular: return 0
        }
    }

    static func compute(payments: [RecurringPayment], minConfidence: Double = 0.6) -> SubscriptionStats {
        let relevant = payments.filter { $0.frequency != .irregular && $0.confidence >= minConfidence }
        let yearly = relevant.reduce(0.0) { $0 + yearlyAmount($1) }
        guard yearly > 0 else { return .empty }

        var byCat: [PaymentCategory: Double] = [:]
        for p in relevant { byCat[p.category, default: 0] += yearlyAmount(p) }

        let slices = byCat
            .map { SubscriptionStats.CategorySlice(category: $0.key, yearlyAmount: $0.value, share: $0.value / yearly) }
            .sorted { $0.yearlyAmount > $1.yearlyAmount }

        return SubscriptionStats(yearlyForecast: yearly, avgMonthly: yearly / 12, byCategory: slices)
    }
}
