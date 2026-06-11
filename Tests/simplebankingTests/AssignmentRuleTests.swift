import XCTest
@testable import simplebanking

final class AssignmentRuleTests: XCTestCase {

    private let storageKey = "assignmentRules.v1"
    private let migratedFlag = "assignmentRules.migratedFromCategoryRules"
    private let raMigrated = "recurringAssignments.migratedFromLegacy.v1"
    private let raStore = "recurringAssignments.v1"

    override func setUp() {
        super.setUp()
        clearAll()
        // Skip RecurringAssignments legacy migration so applyRecurring tests are isolated.
        UserDefaults.standard.set(true, forKey: raMigrated)
    }
    override func tearDown() { clearAll(); super.tearDown() }
    private func clearAll() {
        let d = UserDefaults.standard
        [storageKey, migratedFlag, "categoryUserRules", raStore, raMigrated,
         "fixedCosts.excluded", "subscriptions.userConfirmed", "subscriptions.userExcluded", "subscriptions.tabOverrides"]
            .forEach { d.removeObject(forKey: $0) }
    }

    // MARK: helpers

    private func tx(creditor: String? = nil, debtor: String? = nil, amount: Double,
                    purpose: String = "", e2e: String = "X") -> TransactionsResponse.Transaction {
        let amt = TransactionsResponse.Amount(currency: "EUR", amount: String(format: "%.2f", amount))
        return TransactionsResponse.Transaction(
            bookingDate: "2026-06-01", valueDate: "2026-06-01", status: "booked",
            endToEndId: e2e, amount: amt,
            creditor: creditor.map { TransactionsResponse.Party(name: $0, iban: nil, bic: nil) },
            debtor: debtor.map { TransactionsResponse.Party(name: $0, iban: nil, bic: nil) },
            remittanceInformation: purpose.isEmpty ? nil : [purpose],
            additionalInformation: nil, purposeCode: nil
        )
    }

    private func rule(_ conds: [RuleCondition], category: TransactionCategory? = nil,
                      recurring: RecurringAction? = nil, enabled: Bool = true, priority: Int = 100,
                      created: TimeInterval = 0) -> AssignmentRule {
        AssignmentRule(id: UUID(), enabled: enabled, priority: priority, conditions: conds,
                       setCategory: category, recurring: recurring,
                       createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: created))
    }
    private func cond(_ f: RuleField, _ o: RuleOperator, _ v: String) -> RuleCondition {
        RuleCondition(field: f, op: o, value: v)
    }

    // MARK: text operators

    func test_textOperators() {
        let t = tx(creditor: "NETFLIX.COM", amount: -12.99)
        XCTAssertTrue(rule([cond(.empfaenger, .contains, "netflix")]).matches(t))
        XCTAssertFalse(rule([cond(.empfaenger, .notContains, "netflix")]).matches(t))
        XCTAssertTrue(rule([cond(.empfaenger, .notContains, "spotify")]).matches(t))
        XCTAssertTrue(rule([cond(.empfaenger, .equals, "netflix.com")]).matches(t))
        XCTAssertFalse(rule([cond(.empfaenger, .equals, "netflix")]).matches(t))
        XCTAssertTrue(rule([cond(.empfaenger, .notEquals, "netflix")]).matches(t))
    }

    // MARK: amount operators

    func test_amountOperators() {
        let t = tx(creditor: "X", amount: -49.99)
        XCTAssertTrue(rule([cond(.amount, .amountEquals, "49.99")]).matches(t))
        XCTAssertTrue(rule([cond(.amount, .amountEquals, "49,99")]).matches(t))   // comma decimal
        XCTAssertTrue(rule([cond(.amount, .amountGreater, "40")]).matches(t))
        XCTAssertFalse(rule([cond(.amount, .amountGreater, "50")]).matches(t))
        XCTAssertTrue(rule([cond(.amount, .amountLess, "50")]).matches(t))
    }

    // MARK: AND

    func test_multiCondition_AND() {
        let t = tx(debtor: "Maik", amount: -100, purpose: "Miete")
        let r = rule([cond(.absender, .contains, "maik"), cond(.amount, .amountEquals, "100")])
        XCTAssertTrue(r.matches(t))
        // one condition fails → no match
        let r2 = rule([cond(.absender, .contains, "maik"), cond(.amount, .amountEquals, "999")])
        XCTAssertFalse(r2.matches(t))
    }

    func test_emptyConditions_neverMatch() {
        XCTAssertFalse(rule([]).matches(tx(creditor: "X", amount: -1)))
    }

    // MARK: OR / direction / interval

    func test_conjunction_OR() {
        let t = tx(creditor: "Netflix", amount: -5)
        var conds = [cond(.empfaenger, .contains, "spotify"), cond(.empfaenger, .contains, "netflix")]
        conds[1].joiner = .any
        XCTAssertTrue(rule(conds).matches(t))   // spotify ODER netflix → netflix matcht
        conds[1].joiner = .all
        XCTAssertFalse(rule(conds).matches(t))  // spotify UND netflix → scheitert
    }

    func test_direction() {
        let expense = tx(creditor: "X", amount: -10)
        let income  = tx(debtor: "Y", amount: 10)
        XCTAssertTrue(rule([cond(.direction, .equals, "Zahlung")]).matches(expense))
        XCTAssertFalse(rule([cond(.direction, .equals, "Zahlung")]).matches(income))
        XCTAssertTrue(rule([cond(.direction, .equals, "Eingang")]).matches(income))
        XCTAssertTrue(rule([cond(.direction, .notEquals, "Zahlung")]).matches(income))
    }

    func test_interval_cadence() {
        let t = tx(creditor: "Spotify", amount: -9.99)
        let r = rule([cond(.interval, .equals, PaymentFrequency.monthly.rawValue)])
        XCTAssertTrue(r.matches(t, cadence: .monthly))
        XCTAssertFalse(r.matches(t, cadence: .quarterly))
        // P1-Fix: ohne Cadence ist die Intervallbedingung NICHT erfüllt (sonst matcht
        // eine „monatlich → X"-Regel im Live-Categorizer praktisch jede Buchung).
        XCTAssertFalse(r.matches(t, cadence: nil))
    }

    func test_intervalOnlyRule_doesNotCategorizeWithoutCadence() {
        // firstCategory ruft ohne Cadence auf → Intervall-Regel darf NICHT greifen.
        let t = tx(creditor: "Irgendwer", amount: -3.50)
        let r = rule([cond(.interval, .equals, PaymentFrequency.monthly.rawValue)], category: .abosDigital)
        XCTAssertNil(AssignmentRules.firstCategory(for: t, rules: [r]))
    }

    // MARK: firstCategory

    func test_firstCategory_priorityAndDisabledAndCategoryOnly() {
        let t = tx(creditor: "Netflix", amount: -12.99)
        let low  = rule([cond(.empfaenger, .contains, "netflix")], category: .shopping, priority: 50, created: 100)
        let high = rule([cond(.empfaenger, .contains, "netflix")], category: .abosDigital, priority: 10, created: 200)
        XCTAssertEqual(AssignmentRules.firstCategory(for: t, rules: [low, high]), .abosDigital)

        let disabled = rule([cond(.empfaenger, .contains, "netflix")], category: .abosDigital, enabled: false)
        XCTAssertNil(AssignmentRules.firstCategory(for: t, rules: [disabled]))

        // recurring-only rule (no category) is ignored by firstCategory
        let recurringOnly = rule([cond(.empfaenger, .contains, "netflix")], recurring: .abo)
        XCTAssertNil(AssignmentRules.firstCategory(for: t, rules: [recurringOnly]))
    }

    // MARK: migration

    func test_migrationFromCategoryRules() {
        struct LegacyRule: Codable {
            let id = UUID(); let enabled = true; let priority = 100
            let matchScope: String; let matchType: String; let pattern: String
            let category: TransactionCategory
            let createdAt = Date(timeIntervalSince1970: 0); let updatedAt = Date(timeIntervalSince1970: 0)
        }
        let legacy = [LegacyRule(matchScope: "empfaenger", matchType: "contains", pattern: "rewe", category: .essenAlltag)]
        UserDefaults.standard.set(try! JSONEncoder().encode(legacy), forKey: "categoryUserRules")

        let migrated = AssignmentRules.all()   // triggers migration
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated.first?.conditions.first?.field, .empfaenger)
        XCTAssertEqual(migrated.first?.conditions.first?.value, "rewe")
        XCTAssertEqual(migrated.first?.setCategory, .essenAlltag)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: migratedFlag))
    }

    // MARK: applyRecurring

    func test_applyRecurring_excludeAndTab() {
        let netflixTxs = [tx(creditor: "Netflix", amount: -12.99), tx(creditor: "Netflix", amount: -12.99, e2e: "Y")]
        let excludeRule = rule([cond(.empfaenger, .contains, "netflix")], recurring: .exclude)
        AssignmentRules.applyRecurring(excludeRule, to: netflixTxs)
        XCTAssertTrue(RecurringAssignments.current().isExcluded("netflix"))

        clearAll(); UserDefaults.standard.set(true, forKey: raMigrated)
        let vertragRule = rule([cond(.empfaenger, .contains, "netflix")], recurring: .vertrag)
        AssignmentRules.applyRecurring(vertragRule, to: netflixTxs)
        let a = RecurringAssignments.current().assignment(for: "netflix")
        XCTAssertEqual(a.state, .confirmed)
        XCTAssertEqual(a.tab, SubscriptionTab.vertraege.rawValue)
    }
}
