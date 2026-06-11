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

    /// Monoton wachsendes Token — nur das Ergebnis des jüngsten `load()` wird angewendet.
    private var loadGeneration = 0

    func load(transactions: [TransactionsResponse.Transaction], balance: Double) {
        loadGeneration &+= 1
        let gen = loadGeneration
        let snapshotPeriod = period
        // Die Abo-Erkennung (`SubscriptionDetector.detect`) kann bei langer Historie /
        // Unified-Mode teuer sein — daher OFF-MAIN rechnen und das Ergebnis nur anwenden,
        // wenn kein neueres `load()` dazwischenkam (Generation-Token).
        Task.detached(priority: .userInitiated) {
            let components = Self.computeComponents(
                transactions: transactions, balance: balance, period: snapshotPeriod)
            await MainActor.run { [weak self] in
                guard let self, gen == self.loadGeneration else { return }
                self.real = components
                self.resetPlan()
            }
        }
    }

    /// Reine Berechnung der MMI-Komponenten — bewusst `nonisolated`, damit sie außerhalb
    /// des MainActors laufen kann. Keine UI-/Store-Zugriffe (nur Werttypen + UserDefaults).
    nonisolated static func computeComponents(
        transactions: [TransactionsResponse.Transaction],
        balance: Double,
        period: MMIPeriod
    ) -> MMIComponents {
        let now = Date()
        let cutoff = period.cutoffDate(asOf: now)
        // Eigener Formatter pro Aufruf (DateFormatter ist nicht thread-safe für parallele Nutzung).
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        func txDate(_ tx: TransactionsResponse.Transaction) -> Date {
            guard let s = tx.bookingDate ?? tx.valueDate else { return .distantPast }
            return fmt.date(from: String(s.prefix(10))) ?? .distantPast
        }
        let recent = transactions.filter { txDate($0) >= cutoff }

        // Dieselbe "Sparen"-Definition wie in Abos & Verträge: wiederkehrende Posten,
        // die (auto via defaultTab ODER per User-Verschiebung) im `.sparen`-Tab liegen,
        // zählen als Sparen statt Ausgabe. So sind MMI und Abos konsistent.
        let savingsTagged = savingsTaggedKeys(in: transactions)
        func isTaggedSavings(_ tx: TransactionsResponse.Transaction) -> Bool {
            savingsTagged.contains(savingsKey(for: tx))
        }

        let income   = recent.filter { $0.mmiKind == .income  }.reduce(0.0) { $0 + $1.parsedAmount }
        let expenses = recent.filter { $0.mmiKind == .expense && !isTaggedSavings($0) }
            .reduce(0.0) { $0 + abs($1.parsedAmount) }
        let includeSavings = UserDefaults.standard.object(forKey: "mmiIncludeSavings") as? Bool ?? true
        let savings  = includeSavings
            ? recent.filter { $0.mmiKind == .savings || ($0.mmiKind == .expense && isTaggedSavings($0)) }
                .reduce(0.0) { $0 + abs($1.parsedAmount) }
            : 0

        return MMIComponents(
            income:   income,
            expenses: expenses,
            savings:  savings,
            balance:  balance,
            periodMonths: period.monthsSpan(asOf: now)
        )
    }

    func resetPlan() {
        planIncome   = real.income
        planExpenses = real.expenses
        planSavings  = real.savings
        planBalance  = real.balance
    }

    /// Slot-skalierter Schlüssel `(slotId, fingerprint)`. Im Unified-Modus tragen die
    /// Transaktionen ihre `slotId`; sonst fällt er auf den aktiven Slot zurück (analog
    /// zum Categorizer-Override-Lookup). Verhindert, dass eine Sparbuchung aus Slot A
    /// eine identische Buchung in Slot B fälschlich als Sparen markiert.
    nonisolated static func savingsKey(for tx: TransactionsResponse.Transaction) -> String {
        let slotId = tx.slotId ?? TransactionsDatabase.activeSlotId
        return "\(slotId)|\(TransactionRecord.fingerprint(for: tx))"
    }

    /// Slot-skalierte Schlüssel aller Transaktionen, die zu einem wiederkehrenden Posten im
    /// `.sparen`-Tab gehören (gleiche Klassifizierung wie Abos & Verträge:
    /// `effectiveTab = User-Override ?? candidate.defaultTab`).
    private nonisolated static func savingsTaggedKeys(
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
                set.insert(savingsKey(for: tx))
            }
        }
        return set
    }

}
