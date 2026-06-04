import Foundation

/// User correction state for one recurring payment.
enum RecurringAssignmentState: String, Codable {
    case neutral
    case confirmed   // user said "yes, this is a real recurring payment"
    case excluded    // user said "no, not a recurring payment / hide it"
}

/// A single user override for a recurring-payment group.
struct RecurringAssignment: Codable, Equatable {
    var state: RecurringAssignmentState = .neutral
    var tab: String? = nil           // SubscriptionTab.rawValue override (Abos/Verträge/Sparen/Verbindlichkeiten)
    var frequency: String? = nil     // PaymentFrequency.rawValue (optional manual override)
    var expectedAmount: Double? = nil
}

/// **Single source of truth** for user corrections to recurring-payment detection, shared by BOTH
/// engines (`FixedCostsAnalyzer` and `SubscriptionDetector`/`SubscriptionsView`). An exclusion or
/// confirmation made anywhere therefore applies everywhere — Fixkosten, Abos, Kalender,
/// SimpleReport, AttentionInbox — which removes the old "Fixkosten-Liste ≠ Abo-Liste" contradiction.
///
/// Keyed by a **canonical key** = the merchant base (the part before the first `|` of either engine's
/// groupKey/merchantKey), lowercased+trimmed. Both engines derive that merchant via
/// `FixedCostsAnalyzer.merchantName(for:)`, so the bases line up.
///
/// Persisted as one JSON blob under `storageKey` in UserDefaults (thread-safe reads, so the pure
/// `FixedCostsAnalyzer.analyze` can consult it off the main actor). SwiftUI views observe the same
/// key via `@AppStorage` for reactivity.
struct RecurringAssignments: Codable, Equatable {
    var byKey: [String: RecurringAssignment] = [:]

    static let storageKey = "recurringAssignments.v1"
    private static let migratedFlagKey = "recurringAssignments.migratedFromLegacy.v1"

    // MARK: Canonical key

    /// Merchant base of an engine groupKey / merchantKey, normalized.
    /// `"Telekom|12345678"` → `"telekom"`, `"Netflix|agg"` → `"netflix"`.
    static func canonicalKey(_ groupOrMerchantKey: String) -> String {
        let base = groupOrMerchantKey.split(separator: "|", maxSplits: 1).first.map(String.init) ?? groupOrMerchantKey
        return base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Persistence

    /// Current state from UserDefaults, running the one-time legacy migration if needed.
    static func current() -> RecurringAssignments {
        migrateLegacyIfNeeded()
        return decode(UserDefaults.standard.string(forKey: storageKey) ?? "")
    }

    static func decode(_ raw: String) -> RecurringAssignments {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RecurringAssignments.self, from: data)
        else { return RecurringAssignments() }
        return decoded
    }

    /// JSON encoding — used both for persistence and for binding to `@AppStorage(storageKey)`.
    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    func save() {
        UserDefaults.standard.set(jsonString, forKey: Self.storageKey)
    }

    // MARK: Queries

    func assignment(for key: String) -> RecurringAssignment {
        byKey[Self.canonicalKey(key)] ?? RecurringAssignment()
    }

    func isExcluded(_ key: String) -> Bool { assignment(for: key).state == .excluded }
    func isConfirmed(_ key: String) -> Bool { assignment(for: key).state == .confirmed }

    /// All canonical keys the user has excluded — consumed by `FixedCostsAnalyzer.analyze`.
    func excludedCanonicalKeys() -> Set<String> {
        Set(byKey.filter { $0.value.state == .excluded }.keys)
    }

    // MARK: Mutations (return a new value; call `.save()`)

    func setting(_ key: String, mutate: (inout RecurringAssignment) -> Void) -> RecurringAssignments {
        var copy = self
        let ck = Self.canonicalKey(key)
        var a = copy.byKey[ck] ?? RecurringAssignment()
        mutate(&a)
        if a == RecurringAssignment() { copy.byKey.removeValue(forKey: ck) }
        else { copy.byKey[ck] = a }
        return copy
    }

    // MARK: Migration

    /// One-time, idempotent migration of the four legacy correction keys into this store.
    /// Additive: legacy state is folded in; the flag prevents re-running.
    static func migrateLegacyIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedFlagKey) else { return }

        var store = decode(defaults.string(forKey: storageKey) ?? "")

        func lines(_ key: String) -> [String] {
            (defaults.string(forKey: key) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        }

        // fixedCosts.excluded (groupKeys) + subscriptions.userExcluded (merchantKeys) → excluded
        for raw in lines("fixedCosts.excluded") + lines("subscriptions.userExcluded") {
            let ck = canonicalKey(raw)
            var a = store.byKey[ck] ?? RecurringAssignment()
            a.state = .excluded
            store.byKey[ck] = a
        }
        // subscriptions.userConfirmed → confirmed (only if not already excluded)
        for raw in lines("subscriptions.userConfirmed") {
            let ck = canonicalKey(raw)
            var a = store.byKey[ck] ?? RecurringAssignment()
            if a.state != .excluded { a.state = .confirmed }
            store.byKey[ck] = a
        }
        // subscriptions.tabOverrides: "merchantKey§tabRaw" per line
        for line in lines("subscriptions.tabOverrides") {
            guard let sep = line.lastIndex(of: "§") else { continue }
            let ck = canonicalKey(String(line[..<sep]))
            let tabRaw = String(line[line.index(after: sep)...])
            var a = store.byKey[ck] ?? RecurringAssignment()
            a.tab = tabRaw
            if a.state == .neutral { a.state = .confirmed }  // a tab override implies confirmation
            store.byKey[ck] = a
        }

        store.save()
        defaults.set(true, forKey: migratedFlagKey)
    }
}
