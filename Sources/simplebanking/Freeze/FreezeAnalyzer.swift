import SwiftUI

// MARK: - Freeze Category (3 toggleable categories; Verbindlichkeiten excluded)

enum FreezeCategory: String, CaseIterable, Hashable {
    case abos      = "Abos"
    case vertraege = "Verträge"
    case sparen    = "Sparen"

    var icon: String {
        switch self {
        case .abos:      return "play.rectangle"
        case .vertraege: return "doc.text"
        case .sparen:    return "banknote"
        }
    }
}

// MARK: - Freeze Item (one per merchant group)

struct FreezeItem: Identifiable {
    let id: String               // normalized merchant key
    let displayName: String
    let category: FreezeCategory
    let monthlyAmount: Double
}

// MARK: - Freeze State (singleton for cross-component communication)

@MainActor
final class FreezeState: ObservableObject {
    static let shared = FreezeState()
    private init() {}

    @Published var isActive: Bool = false
    @Published var monthlyAmount: Double = 0
}

// MARK: - Freeze Analyzer

enum FreezeAnalyzer {

    // MARK: Analyze

    /// Builds FreezeItems from SubscriptionDetector candidates.
    /// Respects the same excludedKeys and tabOverrides as Abos & Verträge view so
    /// category totals always match. Verbindlichkeiten (not freeze-able) are excluded.
    /// Multiple contracts at the same provider are grouped into one item.
    static func analyze(
        transactions: [TransactionsResponse.Transaction],
        excludedKeys: Set<String> = [],
        tabOverrides: [String: SubscriptionTab] = [:]
    ) -> [FreezeItem] {
        let candidates = SubscriptionDetector.detect(in: transactions)
            .filter { !excludedKeys.contains($0.id) }

        var groups: [String: (category: FreezeCategory, displayName: String, total: Double)] = [:]

        for candidate in candidates {
            // Apply user tab override first, then fall back to defaultTab
            let tab = tabOverrides[candidate.id] ?? candidate.defaultTab
            guard tab != .verbindlichkeiten else { continue }  // obligations can't be frozen

            let cat: FreezeCategory
            switch tab {
            case .sparen:    cat = .sparen
            case .vertraege: cat = .vertraege
            default:         cat = .abos
            }

            // Strip |agg / |custId suffixes to get base merchant key
            let baseId = candidate.id.contains("|")
                ? String(candidate.id.split(separator: "|", maxSplits: 1).first ?? Substring(candidate.id))
                : candidate.id

            if var g = groups[baseId] {
                g.total += candidate.averageAmount
                groups[baseId] = g
            } else {
                groups[baseId] = (category: cat, displayName: candidate.displayName, total: candidate.averageAmount)
            }
        }

        return groups
            .map { key, value in
                FreezeItem(
                    id: key,
                    displayName: value.displayName,
                    category: value.category,
                    monthlyAmount: value.total
                )
            }
            .sorted { $0.monthlyAmount > $1.monthlyAmount }
    }

    // MARK: Helpers

    /// Returns true if this transaction belongs to an active (non-excluded-category) freeze item.
    static func isFrozen(
        transaction: TransactionsResponse.Transaction,
        items: [FreezeItem],
        excludedCategories: Set<FreezeCategory>
    ) -> Bool {
        guard transaction.parsedAmount < 0 else { return false }
        let key = merchantKey(for: transaction)
        guard let item = items.first(where: { $0.id == key }) else { return false }
        return !excludedCategories.contains(item.category)
    }

    static func merchantKey(for transaction: TransactionsResponse.Transaction) -> String {
        let resolution = MerchantResolver.resolve(transaction: transaction)
        return resolution.normalizedMerchant.isEmpty
            ? (transaction.creditor?.name ?? transaction.stableIdentifier)
            : resolution.normalizedMerchant
    }

    static func monthlyTotal(items: [FreezeItem], excludedCategories: Set<FreezeCategory>) -> Double {
        items
            .filter { !excludedCategories.contains($0.category) }
            .map { $0.monthlyAmount }
            .reduce(0, +)
    }

    /// Per-category total (for overlay display)
    static func categoryTotal(items: [FreezeItem], category: FreezeCategory) -> Double {
        items.filter { $0.category == category }.map { $0.monthlyAmount }.reduce(0, +)
    }
}
