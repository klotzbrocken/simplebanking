import Foundation

// MARK: - MMI ViewModel

@MainActor
final class MMIViewModel: ObservableObject {

    @Published var period: MMIPeriod = .max {
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
            periodMonths: period.monthsSpan()
        )
    }

    // Diff-Badges
    var scoreDiff:       Double { displayed.score       - real.score }
    var savingsRateDiff: Double { displayed.savingsRate - real.savingsRate }

    // MARK: Load

    func load(transactions: [TransactionsResponse.Transaction], balance: Double) {
        let now = Date()
        let cutoff = period.cutoffDate(asOf: now)
        let recent = transactions.filter { txDate($0) >= cutoff }

        // Dieselbe "Sparen"-Definition wie in Abos & Verträge: wiederkehrende Posten,
        // die (auto via defaultTab ODER per User-Verschiebung) im `.sparen`-Tab
        // liegen, zählen als Sparen statt Ausgabe — z.B. die als Altersvorsorge
        // geführte Eigentumswohnung. So sind MMI und Abos konsistent.
        let savingsTagged = Self.savingsTaggedFingerprints(in: transactions)
        func isTaggedSavings(_ tx: TransactionsResponse.Transaction) -> Bool {
            savingsTagged.contains(TransactionRecord.fingerprint(for: tx))
        }

        let income   = recent.filter { $0.mmiKind == .income  }.reduce(0.0) { $0 + $1.parsedAmount }
        let expenses = recent.filter { $0.mmiKind == .expense && !isTaggedSavings($0) }
            .reduce(0.0) { $0 + abs($1.parsedAmount) }
        let includeSavings = UserDefaults.standard.object(forKey: "mmiIncludeSavings") as? Bool ?? true
        let savings  = includeSavings
            ? recent.filter { $0.mmiKind == .savings || ($0.mmiKind == .expense && isTaggedSavings($0)) }
                .reduce(0.0) { $0 + abs($1.parsedAmount) }
            : 0

        real = MMIComponents(
            income:   income,
            expenses: expenses,
            savings:  savings,
            balance:  balance,
            periodMonths: period.monthsSpan(asOf: now)
        )
        resetPlan()
    }

    func resetPlan() {
        planIncome   = real.income
        planExpenses = real.expenses
        planSavings  = real.savings
        planBalance  = real.balance
    }

    /// Fingerprints aller Transaktionen, die zu einem wiederkehrenden Posten im
    /// `.sparen`-Tab gehören (gleiche Klassifizierung wie Abos & Verträge:
    /// `effectiveTab = User-Override ?? candidate.defaultTab`).
    private static func savingsTaggedFingerprints(
        in transactions: [TransactionsResponse.Transaction]
    ) -> Set<String> {
        let candidates = SubscriptionDetector.detect(in: transactions)
        let assignments = RecurringAssignments.current()
        var set = Set<String>()
        for c in candidates {
            let tab = assignments.assignment(for: c.id).tab
                .flatMap { SubscriptionTab(rawValue: $0) } ?? c.defaultTab
            guard tab == .sparen else { continue }
            for tx in c.matchedTransactions {
                set.insert(TransactionRecord.fingerprint(for: tx))
            }
        }
        return set
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
