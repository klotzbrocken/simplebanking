import Foundation

// MARK: - Conditions

/// Which part of a transaction a condition looks at.
enum RuleField: String, Codable, CaseIterable {
    case merchant, empfaenger, absender, verwendungszweck, searchText, endToEndId, amount, direction, interval

    var label: String {
        switch self {
        case .merchant:         return "Händler"
        case .empfaenger:       return "Empfänger"
        case .absender:         return "Absender"
        case .verwendungszweck: return "Zweck"
        case .searchText:       return "Volltext"
        case .endToEndId:       return "E2E-ID"
        case .amount:           return "Betrag"
        case .direction:        return "Buchungsart"
        case .interval:         return "Intervall"
        }
    }

    var icon: String {
        switch self {
        case .merchant:         return "tag"
        case .empfaenger:       return "person"
        case .absender:         return "person.crop.square"
        case .verwendungszweck: return "text.alignleft"
        case .searchText:       return "magnifyingglass"
        case .endToEndId:       return "number"
        case .amount:           return "eurosign"
        case .direction:        return "arrow.left.arrow.right"
        case .interval:         return "repeat"
        }
    }

    var isAmount: Bool { self == .amount }

    /// Feste Auswahl (statt Freitext) für Aufzählungs-Felder.
    var fixedOptions: [String]? {
        switch self {
        case .direction: return ["Zahlung", "Eingang"]
        case .interval:  return [PaymentFrequency.monthly.rawValue, PaymentFrequency.quarterly.rawValue, PaymentFrequency.yearly.rawValue]
        default:         return nil
        }
    }
}

enum RuleOperator: String, Codable, CaseIterable {
    case contains, notContains, equals, notEquals      // text
    case amountEquals, amountGreater, amountLess        // amount (on abs(parsedAmount))

    var label: String {
        switch self {
        case .contains:      return "enthält"
        case .notContains:   return "enthält nicht"
        case .equals:        return "ist"
        case .notEquals:     return "ist nicht"
        case .amountEquals:  return "= Betrag"
        case .amountGreater: return "> Betrag"
        case .amountLess:    return "< Betrag"
        }
    }

    var isAmount: Bool {
        switch self {
        case .amountEquals, .amountGreater, .amountLess: return true
        default: return false
        }
    }

    static func options(for field: RuleField) -> [RuleOperator] {
        switch field {
        case .amount:              return [.amountEquals, .amountGreater, .amountLess]
        case .direction:           return [.equals, .notEquals]
        case .interval:            return [.equals]
        default:                   return [.contains, .notContains, .equals, .notEquals]
        }
    }
}

/// Verknüpfung der Bedingungen.
enum RuleConjunction: String, Codable { case all, any }

struct RuleCondition: Codable, Equatable, Identifiable {
    var id = UUID()
    var field: RuleField = .searchText
    var op: RuleOperator = .contains
    var value: String = ""
    /// Wie diese Bedingung an die VORHERIGE knüpft (UND/ODER). Bei der ersten Bedingung ignoriert.
    var joiner: RuleConjunction = .all

    enum CodingKeys: String, CodingKey { case field, op, value, joiner }  // id is transient
}

extension RuleCondition {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decodeIfPresent(RuleField.self, forKey: .field) ?? .searchText
        op = try c.decodeIfPresent(RuleOperator.self, forKey: .op) ?? .contains
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        joiner = try c.decodeIfPresent(RuleConjunction.self, forKey: .joiner) ?? .all
    }
}

/// Recurring action — what to mark matching merchants as. `.exclude` = „ist nicht" (kein Abo/Fixkost).
enum RecurringAction: String, Codable, CaseIterable {
    case abo, vertrag, verbindlichkeit, sparen, exclude

    var label: String {
        switch self {
        case .abo:            return "Abo"
        case .vertrag:        return "Vertrag"
        case .verbindlichkeit: return "Fixkost"
        case .sparen:         return "Sparen"
        case .exclude:        return "ist nicht (ausschließen)"
        }
    }

    var tab: SubscriptionTab? {
        switch self {
        case .abo:            return .abos
        case .vertrag:        return .vertraege
        case .verbindlichkeit: return .verbindlichkeiten
        case .sparen:         return .sparen
        case .exclude:        return nil
        }
    }
}

// MARK: - Rule

/// A multi-condition assignment rule: „Wenn <Bedingungen, UND-verknüpft> dann <Kategorie und/oder
/// Recurring-Markierung>". Replaces the old single-condition `CategoryRule`.
struct AssignmentRule: Codable, Identifiable {
    let id: UUID
    var enabled: Bool
    var priority: Int
    var conditions: [RuleCondition]
    var setCategory: TransactionCategory?
    var recurring: RecurringAction?
    let createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, enabled, priority, conditions, setCategory, recurring, createdAt, updatedAt
    }

    /// Conditions folded left-to-right using each condition's `joiner` (kein Operator-Vorrang:
    /// „A UND B ODER C" = (A∧B)∨C). Empty list never matches. `cadence` = detected frequency of the
    /// merchant (for `.interval`); `nil` in the live categorizer → interval conditions non-blocking.
    func matches(_ tx: TransactionsResponse.Transaction, cadence: PaymentFrequency? = nil) -> Bool {
        matches(RuleInput(tx), cadence: cadence)
    }

    func matches(_ input: RuleInput, cadence: PaymentFrequency? = nil) -> Bool {
        guard let first = conditions.first else { return false }
        var result = AssignmentRules.evaluate(first, input, cadence: cadence)
        for c in conditions.dropFirst() {
            let e = AssignmentRules.evaluate(c, input, cadence: cadence)
            result = (c.joiner == .all) ? (result && e) : (result || e)
        }
        return result
    }

    /// Human-readable one-liner for the manager list.
    var summary: String {
        var conds = ""
        for (i, c) in conditions.enumerated() {
            if i > 0 { conds += c.joiner == .all ? " UND " : " ODER " }
            conds += "\(c.field.label) \(c.op.label) \(c.value)"
        }
        var actions: [String] = []
        if let cat = setCategory { actions.append(cat.displayName) }
        if let r = recurring { actions.append(r.label) }
        let actionStr = actions.isEmpty ? "—" : actions.joined(separator: " + ")
        return "Wenn \(conds.isEmpty ? "—" : conds) → \(actionStr)"
    }
}

// Decode-tolerant: ältere gespeicherte Regeln haben kein `conjunction`-Feld. In einer Extension,
// damit der synthetisierte Memberwise-Init erhalten bleibt.
extension AssignmentRule {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        priority = try c.decode(Int.self, forKey: .priority)
        conditions = try c.decode([RuleCondition].self, forKey: .conditions)
        setCategory = try c.decodeIfPresent(TransactionCategory.self, forKey: .setCategory)
        recurring = try c.decodeIfPresent(RecurringAction.self, forKey: .recurring)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

// MARK: - Rule input (decoupled from Transaction so both code paths can match)

struct RuleInput {
    let amount: Double          // abs value
    let isExpense: Bool         // sign of the original amount (Zahlung vs. Eingang)
    let empfaenger: String
    let absender: String
    let verwendungszweck: String
    let additionalInformation: String
    let endToEndId: String
    let merchant: String        // aufgelöster Händlername (MerchantResolver / Händler-Regeln)

    init(amount: Double, empfaenger: String?, absender: String?, verwendungszweck: String?,
         additionalInformation: String?, endToEndId: String?, merchant: String = "") {
        self.amount = abs(amount)
        self.isExpense = amount < 0
        self.empfaenger = empfaenger ?? ""
        self.absender = absender ?? ""
        self.verwendungszweck = verwendungszweck ?? ""
        self.additionalInformation = additionalInformation ?? ""
        self.endToEndId = endToEndId ?? ""
        self.merchant = merchant
    }

    init(_ tx: TransactionsResponse.Transaction) {
        self.init(amount: tx.parsedAmount,
                  empfaenger: tx.creditor?.name,
                  absender: tx.debtor?.name,
                  verwendungszweck: (tx.remittanceInformation ?? []).joined(separator: " "),
                  additionalInformation: tx.additionalInformation,
                  endToEndId: tx.endToEndId,
                  merchant: MerchantResolver.resolve(transaction: tx).effectiveMerchant)
    }

    func text(for field: RuleField) -> String {
        switch field {
        case .merchant:         return merchant
        case .empfaenger:       return empfaenger
        case .absender:         return absender
        case .verwendungszweck: return [verwendungszweck, additionalInformation].filter { !$0.isEmpty }.joined(separator: " ")
        case .endToEndId:       return endToEndId
        case .searchText:       return [merchant, empfaenger, absender, verwendungszweck, additionalInformation, endToEndId].filter { !$0.isEmpty }.joined(separator: " ")
        case .amount, .direction, .interval: return ""
        }
    }
}

// MARK: - Store + engine

enum AssignmentRules {
    static let storageKey = "assignmentRules.v1"
    private static let migratedFlagKey = "assignmentRules.migratedFromCategoryRules"

    // Persistence

    static func all() -> [AssignmentRule] {
        migrateFromCategoryRulesIfNeeded()
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([AssignmentRule].self, from: data)
        else { return [] }
        return decoded
    }

    static func save(_ rules: [AssignmentRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    @discardableResult
    static func add(_ rule: AssignmentRule) -> AssignmentRule {
        var rules = all()
        rules.append(rule)
        save(rules)
        return rule
    }

    @discardableResult
    static func remove(id: UUID) -> Bool {
        var rules = all()
        let before = rules.count
        rules.removeAll { $0.id == id }
        guard rules.count != before else { return false }
        save(rules)
        return true
    }

    static func update(_ rule: AssignmentRule, now: Date = Date()) {
        var rules = all()
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        var updated = rule
        updated.updatedAt = now
        rules[idx] = updated
        save(rules)
    }

    static func make(conditions: [RuleCondition],
                     setCategory: TransactionCategory?,
                     recurring: RecurringAction?,
                     priority: Int = 100,
                     now: Date = Date()) -> AssignmentRule {
        AssignmentRule(id: UUID(), enabled: true, priority: priority,
                       conditions: conditions,
                       setCategory: setCategory, recurring: recurring,
                       createdAt: now, updatedAt: now)
    }

    // Matching

    static func evaluate(_ c: RuleCondition, _ input: RuleInput, cadence: PaymentFrequency? = nil) -> Bool {
        switch c.field {
        case .amount:
            guard let target = Double(c.value.replacingOccurrences(of: ",", with: ".")) else { return false }
            switch c.op {
            case .amountEquals:  return abs(input.amount - target) < 0.005
            case .amountGreater: return input.amount > target
            case .amountLess:    return input.amount < target
            default:             return false
            }

        case .direction:
            // Wert „Zahlung" = Ausgabe, „Eingang" = Gutschrift.
            let wantsExpense = normalize(c.value) == normalize("Zahlung")
            let isMatch = (input.isExpense == wantsExpense)
            return c.op == .notEquals ? !isMatch : isMatch

        case .interval:
            // Braucht die erkannte Frequenz des Händlers. Ohne Cadence (z.B. Live-
            // Kategorisierung ohne Abo-Kontext) lässt sich die Bedingung NICHT erfüllen
            // → false. Sonst würde eine Regel „monatlich → Kategorie X" praktisch jede
            // Buchung kategorisieren. Cadence-tragende Pfade (Abo-Kontext) bleiben gültig.
            guard let cadence else { return false }
            return normalize(cadence.rawValue) == normalize(c.value)

        default:
            let target = normalize(c.value)
            guard !target.isEmpty else { return false }
            let hay = normalize(input.text(for: c.field))
            switch c.op {
            case .contains:    return hay.contains(target)
            case .notContains: return !hay.contains(target)
            case .equals:      return hay == target
            case .notEquals:   return hay != target
            default:           return false
            }
        }
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Consumers

    /// First enabled rule (priority then createdAt) that matches and assigns a category.
    static func firstCategory(for input: RuleInput, rules: [AssignmentRule]? = nil) -> TransactionCategory? {
        sorted(rules ?? all()).first { $0.setCategory != nil && $0.matches(input) }?.setCategory
    }

    static func firstCategory(for tx: TransactionsResponse.Transaction, rules: [AssignmentRule]? = nil) -> TransactionCategory? {
        firstCategory(for: RuleInput(tx), rules: rules)
    }

    /// Map merchant (canonical) → detected frequency, for `.interval` conditions.
    static func cadenceMap(for txs: [TransactionsResponse.Transaction]) -> [String: PaymentFrequency] {
        var map: [String: PaymentFrequency] = [:]
        for p in FixedCostsAnalyzer.analyze(transactions: txs) {
            map[RecurringAssignments.canonicalKey(p.groupKey)] = p.frequency
        }
        return map
    }

    static func cadence(for tx: TransactionsResponse.Transaction, map: [String: PaymentFrequency]) -> PaymentFrequency? {
        map[RecurringAssignments.canonicalKey(FixedCostsAnalyzer.merchantName(for: tx))]
    }

    static func matchingTransactions(_ rule: AssignmentRule, in txs: [TransactionsResponse.Transaction],
                                     cadenceMap: [String: PaymentFrequency]? = nil) -> [TransactionsResponse.Transaction] {
        let map = cadenceMap ?? self.cadenceMap(for: txs)
        return txs.filter { rule.matches($0, cadence: cadence(for: $0, map: map)) }
    }

    /// Applies a rule's recurring action to every matching transaction's merchant (one write).
    /// Persistent because `RecurringAssignments` is keyed by merchant → future bookings inherit it.
    static func applyRecurring(_ rule: AssignmentRule, to txs: [TransactionsResponse.Transaction]) {
        guard let action = rule.recurring else { return }
        let map = cadenceMap(for: txs)
        var store = RecurringAssignments.current()
        for tx in txs where rule.matches(tx, cadence: cadence(for: tx, map: map)) {
            let key = FixedCostsAnalyzer.merchantName(for: tx)
            store = store.setting(key) { a in
                if action == .exclude {
                    a.state = .excluded
                    a.tab = nil
                } else {
                    a.state = .confirmed
                    a.tab = action.tab?.rawValue
                }
            }
        }
        store.save()
    }

    private static func sorted(_ rules: [AssignmentRule]) -> [AssignmentRule] {
        rules.filter { $0.enabled }
            .sorted { $0.priority == $1.priority ? $0.createdAt < $1.createdAt : $0.priority < $1.priority }
    }

    // Migration from the old single-condition CategoryRule store

    static func migrateFromCategoryRulesIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedFlagKey) else { return }
        defer { defaults.set(true, forKey: migratedFlagKey) }

        guard let data = defaults.data(forKey: "categoryUserRules"),
              let legacy = try? JSONDecoder().decode([LegacyCategoryRule].self, from: data),
              !legacy.isEmpty else { return }

        var existing: [AssignmentRule] = {
            guard let d = defaults.data(forKey: storageKey),
                  let r = try? JSONDecoder().decode([AssignmentRule].self, from: d) else { return [] }
            return r
        }()

        for old in legacy {
            let cond = RuleCondition(field: legacyField(old.matchScope),
                                     op: legacyOp(old.matchType),
                                     value: old.pattern)
            existing.append(AssignmentRule(
                id: old.id, enabled: old.enabled, priority: old.priority,
                conditions: [cond], setCategory: old.category, recurring: nil,
                createdAt: old.createdAt, updatedAt: old.updatedAt
            ))
        }
        if let encoded = try? JSONEncoder().encode(existing) {
            defaults.set(encoded, forKey: storageKey)
        }
    }

    private static func legacyField(_ scope: String) -> RuleField {
        switch scope {
        case "empfaenger":       return .empfaenger
        case "verwendungszweck": return .verwendungszweck
        case "end_to_end_id":    return .endToEndId
        default:                 return .searchText
        }
    }
    private static func legacyOp(_ type: String) -> RuleOperator {
        switch type {
        case "equals": return .equals
        case "regex":  return .contains   // regex nicht mehr unterstützt → als contains migrieren
        default:       return .contains
        }
    }

    /// Decodes the old `CategoryRule` shape just for migration.
    private struct LegacyCategoryRule: Codable {
        let id: UUID
        var enabled: Bool
        var priority: Int
        var matchScope: String
        var matchType: String
        var pattern: String
        var category: TransactionCategory
        let createdAt: Date
        var updatedAt: Date
    }
}

// MARK: - Taxonomy bridge

/// Maps the 9-case recurring taxonomy onto the 14-case per-transaction taxonomy.
extension PaymentCategory {
    var asTransactionCategory: TransactionCategory {
        switch self {
        case .streaming, .software, .telecom: return .abosDigital
        case .insurance:                      return .versicherungen
        case .utilities:                      return .wohnenKredit
        case .membership:                     return .freizeit
        case .finance:                        return .sparen
        case .transport:                      return .mobilitaet
        case .other:                          return .sonstiges
        }
    }
}
