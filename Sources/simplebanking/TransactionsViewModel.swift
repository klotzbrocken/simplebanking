import Foundation
import SwiftUI

// MARK: - Transaction Filter

enum TxFilter: Int, CaseIterable {
    case all, income, expense, subscriptions, fixedCosts, uncategorized, pending, reminders

    var label: String {
        switch self {
        case .all:            return L10n.t("Alle", "All")
        case .income:         return L10n.t("Einnahmen", "Income")
        case .expense:        return L10n.t("Ausgaben", "Expenses")
        case .subscriptions:  return L10n.t("Abos", "Subscriptions")
        case .fixedCosts:     return L10n.t("Fixkosten", "Fixed costs")
        case .uncategorized:  return L10n.t("Unkategorisiert", "Uncategorized")
        case .pending:        return L10n.t("Vorgemerkt", "Pending")
        case .reminders:      return L10n.t("Erinnerungen", "Reminders")
        }
    }

    var icon: String {
        switch self {
        case .all:            return "line.3.horizontal.decrease"
        case .income:         return "arrow.down.circle"
        case .expense:        return "arrow.up.circle"
        case .subscriptions:  return "repeat.circle"
        case .fixedCosts:     return "calendar.badge.clock"
        case .uncategorized:  return "questionmark.circle"
        case .pending:        return "clock.badge.questionmark"
        case .reminders:      return "bell.fill"
        }
    }
}

// MARK: - Transactions Panel (paged, SwiftUI)

@MainActor
final class TransactionsViewModel: ObservableObject {
    @Published var isLoading: Bool = false
    @Published var error: String? = nil
    @Published var errorNeedsReconnect: Bool = false
    @Published var transactions: [TransactionsResponse.Transaction] = [] {
        didSet {
            // Indizes off-main rebuilden (Search-Index, Fixed-Costs, Subscriptions)
            // — bei Unified-Mode + 365-Tage-Import + 3 Banken können das schnell
            // 5–10k Transaktionen werden, jeder Resolver-Call ist nicht-trivial.
            // Vorher synchron auf MainActor → spürbarer UI-Hänger.
            // Filter wird sofort mit ALTEM Index angewandt damit die `.all`-View
            // nicht stale ist; nach Rebuild wird re-applied (deckt Search/Subs/Fixed).
            applyCurrentFilter(resetPage: true)
            scheduleIndexRebuild()
        }
    }

    private var indexGen: Int = 0
    private var indexRebuildTask: Task<Void, Never>?

    /// Berechnet Search-Index, Fixed-Costs-Set und Subscription-IDs off-main
    /// auf einem Snapshot der aktuellen Transaktionen. Älterer Rebuild wird
    /// gecancelt; Stale-Results werden via Generation-Token verworfen.
    private func scheduleIndexRebuild() {
        indexGen &+= 1
        let gen = indexGen
        let snapshot = transactions
        indexRebuildTask?.cancel()
        indexRebuildTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // Pure Funktionen / read-only Resolver — safe off-main.
            let search = snapshot.map(Self.computeSearchIndexText)
            if Task.isCancelled { return }
            let fixed = FixedCostsAnalyzer.getFixedCostMerchants(transactions: snapshot)
            if Task.isCancelled { return }
            let subs = SubscriptionDetector.detect(in: snapshot)
            if Task.isCancelled { return }
            var subIDs: Set<String> = []
            for c in subs {
                for tx in c.matchedTransactions {
                    subIDs.insert(TransactionRecord.fingerprint(for: tx))
                }
            }
            await MainActor.run {
                guard self.indexGen == gen else { return }   // stale → discard
                self.searchIndex = search
                self.fixedMerchants = fixed
                self.subscriptionTxIDs = subIDs
                // Re-apply mit frischem Index — relevant für Search/Subs/FixedCosts.
                self.applyCurrentFilter(resetPage: false)
            }
        }
    }
    private var subscriptionTxIDs: Set<String> = []
    @Published var page: Int = 0
    @Published var query: String = "" {
        didSet {
            scheduleFilterUpdate()
        }
    }
    @Published var fromDate: String?
    @Published var toDate: String?
    @Published var currentBalance: String?
    @Published var currentBalanceFetchedAt: Date? = nil
    @Published var connectedBankDisplayName: String = ""
    @Published var connectedBankLogoID: String? = nil
    @Published var connectedBankLogoImage: NSImage? = nil
    @Published var connectedBankIBAN: String? = nil
    @Published var connectedBankCurrency: String? = nil
    @Published var connectedBankNickname: String? = nil
    @Published var anthropicApiKey: String? = nil
    @Published var aiProvider: AIProvider = .anthropic
    @Published var confettiTrigger: Int = 0
    @Published var rippleTrigger: Int = 0
    @Published var isTanPending: Bool = false
    /// Sum of recurring payments still expected in the current cycle (nil = not computed yet).
    @Published var leftToPayAmount: Double? = nil
    /// Ende des aktuellen Gehaltszyklus (= nächster erwarteter Gehaltseingang) — derselbe
    /// Zyklus, den `leftToPayAmount` nutzt. Treibt das "bis zum …"-Datum im Untertitel.
    @Published var leftToPayCycleEnd: Date? = nil
    @Published var enrichmentData: [String: TxEnrichment] = [:] {
        didSet {
            // Re-apply filter when reminders filter is active — enrichment changes
            // (set/remove reminder) must update the filtered list immediately.
            if activeFilter == .reminders {
                applyCurrentFilter(resetPage: false)
            }
        }
    }
    @AppStorage("unifiedModeEnabled") var unifiedModeEnabled: Bool = false
    @Published var slotMap: [String: BankSlot] = [:]
    @Published var internalTransferIDs: Set<String> = []
    @Published var loadError: Error? = nil
    @Published private(set) var filteredTransactions: [TransactionsResponse.Transaction] = []
    @Published var activeFilter: TxFilter = .all {
        didSet { applyCurrentFilter(resetPage: true) }
    }

    var isUnifiedMode: Bool {
        unifiedModeEnabled && MultibankingStore.shared.slots.count > 1
    }

    let pageSize: Int = 10
    private let searchDebounceNanoseconds: UInt64 = 150_000_000
    private let minimumSearchCharacters: Int = 2

    private var queryTask: Task<Void, Never>?
    private var searchIndex: [String] = []
    private var uniqueDateCache: [String] = []
    private var fixedMerchants: Set<String> = []

    deinit {
        queryTask?.cancel()
    }

    private func clean(_ s: String?) -> String { Self.clean(s) }

    /// Pure helper — wird off-main vom Index-Rebuild genutzt.
    nonisolated private static func clean(_ s: String?) -> String {
        (s ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isSearchActive: Bool {
        normalizedQuery.count >= minimumSearchCharacters
    }

    private func queryVariants() -> (raw: String, dot: String, compact: String) {
        let raw = normalizedQuery
        let dot = raw.replacingOccurrences(of: ",", with: ".")
        let compact = dot.replacingOccurrences(of: ".", with: "")
        return (raw, dot, compact)
    }

    private func searchableText(for transaction: TransactionsResponse.Transaction) -> String {
        Self.computeSearchableText(transaction)
    }

    private func buildSearchIndexText(for transaction: TransactionsResponse.Transaction) -> String {
        Self.computeSearchIndexText(transaction)
    }

    /// Off-main-fähige Variante — nur read-only Resolver + pure String-Ops.
    nonisolated private static func computeSearchableText(_ transaction: TransactionsResponse.Transaction) -> String {
        let remittance = (transaction.remittanceInformation ?? []).map(clean).joined(separator: " ")
        let resolvedMerchant = MerchantResolver.resolve(transaction: transaction).effectiveMerchant
        let resolvedCategory = TransactionCategorizer.category(for: transaction).displayName
        let fields: [String] = [
            clean(transaction.bookingDate),
            clean(transaction.valueDate),
            clean(transaction.endToEndId),
            clean(transaction.amount?.amount),
            clean(transaction.amount?.currency),
            clean(resolvedMerchant),
            clean(transaction.creditor?.name),
            clean(transaction.creditor?.iban),
            clean(transaction.creditor?.bic),
            clean(transaction.debtor?.name),
            clean(transaction.debtor?.iban),
            clean(transaction.debtor?.bic),
            clean(transaction.additionalInformation),
            clean(transaction.purposeCode),
            clean(transaction.category),
            clean(resolvedCategory),
            remittance,
        ]
        return fields.joined(separator: " ").lowercased()
    }

    nonisolated static func computeSearchIndexText(_ transaction: TransactionsResponse.Transaction) -> String {
        let base = computeSearchableText(transaction)
        let amountRaw = clean(transaction.amount?.amount).lowercased()
        let amountDot = amountRaw.replacingOccurrences(of: ",", with: ".")
        let amountCompact = amountDot.replacingOccurrences(of: ".", with: "")
        return [base, amountRaw, amountDot, amountCompact]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // rebuildSearchIndex / rebuildSubscriptionIndex sind entfallen — Berechnung
    // läuft jetzt off-main via `scheduleIndexRebuild()` (Generation-Token-Pattern).

    private func rebuildUniqueDateCache() {
        guard !isSearchActive else {
            uniqueDateCache = []
            return
        }

        let dates = filteredTransactions.compactMap { $0.bookingDate ?? $0.valueDate }
        uniqueDateCache = Array(Set(dates)).sorted(by: >)
    }

    private func applyCurrentFilter(resetPage: Bool) {
        // Step 1: Search v2 — semantic search with structured query
        var base: [TransactionsResponse.Transaction]
        if !isSearchActive {
            base = transactions
        } else {
            let parsed = TransactionSearchEngine.parse(normalizedQuery)
            base = TransactionSearchEngine.execute(
                query: parsed,
                transactions: transactions,
                searchIndex: searchIndex,
                subscriptionIDs: subscriptionTxIDs
            )
        }

        // Step 2: active filter
        switch activeFilter {
        case .all:
            break
        case .income:
            base = base.filter { $0.parsedAmount > 0 }
        case .expense:
            base = base.filter { $0.parsedAmount < 0 }
        case .subscriptions:
            base = base.filter { tx in
                guard tx.parsedAmount < 0 else { return false }
                return subscriptionTxIDs.contains(TransactionRecord.fingerprint(for: tx))
            }
        case .fixedCosts:
            base = base.filter { FixedCostsAnalyzer.isFixedCost($0, fixedMerchants: fixedMerchants) }
        case .uncategorized:
            base = base.filter { TransactionCategorizer.category(for: $0) == .sonstiges }
        case .pending:
            base = base.filter { $0.status == "pending" }
        case .reminders:
            base = base.filter { tx in
                let slotId = tx.slotId ?? TransactionsDatabase.activeSlotId
                let key = TxEnrichmentKey.make(slotId: slotId, txID: TransactionRecord.fingerprint(for: tx))
                return enrichmentData[key]?.reminderId != nil
            }
        }

        filteredTransactions = base
        rebuildUniqueDateCache()

        if resetPage {
            page = 0
        } else {
            page = min(page, max(0, totalPages - 1))
        }
    }

    private func scheduleFilterUpdate() {
        queryTask?.cancel()

        if !isSearchActive {
            applyCurrentFilter(resetPage: true)
            return
        }

        let debounce = searchDebounceNanoseconds

        queryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: debounce)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.applyCurrentFilter(resetPage: true)
        }
    }

    var filtered: [TransactionsResponse.Transaction] {
        filteredTransactions
    }

    var totalPages: Int {
        if !isSearchActive {
            return uniqueDateCache.count
        }
        return max(1, Int(ceil(Double(filteredTransactions.count) / Double(pageSize))))
    }

    var currentDateLabel: String {
        guard page < uniqueDateCache.count else { return "" }
        return uniqueDateCache[page]
    }

    var currentPageItems: [TransactionsResponse.Transaction] {
        let list = filteredTransactions

        if !isSearchActive {
            guard !uniqueDateCache.isEmpty, page < uniqueDateCache.count else { return [] }
            let targetDate = uniqueDateCache[page]
            return list.filter { ($0.bookingDate ?? $0.valueDate) == targetDate }
        }

        let start = page * pageSize
        guard start < list.count else { return [] }
        let end = min(list.count, start + pageSize)
        return Array(list[start..<end])
    }

    func resetPaging() {
        if page != 0 {
            page = 0
        }
    }

    func nextPage() {
        page = min(page + 1, totalPages - 1)
    }

    func prevPage() {
        page = max(page - 1, 0)
    }

    /// Make the transaction matching `fingerprint` visible: clears search + filter,
    /// switches to the page that contains the tx, and returns its `stableIdentifier`
    /// so the caller can trigger `scrollTo`. Returns `nil` if no match.
    /// Used by the Attention-Inbox „Ansehen"-Button.
    func jumpToTransaction(matchingFingerprint fingerprint: String) -> String? {
        guard let tx = transactions.first(where: { TransactionRecord.fingerprint(for: $0) == fingerprint }) else {
            return nil
        }
        // Clear any search/filter that might hide the target tx
        if !query.isEmpty { query = "" }
        if activeFilter != .all { activeFilter = .all }
        // After filter reset, filteredTransactions + uniqueDateCache are rebuilt synchronously
        // via the @Published didSet chain. Find the page now.
        if !isSearchActive,
           let targetDate = tx.bookingDate ?? tx.valueDate,
           let pageIndex = uniqueDateCache.firstIndex(of: targetDate) {
            page = pageIndex
        } else if let idx = filteredTransactions.firstIndex(where: {
            TransactionRecord.fingerprint(for: $0) == fingerprint
        }) {
            page = idx / pageSize
        }
        return tx.stableIdentifier
    }

    /// Detect internal transfers between own accounts.
    /// Scans the last 30 days / 1,000 rows (O(n²) cap) — see TODOS.md for indexed future approach.
    /// Matches: counterparty IBAN is one of our own IBANs + same absolute amount (±€0.01 fee tolerance) + bookingDate within ±1 day.
    func detectInternalTransfers(ownIBANs: Set<String>) {
        guard !ownIBANs.isEmpty else {
            internalTransferIDs = []
            return
        }
        let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let cutoffStr = Self.isoDateFormatter.string(from: cutoff)
        let candidates = transactions
            .filter { ($0.bookingDate ?? $0.valueDate ?? "") >= cutoffStr }
            .prefix(1000)

        var found: Set<String> = []
        let list = Array(candidates)
        for i in 0..<list.count {
            let a = list[i]
            let aIBAN = a.creditor?.iban ?? a.debtor?.iban ?? ""
            guard ownIBANs.contains(aIBAN) else { continue }
            let aAmt = abs(a.parsedAmount)
            let aDate = a.bookingDate ?? a.valueDate ?? ""
            let aID = TransactionRecord.fingerprint(for: a)
            for j in (i + 1)..<list.count {
                let b = list[j]
                let bIBAN = b.creditor?.iban ?? b.debtor?.iban ?? ""
                guard ownIBANs.contains(bIBAN) else { continue }
                let bAmt = abs(b.parsedAmount)
                guard abs(aAmt - bAmt) < 0.015 else { continue }  // ±€0.01 tolerance for transfer fees
                let bDate = b.bookingDate ?? b.valueDate ?? ""
                guard Self.dayDiff(aDate, bDate) <= 1 else { continue }
                let bID = TransactionRecord.fingerprint(for: b)
                found.insert(aID)
                found.insert(bID)
            }
        }
        internalTransferIDs = found
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dayDiff(_ a: String, _ b: String) -> Int {
        guard let da = isoDateFormatter.date(from: a),
              let db = isoDateFormatter.date(from: b) else { return Int.max }
        return abs(Calendar(identifier: .gregorian).dateComponents([.day], from: da, to: db).day ?? Int.max)
    }

    func loadEnrichmentData(bankId: String) {
        Task { [weak self] in
            let data = (try? TransactionsDatabase.loadEnrichmentData(bankId: bankId)) ?? [:]
            await MainActor.run {
                self?.enrichmentData = data
            }
        }
    }

    func searchMatchBadges(for transaction: TransactionsResponse.Transaction) -> [String] {
        guard isSearchActive else { return [] }

        let variants = queryVariants()
        var badges: [String] = []

        let containsTextQuery: (String) -> Bool = { text in
            let normalized = text.lowercased()
            return normalized.contains(variants.raw) || normalized.contains(variants.dot)
        }

        let ibanRaw = [clean(transaction.creditor?.iban), clean(transaction.debtor?.iban)]
            .compactMap { $0 }
            .joined(separator: " ")
        let ibanCompact = ibanRaw
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        let queryCompact = variants.raw.replacingOccurrences(of: " ", with: "")
        if !queryCompact.isEmpty, ibanCompact.contains(queryCompact) {
            badges.append("IBAN")
        }

        let merchantName = MerchantResolver.resolve(transaction: transaction).effectiveMerchant
        let counterpartyRaw = [
            clean(transaction.creditor?.name),
            clean(transaction.debtor?.name),
            clean(merchantName),
        ]
            .compactMap { $0 }
            .joined(separator: " ")
        if !counterpartyRaw.isEmpty, containsTextQuery(counterpartyRaw) {
            badges.append("Empfänger")
        }

        let purposeRaw = [
            clean((transaction.remittanceInformation ?? []).joined(separator: " ")),
            clean(transaction.additionalInformation),
            clean(transaction.purposeCode),
        ]
            .compactMap { $0 }
            .joined(separator: " ")
        if !purposeRaw.isEmpty, containsTextQuery(purposeRaw) {
            badges.append("Verwendungszweck")
        }

        let amountRaw = clean(transaction.amount?.amount).lowercased()
        let amountDot = amountRaw.replacingOccurrences(of: ",", with: ".")
        let amountCompact = amountDot.replacingOccurrences(of: ".", with: "")
        let amountMatches = amountRaw.contains(variants.raw) ||
            amountDot.contains(variants.dot) ||
            (!variants.compact.isEmpty && amountCompact.contains(variants.compact))
        if amountMatches {
            badges.append("Betrag")
        }

        return badges
    }

}
