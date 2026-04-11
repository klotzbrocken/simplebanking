import Foundation

// MARK: - MMI ViewModel

@MainActor
final class MMIViewModel: ObservableObject {

    @Published var period: MMIPeriod = .quarter {
        didSet { resetPlan() }
    }
    @Published var planMode: Bool = false {
        didSet { if planMode { resetPlan() } }
    }

    // Plan-Overrides (Startwert = echte Werte, live editierbar)
    @Published var planIncome:   Double = 0
    @Published var planExpenses: Double = 0
    @Published var planSavings:  Double = 0
    @Published var planBalance:  Double = 0

    @Published private(set) var real: MMIComponents = .zero

    // Angezeigte Werte: plan-overrides wenn planMode aktiv
    var displayed: MMIComponents {
        guard planMode else { return real }
        return MMIComponents(
            income:   planIncome,
            expenses: planExpenses,
            savings:  planSavings,
            balance:  planBalance,
            period:   period
        )
    }

    // Diff-Badges
    var scoreDiff:       Double { displayed.score       - real.score }
    var savingsRateDiff: Double { displayed.savingsRate - real.savingsRate }

    // MARK: Load

    func load(transactions: [TransactionsResponse.Transaction], balance: Double) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -period.days, to: Date()) ?? Date()
        let recent = transactions.filter { txDate($0) >= cutoff }

        let income   = recent.filter { $0.mmiKind == .income  }.reduce(0.0) { $0 + $1.parsedAmount }
        let expenses = recent.filter { $0.mmiKind == .expense }.reduce(0.0) { $0 + abs($1.parsedAmount) }
        let includeSavings = UserDefaults.standard.object(forKey: "mmiIncludeSavings") as? Bool ?? true
        let savings  = includeSavings
            ? recent.filter { $0.mmiKind == .savings }.reduce(0.0) { $0 + abs($1.parsedAmount) }
            : 0

        real = MMIComponents(
            income:   income,
            expenses: expenses,
            savings:  savings,
            balance:  balance,
            period:   period
        )
        resetPlan()
    }

    func resetPlan() {
        planIncome   = real.income
        planExpenses = real.expenses
        planSavings  = real.savings
        planBalance  = real.balance
    }

    // MARK: Helpers

    private let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func txDate(_ tx: TransactionsResponse.Transaction) -> Date {
        guard let s = tx.bookingDate ?? tx.valueDate else { return .distantPast }
        return isoFmt.date(from: String(s.prefix(10))) ?? .distantPast
    }
}
